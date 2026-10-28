import io
import socket
import threading
import unittest

from usi_stream.protocol import HEADER, MAGIC, VERSION, MessageType, ProtocolError, decode_packet, encode_packet, recv_packet
from usi_stream.receiver import MetadataLogger, Receiver


class ReviewRegressionTests(unittest.TestCase):
    def test_excessive_metadata_nesting_is_a_protocol_error(self):
        body = b'{"role":"host","protocol_version":1,"extension":' + b'[' * 600 + b'0' + b']' * 600 + b'}'
        wire = HEADER.pack(MAGIC, VERSION, MessageType.HELLO, len(body), 0) + body
        with self.assertRaises(ProtocolError):
            decode_packet(wire)

    def test_pong_extension_cannot_override_receiver_event_fields(self):
        host, phone = socket.socketpair()
        errors = []

        def peer():
            try:
                with phone:
                    recv_packet(phone)
                    phone.sendall(encode_packet(MessageType.HELLO, {
                        'role': 'phone', 'protocol_version': 1, 'session_id': 'test-session',
                        'camera_frame': 'arkit_camera', 'world_frame': 'arkit_world',
                        'arkit_clock': 'ARFrame.timestamp_seconds', 'phone_clock': 'ProcessInfo.systemUptime_ns'}))
                    ping = recv_packet(phone)
                    pong = dict(ping.metadata, phone_receive_ns=100, phone_send_ns=101,
                                session_id='test-session', matched='peer-extension', event='peer-event',
                                connection_id=999, host_receive_monotonic_ns=0)
                    phone.sendall(encode_packet(MessageType.PONG, pong))
            except BaseException as exc:
                errors.append(exc)

        thread = threading.Thread(target=peer)
        thread.start()
        log = io.StringIO()
        with host:
            Receiver(logger=MetadataLogger(log), output=io.StringIO()).consume(host)
        thread.join(2)
        self.assertFalse(thread.is_alive())
        if errors:
            raise errors[0]
        import json
        event = next(json.loads(line) for line in log.getvalue().splitlines() if json.loads(line)['event'] == 'pong')
        self.assertTrue(event['matched'])
        self.assertEqual(event['connection_id'], 1)
        self.assertGreater(event['host_receive_monotonic_ns'], 0)
