"""Generated protocol fixtures for the authoritative host state machine."""
import json
import re
from pathlib import Path

import pytest

from usi_stream.collection_protocol import MessageType, validate_metadata
from usi_stream.collector import Collector, UsbClock
from usi_stream.collection_protocol import Packet
from usi_stream.recorder import Record


DOC = Path(__file__).parents[1] / 'docs/collection-protocol-v2.md'


def example(name):
    text = DOC.read_text()
    return json.loads(re.search(r'### ' + name + r' \([^\n]+\)\n\n```json\n(.*?)\n```', text, re.S).group(1))


class MemoryStore:
    def __init__(self, drop_stream=None, fail_write=False):
        self.records = []
        self.drop_stream = drop_stream
        self.fail_write = fail_write
        self.closed = False

    def open(self, path):
        self.path = path
        path.mkdir(); (path/'generated-test-only.mcap').write_bytes(b'fake adapter fixture')

    def write(self, record):
        if self.fail_write:
            raise OSError('disk full')
        self.records.append(record)

    def close(self):
        self.closed = True

    def scan(self):
        return [r for r in self.records if r.stream_id != self.drop_stream]


def core_prepare():
    request = example('collection_trial_command_prepare')
    snap = request['snapshot']
    snap['profile'] = 'core'
    snap['required_streams'].remove('ultrawide')
    snap['missing_modalities'] = ['ultrawide']
    snap['capabilities'] = [c for c in snap['capabilities'] if c['stream_id'] != 'ultrawide']
    sources={'main_rgb':('session-A','world-A'),'raw_depth':('session-A','world-A'),
             'depth_confidence':('session-A','world-A'),'camera_pose':('phone-A','world-A'),
             'tracking':('phone-A','world-A'),'pressures':('esp','boot-A'),
             'trigger':('esp','boot-A'),'seal':('esp','boot-A')}
    from usi_stream.collector import SCHEMA,UNITS
    for cap in snap['capabilities']:
        cap['schema']=SCHEMA; cap['units']=UNITS[cap['stream_id']]
        cap['source_id'],cap['epoch_id']=sources.get(cap['stream_id'],('phone-A','world-A'))
    request['expected_revision'] = 0
    return request


def fences(next_seq):
    return [dict(stream_id=stream, source_id=source, epoch_id=epoch, next_sequence=next_seq)
            for stream, source, epoch in [('main_rgb','session-A','world-A'), ('camera_pose','phone-A','world-A'),
                                          ('pressures','esp','boot-A'), ('trigger','esp','boot-A')]]


def packets(sequence=0):
    frame=example('collection_frame'); frame['frame_seq']=sequence
    frame['counters']['acquired_frames']=sequence+1
    pose=example('collection_poses'); pose['samples'][0]['frame_seq']=sequence
    pressure=example('collection_pressure'); pressure['samples'][0]['sequence']=sequence
    pressure['samples'][0]['raw_sequence']=sequence
    trigger=example('collection_trigger'); trigger['sequence']=sequence
    trigger['raw_sequence']=sequence
    return [Packet(MessageType.FRAME,frame,b'abc'+b'\0'*8+b'\0'*2),
            Packet(MessageType.POSES,pose),Packet(MessageType.PRESSURE,pressure),
            Packet(MessageType.TRIGGER,trigger)]


def fake_records(packet,received_ns,wall_ns):
    meta=packet.metadata; kind=packet.message_type
    if kind==MessageType.FRAME:
        identities=[(s,meta['session_id'],meta['world_epoch_id'],meta['frame_seq'])
                    for s in ('main_rgb',)+(('raw_depth',) if meta['depth'] is not None else ())+
                             (('depth_confidence',) if meta['confidence'] is not None else ())]
    elif kind==MessageType.POSES:
        identities=[(stream,meta['session_id'],meta['world_epoch_id'],s['frame_seq'])
                    for s in meta['samples'] for stream in ('camera_pose','tracking')]
    elif kind==MessageType.PRESSURE:
        identities=[(stream,meta['source_id'],meta['boot_id'],s['sequence'])
                    for s in meta['samples'] for stream in ('pressures','seal')]
    elif kind==MessageType.TRIGGER:
        identities=[('trigger',meta['source_id'],meta['boot_id'],meta['sequence'])]
    elif kind==MessageType.BLE_CLOCK:
        identities=[('timing',meta['source_id'],meta['epoch_id'],0)]
    elif kind==MessageType.HEALTH:
        identities=[('health',meta['session_id'],meta['session_id'],0)]
    else: identities=[]
    return [Record('/'+s,'test/msg/Record',b'x',wall_ns,s,source,epoch,seq)
            for s,source,epoch,seq in identities]


def fake_static(snapshot,trial_id,wall_ns,calibration,begin_sequence):
    cap=next(c for c in snapshot['capabilities'] if c['stream_id']=='camera_calibration')
    return [Record('/usi_collection/trial_metadata','test/msg/Record',b'fixture',wall_ns,
                  'trial_metadata',snapshot['session_id'],snapshot['session_id'],0),
            Record('/usi_collection/camera_calibration','test/msg/Record',b'fixture',wall_ns,
                  'camera_calibration',cap['source_id'],cap['epoch_id'],begin_sequence,
                  json.dumps(calibration,sort_keys=True,separators=(',',':')))]


def host_at(root,store):
    host=Collector(root,storage_factory=lambda:store,record_factory=fake_records,
                   static_record_factory=fake_static,now_ns=lambda:1_000_000_000,
                   wall_ns=lambda:2_000_000_000,drain_timeout_s=0.01)
    for packet in packets(): host.ingest(packet)
    return host


def add_control_evidence(host):
    host.ingest(Packet(MessageType.BLE_CLOCK,example('collection_ble_clock')))
    health=example('collection_health'); health['counters']=[]
    host.ingest(Packet(MessageType.HEALTH,health))


def command(action, revision, next_seq):
    value = dict(action=action, request_id='request-'+action, trial_id='trial-A', expected_revision=revision,
                 fences=fences(next_seq))
    if action == 'stop': value['counters'] = []
    return value


def test_prepare_retry_is_idempotent_and_conflict_is_rejected(tmp_path):
    created = []
    def factory():
        store = MemoryStore(); created.append(store); return store
    host = Collector(tmp_path, storage_factory=factory,record_factory=fake_records,
                     static_record_factory=fake_static,now_ns=lambda:1_000_000_000)
    for packet in packets(): host.ingest(packet)
    request = core_prepare()
    first = host.command(request)
    validate_metadata(MessageType.TRIAL_STATUS, first)
    assert first['state'] == 'preparing'
    assert host.command(request)['revision'] == first['revision']
    assert len(created) == 1
    changed = dict(request, expected_revision=9)
    with pytest.raises(ValueError, match='request_id'):
        host.command(changed)


def test_begin_needs_exact_fences_and_fresh_sources(tmp_path):
    host = host_at(tmp_path,MemoryStore())
    host.command(core_prepare())
    bad = command('begin', 1, 1)
    bad['fences'].pop()
    result = host.command(bad)
    assert result['state'] != 'recording'
    assert 'fenced lane' in result['reason']


def test_missing_record_cannot_be_saved_after_reopen(tmp_path):
    store = MemoryStore(drop_stream='pressures')
    host = host_at(tmp_path,store)
    host.command(core_prepare())
    assert host.command(command('begin', 1, 1))['state'] == 'recording'
    for packet in packets(1): host.ingest(packet)
    host.command(command('stop', 2, 2))
    result=host.await_final(1)
    assert result['state'] == 'incomplete'
    assert result['verification'] == 'failed'
    assert store.closed


def test_writer_failure_is_incomplete(tmp_path):
    host = host_at(tmp_path,MemoryStore(fail_write=True))
    host.command(core_prepare())
    assert host.command(command('begin', 1, 1))['state'] != 'recording'
    assert host.await_final(1)['state'] == 'incomplete'


def test_delayed_image_drains_and_lost_stop_ack_is_idempotent(tmp_path):
    store=MemoryStore(); host=host_at(tmp_path,store)
    host.command(core_prepare())
    host.command(command('begin',1,1))
    stream=packets(1)
    for packet in (stream[1],stream[2],stream[3]): host.ingest(packet)
    host.ingest(Packet(MessageType.BLE_CLOCK,example('collection_ble_clock')))
    health=example('collection_health'); health['counters']=[]
    host.ingest(Packet(MessageType.HEALTH,health))
    stop=command('stop',2,2)
    assert host.command(stop)['state']=='finalizing'
    host.ingest(stream[0])  # encoded image arrives after Stop control
    final=host.await_final(1)
    assert final['state']=='saved',final['reason']
    assert host.command(stop)['state']=='saved'
    assert store.closed


def test_dropped_pose_sequence_is_incomplete(tmp_path):
    host=host_at(tmp_path,MemoryStore()); host.command(core_prepare())
    host.command(command('begin',1,1))
    for packet in packets(1): host.ingest(packet)
    host.command(command('stop',2,3))
    assert host.await_final(1)['state']=='incomplete'
    assert 'camera_pose:2' in host.status()['reason']


def test_disconnect_ends_active_trial_incomplete(tmp_path):
    host=host_at(tmp_path,MemoryStore()); host.command(core_prepare())
    host.command(command('begin',1,1))
    host.disconnect()
    result=host.await_final(1)
    assert result['state']=='incomplete'
    assert 'disconnected' in result['reason']


def test_known_image_encode_loss_fails_full_inventory(tmp_path):
    host=host_at(tmp_path,MemoryStore()); host.command(core_prepare())
    host.command(command('begin',1,1))
    stream=packets(1); stream[0].metadata['counters']['encode_drops']=1
    for packet in stream: host.ingest(packet)
    assert host.status()['state'] != 'recording'
    result=host.await_final(1)
    assert result['state']=='incomplete'
    assert 'image source loss' in result['reason']


def test_frame_outside_trial_cannot_add_lifetime_drop_loss(tmp_path):
    host=host_at(tmp_path,MemoryStore()); host.command(core_prepare())
    host.command(command('begin',1,1))
    old=packets(0)[0]; old.metadata['counters']['encode_drops']=1
    host.ingest(old)
    assert host.status()['state']=='recording'


def test_explicit_camera_prefix_counters_do_not_attribute_old_encode_to_trial(tmp_path):
    host=host_at(tmp_path,MemoryStore()); host.command(core_prepare())
    health=example('collection_health')
    health['counters']=[dict(stream_id='main_rgb',source_id='session-A',epoch_id='world-A',
        source_count=1,received_count=1,writer_accepted_count=None,queue_overflow_count=None,
        rejected_count=None,duplicate_count=0,missing_ranges=[])]
    host.ingest(Packet(MessageType.HEALTH,health))
    host.command(command('begin',1,1))
    stream=packets(1); stream[0].metadata['counters']['encode_drops']=1
    for packet in stream: host.ingest(packet)
    assert host.status()['state']=='recording'
    add_control_evidence(host)
    host.command(command('stop',2,2))
    result=host.await_final(1)
    assert result['state']=='saved',result['reason']
    assert result['ready'] is True, 'A completed host must accept the next trial'


def test_stale_required_source_revokes_recording(tmp_path):
    clock=[1_000_000_000]
    host=Collector(tmp_path,storage_factory=MemoryStore,record_factory=fake_records,
                   static_record_factory=fake_static,now_ns=lambda:clock[0],drain_timeout_s=0.01)
    for packet in packets(): host.ingest(packet)
    host.command(core_prepare()); host.command(command('begin',1,1))
    clock[0]=3_000_000_000
    assert host.status()['state']!='recording'
    result=host.await_final(1)
    assert result['state']=='incomplete'
    assert 'stale required source' in result['reason']


def test_unsupported_capability_schema_blocks_prepare(tmp_path):
    host=host_at(tmp_path,MemoryStore())
    request=core_prepare(); request['snapshot']['capabilities'][0]['schema']='unknown'
    result=host.command(request)
    assert result['state']=='incomplete'
    assert 'main_rgb' in result['missing_required_streams']


def test_wrong_revision_and_duplicate_begin_do_not_open_second_artifact(tmp_path):
    store=MemoryStore(); host=host_at(tmp_path,store)
    host.command(core_prepare())
    wrong=command('begin',0,1)
    with pytest.raises(ValueError,match='revision'):
        host.command(wrong)
    begin=command('begin',1,1)
    first=host.command(begin)
    assert first['state']=='recording'
    assert host.command(begin)['revision']==first['revision']
    assert host.command(dict(action='status',request_id='lookup',trial_id='trial-A',expected_revision=999))['state']=='recording'
    assert len(list(tmp_path.glob('trial-*')))==1
    assert len([r for r in store.records if r.stream_id=='trial_metadata'])==1
    host.disconnect(); host.await_final(1)


def test_disk_space_failure_has_no_recording_assurance(tmp_path):
    host=Collector(tmp_path,storage_factory=MemoryStore,record_factory=fake_records,
                   static_record_factory=fake_static,now_ns=lambda:1_000_000_000,min_free_bytes=10**30)
    for packet in packets(): host.ingest(packet)
    result=host.command(core_prepare())
    assert result['state']=='incomplete'
    assert result['verification']=='failed'
    assert 'disk space' in result['reason']
    assert not list(tmp_path.glob('trial-*'))


def test_source_cadence_shortfall_fails_despite_complete_sequences(tmp_path):
    clock=[1_000_000_000]
    host=Collector(tmp_path,storage_factory=MemoryStore,record_factory=fake_records,
                   static_record_factory=fake_static,now_ns=lambda:clock[0],
                   drain_timeout_s=0.01)
    for packet in packets(): host.ingest(packet)
    host.command(core_prepare()); host.command(command('begin',1,1))
    for seq,when,source_time in ((1,2_000_000_000,123.125),(2,3_000_000_000,123.625)):
        clock[0]=when
        for packet in packets(seq):
            if packet.message_type==MessageType.FRAME: packet.metadata['arkit_timestamp_s']=source_time
            if packet.message_type==MessageType.POSES: packet.metadata['samples'][0]['arkit_timestamp_s']=source_time
            host.ingest(packet)
    host.command(command('stop',2,3))
    result=host.await_final(1)
    assert result['state']=='incomplete'
    assert 'source cadence shortfall' in result['reason']


def test_cumulative_loss_counter_uses_begin_baseline(tmp_path):
    host=host_at(tmp_path,MemoryStore())
    baseline=example('collection_health')['counters'][0]
    baseline.update(source_count=1,received_count=1,queue_overflow_count=0,missing_ranges=[])
    health=example('collection_health'); health['counters']=[baseline]
    host.ingest(Packet(MessageType.HEALTH,health))
    host.command(core_prepare()); host.command(command('begin',1,1))
    for packet in packets(1): host.ingest(packet)
    final=dict(baseline,source_count=2,received_count=2,queue_overflow_count=1)
    stop=command('stop',2,2); stop['counters']=[final]
    host.command(stop)
    result=host.await_final(1)
    assert result['state']=='incomplete'
    assert 'source loss queue_overflow_count' in result['reason']


def test_exclusive_stop_rejects_already_written_overrun_and_keeps_both_fences(tmp_path):
    store=MemoryStore(); host=host_at(tmp_path,store)
    host.command(core_prepare()); host.command(command('begin',1,1))
    for seq in (1,2):
        for packet in packets(seq): host.ingest(packet)
    add_control_evidence(host)
    host.command(command('stop',2,2)); result=host.await_final(2)
    assert result['state']=='incomplete'
    assert 'outside fence' in result['reason']
    manifest=json.loads((Path(result['bag_path'])/'verification.json').read_text())
    assert manifest['begin_fences']['main_rgb'][2]==1
    assert manifest['end_fences']['main_rgb'][2]==2


def test_prebegin_companions_are_not_written(tmp_path):
    store=MemoryStore(); host=host_at(tmp_path,store)
    host.command(core_prepare()); host.command(command('begin',1,1))
    for seq in (0,1):
        for packet in packets(seq): host.ingest(packet)
    add_control_evidence(host)
    host.command(command('stop',2,2)); assert host.await_final(2)['state']=='saved'
    assert not [(r.stream_id,r.sequence) for r in store.records if r.sequence==0 and r.stream_id in ('tracking','seal')]


def test_reopened_wrong_derived_join_is_incomplete(tmp_path):
    from dataclasses import replace
    class WrongJoin(MemoryStore):
        def scan(self):
            return [replace(r,source_id='wrong-source',sequence=999) if r.stream_id=='tracking' else r for r in self.records]
    host=host_at(tmp_path,WrongJoin()); host.command(core_prepare()); host.command(command('begin',1,1))
    for packet in packets(1): host.ingest(packet)
    add_control_evidence(host)
    host.command(command('stop',2,2)); result=host.await_final(2)
    assert result['state']=='incomplete'
    assert 'derived join' in result['reason']


def test_reopened_changed_frozen_calibration_is_incomplete(tmp_path):
    from dataclasses import replace
    class ChangedCalibration(MemoryStore):
        def scan(self):
            return [replace(r,details='{}') if r.stream_id=='camera_calibration' else r for r in self.records]
    host=host_at(tmp_path,ChangedCalibration())
    host.command(core_prepare()); host.command(command('begin',1,1))
    for packet in packets(1): host.ingest(packet)
    add_control_evidence(host)
    host.command(command('stop',2,2))
    result=host.await_final(2)
    assert result['state']=='incomplete'
    assert 'frozen camera calibration' in result['reason']


def test_disconnect_during_drain_invalidates_late_completion(tmp_path):
    host=host_at(tmp_path,MemoryStore()); host.command(core_prepare()); host.command(command('begin',1,1))
    stream=packets(1)
    for packet in stream[1:]: host.ingest(packet)
    add_control_evidence(host)
    host.command(command('stop',2,2)); host.disconnect(); host.ingest(stream[0])
    result=host.await_final(2)
    assert result['state']=='incomplete'
    assert 'disconnected' in result['reason']


def test_unchanged_historical_health_loss_does_not_abort_recording(tmp_path):
    host=host_at(tmp_path,MemoryStore())
    health=example('collection_health'); health['counters'][0].update(queue_overflow_count=1,rejected_count=0,missing_ranges=[])
    host.ingest(Packet(MessageType.HEALTH,health))
    host.command(core_prepare()); host.command(command('begin',1,1))
    host.ingest(Packet(MessageType.HEALTH,health))
    assert host.status()['state']=='recording'
    host.disconnect(); host.await_final(2)


def test_health_missing_range_outside_observed_interval_is_deferred(tmp_path):
    host=host_at(tmp_path,MemoryStore())
    host.command(core_prepare()); host.command(command('begin',1,1))
    health=example('collection_health')
    health['counters'][0].update(queue_overflow_count=0,rejected_count=0,
                                  missing_ranges=[dict(start=100,end_exclusive=101)])
    host.ingest(Packet(MessageType.HEALTH,health))
    assert host.status()['state']=='recording'
    host.disconnect(); host.await_final(2)


def test_deferred_health_gap_inside_final_fence_fails_without_stop_counters(tmp_path):
    host=host_at(tmp_path,MemoryStore())
    host.command(core_prepare()); host.command(command('begin',1,1))
    health=example('collection_health')
    health['counters'][0].update(queue_overflow_count=0,rejected_count=0,
                                  missing_ranges=[dict(start=1,end_exclusive=2)])
    host.ingest(Packet(MessageType.HEALTH,health))
    assert host.status()['state']=='recording'
    for packet in packets(1): host.ingest(packet)
    add_control_evidence(host)
    stop=command('stop',2,2); stop['counters']=[]
    host.command(stop)
    result=host.await_final(2)
    assert result['state']=='incomplete'
    assert 'observed source missing range' in result['reason']


def test_historical_health_gap_outside_final_fence_does_not_fail(tmp_path):
    host=host_at(tmp_path,MemoryStore())
    health=example('collection_health')
    health['counters'][0].update(queue_overflow_count=0,rejected_count=0,
                                  missing_ranges=[dict(start=0,end_exclusive=1)])
    host.ingest(Packet(MessageType.HEALTH,health))
    host.command(core_prepare()); host.command(command('begin',1,1))
    host.ingest(Packet(MessageType.HEALTH,health))
    for packet in packets(1): host.ingest(packet)
    add_control_evidence(host)
    host.command(command('stop',2,2))
    assert host.await_final(2)['state']=='saved'


def test_old_trial_retry_and_status_are_scoped(tmp_path):
    host=host_at(tmp_path,MemoryStore()); old=core_prepare()
    host.command(old); host.command(command('begin',1,1))
    for packet in packets(1): host.ingest(packet)
    add_control_evidence(host)
    host.command(command('stop',2,2)); assert host.await_final(2)['state']=='saved'
    new=core_prepare(); new.update(request_id='prepare-B',trial_id='trial-B',expected_revision=host.revision)
    assert host.command(new)['trial_id']=='trial-B'
    replay=host.command(old)
    assert replay['trial_id']=='trial-A' and replay['state']=='saved'
    lookup=dict(action='status',request_id='status-A',trial_id='trial-A',expected_revision=0)
    assert host.command(lookup)['trial_id']=='trial-A'
    with pytest.raises(ValueError,match='request_id'):
        host.command(dict(lookup,trial_id='trial-B'))
    host.disconnect()


def test_calibration_frozen_at_begin_and_change_invalidates(tmp_path):
    store=MemoryStore(); host=host_at(tmp_path,store)
    host.command(core_prepare()); host.command(command('begin',1,1))
    assert len([r for r in store.records if r.stream_id=='camera_calibration'])==1
    frame=packets(1)[0]; frame.metadata['source_image_size'][0]+=1
    host.ingest(frame)
    assert host.await_final(2)['state']=='incomplete'
    assert 'camera calibration changed' in host.status()['reason']


def test_intrinsic_variation_keeps_frozen_calibration_record(tmp_path):
    store=MemoryStore(); host=host_at(tmp_path,store)
    host.command(core_prepare()); host.command(command('begin',1,1))
    stream=packets(1); stream[0].metadata['intrinsics_row_major'][0]+=1
    for packet in stream: host.ingest(packet)
    add_control_evidence(host)
    host.command(command('stop',2,2))
    assert host.await_final(2)['state']=='saved'
    assert len([r for r in store.records if r.stream_id=='camera_calibration'])==1


def test_missing_depth_on_one_frame_does_not_change_calibration(tmp_path):
    host=host_at(tmp_path,MemoryStore())
    host.command(core_prepare()); host.command(command('begin',1,1))
    for packet in packets(1): host.ingest(packet)
    stream=packets(2)
    frame=stream[0]; frame.metadata['depth']=None; frame.metadata['confidence']=None
    frame=Packet(MessageType.FRAME,frame.metadata,b'abc')
    for packet in (frame,*stream[1:]): host.ingest(packet)
    add_control_evidence(host)
    host.command(command('stop',2,3))
    assert host.await_final(2)['state']=='saved'


def test_prepare_uses_calibration_from_prepared_camera_source(tmp_path):
    host=host_at(tmp_path,MemoryStore())
    other=packets(0)[0]
    other.metadata['session_id']='other-session'; other.metadata['world_epoch_id']='other-world'
    host.ingest(other)
    host.command(core_prepare()); host.command(command('begin',1,1))
    for packet in packets(1): host.ingest(packet)
    add_control_evidence(host)
    host.command(command('stop',2,2))
    assert host.await_final(2)['state']=='saved'


def test_completed_host_usb_exchange_is_persisted_as_timing(tmp_path):
    store=MemoryStore(); host=host_at(tmp_path,store)
    host.command(core_prepare()); host.command(command('begin',1,1))
    clock=UsbClock(host.host_session_id); ping=clock.ping(100)
    pong=dict(ping_id=ping['ping_id'],host_send_ns=100,phone_receive_ns=120,
              phone_send_ns=130,session_id='phone-A')
    completed=clock.complete(pong,150)
    host.ingest(Packet(MessageType.BLE_CLOCK,completed),received_ns=150)
    for packet in packets(1): host.ingest(packet)
    health=example('collection_health'); health['counters']=[]
    host.ingest(Packet(MessageType.HEALTH,health))
    host.command(command('stop',2,2))
    assert host.await_final(2)['state']=='saved'
    assert len([r for r in store.records if r.stream_id=='timing'])==1
