"""Strict bounded collection v2 framing. Diagnostic protocol.py remains frozen.

SCHEMAS contains the full JSON Schema subset enforced by both implementations.
Trial fences bound source identities using [begin.next_sequence, end.next_sequence).
"""
from dataclasses import dataclass
from enum import IntEnum
import json
import math
import struct
from . import protocol as legacy

MAGIC = b'USI2'
VERSION = 2
PORT = 5559
HEADER = struct.Struct('!4sHHII')
MAX_METADATA = 65_536
MAX_PAYLOAD = 16_777_216
MAX_BATCH = 64
MAX_NESTING = 32
U64_MAX = 2**64 - 1
ProtocolError = legacy.ProtocolError


class MessageType(IntEnum):
    HELLO = 1
    FRAME = 2
    PING = 3
    PONG = 4
    HEALTH = 5
    POSES = 6
    PRESSURE = 7
    TRIGGER = 8
    BLE_CLOCK = 9
    TRIAL_COMMAND = 10
    TRIAL_STATUS = 11


@dataclass(frozen=True)
class Packet:
    message_type: MessageType
    metadata: dict
    payload: bytes = b''


STREAM_IDS = ('main_rgb', 'raw_depth', 'depth_confidence', 'camera_pose', 'tracking',
              'camera_calibration', 'ultrawide', 'pressures', 'trigger', 'seal',
              'trial_metadata', 'timing', 'health', 'pump_command', 'pump_feedback', 'tcp', 'raw_imu', 'audio')


FULL_REQUIRED_STREAMS = STREAM_IDS[:13]
CORE_REQUIRED_STREAMS = tuple(s for s in FULL_REQUIRED_STREAMS if s != 'ultrawide')
FENCED_STREAMS = ('main_rgb','camera_pose','ultrawide','pressures','trigger')

def obj(properties, optional=()):
    return dict(type='object', properties=properties,
                required=[k for k in properties if k not in optional], additionalProperties=False)


def arr(items, low=0, high=MAX_BATCH):
    return dict(type='array', items=items, minItems=low, maxItems=high)


def choice(*values): return dict(enum=list(values))
def nullable(schema): return dict(anyOf=[schema, dict(type='null')])
UINT = dict(type='integer', minimum=0, maximum=U64_MAX)
NUMBER = dict(type='number')
TIME = dict(type='number', minimum=0)
STRING = dict(type='string', minLength=1, maxLength=512)
TEXT = dict(type='string', maxLength=4096)
BOOL = dict(type='boolean')
STREAM = choice(*STREAM_IDS)
V3 = arr(NUMBER, 3, 3)
Q4 = arr(NUMBER, 4, 4)
M9 = arr(NUMBER, 9, 9)
M16 = arr(NUMBER, 16, 16)
COUNTER = obj(dict(stream_id=STREAM, source_id=STRING, epoch_id=STRING,
    source_count=nullable(UINT), received_count=nullable(UINT), writer_accepted_count=nullable(UINT),
    queue_overflow_count=nullable(UINT), rejected_count=nullable(UINT), duplicate_count=nullable(UINT),
    missing_ranges=arr(obj(dict(start=UINT, end_exclusive=UINT)), 0, 256)))
FENCE = obj(dict(stream_id=choice(*FENCED_STREAMS), source_id=STRING, epoch_id=STRING, next_sequence=UINT))
CAPABILITY = obj(dict(stream_id=STREAM, available=BOOL, reason=nullable(TEXT), schema=STRING,
                      units=STRING, source_id=nullable(STRING), epoch_id=nullable(STRING)))
CHAMBER = obj(dict(sensor_index=dict(type='integer', minimum=0, maximum=2),
                   sector_index=dict(type='integer', minimum=0, maximum=2),
                   seal_on_kpa_abs=TIME, seal_off_kpa_abs=TIME, persistence_ns=UINT))
CALIBRATION = obj(dict(calibration_id=STRING, chambers=arr(CHAMBER,3,3),
                       ambient_kpa_abs=nullable(TIME), provenance=TEXT))
CONFIG = obj(dict(pressure_stale_ns=UINT, trigger_stale_ns=UINT, vision_stale_ns=UINT,
    host_status_stale_ns=UINT, mandatory_stale_grace_ns=UINT, host_heartbeat_ns=UINT,
    trigger_heartbeat_ns=UINT, target_fps=dict(type='number',exclusiveMinimum=0,maximum=240)))
SNAPSHOT = obj(dict(session_id=STRING, task_label=STRING, gripper_id=STRING,
    profile=choice('full','core'), calibration=nullable(CALIBRATION), configuration=CONFIG,
    capabilities=arr(CAPABILITY,1,32), required_streams=arr(STREAM,1,32),
    missing_modalities=arr(STREAM,0,32)))
POSE = obj(dict(frame_seq=UINT, arkit_timestamp_s=TIME, phone_uptime_ns=UINT,
    camera_transform_row_major=M16, position_m=V3, quaternion_xyzw=Q4,
    tracking_state=choice('normal','limited','not_available'), tracking_reason=TEXT, pose_valid=BOOL))
PRESSURE = obj(dict(sequence=UINT, raw_sequence=dict(type='integer',minimum=0,maximum=2**32-1),
    source_time_us=UINT, phone_receive_ns=UINT,
    pressure_centi_pa=arr(dict(type='integer',minimum=-(2**31),maximum=2**31-1),3,3),
    quality_mask=dict(type='integer',minimum=0,maximum=7)))
SENSOR_ID = dict(source_id=STRING, boot_id=STRING, connection_id=STRING, phone_session_id=STRING)
DIM = dict(type='integer',minimum=1,maximum=8192)
MODALITY = obj(dict(encoding=STRING,width=DIM,height=DIM,length=dict(type='integer',minimum=1,maximum=MAX_PAYLOAD)), optional=())
DEPTH = obj(dict(**MODALITY['properties'],association=choice('same_arframe_no_independent_timestamp')))
FRAME = obj(dict(session_id=STRING, world_epoch_id=STRING, stream_id=choice('main_rgb','ultrawide'),
    frame_seq=UINT, arkit_timestamp_s=TIME, phone_uptime_ns=UINT,
    world_frame=choice('arkit_world'), camera_frame=choice('arkit_camera'), image_orientation=choice('sensor_native'),
    camera_transform_row_major=M16, position_m=V3, quaternion_xyzw=Q4,
    tracking_state=choice('normal','limited','not_available'), tracking_reason=TEXT, pose_valid=BOOL,
    intrinsics_row_major=M9, source_image_size=arr(DIM,2,2), rgb_intrinsics_row_major=M9,
    rgb=MODALITY,depth=nullable(DEPTH),confidence=nullable(MODALITY),
    counters=obj(dict(acquired_frames=UINT,encode_drops=UINT,transport_drops=UINT)),
    thermal_state=choice('nominal','fair','serious','critical','unknown')))
FRAME['properties']['stream_id'] = choice('main_rgb')
ULTRAWIDE = obj(dict(session_id=STRING,world_epoch_id=STRING,stream_id=choice('ultrawide'),
    frame_seq=UINT,source_timestamp_s=TIME,source_clock=STRING,phone_uptime_ns=UINT,
    camera_frame=choice('ultrawide_camera'),image_orientation=choice('sensor_native'),
    intrinsics_row_major=M9,source_image_size=arr(DIM,2,2),rgb_intrinsics_row_major=M9,rgb=MODALITY,
    counters=obj(dict(acquired_frames=UINT,encode_drops=UINT,transport_drops=UINT)),
    thermal_state=choice('nominal','fair','serious','critical','unknown')))
FRAMES = {'main_rgb':FRAME,'ultrawide':ULTRAWIDE}
REQUEST_BASE = dict(action=choice('prepare','begin','stop','status'),request_id=STRING,trial_id=STRING,expected_revision=UINT)
REQUESTS = {
    'prepare': obj(dict(**REQUEST_BASE,snapshot=SNAPSHOT)),
    'begin': obj(dict(**REQUEST_BASE,fences=arr(FENCE,1,32))),
    'stop': obj(dict(**REQUEST_BASE,fences=arr(FENCE,1,32),counters=arr(COUNTER,0,32))),
    'status': obj(REQUEST_BASE),
}
for _action, _request_schema in REQUESTS.items():
    _request_schema['properties'] = dict(_request_schema['properties'], action=choice(_action))
SCHEMAS = {
    'HELLO': obj(dict(role=choice('host','phone'),protocol_version=choice(2),session_id=STRING,
                      capabilities=arr(CAPABILITY,0,32),profiles=arr(choice('full','core'),0,2)),
                 optional=('session_id','capabilities','profiles')),
    'FRAME': dict(anyOf=list(FRAMES.values())),
    'PING': obj(dict(ping_id=UINT,host_send_ns=UINT)),
    'PONG': obj(dict(ping_id=UINT,host_send_ns=UINT,phone_receive_ns=UINT,phone_send_ns=UINT,session_id=STRING)),
    'HEALTH': obj(dict(session_id=STRING,event=STRING,message=TEXT,counters=arr(COUNTER,0,32),
                       capabilities=arr(CAPABILITY,0,32),thermal_state=choice('nominal','fair','serious','critical','unknown')),
                  optional=('capabilities','thermal_state')),
    'POSES': obj(dict(session_id=STRING,world_epoch_id=STRING,samples=arr(POSE,1,MAX_BATCH))),
    'PRESSURE': obj(dict(**SENSOR_ID,samples=arr(PRESSURE,1,MAX_BATCH))),
    'TRIGGER': obj(dict(**SENSOR_ID,sequence=UINT,raw_sequence=dict(type='integer',minimum=0,maximum=2**32-1),
        source_time_us=UINT,phone_receive_ns=UINT,pressed=BOOL,event=choice('transition','heartbeat'))),
    'BLE_CLOCK': obj(dict(link=choice('ble','usb'),exchange_id=STRING,source_id=STRING,epoch_id=STRING,
        t1_ns=UINT,t2_ns=UINT,t3_ns=UINT,t4_ns=UINT,
        mapping=obj(dict(valid=BOOL,scale=nullable(NUMBER),offset_ns=nullable(NUMBER),uncertainty_ns=nullable(TIME))))),
    'TRIAL_COMMAND': dict(anyOf=list(REQUESTS.values())),
    'TRIAL_STATUS': obj(dict(host_session_id=STRING,host_time_ns=UINT,request_id=nullable(STRING),trial_id=nullable(STRING),
        revision=UINT,state=choice('idle','preparing','recording','finalizing','saved','incomplete'),ready=BOOL,
        profile=nullable(choice('full','core')),required_streams=arr(STREAM,0,32),missing_modalities=arr(STREAM,0,32),
        missing_required_streams=arr(STREAM,0,32),
        reason=nullable(TEXT),bag_path=nullable(STRING),verification=choice('pending','passed','failed'),
        counters=arr(COUNTER,0,32))),
}


def _require(condition, message):
    if not condition: raise ProtocolError(message)


def _finite(value, depth=0):
    _require(depth <= MAX_NESTING, 'metadata nesting exceeds 32')
    if type(value) is dict:
        _require(all(type(k) is str for k in value), 'JSON object keys must be strings')
        for child in value.values(): _finite(child,depth+1)
    elif type(value) is list:
        for child in value: _finite(child,depth+1)
    elif type(value) is float: _require(math.isfinite(value),'nonfinite JSON')
    elif type(value) is int: _require(-(2**63) <= value <= U64_MAX,'integer token outside signed/unsigned 64-bit domain')
    else: _require(value is None or type(value) in (str,int,bool),'invalid JSON value')


def _schema(value, schema, path='$'):
    if 'anyOf' in schema:
        for candidate in schema['anyOf']:
            try: _schema(value,candidate,path); return
            except ProtocolError: pass
        raise ProtocolError(path + ': no matching schema')
    if 'enum' in schema:
        _require(any(type(value) is type(v) and value == v for v in schema['enum']),path+': invalid enum'); return
    kind = schema['type']
    ok = {'object':type(value) is dict, 'array':type(value) is list,
          'integer':type(value) is int, 'number':type(value) in (int,float),
          'boolean':type(value) is bool, 'string':type(value) is str, 'null':value is None}[kind]
    _require(ok,path+': expected '+kind)
    if kind == 'object':
        _require(all(k in value for k in schema['required']),path+': missing required field')
        _require(set(value) <= set(schema['properties']),path+': unknown field')
        for key, child in value.items(): _schema(child,schema['properties'][key],path+'.'+key)
    elif kind == 'array':
        _require(schema['minItems'] <= len(value) <= schema['maxItems'],path+': array length')
        for child in value: _schema(child,schema['items'],path+'[]')
    elif kind == 'string':
        _require(schema.get('minLength',0) <= len(value) <= schema['maxLength'],path+': string length')
    elif kind in ('integer','number'):
        if 'minimum' in schema: _require(value >= schema['minimum'],path+': below minimum')
        if 'maximum' in schema: _require(value <= schema['maximum'],path+': above maximum')
        if 'exclusiveMinimum' in schema: _require(value > schema['exclusiveMinimum'],path+': below exclusive minimum')


def _pose(meta):
    try: norm = math.hypot(*meta['quaternion_xyzw'])
    except (OverflowError, ValueError) as exc: raise ProtocolError('invalid quaternion magnitude') from exc
    _require(math.isfinite(norm) and abs(norm-1) <= 1e-3,'quaternion must be normalized')
    _require(meta['tracking_state'] != 'not_available' or not meta['pose_valid'],'unavailable valid pose')


def _unique(items, keys):
    values = [tuple(item[k] for k in keys) for item in items]
    _require(len(set(values)) == len(values),'duplicate identities')


def validate_metadata(kind, metadata, payload_length=0):
    _require(type(kind) in (int,MessageType), 'invalid message type')
    try: kind = MessageType(kind)
    except ValueError as exc: raise ProtocolError('unknown message type') from exc
    _finite(metadata)
    _require(type(payload_length) is int and 0 <= payload_length <= MAX_PAYLOAD,'payload length out of bounds')
    _require(kind == MessageType.FRAME or payload_length == 0,'only FRAME carries payload')
    _schema(metadata,SCHEMAS[kind.name])
    if kind == MessageType.FRAME:
        if metadata['stream_id'] == 'main_rgb': legacy._validate_frame(metadata,payload_length)
        else:
            _require(legacy._modality(metadata['rgb'],'jpeg') == payload_length,'ultrawide payload mismatch')
            _require(metadata['counters']['acquired_frames'] >= metadata['frame_seq']+1,'acquired counter precedes frame')
    if kind == MessageType.POSES:
        for sample in metadata['samples']: _pose(sample)
        _require(all(a['frame_seq'] < b['frame_seq'] for a,b in zip(metadata['samples'],metadata['samples'][1:])), 'pose batch order')
    if kind in (MessageType.PRESSURE,MessageType.TRIGGER):
        samples = metadata['samples'] if kind == MessageType.PRESSURE else [metadata]
        for sample in samples: _require(sample['sequence'] % 2**32 == sample['raw_sequence'],'raw sequence mismatch')
        _require(all(a['sequence'] < b['sequence'] for a,b in zip(samples,samples[1:])), 'pressure batch order')
    for key, fields in [('counters',('stream_id','source_id','epoch_id')),('fences',('stream_id',))]:
        if key in metadata and type(metadata[key]) is list:
            _unique(metadata[key],fields)
    for counter in (metadata.get('counters',[]) if kind != MessageType.FRAME else []):
        end = -1
        for gap in counter['missing_ranges']:
            _require(end <= gap['start'] < gap['end_exclusive'],'invalid/overlapping missing range'); end = gap['end_exclusive']
    if kind == MessageType.BLE_CLOCK:
        mapping = metadata['mapping']
        _require(metadata['t3_ns'] >= metadata['t2_ns'] and metadata['t4_ns'] >= metadata['t1_ns'],'invalid exchange ordering')
        if mapping['valid']:
            _require(all(mapping[k] is not None for k in ('scale','offset_ns','uncertainty_ns')) and mapping['scale'] > 0,'invalid valid clock mapping')
    for capability in metadata.get('capabilities',[]):
        _require(capability['available'] or bool(capability['reason']),'unavailable capability needs reason')
        _require(not capability['available'] or (capability['source_id'] is not None and capability['epoch_id'] is not None),'available capability needs source identity')
    if kind == MessageType.TRIAL_COMMAND and metadata['action'] == 'prepare':
        snap = metadata['snapshot']; _unique(snap['capabilities'],('stream_id',))
        required = FULL_REQUIRED_STREAMS if snap['profile'] == 'full' else CORE_REQUIRED_STREAMS
        _require(set(required) <= set(snap['required_streams']),'profile missing required inventory')
        for capability in snap['capabilities']:
            _require(capability['available'] or bool(capability['reason']),'unavailable capability needs reason')
            _require(not capability['available'] or (capability['source_id'] is not None and capability['epoch_id'] is not None),'available capability needs source identity')
        _require(len(set(snap['required_streams'])) == len(snap['required_streams']), 'duplicate required streams')
        _require(len(set(snap['missing_modalities'])) == len(snap['missing_modalities']), 'duplicate missing streams')
        _require(not (set(snap['required_streams']) & set(snap['missing_modalities'])),'required modality missing')
        _require(snap['profile'] != 'full' or 'ultrawide' in snap['required_streams'],'full requires ultrawide')
        _require(snap['profile'] != 'core' or 'ultrawide' in snap['missing_modalities'],'core declares ultrawide missing')
        if snap['calibration'] is not None:
            cal = snap['calibration']; _unique(cal['chambers'],('sensor_index',)); _unique(cal['chambers'],('sector_index',))
            _require(all(c['seal_on_kpa_abs'] < c['seal_off_kpa_abs'] for c in cal['chambers']),'invalid calibration thresholds')
    if kind == MessageType.TRIAL_STATUS:
        required=metadata['required_streams']; missing=metadata['missing_modalities']; unavailable=metadata['missing_required_streams']; profile=metadata['profile']
        _require(len(set(required)) == len(required) and len(set(missing)) == len(missing) and len(set(unavailable)) == len(unavailable),'duplicate inventory streams')
        _require(not set(required) & set(missing),'required modality missing')
        _require(set(unavailable) <= set(required),'unavailable stream must be required')
        if metadata['state'] in ('recording','saved'):
            _require(not unavailable,'recording/saved assurance requires all required streams')
        if profile is None:
            _require(metadata['state'] == 'idle' and not required and not missing and not unavailable,'unselected profile only allowed for empty idle inventory')
        else:
            mandatory=FULL_REQUIRED_STREAMS if profile == 'full' else CORE_REQUIRED_STREAMS
            _require(set(mandatory) <= set(required),'status profile missing required inventory')
            _require(profile != 'core' or 'ultrawide' in missing,'core status declares ultrawide missing')
        _require(metadata['state'] == 'idle' or metadata['trial_id'] is not None,'missing active trial ID')
        if metadata['state'] == 'saved':
            _require(metadata['verification'] == 'passed' and metadata['bag_path'] is not None,'saved requires verified bag')
        _require(metadata['verification'] != 'passed' or metadata['state'] == 'saved','verification passed without saved')


def _header(data):
    _require(len(data) == HEADER.size,'truncated header')
    magic,version,kind,metadata_length,payload_length = HEADER.unpack(data)
    _require(magic == MAGIC,'bad magic'); _require(version == VERSION,'bad version')
    try: kind = MessageType(kind)
    except ValueError as exc: raise ProtocolError('unknown type') from exc
    _require(2 <= metadata_length <= MAX_METADATA and payload_length <= MAX_PAYLOAD,'invalid length')
    _require(kind == MessageType.FRAME or payload_length == 0,'unexpected payload')
    return kind,metadata_length,payload_length


def encode_packet(message_type, metadata, payload=b''):
    """Return bounded v2 bytes; strict validation precedes JSON encoding."""
    _require(type(message_type) in (int,MessageType),'invalid type')
    try: kind = MessageType(message_type)
    except ValueError as exc: raise ProtocolError('unknown type') from exc
    _require(isinstance(payload,(bytes,bytearray,memoryview)),'payload must be bytes')
    validate_metadata(kind,metadata,len(payload))
    try: body = json.dumps(metadata,sort_keys=True,separators=(',',':'),ensure_ascii=False,allow_nan=False).encode('utf-8')
    except (ValueError,UnicodeError,RecursionError) as exc: raise ProtocolError('invalid JSON') from exc
    _require(len(body) <= MAX_METADATA,'metadata too large')
    return HEADER.pack(MAGIC,VERSION,kind,len(body),len(payload)) + body + bytes(payload)


def _json(data):
    value = legacy._json(data)
    _finite(value)
    return value


def decode_packet(data):
    """Decode exactly one complete packet; trailing bytes are rejected."""
    kind,ml,pl = _header(data[:HEADER.size])
    _require(len(data) == HEADER.size+ml+pl,'packet length mismatch')
    metadata = _json(data[HEADER.size:HEADER.size+ml])
    validate_metadata(kind,metadata,pl)
    return Packet(kind,metadata,bytes(data[HEADER.size+ml:]))


def recv_packet(sock):
    """Blocking recv reader; None only at clean packet boundary EOF.

    On timeout close/reconnect rather than discarding a partial packet.
    Header and metadata are validated before reading/allocating image payload.
    """
    header = legacy.recv_exact(sock,HEADER.size,clean_eof=True)
    if header is None: return None
    kind,ml,pl = _header(header)
    metadata = _json(legacy.recv_exact(sock,ml))
    validate_metadata(kind,metadata,pl)
    return Packet(kind,metadata,legacy.recv_exact(sock,pl))


def slice_frame(packet):
    """Return legacy.FrameParts of validated zero-copy RGB/depth/confidence views."""
    _require(packet.message_type == MessageType.FRAME,'expected FRAME')
    validate_metadata(packet.message_type,packet.metadata,len(packet.payload))
    view = memoryview(packet.payload); offset = packet.metadata['rgb']['length']
    rgb = view[:offset]; depth = confidence = None
    if packet.metadata.get('depth') is not None:
        end = offset + packet.metadata['depth']['length']; depth = view[offset:end]; offset=end
    if packet.metadata.get('confidence') is not None: confidence=view[offset:]
    return legacy.FrameParts(rgb,depth,confidence)
