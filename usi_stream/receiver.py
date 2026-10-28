"""Diagnostic USB camera/pose receiver; JSONL is not an MCAP dataset.

Example: python3 -m usi_stream.receiver --headless --metadata-log stream.jsonl
OpenCV/NumPy are imported only when the optional preview is requested. Raw phone
clocks are preserved separately; no clock fit or synchronized stamps are made.
"""
import argparse
from collections import OrderedDict
import json
import math
import select
import socket
import sys
import time

from .protocol import MessageType, ProtocolError, encode_packet, recv_packet, slice_frame
from .usbmux import NoDeviceError, USBMuxError, connect_usb


class MetadataLogger:
    """Append compact diagnostic events to an already opened text stream."""
    def __init__(self, stream=None):
        self.stream = stream

    def emit(self, event, **fields):
        if self.stream is not None:
            self.stream.write(json.dumps(dict(fields, event=event), sort_keys=True,
                                         separators=(',', ':'), allow_nan=False) + '\n')
            self.stream.flush()


class ReceiverState:
    """Current source epoch; reconnecting the same session preserves gap history."""
    def __init__(self):
        self.session_id = None
        self.last_seq = None
        self.session_sequence_gaps = 0
        self.last_arkit_timestamp = None
        self.last_phone_uptime = None
        self.last_tracking = None
        self.first_receive_ns = None
        self.frame_count = 0

    def begin_session(self, session_id):
        if self.session_id == session_id:
            return False
        self.session_id = session_id
        self.last_seq = None
        self.session_sequence_gaps = 0
        self.last_arkit_timestamp = None
        self.last_phone_uptime = None
        self.last_tracking = None
        self.first_receive_ns = None
        self.frame_count = 0
        return True

    def observe_frame(self, meta, receive_ns):
        changed = self.begin_session(meta['session_id'])
        seq = meta['frame_seq']
        if self.last_seq is not None and seq <= self.last_seq:
            raise ProtocolError('frame sequence must increase within a source session')
        gap = seq if self.last_seq is None else seq - self.last_seq - 1
        self.session_sequence_gaps += gap
        camera_fps = None
        arkit_regressed = (self.last_arkit_timestamp is not None and
                           meta['arkit_timestamp_s'] <= self.last_arkit_timestamp)
        phone_regressed = (self.last_phone_uptime is not None and
                           meta['phone_uptime_ns'] < self.last_phone_uptime)
        if self.last_arkit_timestamp is not None and not arkit_regressed:
            delta = meta['arkit_timestamp_s'] - self.last_arkit_timestamp
            try:
                candidate = (seq - self.last_seq) / delta
                if math.isfinite(candidate):
                    camera_fps = candidate
            except OverflowError:
                pass
        tracking = (meta['tracking_state'], meta['tracking_reason'], meta['pose_valid'])
        tracking_changed = tracking != self.last_tracking
        if self.first_receive_ns is None:
            self.first_receive_ns = receive_ns
        self.frame_count += 1
        elapsed = (receive_ns - self.first_receive_ns) / 1e9
        receive_fps = (self.frame_count - 1) / elapsed if elapsed > 0 else None
        self.last_seq = seq
        self.last_arkit_timestamp = meta['arkit_timestamp_s']
        self.last_phone_uptime = meta['phone_uptime_ns']
        self.last_tracking = tracking
        return {'session_changed': changed, 'sequence_gap': gap,
                'session_sequence_gaps': self.session_sequence_gaps,
                'tracking_changed': tracking_changed, 'camera_fps': camera_fps,
                'receive_fps': receive_fps, 'arkit_clock_regressed': arkit_regressed,
                'phone_clock_regressed': phone_regressed,
                'source_clock_regressed': arkit_regressed or phone_regressed}


class Preview:
    """Throttled rendering only; source payload and clocks remain untouched."""
    def __init__(self, fps=10):
        import cv2
        import numpy as np
        self.cv2, self.np = cv2, np
        self.interval_ns = int(1e9 / fps)
        self.last_ns = None

    def show(self, packet, now_ns):
        if self.last_ns is not None and now_ns - self.last_ns < self.interval_ns:
            return True
        self.last_ns = now_ns
        cv2, np = self.cv2, self.np
        parts = slice_frame(packet)
        rgb_meta = packet.metadata['rgb']
        rgb = cv2.imdecode(np.frombuffer(parts.rgb, dtype=np.uint8), cv2.IMREAD_COLOR)
        if rgb is None or rgb.shape[:2] != (rgb_meta['height'], rgb_meta['width']):
            raise ProtocolError('JPEG decode or dimensions do not match metadata')
        tiles = [rgb]
        if parts.depth is not None:
            meta = packet.metadata['depth']
            depth = np.frombuffer(parts.depth, dtype='<f4').reshape(meta['height'], meta['width'])
            # A fixed display range in meters is independent of the raw depth.
            display = np.zeros(depth.shape, dtype=np.uint8)
            valid = np.isfinite(depth) & (depth > 0)
            display[valid] = (np.clip(depth[valid] / 3.0, 0, 1) * 255).astype(np.uint8)
            color = cv2.applyColorMap(display, cv2.COLORMAP_TURBO)
            color[~valid] = 0
            tiles.append(cv2.resize(color, (rgb_meta['width'], rgb_meta['height']),
                                    interpolation=cv2.INTER_NEAREST))
        if parts.confidence is not None:
            meta = packet.metadata['confidence']
            levels = np.frombuffer(parts.confidence, dtype=np.uint8).reshape(meta['height'], meta['width'])
            image = (np.clip(levels, 0, 2).astype(np.uint16) * 127).astype(np.uint8)
            image = cv2.cvtColor(image, cv2.COLOR_GRAY2BGR)
            tiles.append(cv2.resize(image, (rgb_meta['width'], rgb_meta['height']),
                                    interpolation=cv2.INTER_NEAREST))
        cv2.imshow('USI Stream: RGB | depth 0-3m | confidence 0/1/2', cv2.hconcat(tiles))
        return cv2.waitKey(1) & 0xff not in (27, ord('q'))

    def close(self):
        self.cv2.destroyAllWindows()


class Receiver:
    def __init__(self, *, logger=None, output=None, preview=None,
                 ping_interval=1.0, io_timeout=3.0, clock=time):
        if not math.isfinite(ping_interval) or ping_interval <= 0:
            raise ValueError('ping interval must be positive and finite')
        if not math.isfinite(io_timeout) or io_timeout <= 0:
            raise ValueError('I/O timeout must be positive and finite')
        self.logger = logger if logger is not None else MetadataLogger()
        self.output = output if output is not None else sys.stderr
        self.preview = preview
        self.clock = clock
        self.ping_interval_ns = max(1, int(ping_interval * 1e9))
        self.io_timeout = io_timeout
        self.state = ReceiverState()
        self.connection_id = 0
        self.next_ping_id = 0
        self.pending_pings = OrderedDict()
        self.stop_requested = False

    def _emit(self, event, **fields):
        self.logger.emit(event, connection_id=self.connection_id, **fields)

    def _receive(self, sock):
        packet = recv_packet(sock)
        # Capture these immediately after the complete packet is received.
        mono = self.clock.monotonic_ns()
        wall = self.clock.time_ns()
        return packet, {'host_receive_monotonic_ns': mono, 'host_receive_wall_ns': wall}

    def _begin_session(self, session_id, source, provenance):
        previous = self.state.session_id
        if self.state.begin_session(session_id):
            self._emit('session_change', session_id=session_id, previous_session_id=previous,
                       source=source, **provenance)
            print('USI source session changed', file=self.output)

    def _ping(self, sock):
        ping_id = self.next_ping_id
        self.next_ping_id += 1
        host_send_ns = self.clock.monotonic_ns()
        metadata = {'ping_id': ping_id, 'host_send_ns': host_send_ns}
        sock.sendall(encode_packet(MessageType.PING, metadata))
        self.pending_pings[ping_id] = host_send_ns
        while len(self.pending_pings) > 16:
            self.pending_pings.popitem(last=False)
        self._emit('ping_sent', **metadata)

    def consume(self, sock):
        """Handshake and consume one socket until EOF. Errors abort this socket.

        One reader owns framing; a timeout never resumes from an unknown packet
        boundary. The outer run loop closes and reconnects instead. select lets
        PINGs continue once per second when no frames arrive.
        """
        self.connection_id += 1
        self.pending_pings.clear()
        self._emit('connect', host_monotonic_ns=self.clock.monotonic_ns(),
                   host_wall_ns=self.clock.time_ns())
        sock.settimeout(self.io_timeout)
        sock.sendall(encode_packet(MessageType.HELLO, {'role':'host','protocol_version':1}))
        hello, provenance = self._receive(sock)
        if hello is None or hello.message_type != MessageType.HELLO or hello.metadata['role'] != 'phone':
            raise ProtocolError('expected phone HELLO before stream data')
        self._emit('hello', metadata=hello.metadata, **provenance)
        self._begin_session(hello.metadata['session_id'], 'hello', provenance)
        next_ping_ns = self.clock.monotonic_ns()
        next_report_ns = next_ping_ns
        frames = 0
        while not self.stop_requested:
            now = self.clock.monotonic_ns()
            if now >= next_ping_ns:
                self._ping(sock)
                next_ping_ns = self.clock.monotonic_ns() + self.ping_interval_ns
            wait = max(0.0, (next_ping_ns - self.clock.monotonic_ns()) / 1e9)
            readable, _, _ = select.select([sock], [], [], wait)
            if not readable:
                continue
            packet, provenance = self._receive(sock)
            if packet is None:
                self._emit('disconnect', reason='eof', **provenance)
                return frames
            meta = packet.metadata
            if packet.message_type == MessageType.FRAME:
                previous_session = self.state.session_id
                stats = self.state.observe_frame(meta, provenance['host_receive_monotonic_ns'])
                if stats['session_changed']:
                    self._emit('session_change', session_id=meta['session_id'],
                               previous_session_id=previous_session, source='frame', **provenance)
                if stats['sequence_gap']:
                    self._emit('sequence_gap', session_id=meta['session_id'], frame_seq=meta['frame_seq'],
                               missing_frames=stats['sequence_gap'], **provenance)
                if stats['tracking_changed']:
                    self._emit('tracking_change', session_id=meta['session_id'],
                               tracking_state=meta['tracking_state'], tracking_reason=meta['tracking_reason'],
                               pose_valid=meta['pose_valid'], **provenance)
                self._emit('frame', metadata=meta, **stats, **provenance)
                frames += 1
                now = provenance['host_receive_monotonic_ns']
                if now >= next_report_ns:
                    camera = '?' if stats['camera_fps'] is None else f"{stats['camera_fps']:.1f}"
                    received = '?' if stats['receive_fps'] is None else f"{stats['receive_fps']:.1f}"
                    print(f"USI seq={meta['frame_seq']} camera={camera} FPS receive={received} FPS "
                          f"tracking={meta['tracking_state']} pose_valid={meta['pose_valid']} "
                          f"gaps={stats['session_sequence_gaps']} "
                          f"encode_drops={meta['counters']['encode_drops']} "
                          f"transport_drops={meta['counters']['transport_drops']}", file=self.output)
                    next_report_ns = now + 1_000_000_000
                if self.preview is not None and not self.preview.show(packet, now):
                    self.stop_requested = True
            elif packet.message_type == MessageType.PONG:
                sent = self.pending_pings.pop(meta['ping_id'], None)
                matched = sent is not None and sent == meta['host_send_ns']
                observed = {key: meta[key] for key in ('ping_id', 'host_send_ns', 'phone_receive_ns',
                                                      'phone_send_ns', 'session_id')}
                self._emit('pong', **observed, matched=matched, **provenance)
            elif packet.message_type == MessageType.HEALTH:
                self._emit('health', metadata=meta, **provenance)
            else:
                raise ProtocolError('unexpected control packet from phone')
        self._emit('disconnect', reason='stop_requested', host_monotonic_ns=self.clock.monotonic_ns())
        return frames

    def run(self, *, port=5558, socket_path='/var/run/usbmuxd', connector=connect_usb,
            max_attempts=0, retry_delay=1.0, sleep=time.sleep):
        """Reconnect until stopped; max_attempts=0 retries indefinitely."""
        if type(max_attempts) is not int or max_attempts < 0:
            raise ValueError('max_attempts must be a nonnegative integer')
        if not math.isfinite(retry_delay) or retry_delay < 0:
            raise ValueError('retry_delay must be nonnegative and finite')
        attempts = 0
        successful = False
        while not self.stop_requested and (not max_attempts or attempts < max_attempts):
            attempts += 1
            try:
                with connector(port=port, socket_path=socket_path, timeout=self.io_timeout) as sock:
                    self.consume(sock)
                    successful = True
            except (USBMuxError, ProtocolError, OSError) as exc:
                # Do not forward peer/daemon contents or identifiers into errors.
                reason = type(exc).__name__
                self._emit('connection_error', reason=reason, attempt=attempts,
                           host_monotonic_ns=self.clock.monotonic_ns(), host_wall_ns=self.clock.time_ns())
                print(f'USI connection unavailable ({reason}); retrying', file=self.output)
            if not self.stop_requested and (not max_attempts or attempts < max_attempts):
                sleep(retry_delay)
        return 0 if successful or self.stop_requested else 1


def _positive(value):
    number = float(value)
    if not math.isfinite(number) or number <= 0:
        raise argparse.ArgumentTypeError('must be positive and finite')
    return number


def main(argv=None):
    parser = argparse.ArgumentParser(description='USI USB diagnostic receiver; raw clocks, no synchronization or MCAP.')
    parser.add_argument('--headless', action='store_true', help='receive without OpenCV/NumPy or windows')
    parser.add_argument('--metadata-log', metavar='PATH', help='append diagnostic metadata/provenance JSONL')
    parser.add_argument('--port', type=int, default=5558, help='phone port (default: 5558)')
    parser.add_argument('--usbmux-socket', default='/var/run/usbmuxd', help='local daemon AF_UNIX socket')
    parser.add_argument('--timeout', type=_positive, default=3.0, help='daemon/packet I/O timeout in seconds')
    parser.add_argument('--retry-delay', type=_positive, default=1.0, help='seconds between attempts')
    parser.add_argument('--max-attempts', type=int, default=0, help='connection attempts; 0 retries until interrupted')
    parser.add_argument('--preview-fps', type=_positive, default=10.0, help='maximum display rate; independent of capture')
    args = parser.parse_args(argv)
    if not 1 <= args.port <= 65535:
        parser.error('--port must be in 1..65535')
    if args.max_attempts < 0:
        parser.error('--max-attempts must be nonnegative')
    preview = None
    stream = None
    try:
        if not args.headless:
            try:
                preview = Preview(args.preview_fps)
            except ImportError:
                print('Preview requires OpenCV and NumPy; use --headless or the separate USB virtual environment.', file=sys.stderr)
                return 2
        if args.metadata_log:
            stream = open(args.metadata_log, 'a', encoding='utf-8')
        receiver = Receiver(logger=MetadataLogger(stream), preview=preview, io_timeout=args.timeout)
        return receiver.run(port=args.port, socket_path=args.usbmux_socket,
                            max_attempts=args.max_attempts, retry_delay=args.retry_delay)
    except KeyboardInterrupt:
        return 0
    except OSError:
        print('Unable to open or write the diagnostic metadata log.', file=sys.stderr)
        return 2
    finally:
        if stream is not None:
            stream.close()
        if preview is not None:
            preview.close()


if __name__ == '__main__':
    raise SystemExit(main())
