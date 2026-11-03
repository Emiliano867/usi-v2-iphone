"""Generated JPEG/depth/pressure/trigger data; this is software test evidence."""
import io
import json
import os
import re
import subprocess
import sys
from pathlib import Path

import pytest
from PIL import Image
from rclpy.serialization import deserialize_message

from usi_stream.collection_protocol import MessageType, Packet, validate_metadata
from usi_stream.ros_messages import records_for_packet
from usi_stream.recorder import BoundedRecorder, JazzyMcapStore
from usi_stream.collector import Collector, SCHEMA, UNITS


DOC=Path(__file__).parents[2]/'docs/collection-protocol-v2.md'

def example(name):
    return json.loads(re.search(r'### '+name+r' \([^\n]+\)\n\n```json\n(.*?)\n```',DOC.read_text(),re.S).group(1))


def _run_child(case,tmp_path,omitted='none'):
    env=os.environ.copy()
    env['PYTHONPATH']=str(Path(__file__).parents[2])+os.pathsep+env.get('PYTHONPATH','')
    result=subprocess.run([sys.executable,str(Path(__file__).resolve()),case,str(tmp_path),omitted],
                          env=env,text=True,capture_output=True,timeout=30)
    assert result.returncode==0,result.stdout+result.stderr


def test_generated_mcap_closes_reopens_and_deserializes(tmp_path):
    _run_child('direct',tmp_path)


def _direct_mcap_roundtrip(tmp_path):
    from rosidl_runtime_py.utilities import get_message
    frame=example('collection_frame')
    jpeg=io.BytesIO(); Image.new('RGB',(2,2),(12,23,34)).save(jpeg,format='JPEG')
    rgb=jpeg.getvalue()
    frame['rgb'].update(width=2,height=2,length=len(rgb))
    frame['source_image_size']=[2,2]
    # The depth plane is 2x2 tightly packed little-endian float32 meters.
    import struct
    depth=struct.pack('<4f',1.0,float('nan'),1.2,1.3)
    frame['depth'].update(width=2,height=2,length=len(depth))
    frame['confidence'].update(width=2,height=2,length=4)
    payload=rgb+depth+bytes([2,0,1,2])
    validate_metadata(MessageType.FRAME,frame,len(payload))
    packets=[Packet(MessageType.FRAME,frame,payload),
             Packet(MessageType.POSES,example('collection_poses')),
             Packet(MessageType.PRESSURE,example('collection_pressure')),
             Packet(MessageType.TRIGGER,example('collection_trigger'))]
    store=JazzyMcapStore(); writer=BoundedRecorder(store,tmp_path/'generated_fixture',capacity=32)
    writer.open()
    for packet in packets:
        for record in records_for_packet(packet,1000000,2000000):
            assert writer.submit(record)
    writer.close()
    reopened=store.scan()
    streams={r.stream_id for r in reopened}
    assert {'main_rgb','raw_depth','depth_confidence','camera_pose','pressures','trigger'} <= streams
    import rosbag2_py
    reader=rosbag2_py.SequentialReader()
    reader.open(rosbag2_py.StorageOptions(uri=str(tmp_path/'generated_fixture'),storage_id='mcap'),
                rosbag2_py.ConverterOptions('cdr','cdr'))
    types={topic.name:topic.type for topic in reader.get_all_topics_and_types()}
    count=0; timing={}
    while reader.has_next():
        topic,serialized,_=reader.read_next()
        message=deserialize_message(serialized,get_message(types[topic])); count+=1
        if topic in ('/pressure_timing','/trigger_timing'): timing[topic]=list(message.data)
        if topic=='/usi_collection/raw_depth':
            assert bytes(message.depth_le_f32)==depth
            assert list(message.depth_valid_mask)==[1,0,1,1]
    reader.close()
    assert count==len(reopened)
    assert types['/pressure_timing']=='std_msgs/msg/UInt64MultiArray'
    assert types['/trigger_timing']=='std_msgs/msg/UInt64MultiArray'
    assert timing['/pressure_timing'][1:5]==[100,2000000,1,7]
    assert timing['/trigger_timing'][1:4]==[111,2000000,1]
    assert timing['/pressure_timing'][5]!=0  # stable numeric surrogate; raw boot string is in typed record
    assert (tmp_path/'generated_fixture'/'metadata.yaml').exists()


@pytest.mark.parametrize('omitted_kind,expected_state',[
    (None,'saved'),(MessageType.PRESSURE,'incomplete'),(MessageType.FRAME,'incomplete')])
def test_generated_core_trial_saves_only_after_reopened_inventory(tmp_path,omitted_kind,expected_state):
    _run_child('core',tmp_path,omitted_kind.name if omitted_kind else 'none')


def _core_trial_roundtrip(tmp_path,omitted_kind,expected_state):
    import struct
    jpeg=io.BytesIO(); Image.new('RGB',(2,2),(12,23,34)).save(jpeg,format='JPEG')
    rgb=jpeg.getvalue(); depth=struct.pack('<4f',1.0,1.1,1.2,1.3)
    def frame(seq):
        meta=example('collection_frame'); meta['frame_seq']=seq
        meta['counters']['acquired_frames']=seq+1
        meta['rgb'].update(width=2,height=2,length=len(rgb)); meta['source_image_size']=[2,2]
        meta['depth'].update(width=2,height=2,length=16)
        meta['confidence'].update(width=2,height=2,length=4)
        return Packet(MessageType.FRAME,meta,rgb+depth+bytes([0,1,2,2]))
    def sensor_packets(seq):
        pose=example('collection_poses'); pose['samples'][0]['frame_seq']=seq
        pressure=example('collection_pressure'); pressure['samples'][0]['sequence']=seq
        pressure['samples'][0]['raw_sequence']=seq
        trigger=example('collection_trigger'); trigger['sequence']=seq; trigger['raw_sequence']=seq
        return [Packet(MessageType.POSES,pose),Packet(MessageType.PRESSURE,pressure),Packet(MessageType.TRIGGER,trigger)]
    from usi_stream.collector import UsbClock
    host=Collector(tmp_path,now_ns=lambda:1_000_000_000,wall_ns=lambda:2_000_000_000,
                   drain_timeout_s=0.05,generated_test_data=True)
    for packet in [frame(0),*sensor_packets(0)]: host.ingest(packet)
    prepare=example('collection_trial_command_prepare'); prepare['expected_revision']=0
    snap=prepare['snapshot']; snap['profile']='core'; snap['required_streams'].remove('ultrawide')
    snap['missing_modalities']=['ultrawide']; snap['calibration']=None
    snap['capabilities']=[c for c in snap['capabilities'] if c['stream_id']!='ultrawide']
    identities={'main_rgb':('session-A','world-A'),'raw_depth':('session-A','world-A'),
        'depth_confidence':('session-A','world-A'),'camera_pose':('phone-A','world-A'),
        'tracking':('phone-A','world-A'),'pressures':('esp','boot-A'),'seal':('esp','boot-A'),
        'trigger':('esp','boot-A')}
    for cap in snap['capabilities']:
        cap['schema']=SCHEMA; cap['units']=UNITS[cap['stream_id']]
        cap['source_id'],cap['epoch_id']=identities.get(cap['stream_id'],('phone-A','world-A'))
    assert host.command(prepare)['state']=='preparing'
    lanes=[('main_rgb','session-A','world-A'),('camera_pose','phone-A','world-A'),
           ('pressures','esp','boot-A'),('trigger','esp','boot-A')]
    def fences(seq):
        return [dict(stream_id=s,source_id=source,epoch_id=epoch,next_sequence=seq)
                for s,source,epoch in lanes]
    begin=dict(action='begin',request_id='begin',trial_id=prepare['trial_id'],expected_revision=1,fences=fences(1))
    assert host.command(begin)['state']=='recording'
    usb=UsbClock(host.host_session_id)
    ping=usb.ping(1_000_000_000)
    usb_exchange=usb.complete(dict(ping_id=ping['ping_id'],host_send_ns=ping['host_send_ns'],
        phone_receive_ns=1_000_000_050,phone_send_ns=1_000_000_100,session_id='phone-A'),1_000_000_200)
    health=example('collection_health'); health['counters']=[]
    for packet in [frame(1),*sensor_packets(1),
                   Packet(MessageType.BLE_CLOCK,usb_exchange),
                   Packet(MessageType.HEALTH,health)]:
        if packet.message_type!=omitted_kind: host.ingest(packet)
    stop=dict(action='stop',request_id='stop',trial_id=prepare['trial_id'],expected_revision=2,
              fences=fences(2),counters=[])
    assert host.command(stop)['state']=='finalizing'
    result=host.await_final(5)
    assert result['state']==expected_state,result['reason']
    assert result['verification']==('passed' if expected_state=='saved' else 'failed')
    manifest=json.loads((Path(result['bag_path'])/'verification.json').read_text())
    assert manifest['generated_test_data'] is True
    assert manifest['reopened_counts'].get('raw_depth',0)==(0 if omitted_kind==MessageType.FRAME else 1)
    assert manifest['reopened_counts'].get('pressures',0)==(0 if omitted_kind==MessageType.PRESSURE else 1)
    assert manifest['reopened_counts']['trial_metadata']==1
    assert manifest['reopened_counts']['camera_calibration']==1
    assert manifest['reopened_counts']['timing']==1
    if expected_state=='saved':
        assert len(result['counters'])==12
        assert next(c for c in result['counters'] if c['stream_id']=='pressures')['writer_accepted_count']==1
        import rosbag2_py
        from rclpy.serialization import deserialize_message
        from usi_collection_msgs.msg import ClockRecord
        reader=rosbag2_py.SequentialReader()
        reader.open(rosbag2_py.StorageOptions(uri=result['bag_path'],storage_id='mcap'),
                    rosbag2_py.ConverterOptions('cdr','cdr'))
        clocks=[]
        while reader.has_next():
            topic,data,_=reader.read_next()
            if topic=='/usi_collection/timing': clocks.append(deserialize_message(data,ClockRecord))
        reader.close()
        assert len(clocks)==1 and clocks[0].link=='usb'
        assert [getattr(clocks[0],key) for key in ('t1_ns','t2_ns','t3_ns','t4_ns')]==[
            1_000_000_000,1_000_000_050,1_000_000_100,1_000_000_200]
        assert not clocks[0].mapping_valid


if __name__=='__main__':
    case,folder,omitted=sys.argv[1:4]
    folder=Path(folder)
    if case=='direct': _direct_mcap_roundtrip(folder)
    else:
        omitted_kind=None if omitted=='none' else MessageType[omitted]
        _core_trial_roundtrip(folder,omitted_kind,'saved' if omitted_kind is None else 'incomplete')
