import contextlib
import io
import json
import socket
import subprocess
import sys
import threading
import unittest
from unittest import mock

from test_usi_protocol import frame_metadata
from usi_stream.protocol import MessageType, ProtocolError, encode_packet, recv_packet
try:
    from usi_stream import receiver as r
except ImportError:
    r=None


def phone_hello(session='session-A'):
    return {'role':'phone','protocol_version':1,'session_id':session,
            'camera_frame':'arkit_camera','world_frame':'arkit_world',
            'arkit_clock':'ARFrame.timestamp_seconds','phone_clock':'ProcessInfo.systemUptime_ns'}


class Availability(unittest.TestCase):
    def test_receiver_is_available(self):self.assertIsNotNone(r,'receiver implementation missing')


@unittest.skipIf(r is None,'not implemented')
class ReceiverTests(unittest.TestCase):
    def test_session_gaps_resets_tracking_and_camera_fps(self):
        state=r.ReceiverState()
        first=state.observe_frame(frame_metadata(0),100)
        self.assertEqual(first['sequence_gap'],0)
        self.assertIsNone(first['camera_fps'])
        meta=frame_metadata(3);meta['arkit_timestamp_s']+=0.1;meta['tracking_state']='limited'
        next_frame=state.observe_frame(meta,100_000_100)
        self.assertEqual(next_frame['sequence_gap'],2)
        self.assertEqual(next_frame['session_sequence_gaps'],2)
        self.assertAlmostEqual(next_frame['camera_fps'],30)
        self.assertTrue(next_frame['tracking_changed'])
        # Reconnection with the same source session preserves sequence history.
        state.begin_session('session-A')
        meta=frame_metadata(5);meta['arkit_timestamp_s']+=0.2
        self.assertEqual(state.observe_frame(meta,200_000_100)['sequence_gap'],1)
        # A frame is authoritative even if there was no HEALTH / HELLO reset.
        reset=state.observe_frame(frame_metadata(0,'session-B'),300_000_100)
        self.assertTrue(reset['session_changed'])
        self.assertEqual(reset['session_sequence_gaps'],0)
        self.assertIsNone(reset['camera_fps'])

    def test_first_sequence_gap_and_regression(self):
        state=r.ReceiverState()
        self.assertEqual(state.observe_frame(frame_metadata(8),100)['sequence_gap'],8)
        for seq in [8,7]:
            with self.subTest(seq=seq),self.assertRaises(ProtocolError):state.observe_frame(frame_metadata(seq),101)

    def test_source_clock_regression_is_visible_not_synchronized(self):
        state=r.ReceiverState();state.observe_frame(frame_metadata(0),100)
        meta=frame_metadata(1);meta['arkit_timestamp_s']=1
        stats=state.observe_frame(meta,200)
        self.assertTrue(stats['source_clock_regressed'])
        self.assertIsNone(stats['camera_fps'])
        self.assertNotIn('synchronized_timestamp',stats)

    def test_handshake_ping_pong_frame_provenance_and_eof(self):
        host,phone=socket.socketpair();errors=[];log=io.StringIO()
        def server():
            try:
                with phone:
                    hello=recv_packet(phone)
                    self.assertEqual(hello.metadata,{'role':'host','protocol_version':1})
                    phone.sendall(encode_packet(MessageType.HELLO,phone_hello()))
                    ping=recv_packet(phone)
                    self.assertEqual(ping.message_type,MessageType.PING)
                    pong=dict(ping.metadata,phone_receive_ns=50,phone_send_ns=75,session_id='session-A')
                    frame=frame_metadata()
                    phone.sendall(encode_packet(MessageType.PONG,pong)+
                                  encode_packet(MessageType.FRAME,frame,b'jpg'+b'\0'*10))
            except BaseException as exc:errors.append(exc)
        thread=threading.Thread(target=server);thread.start()
        with host:
            receiver=r.Receiver(logger=r.MetadataLogger(log),output=io.StringIO())
            self.assertEqual(receiver.consume(host),1)
        thread.join(2);self.assertFalse(thread.is_alive())
        if errors:raise errors[0]
        events=[json.loads(line) for line in log.getvalue().splitlines()]
        pong=next(event for event in events if event['event']=='pong')
        self.assertTrue(pong['matched'])
        for key in ['host_send_ns','phone_receive_ns','phone_send_ns',
                    'host_receive_monotonic_ns','host_receive_wall_ns']:
            self.assertIs(type(pong[key]),int)
        frame=next(event for event in events if event['event']=='frame')
        self.assertEqual(frame['metadata']['arkit_timestamp_s'],123.125)
        self.assertEqual(frame['metadata']['phone_uptime_ns'],987654321)
        self.assertNotIn('payload',frame)

    def test_frames_before_handshake_and_host_peer_rejected(self):
        for wire in [encode_packet(MessageType.FRAME,frame_metadata(),b'jpg'+b'\0'*10),
                     encode_packet(MessageType.HELLO,{'role':'host','protocol_version':1})]:
            host,phone=socket.socketpair()
            with host,phone:
                phone.sendall(wire)
                with self.assertRaises(ProtocolError):r.Receiver(output=io.StringIO()).consume(host)

    def test_periodic_ping_while_phone_idle(self):
        host,phone=socket.socketpair();errors=[]
        def server():
            try:
                with phone:
                    recv_packet(phone);phone.sendall(encode_packet(MessageType.HELLO,phone_hello()))
                    first=recv_packet(phone);second=recv_packet(phone)
                    self.assertGreaterEqual(second.metadata['host_send_ns']-first.metadata['host_send_ns'],5_000_000)
            except BaseException as exc:errors.append(exc)
        thread=threading.Thread(target=server);thread.start()
        with host:r.Receiver(ping_interval=0.01,output=io.StringIO()).consume(host)
        thread.join(2)
        if errors:raise errors[0]

    def test_reconnect_keeps_source_session_history(self):
        events=io.StringIO();receiver=r.Receiver(logger=r.MetadataLogger(events),output=io.StringIO())
        for seq in [0,3]:
            host,phone=socket.socketpair()
            def server():
                with phone:
                    recv_packet(phone);phone.sendall(encode_packet(MessageType.HELLO,phone_hello()))
                    recv_packet(phone)
                    phone.sendall(encode_packet(MessageType.FRAME,frame_metadata(seq),b'jpg'+b'\0'*10))
            thread=threading.Thread(target=server);thread.start()
            with host:receiver.consume(host)
            thread.join(2)
        frames=[json.loads(line) for line in events.getvalue().splitlines() if json.loads(line)['event']=='frame']
        self.assertEqual([f['connection_id'] for f in frames],[1,2])
        self.assertEqual(frames[-1]['sequence_gap'],2)

    def test_no_device_retry_is_finite_and_no_gui_import(self):
        calls=[];sleeps=[]
        def connector(**kwargs):
            calls.append(kwargs);raise r.NoDeviceError('no USB-connected phone available')
        receiver=r.Receiver(output=io.StringIO())
        result=receiver.run(connector=connector,max_attempts=3,retry_delay=0.01,sleep=sleeps.append)
        self.assertEqual(result,1)
        self.assertEqual(len(calls),3)
        self.assertEqual(sleeps,[0.01,0.01])
        self.assertNotIn('cv2',sys.modules)
        self.assertNotIn('numpy',sys.modules)

    def test_headless_cli_help_has_no_optional_dependencies(self):
        process=subprocess.run([sys.executable,'-m','usi_stream.receiver','--help'],capture_output=True,text=True)
        self.assertEqual(process.returncode,0,process.stderr)
        self.assertIn('--headless',process.stdout)
        self.assertIn('--metadata-log',process.stdout)
        self.assertIn('--max-attempts',process.stdout)

    def test_partial_packet_timeout_aborts_instead_of_resuming_mid_packet(self):
        host,phone=socket.socketpair()
        with host,phone:
            phone.sendall(encode_packet(MessageType.HELLO,phone_hello())[:20])
            with self.assertRaises(socket.timeout):
                r.Receiver(io_timeout=0.01,output=io.StringIO()).consume(host)
