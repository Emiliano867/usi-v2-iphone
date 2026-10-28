import copy
import json
from pathlib import Path
import socket
import struct
import threading
import unittest

try:
    from usi_stream import protocol as p
except ImportError:
    p = None


def frame_metadata(seq=0, session='session-A'):
    return {
        'session_id': session, 'frame_seq': seq,
        'arkit_timestamp_s': 123.125, 'phone_uptime_ns': 987654321,
        'world_frame': 'arkit_world', 'camera_frame': 'arkit_camera',
        'image_orientation': 'sensor_native',
        'camera_transform_row_major': [1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1],
        'position_m': [0,0,0], 'quaternion_xyzw': [0,0,0,1],
        'tracking_state': 'normal', 'tracking_reason': '', 'pose_valid': True,
        'intrinsics_row_major': [100,0,2,0,100,1,0,0,1],
        'source_image_size': [4,2],
        'rgb_intrinsics_row_major': [100,0,2,0,100,1,0,0,1],
        'rgb': {'encoding':'jpeg','width':4,'height':2,'length':3},
        'depth': {'encoding':'float32_le_m','width':2,'height':1,'length':8,
                  'association':'same_arframe_no_independent_timestamp'},
        'confidence': {'encoding':'uint8','width':2,'height':1,'length':2},
        'counters': {'acquired_frames':seq+1,'encode_drops':0,'transport_drops':0},
        'thermal_state': 'nominal',
    }


def raw_packet(kind=1, metadata=b'{}', payload=b'', magic=b'USI2', version=1):
    return struct.pack('!4sHHII', magic, version, kind, len(metadata), len(payload)) + metadata + payload


class Availability(unittest.TestCase):
    def test_protocol_is_available(self):
        self.assertIsNotNone(p, 'USI protocol implementation is missing')


@unittest.skipIf(p is None, 'protocol not implemented')
class ProtocolTests(unittest.TestCase):
    def test_golden_hello(self):
        wire = p.encode_packet(p.MessageType.HELLO, {'role':'host','protocol_version':1})
        self.assertEqual(wire.hex(), Path('tests/fixtures/usi_hello_v1.hex').read_text().strip())
        decoded = p.decode_packet(wire)
        self.assertEqual(decoded.message_type, p.MessageType.HELLO)
        self.assertEqual(decoded.metadata, {'protocol_version':1,'role':'host'})

    def test_fragmented_and_coalesced_packets_and_clean_eof(self):
        left, right = socket.socketpair()
        wire = p.encode_packet(p.MessageType.HELLO, {'role':'host','protocol_version':1})
        def writer():
            with left:
                for byte in wire:
                    left.sendall(bytes([byte]))
                left.sendall(wire + wire)
        thread = threading.Thread(target=writer)
        thread.start()
        with right:
            self.assertEqual(p.recv_packet(right).metadata['role'], 'host')
            self.assertEqual(p.recv_packet(right), p.recv_packet(right))
            self.assertIsNone(p.recv_packet(right))
        thread.join()

    def test_header_rejected_before_body_read(self):
        class HeaderOnly:
            def __init__(self, header): self.header = header
            def recv(self, count):
                if not self.header: raise AssertionError('invalid header must not read body')
                result, self.header = self.header[:count], self.header[count:]
                return result
        headers = [
            struct.pack('!4sHHII', b'FAIL',1,1,0,0),
            struct.pack('!4sHHII', b'USI2',2,1,0,0),
            struct.pack('!4sHHII', b'USI2',1,99,0,0),
            struct.pack('!4sHHII', b'USI2',1,1,65537,0),
            struct.pack('!4sHHII', b'USI2',1,2,2,16777217),
            struct.pack('!4sHHII', b'USI2',1,3,2,1),
        ]
        for header in headers:
            with self.subTest(header=header), self.assertRaises(p.ProtocolError):
                p.recv_packet(HeaderOnly(header))

    def test_bad_json_and_nonfinite(self):
        for body in [b'[]', b'null', b'{', b'\xff', b'{"x":NaN}', b'{"x":1e999}',
                     b'{"x":Infinity}', b'{"x":-Infinity}', b'{"x":true,"x":false}']:
            with self.subTest(body=body), self.assertRaises(p.ProtocolError):
                p.decode_packet(raw_packet(metadata=body))

    def test_truncation_and_trailing_data(self):
        wire = p.encode_packet(p.MessageType.HELLO, {'role':'host','protocol_version':1})
        for bad in [wire[:2], wire[:16], wire[:-1], wire+b'x']:
            with self.subTest(bad=bad), self.assertRaises(p.ProtocolError): p.decode_packet(bad)
        for bad in [wire[:2], wire[:-1]]:
            left,right=socket.socketpair()
            with left,right:
                left.sendall(bad); left.shutdown(socket.SHUT_WR)
                with self.assertRaises(p.ProtocolError): p.recv_packet(right)

    def test_frame_slices_and_source_clocks(self):
        meta = frame_metadata()
        payload = b'jpg' + struct.pack('<ff', 0.1, 0.2) + b'\x00\x02'
        packet = p.decode_packet(p.encode_packet(p.MessageType.FRAME, meta, payload))
        parts = p.slice_frame(packet)
        self.assertEqual(bytes(parts.rgb), b'jpg')
        self.assertEqual(bytes(parts.depth), struct.pack('<ff', 0.1, 0.2))
        self.assertEqual(bytes(parts.confidence), b'\x00\x02')
        self.assertEqual(packet.metadata['arkit_timestamp_s'], 123.125)
        self.assertEqual(packet.metadata['phone_uptime_ns'], 987654321)

    def test_missing_depth_is_none(self):
        meta=frame_metadata(); meta['depth']=meta['confidence']=None
        parts=p.slice_frame(p.decode_packet(p.encode_packet(p.MessageType.FRAME,meta,b'jpg')))
        self.assertIsNone(parts.depth); self.assertIsNone(parts.confidence)

    def test_frame_required_fields(self):
        for key in frame_metadata():
            meta=frame_metadata(); del meta[key]
            with self.subTest(key=key),self.assertRaises(p.ProtocolError):
                p.encode_packet(p.MessageType.FRAME,meta,b'jpg'+b'\0'*10)

    def test_frame_bad_types_values_and_dimensions(self):
        mutations = [
            ('frame_seq',True), ('frame_seq',-1), ('session_id',''),
            ('arkit_timestamp_s',-1), ('phone_uptime_ns',1.2),
            ('position_m',[0,0,float('nan')]), ('position_m',[1,2]),
            ('quaternion_xyzw',[0,0,0,2]), ('quaternion_xyzw',[False,0,0,1]),
            ('camera_transform_row_major',[0]*15),
            ('intrinsics_row_major',[float('inf')]*9),
            ('source_image_size',[8193,1]), ('source_image_size',[True,1]),
            ('pose_valid',1), ('tracking_state','unknown'), ('thermal_state','hot'),
            ('world_frame','map'), ('camera_frame','camera'), ('image_orientation','portrait'),
        ]
        for key,value in mutations:
            meta=frame_metadata();meta[key]=value
            with self.subTest(key=key,value=value),self.assertRaises(p.ProtocolError):
                p.encode_packet(p.MessageType.FRAME,meta,b'jpg'+b'\0'*10)
        for modality,key,value in [('rgb','width',0),('rgb','height',8193),('rgb','length',0),
                ('depth','length',9),('depth','width',8192),('depth','encoding','float64'),
                ('confidence','height',2),('confidence','length',1),
                ('counters','acquired_frames',0),('counters','encode_drops',True)]:
            meta=frame_metadata(); meta[modality][key]=value
            with self.subTest(modality=modality,key=key),self.assertRaises(p.ProtocolError):
                p.encode_packet(p.MessageType.FRAME,meta,b'jpg'+b'\0'*10)
        for mutate in ['orphan', 'pose', 'payload']:
            meta=frame_metadata(); payload=b'jpg'+b'\0'*10
            if mutate=='orphan':meta['depth']=None
            if mutate=='pose':meta['tracking_state']='not_available'
            if mutate=='payload':payload+=b'x'
            with self.subTest(mutate=mutate),self.assertRaises(p.ProtocolError):
                p.encode_packet(p.MessageType.FRAME,meta,payload)

    def test_control_metadata_and_payload_validation(self):
        cases=[(p.MessageType.HELLO,{'role':'host','protocol_version':True}),
               (p.MessageType.HELLO,{'role':'other','protocol_version':1}),
               (p.MessageType.PING,{'ping_id':True,'host_send_ns':0}),
               (p.MessageType.PONG,{'ping_id':0,'host_send_ns':0,'phone_receive_ns':0,'phone_send_ns':0}),
               (p.MessageType.HEALTH,{'event':1,'session_id':'A','message':''})]
        for kind,meta in cases:
            with self.subTest(kind=kind),self.assertRaises(p.ProtocolError):p.encode_packet(kind,meta)
        with self.assertRaises(p.ProtocolError):
            p.encode_packet(p.MessageType.PING,{'ping_id':0,'host_send_ns':0},b'x')

    def test_encoder_bounds(self):
        with self.assertRaises(p.ProtocolError):
            p.encode_packet(p.MessageType.HEALTH,{'event':'x','session_id':'a','message':'x'*65536})
        with self.assertRaises(p.ProtocolError):
            p.encode_packet(99,{})
