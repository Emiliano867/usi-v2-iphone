import copy
import json
from pathlib import Path
import socket
import struct
import unittest
try:
    from usi_stream import collection_protocol as p
except ImportError:
    p = None
from test_usi_protocol import frame_metadata


def pressure_sample(sequence=0):
    return dict(sequence=sequence, raw_sequence=sequence % 2**32, source_time_us=100,
                phone_receive_ns=200, pressure_centi_pa=[10000000, 9000000, 8000000], quality_mask=7)


def pressure_batch():
    return dict(source_id='esp', boot_id='boot-A', connection_id='ble-A', phone_session_id='phone-A',
                samples=[pressure_sample()])


def status(state='recording', revision=2):
    return dict(host_session_id='host-A', host_time_ns=100, request_id='req-A', trial_id='trial-A',
                revision=revision, state=state, ready=True, reason=None, bag_path=None,
                verification='pending', counters=[],profile='full',required_streams=list(p.FULL_REQUIRED_STREAMS),missing_modalities=[],missing_required_streams=[])


class CollectionProtocolTests(unittest.TestCase):
    def test_implementation_available(self):
        self.assertIsNotNone(p, 'collection implementation missing')

    @unittest.skipIf(p is None, 'missing collection implementation')
    def test_hello_shared_fixture_and_v1_rejection(self):
        wire = p.encode_packet(p.MessageType.HELLO, dict(role='host', protocol_version=2))
        self.assertEqual(wire.hex(), Path('tests/fixtures/collection_hello.hex').read_text().strip())
        self.assertEqual(p.decode_packet(wire).metadata['protocol_version'], 2)
        for index, value in [(0, 0), (5, 1), (7, 99), (8, 255), (12, 255)]:
            bad = bytearray(wire); bad[index] = value
            with self.assertRaises(p.ProtocolError): p.decode_packet(bad)
        for length in range(len(wire)):
            with self.assertRaises(p.ProtocolError): p.decode_packet(wire[:length])

    @unittest.skipIf(p is None, 'missing collection implementation')
    def test_strict_types_duplicate_keys_and_nested_limits(self):
        for meta in [dict(role='host', protocol_version=True), dict(role='host', protocol_version=2, x=1),
                     dict(role='phone', protocol_version=2, capabilities=[{'bad':float('nan')}])]:
            with self.assertRaises(p.ProtocolError): p.encode_packet(p.MessageType.HELLO, meta)
        for body in [b'{"role":"host","role":"phone","protocol_version":2}', b'{"x":NaN}']:
            wire = struct.pack('!4sHHII', b'USI2', 2, 1, len(body), 0) + body
            with self.assertRaises(p.ProtocolError): p.decode_packet(wire)
        deep = {}; child = deep
        for _ in range(40): child['x'] = {}; child = child['x']
        with self.assertRaises(p.ProtocolError): p.encode_packet(p.MessageType.HEALTH, deep)

    @unittest.skipIf(p is None, 'missing collection implementation')
    def test_sensor_bounds_raw_wrap_and_independent_trigger(self):
        meta = pressure_batch()
        packet = p.decode_packet(p.encode_packet(p.MessageType.PRESSURE, meta))
        self.assertEqual(packet.metadata, meta)
        for mutation in [lambda m: m['samples'][0].update(quality_mask=8),
                         lambda m: m['samples'][0].update(sequence=True),
                         lambda m: m['samples'][0].update(raw_sequence=1),
                         lambda m: m['samples'][0].update(pressure_centi_pa=[0,0,2**31]),
                         lambda m: m.update(samples=[pressure_sample()] * 257)]:
            bad = copy.deepcopy(meta); mutation(bad)
            with self.assertRaises(p.ProtocolError): p.encode_packet(p.MessageType.PRESSURE, bad)
        meta['samples'] = [pressure_sample(2**32)]
        self.assertEqual(p.decode_packet(p.encode_packet(p.MessageType.PRESSURE, meta)).metadata, meta)
        trigger = dict(source_id='esp', boot_id='boot-A', connection_id='ble-A', phone_session_id='phone-A',
                       sequence=3, raw_sequence=3, source_time_us=111, phone_receive_ns=222,
                       pressed=True, event='heartbeat')
        self.assertEqual(p.decode_packet(p.encode_packet(p.MessageType.TRIGGER, trigger)).metadata, trigger)

    @unittest.skipIf(p is None, 'missing collection implementation')
    def test_frame_slices_and_bad_lengths(self):
        meta = frame_metadata(); meta.update(world_epoch_id='world-A', stream_id='main_rgb')
        packet = p.decode_packet(p.encode_packet(p.MessageType.FRAME, meta, b'jpg' + b'12345678' + b'12'))
        parts = p.slice_frame(packet)
        self.assertEqual(bytes(parts.rgb), b'jpg'); self.assertEqual(bytes(parts.depth), b'12345678')
        self.assertEqual(bytes(parts.confidence), b'12')
        with self.assertRaises(p.ProtocolError): p.encode_packet(p.MessageType.FRAME, meta, b'jpg')
        meta['pose_valid'] = 1
        with self.assertRaises(p.ProtocolError): p.encode_packet(p.MessageType.FRAME, meta, b'jpg1234567812')

    @unittest.skipIf(p is None, 'missing collection implementation')
    def test_control_fences_and_no_false_saved(self):
        fence = dict(stream_id='camera_pose', source_id='phone-A', epoch_id='world-A', next_sequence=9)
        req = dict(action='stop', request_id='r', trial_id='t', expected_revision=2, fences=[fence], counters=[])
        self.assertEqual(p.decode_packet(p.encode_packet(p.MessageType.TRIAL_COMMAND, req)).metadata, req)
        for bad in [dict(req, fences=[fence, fence]), dict(req, expected_revision=True), dict(req, fences=[])]:
            with self.assertRaises(p.ProtocolError): p.encode_packet(p.MessageType.TRIAL_COMMAND, bad)
        saved = status('saved', 4)
        with self.assertRaises(p.ProtocolError): p.encode_packet(p.MessageType.TRIAL_STATUS, saved)
        saved.update(verification='passed', bag_path='/data/trial-A')
        self.assertEqual(p.decode_packet(p.encode_packet(p.MessageType.TRIAL_STATUS, saved)).metadata, saved)

    @unittest.skipIf(p is None, 'missing collection implementation')
    def test_streaming_fragmented_packets_clean_eof_and_header_before_read(self):
        wire = p.encode_packet(p.MessageType.HELLO, dict(role='host', protocol_version=2))
        class Reader:
            def __init__(self, data): self.data = data
            def recv(self, count):
                result, self.data = self.data[:min(count, 1)], self.data[min(count, 1):]
                return result
        reader = Reader(wire + wire)
        self.assertEqual(p.recv_packet(reader), p.recv_packet(reader)); self.assertIsNone(p.recv_packet(reader))
        with self.assertRaises(p.ProtocolError): p.recv_packet(Reader(wire[:-1]))
        class HeaderOnly:
            def recv(self, count):
                if count != 16: raise AssertionError('read body after invalid header')
                return struct.pack('!4sHHII', b'USI2', 2, 7, 2, 1)
        with self.assertRaises(p.ProtocolError): p.recv_packet(HeaderOnly())

    @unittest.skipIf(p is None, 'missing collection implementation')
    def test_full_profile_requires_entire_inventory_and_known_capability_reason(self):
        config=dict(pressure_stale_ns=250000000,trigger_stale_ns=1000000000,vision_stale_ns=500000000,
                    host_status_stale_ns=2000000000,mandatory_stale_grace_ns=1000000000,
                    host_heartbeat_ns=500000000,trigger_heartbeat_ns=250000000,target_fps=60)
        cap=dict(stream_id='ultrawide',available=False,reason=None,schema='jpeg',units='pixels',source_id=None,epoch_id=None)
        snap=dict(session_id='s',task_label='task',gripper_id='tool',profile='full',calibration=None,
                  configuration=config,capabilities=[cap],required_streams=['ultrawide'],missing_modalities=[])
        req=dict(action='prepare',request_id='r',trial_id='t',expected_revision=0,snapshot=snap)
        with self.assertRaises(p.ProtocolError): p.encode_packet(p.MessageType.TRIAL_COMMAND,req)
        with self.assertRaises(p.ProtocolError): p.encode_packet(p.MessageType.HELLO,dict(role='phone',protocol_version=2,capabilities=[cap]))

    @unittest.skipIf(p is None, 'missing collection implementation')
    def test_all_shared_vectors_and_per_field_rejection(self):
        for path in sorted(Path('tests/fixtures').glob('collection_*.hex')):
            if path.name.startswith('collection_malformed_'): continue
            with self.subTest(path=path):
                wire=bytes.fromhex(path.read_text()); packet=p.decode_packet(wire)
                self.assertEqual(p.encode_packet(packet.message_type,packet.metadata,packet.payload),wire)
                schema=p.SCHEMAS[packet.message_type.name]
                if packet.message_type == p.MessageType.TRIAL_COMMAND: schema=p.REQUESTS[packet.metadata['action']]
                if packet.message_type == p.MessageType.FRAME: schema=p.FRAMES[packet.metadata['stream_id']]
                for key in schema['required']:
                    bad=copy.deepcopy(packet.metadata); del bad[key]
                    with self.assertRaises(p.ProtocolError): p.encode_packet(packet.message_type,bad,packet.payload)
                bad=copy.deepcopy(packet.metadata); bad['unknown_field']=1
                with self.assertRaises(p.ProtocolError): p.encode_packet(packet.message_type,bad,packet.payload)

    @unittest.skipIf(p is None, 'missing collection implementation')
    def test_metadata_limits_malformed_json_finite_and_batch_size(self):
        for body in [b'[]',b'null',b'\xff',b'{',b'{"protocol_version":2,"role":"host","x":1e999}']:
            with self.assertRaises(p.ProtocolError): p.decode_packet(struct.pack('!4sHHII',b'USI2',2,1,len(body),0)+body)
        wire=bytes.fromhex(Path('tests/fixtures/collection_poses.hex').read_text()); packet=p.decode_packet(wire)
        for value in [True, float('nan'), float('inf')]:
            bad=copy.deepcopy(packet.metadata);bad['samples'][0]['arkit_timestamp_s']=value
            with self.assertRaises(p.ProtocolError): p.encode_packet(packet.message_type,bad)
        bad=pressure_batch(); bad['samples']=[pressure_sample(i) for i in range(65)]
        with self.assertRaises(p.ProtocolError): p.encode_packet(p.MessageType.PRESSURE,bad)
        bad=copy.deepcopy(packet.metadata); bad['samples']=[bad['samples'][0]]*65
        with self.assertRaises(p.ProtocolError): p.encode_packet(p.MessageType.POSES,bad)
        header=struct.pack('!4sHHII',b'USI2',2,1,65537,0)
        with self.assertRaises(p.ProtocolError): p.decode_packet(header)

    @unittest.skipIf(p is None, 'missing collection implementation')
    def test_ultrawide_has_independent_source_clock_and_intrinsics(self):
        meta=dict(stream_id='ultrawide',session_id='phone-A',world_epoch_id='capture-A',frame_seq=8,
                  source_timestamp_s=321.125,source_clock='verified-camera-source',phone_uptime_ns=999,
                  camera_frame='ultrawide_camera',image_orientation='sensor_native',intrinsics_row_major=[2,0,1,0,2,1,0,0,1],
                  source_image_size=[2,2],rgb_intrinsics_row_major=[2,0,1,0,2,1,0,0,1],
                  rgb=dict(encoding='jpeg',width=2,height=2,length=3),
                  counters=dict(acquired_frames=9,encode_drops=0,transport_drops=0),thermal_state='nominal')
        packet=p.decode_packet(p.encode_packet(p.MessageType.FRAME,meta,b'jpg'))
        self.assertEqual(packet.metadata['source_timestamp_s'],321.125)
        self.assertNotIn('arkit_timestamp_s',packet.metadata)
        self.assertIsNone(p.slice_frame(packet).depth)
        del meta['source_clock']
        with self.assertRaises(p.ProtocolError):p.encode_packet(p.MessageType.FRAME,meta,b'jpg')

    @unittest.skipIf(p is None, 'missing collection implementation')
    def test_canonical_message_names_preserve_wire_ids(self):
        self.assertEqual(p.MessageType.PRESSURE.value,7)
        self.assertEqual(p.MessageType.BLE_CLOCK.value,9)
        self.assertEqual(p.MessageType.TRIAL_COMMAND.value,10)
        self.assertNotIn('PRESSURES',p.MessageType.__members__)
        self.assertNotIn('CLOCK',p.MessageType.__members__)
        self.assertNotIn('TRIAL_REQUEST',p.MessageType.__members__)

    @unittest.skipIf(p is None, 'missing collection implementation')
    def test_status_inventory_survives_recovery_and_rejects_profile_conflicts(self):
        full=dict(status(),profile='full',required_streams=list(p.FULL_REQUIRED_STREAMS),missing_modalities=[])
        self.assertEqual(p.decode_packet(p.encode_packet(p.MessageType.TRIAL_STATUS,full)).metadata,full)
        core=dict(full,profile='core',required_streams=list(p.CORE_REQUIRED_STREAMS),missing_modalities=['ultrawide'])
        self.assertEqual(p.decode_packet(p.encode_packet(p.MessageType.TRIAL_STATUS,core)).metadata,core)
        idle=dict(full,state='idle',trial_id=None,request_id=None,profile=None,required_streams=[],missing_modalities=[],missing_required_streams=[])
        self.assertEqual(p.decode_packet(p.encode_packet(p.MessageType.TRIAL_STATUS,idle)).metadata,idle)
        invalid=[dict(full,required_streams=['ultrawide']),dict(full,missing_modalities=['ultrawide']),
                 dict(core,missing_modalities=[]),dict(core,required_streams=list(p.CORE_REQUIRED_STREAMS)*2),
                 dict(full,profile=None),dict(full,missing_modalities=['audio']*33),
                 dict(full,missing_required_streams=['audio']),dict(full,missing_required_streams=['pressures']*2)]
        for key in ('profile','required_streams','missing_modalities','missing_required_streams'):
            bad=copy.deepcopy(full);del bad[key];invalid.append(bad)
        for bad in invalid:
            with self.subTest(bad=bad),self.assertRaises(p.ProtocolError):p.encode_packet(p.MessageType.TRIAL_STATUS,bad)

    @unittest.skipIf(p is None, 'missing collection implementation')
    def test_status_reports_unavailable_required_streams_separately_from_profile_exclusions(self):
        unavailable=dict(status('preparing'),reason='required sources unavailable',missing_required_streams=['ultrawide','pressures'])
        packet=p.decode_packet(p.encode_packet(p.MessageType.TRIAL_STATUS,unavailable))
        self.assertEqual(packet.metadata['missing_required_streams'],['ultrawide','pressures'])
        self.assertEqual(packet.metadata['missing_modalities'],[])
        self.assertEqual(packet.metadata['required_streams'],list(p.FULL_REQUIRED_STREAMS))
        incomplete=dict(unavailable,state='incomplete',verification='failed',reason='required sources remained unavailable')
        self.assertEqual(p.decode_packet(p.encode_packet(p.MessageType.TRIAL_STATUS,incomplete)).metadata,incomplete)
        for state in ('recording','saved'):
            bad=dict(unavailable,state=state,missing_required_streams=['pressures'])
            if state == 'saved': bad.update(verification='passed',bag_path='/data/trial-A')
            with self.subTest(state=state),self.assertRaises(p.ProtocolError):
                p.encode_packet(p.MessageType.TRIAL_STATUS,bad)

    @unittest.skipIf(p is None, 'missing collection implementation')
    def test_oversized_numeric_tokens_are_protocol_errors(self):
        wire=bytes.fromhex(Path('tests/fixtures/collection_poses.hex').read_text())
        packet=p.decode_packet(wire)
        for key,value in [('quaternion_xyzw',[10**400,0,0,1]),('arkit_timestamp_s',10**400),('arkit_timestamp_s',2**64)]:
            bad=copy.deepcopy(packet.metadata);bad['samples'][0][key]=value
            with self.subTest(key=key,value=str(value)[:40]),self.assertRaises(p.ProtocolError):p.encode_packet(packet.message_type,bad)
        for value in [2**64-1,1e200,float.fromhex('0x1.fffffffffffffp+1023')]:
            good=copy.deepcopy(packet.metadata);good['samples'][0]['arkit_timestamp_s']=value
            decoded=p.decode_packet(p.encode_packet(packet.message_type,good))
            self.assertEqual(decoded.metadata['samples'][0]['arkit_timestamp_s'],value)
        for path in Path('tests/fixtures').glob('collection_malformed_*.hex'):
            with self.subTest(path=path),self.assertRaises(p.ProtocolError):p.decode_packet(bytes.fromhex(path.read_text()))
