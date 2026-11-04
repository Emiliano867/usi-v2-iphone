"""Validated v2 packets to serialized ROS records; source clocks stay source clocks."""
import io
import hashlib
import json
from array import array

from .collection_protocol import MessageType, slice_frame, validate_metadata
from .recorder import Record


def _json(value): return json.dumps(value,sort_keys=True,separators=(',',':'),allow_nan=False)

def _header(msg,wall_ns,frame):
    msg.header.stamp.sec=wall_ns//1_000_000_000
    msg.header.stamp.nanosec=wall_ns%1_000_000_000
    msg.header.frame_id=frame

def _serialize(topic,msg,stream,source,epoch,sequence,wall_ns):
    from rclpy.serialization import serialize_message
    return Record(topic,msg.__class__.__module__.replace('.msg._','/msg/').split('/msg/')[0]+'/msg/'+msg.__class__.__name__,
                  serialize_message(msg),wall_ns,stream,source,epoch,sequence)

def _source(stream,meta,sequence,monotonic_ns,wall_ns, *, source_id=None,epoch_id=None,sample=None):
    from usi_collection_msgs.msg import SourceRecord
    source=SourceRecord()
    source.stream_id=stream
    source.source_id=source_id or meta.get('source_id',meta.get('session_id',''))
    source.epoch_id=epoch_id or meta.get('boot_id',meta.get('world_epoch_id',''))
    source.sequence=sequence
    sample=sample or meta
    source.raw_sequence=sample.get('raw_sequence',0)
    source.has_raw_sequence='raw_sequence' in sample
    source.source_time_us=sample.get('source_time_us',0)
    source.has_source_time_us='source_time_us' in sample
    source.phone_receive_ns=sample.get('phone_receive_ns',0)
    source.has_phone_receive_ns='phone_receive_ns' in sample
    source.phone_uptime_ns=sample.get('phone_uptime_ns',meta.get('phone_uptime_ns',0))
    source.has_phone_uptime_ns='phone_uptime_ns' in sample or 'phone_uptime_ns' in meta
    source.arkit_timestamp_s=sample.get('arkit_timestamp_s',meta.get('arkit_timestamp_s',0.0))
    source.has_arkit_timestamp='arkit_timestamp_s' in sample or 'arkit_timestamp_s' in meta
    source.source_timestamp_s=sample.get('source_timestamp_s',meta.get('source_timestamp_s',0.0))
    source.has_source_timestamp='source_timestamp_s' in sample or 'source_timestamp_s' in meta
    source.host_receive_monotonic_ns=monotonic_ns
    source.host_receive_wall_ns=wall_ns
    source.connection_id=meta.get('connection_id','')
    source.phone_session_id=meta.get('phone_session_id',meta.get('session_id',''))
    source.metadata_json=_json(meta if sample is meta else sample)
    _header(source,wall_ns,'arkit_camera' if stream in ('camera_pose','main_rgb') else stream)
    return source

def _validate_pixels(meta,parts):
    import numpy as np
    from PIL import Image
    for descriptor,data in [(meta['rgb'],parts.rgb)]:
        with Image.open(io.BytesIO(data.tobytes())) as image:
            image.verify()
        with Image.open(io.BytesIO(data.tobytes())) as image:
            if image.size != (descriptor['width'],descriptor['height']): raise ValueError('JPEG dimensions differ')
    # Preserve every raw IEEE754 bit pattern. Nonfinite/nonpositive pixels get
    # mask 0 below; changing those bytes would falsify the source plane.
    if parts.confidence is not None and np.frombuffer(parts.confidence,dtype=np.uint8).max(initial=0)>2:
        raise ValueError('invalid confidence level')

def _depth_mask(data):
    import numpy as np
    values=np.frombuffer(data,dtype='<f4')
    return (np.isfinite(values) & (values>0)).astype(np.uint8).tobytes()

def _legacy_boot_number(boot_id):
    if boot_id.isdecimal():
        value=int(boot_id)
        if value<=2**64-1: return value
    return int.from_bytes(hashlib.sha256(boot_id.encode('utf-8')).digest()[:8],'big')

def camera_calibration_snapshot(meta):
    """Freeze prepared calibration; JPEG length and per-frame K may vary."""
    return dict(intrinsics_row_major=meta['intrinsics_row_major'],
        rgb_intrinsics_row_major=meta['rgb_intrinsics_row_major'],
        source_image_size=meta['source_image_size'],
        rgb={k:meta['rgb'][k] for k in ('encoding','width','height')},
        depth=None if meta['depth'] is None else {k:meta['depth'][k] for k in ('encoding','width','height','association')},
        confidence=None if meta['confidence'] is None else {k:meta['confidence'][k] for k in ('encoding','width','height')},
        world_frame=meta['world_frame'],camera_frame=meta['camera_frame'],
        image_orientation=meta['image_orientation'],world_epoch_id=meta['world_epoch_id'])

def camera_format(snapshot):
    return {k:snapshot[k] for k in ('source_image_size','rgb','world_frame',
                                    'camera_frame','image_orientation','world_epoch_id')}

def compatible_camera_format(current,prepared):
    if camera_format(current)!=camera_format(prepared): return False
    # Depth/confidence are actually delivered at an independent cadence. Their
    # absence on an RGB frame cannot redefine the prepared camera format.
    for stream in ('depth','confidence'):
        if current[stream] is not None and prepared[stream] is not None and current[stream]!=prepared[stream]:
            return False
    return True

def _legacy_timing(stream,sample,meta,wall,bridge_counts):
    from std_msgs.msg import UInt64MultiArray
    number=bridge_counts.get(stream,0)
    bridge_counts[stream]=number+1
    values=[number,sample['source_time_us'],wall,1]
    # Typed v2 uses set bit = valid; audited legacy timing uses set bit = error.
    if stream=='pressures': values.append((~sample['quality_mask']) & 7)
    values.extend((_legacy_boot_number(meta['boot_id']),sample['raw_sequence']))
    message=UInt64MultiArray(); message.data=values
    topic='/pressure_timing' if stream=='pressures' else '/trigger_timing'
    return _serialize(topic,message,'',meta['source_id'],meta['boot_id'],sample['sequence'],wall)

def validate_reopened_frame(msg):
    """Verify actual stored content after independent deserialization."""
    from PIL import Image
    if msg.encoding=='jpeg':
        with Image.open(io.BytesIO(bytes(msg.rgb_jpeg))) as image:
            image.verify()
        with Image.open(io.BytesIO(bytes(msg.rgb_jpeg))) as image:
            if image.size!=(msg.width,msg.height): raise ValueError('reopened JPEG dimensions differ')
    elif msg.encoding=='32FC1':
        if msg.stride!=msg.width*4 or len(msg.depth_le_f32)!=msg.stride*msg.height:
            raise ValueError('reopened depth stride/length')
        if bytes(msg.depth_valid_mask)!=_depth_mask(msg.depth_le_f32):
            raise ValueError('reopened depth validity mask differs from raw plane')
    elif msg.encoding=='mono8':
        if msg.stride!=msg.width or len(msg.confidence_level)!=msg.width*msg.height:
            raise ValueError('reopened confidence stride/length')
        if any(x>2 for x in msg.confidence_level): raise ValueError('reopened confidence content')
    else: raise ValueError('unknown stored frame encoding')

def records_for_packet(packet,host_receive_monotonic_ns,host_receive_wall_ns,seal_model=None,legacy_bridge_counts=None):
    """Return one or more typed records; callers validate before allocating payload."""
    from usi_collection_msgs.msg import FrameRecord, PressureRecord, TriggerRecord, ClockRecord, HealthRecord
    from geometry_msgs.msg import Vector3Stamped
    from sensor_msgs.msg import Joy
    kind=MessageType(packet.message_type); meta=packet.metadata
    validate_metadata(kind,meta,len(packet.payload))
    wall=host_receive_wall_ns; mono=host_receive_monotonic_ns
    if legacy_bridge_counts is None: legacy_bridge_counts={}
    records=[]
    if kind == MessageType.FRAME:
        parts=slice_frame(packet); _validate_pixels(meta,parts)
        seq=meta['frame_seq']; base=meta['stream_id']
        modalities=[(base,meta['rgb'],parts.rgb,'jpeg')]
        if parts.depth is not None: modalities.append(('raw_depth',meta['depth'],parts.depth,'32FC1'))
        if parts.confidence is not None: modalities.append(('depth_confidence',meta['confidence'],parts.confidence,'mono8'))
        for stream,desc,data,encoding in modalities:
            msg=FrameRecord(); msg.source=_source(stream,meta,seq,mono,wall)
            msg.encoding=encoding; msg.width=desc['width']; msg.height=desc['height']
            msg.stride=desc['width']*4 if stream=='raw_depth' else desc['width'] if stream=='depth_confidence' else 0
            msg.depth_present=parts.depth is not None; msg.confidence_present=parts.confidence is not None
            msg.depth_encoding='32FC1' if parts.depth is not None else ''
            msg.depth_association=meta['depth']['association'] if parts.depth is not None else ''
            # ROS accepts native uint8 arrays without scanning Python integers.
            # Keep conversion well below the camera's 16.7 ms frame interval.
            if stream in ('main_rgb','ultrawide'): msg.rgb_jpeg=array('B',data.tobytes())
            elif stream=='raw_depth':
                msg.depth_le_f32=array('B',data.tobytes())
                msg.depth_valid_mask=array('B',_depth_mask(data))
            else: msg.confidence_level=array('B',data.tobytes())
            records.append(_serialize('/usi_collection/'+stream,msg,stream,msg.source.source_id,msg.source.epoch_id,seq,wall))
    elif kind == MessageType.POSES:
        for sample in meta['samples']:
            msg=_source('camera_pose',meta,sample['frame_seq'],mono,wall,sample=sample)
            records.append(_serialize('/usi_collection/camera_pose',msg,'camera_pose',msg.source_id,msg.epoch_id,msg.sequence,wall))
            tracking=_source('tracking',meta,sample['frame_seq'],mono,wall,sample=sample)
            tracking.metadata_json=_json(dict(tracking_state=sample['tracking_state'],
                tracking_reason=sample['tracking_reason'],pose_valid=sample['pose_valid']))
            records.append(_serialize('/usi_collection/tracking',tracking,'tracking',tracking.source_id,tracking.epoch_id,tracking.sequence,wall))
    elif kind == MessageType.PRESSURE:
        for sample in meta['samples']:
            source=_source('pressures',meta,sample['sequence'],mono,wall,sample=sample)
            msg=PressureRecord(); msg.source=source
            msg.pressure_centi_pa=sample['pressure_centi_pa']; msg.quality_mask=sample['quality_mask']
            msg.pressure_kpa_abs=[x/100000 for x in sample['pressure_centi_pa']]
            records.append(_serialize('/usi_collection/pressures',msg,'pressures',source.source_id,source.epoch_id,source.sequence,wall))
            seal=_source('seal',meta,sample['sequence'],mono,wall,sample=sample)
            if seal_model:
                seal_model.update(msg.pressure_kpa_abs,quality_mask=sample['quality_mask'],received_ns=mono)
                state=seal_model.snapshot(mono)
                seal.metadata_json=_json(dict(calibration_id=state.calibration_id,states=state.states,
                    aggregate=state.aggregate,sealed_count=state.sealed_count,known_count=state.known_count,
                    pressure_sequence=sample['sequence']))
            else:
                seal.metadata_json=_json(dict(calibration_id=None,states=['uncalibrated']*3,
                    aggregate='unavailable',sealed_count=0,known_count=0,pressure_sequence=sample['sequence']))
            records.append(_serialize('/usi_collection/seal',seal,'seal',seal.source_id,seal.epoch_id,seal.sequence,wall))
            legacy=Vector3Stamped(); _header(legacy,wall,'pressure_sensor')
            # The audited legacy Vector3Stamped carries absolute Pa, not display kPa.
            legacy.vector.x,legacy.vector.y,legacy.vector.z=[x/100 for x in sample['pressure_centi_pa']]
            records.append(_serialize('/pressure',legacy,'',source.source_id,source.epoch_id,source.sequence,wall))
            records.append(_legacy_timing('pressures',sample,meta,wall,legacy_bridge_counts))
    elif kind == MessageType.TRIGGER:
        source=_source('trigger',meta,meta['sequence'],mono,wall)
        msg=TriggerRecord(); msg.source=source; msg.pressed=meta['pressed']; msg.suction_on=not meta['pressed']; msg.event=meta['event']
        records.append(_serialize('/usi_collection/trigger',msg,'trigger',source.source_id,source.epoch_id,source.sequence,wall))
        legacy=Joy(); _header(legacy,wall,'trigger'); legacy.buttons=[int(meta['pressed']),int(not meta['pressed'])]
        records.append(_serialize('/trigger',legacy,'',source.source_id,source.epoch_id,source.sequence,wall))
        records.append(_legacy_timing('trigger',meta,meta,wall,legacy_bridge_counts))
    elif kind == MessageType.BLE_CLOCK:
        msg=ClockRecord(); _header(msg,wall,'host_receipt'); msg.link=meta['link']; msg.exchange_id=meta['exchange_id']
        msg.source_id=meta['source_id']; msg.epoch_id=meta['epoch_id']
        for k in ('t1_ns','t2_ns','t3_ns','t4_ns'): setattr(msg,k,meta[k])
        mapping=meta['mapping']; msg.mapping_valid=mapping['valid']
        for field,key in [('mapping_scale','scale'),('mapping_offset_ns','offset_ns'),('mapping_uncertainty_ns','uncertainty_ns')]:
            setattr(msg,field,mapping[key] or 0.0)
            setattr(msg,'has_'+field,mapping[key] is not None)
        msg.host_receive_monotonic_ns=mono; msg.host_receive_wall_ns=wall
        msg.metadata_json=_json(meta)
        records.append(_serialize('/usi_collection/timing',msg,'timing',msg.source_id,msg.epoch_id,0,wall))
    elif kind == MessageType.HEALTH:
        msg=HealthRecord(); _header(msg,wall,'host_receipt'); msg.session_id=meta['session_id']; msg.event=meta['event']
        msg.message=meta['message']; msg.counters_json=_json(meta['counters']); msg.capabilities_json=_json(meta.get('capabilities',[]))
        msg.thermal_state=meta.get('thermal_state','unknown')
        records.append(_serialize('/usi_collection/health',msg,'health',msg.session_id,msg.session_id,0,wall))
    return records
