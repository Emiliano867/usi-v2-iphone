"""Bounded USI2 framing and frozen v1 metadata validation.

recv_packet owns the blocking reader: do not discard a partially read packet on a
socket timeout. A caller may close the connection and establish a new handshake.
"""
from dataclasses import dataclass
from enum import IntEnum
import json
import math
import struct

MAGIC = b'USI2'
VERSION = 1
HEADER = struct.Struct('!4sHHII')
MAX_METADATA = 65_536
MAX_PAYLOAD = 16_777_216
MAX_DIMENSION = 8192


class ProtocolError(ValueError):
    """A malformed or incompatible peer packet."""


class MessageType(IntEnum):
    HELLO = 1
    FRAME = 2
    PING = 3
    PONG = 4
    HEALTH = 5


@dataclass(frozen=True)
class Packet:
    message_type: MessageType
    metadata: dict
    payload: bytes = b''


@dataclass(frozen=True)
class FrameParts:
    rgb: memoryview
    depth: object  # memoryview or None
    confidence: object  # memoryview or None


def _require(condition, message):
    if not condition:
        raise ProtocolError(message)


def _uint(value):
    return type(value) is int and value >= 0


def _number(value):
    return type(value) in (int, float) and (type(value) is int or math.isfinite(value))


def _string(value):
    return isinstance(value, str) and bool(value)


def _finite_json(value):
    pending = [(value, 0)]
    while pending:
        item, depth = pending.pop()
        _require(depth <= 64, 'metadata JSON nesting exceeds 64 levels')
        if isinstance(item, dict):
            _require(all(isinstance(key, str) for key in item), 'JSON keys must be strings')
            pending.extend((child, depth + 1) for child in item.values())
        elif isinstance(item, (list, tuple)):
            pending.extend((child, depth + 1) for child in item)
        elif isinstance(item, float):
            _require(math.isfinite(item), 'JSON numbers must be finite')
        else:
            _require(item is None or type(item) in (str, bool, int), 'invalid JSON value')


def _array(value, length):
    return isinstance(value, list) and len(value) == length and all(_number(x) for x in value)


def _dimension(value):
    return type(value) is int and 0 < value <= MAX_DIMENSION


def validate_metadata(kind, meta, payload_length=0):
    """Validate metadata and declared payload length before allocating payloads."""
    _require(isinstance(meta, dict), 'metadata must be a JSON object')
    _finite_json(meta)
    _require(_uint(payload_length) and payload_length <= MAX_PAYLOAD, 'payload length out of bounds')
    if kind != MessageType.FRAME:
        _require(payload_length == 0, 'only FRAME may contain payload')
    if kind == MessageType.HELLO:
        _require(type(meta.get('protocol_version')) is int and meta['protocol_version'] == VERSION,
                 'incompatible HELLO protocol_version')
        _require(meta.get('role') in ('host', 'phone'), 'invalid HELLO role')
        if meta['role'] == 'phone':
            _require(_string(meta.get('session_id')), 'missing phone session_id')
            for key, expected in [('camera_frame','arkit_camera'), ('world_frame','arkit_world'),
                                  ('arkit_clock','ARFrame.timestamp_seconds'),
                                  ('phone_clock','ProcessInfo.systemUptime_ns')]:
                _require(meta.get(key) == expected, 'invalid phone HELLO ' + key)
    elif kind in (MessageType.PING, MessageType.PONG):
        keys = ['ping_id', 'host_send_ns']
        if kind == MessageType.PONG:
            keys += ['phone_receive_ns', 'phone_send_ns']
            _require(_string(meta.get('session_id')), 'invalid PONG session_id')
        for key in keys:
            _require(_uint(meta.get(key)), 'invalid ' + key)
    elif kind == MessageType.HEALTH:
        for key in ['event', 'session_id', 'message']:
            _require(isinstance(meta.get(key), str), 'invalid HEALTH ' + key)
        _require(_string(meta['session_id']), 'empty HEALTH session_id')
    elif kind == MessageType.FRAME:
        _validate_frame(meta, payload_length)
    else:
        raise ProtocolError('unknown packet type')


def _validate_frame(meta, payload_length):
    required = ('session_id frame_seq arkit_timestamp_s phone_uptime_ns world_frame camera_frame '
                'image_orientation camera_transform_row_major position_m quaternion_xyzw '
                'tracking_state tracking_reason pose_valid intrinsics_row_major source_image_size '
                'rgb_intrinsics_row_major rgb depth confidence counters thermal_state').split()
    _require(all(key in meta for key in required), 'missing FRAME metadata field')
    _require(_string(meta['session_id']), 'invalid session_id')
    for key in ('frame_seq', 'phone_uptime_ns'):
        _require(_uint(meta[key]), 'invalid ' + key)
    timestamp = meta['arkit_timestamp_s']
    _require(_number(timestamp) and timestamp >= 0, 'invalid arkit_timestamp_s')
    for key, expected in [('world_frame','arkit_world'), ('camera_frame','arkit_camera'),
                          ('image_orientation','sensor_native')]:
        _require(meta[key] == expected, 'invalid ' + key)
    for key, length in [('camera_transform_row_major',16), ('position_m',3),
                        ('quaternion_xyzw',4), ('intrinsics_row_major',9),
                        ('rgb_intrinsics_row_major',9)]:
        _require(_array(meta[key], length), 'invalid ' + key)
    # hypot avoids overflowing for malicious, finite but enormous components.
    try:
        norm = math.hypot(*meta['quaternion_xyzw'])
    except OverflowError as exc:
        raise ProtocolError('invalid quaternion magnitude') from exc
    _require(abs(norm - 1.0) <= 1e-3, 'quaternion must be normalized')
    _require(meta['tracking_state'] in ('normal','limited','not_available'), 'invalid tracking_state')
    _require(isinstance(meta['tracking_reason'], str), 'invalid tracking_reason')
    _require(type(meta['pose_valid']) is bool, 'invalid pose_valid')
    _require(meta['tracking_state'] != 'not_available' or not meta['pose_valid'],
             'unavailable tracking cannot have valid pose')
    size = meta['source_image_size']
    _require(isinstance(size, list) and len(size) == 2 and all(_dimension(v) for v in size),
             'invalid source_image_size')
    _require(meta['thermal_state'] in ('nominal','fair','serious','critical','unknown'),
             'invalid thermal_state')
    counters = meta['counters']
    _require(isinstance(counters, dict), 'invalid counters')
    for key in ('acquired_frames','encode_drops','transport_drops'):
        _require(_uint(counters.get(key)), 'invalid counter ' + key)
    _require(counters['acquired_frames'] >= meta['frame_seq'] + 1, 'acquired counter precedes frame')
    total = _modality(meta['rgb'], 'jpeg')
    depth = meta['depth']
    confidence = meta['confidence']
    if depth is not None:
        total += _modality(depth, 'float32_le_m', 4)
        _require(depth.get('association') == 'same_arframe_no_independent_timestamp',
                 'invalid depth association')
    if confidence is not None:
        _require(depth is not None, 'confidence requires depth')
        total += _modality(confidence, 'uint8', 1)
        _require((confidence['width'],confidence['height']) == (depth['width'],depth['height']),
                 'confidence dimensions must match depth')
    _require(total == payload_length, 'FRAME payload length does not match modalities')


def _modality(meta, encoding, bytes_per_pixel=None):
    _require(isinstance(meta, dict), 'invalid modality object')
    _require(meta.get('encoding') == encoding, 'invalid modality encoding')
    for key in ('width', 'height'):
        _require(_dimension(meta.get(key)), 'invalid modality ' + key)
    length = meta.get('length')
    _require(type(length) is int and 0 < length <= MAX_PAYLOAD, 'invalid modality length')
    if bytes_per_pixel is not None:
        _require(length == meta['width'] * meta['height'] * bytes_per_pixel,
                 'modality length does not match dimensions')
    return length


def _header(data):
    _require(len(data) == HEADER.size, 'truncated header')
    magic, version, kind, metadata_length, payload_length = HEADER.unpack(data)
    _require(magic == MAGIC, 'invalid USI magic')
    _require(version == VERSION, 'unsupported USI version')
    try:
        kind = MessageType(kind)
    except ValueError as exc:
        raise ProtocolError('unknown packet type') from exc
    _require(metadata_length <= MAX_METADATA, 'metadata length out of bounds')
    _require(payload_length <= MAX_PAYLOAD, 'payload length out of bounds')
    _require(kind == MessageType.FRAME or payload_length == 0, 'only FRAME may contain payload')
    return kind, metadata_length, payload_length


def _json(data):
    def pairs(items):
        result = {}
        for key, value in items:
            _require(key not in result, 'duplicate JSON key')
            result[key] = value
        return result
    try:
        value = json.loads(data.decode('utf-8'), object_pairs_hook=pairs,
                           parse_constant=lambda _: (_ for _ in ()).throw(ProtocolError('nonfinite JSON')))
        _require(isinstance(value, dict), 'metadata must be a JSON object')
        return value
    except (ValueError, UnicodeError, RecursionError) as exc:
        raise ProtocolError('invalid JSON metadata: ' + str(exc)) from exc


def encode_packet(message_type, metadata, payload=b''):
    try:
        _require(type(message_type) is not bool, 'invalid packet type')
        kind = MessageType(message_type)
        _require(isinstance(payload, (bytes, bytearray, memoryview)), 'payload must be bytes')
        validate_metadata(kind, metadata, len(payload))
        encoded = json.dumps(metadata, sort_keys=True, separators=(',', ':'),
                             allow_nan=False, ensure_ascii=True).encode('utf-8')
        _require(len(encoded) <= MAX_METADATA, 'metadata length out of bounds')
        return HEADER.pack(MAGIC, VERSION, kind, len(encoded), len(payload)) + encoded + bytes(payload)
    except (ValueError, TypeError, OverflowError, RecursionError) as exc:
        raise ProtocolError(str(exc)) from exc


def decode_packet(data):
    kind, metadata_length, payload_length = _header(data[:HEADER.size])
    _require(len(data) == HEADER.size + metadata_length + payload_length, 'packet length mismatch')
    boundary = HEADER.size + metadata_length
    meta = _json(data[HEADER.size:boundary])
    validate_metadata(kind, meta, payload_length)
    return Packet(kind, meta, bytes(data[boundary:]))


def recv_exact(sock, count, *, clean_eof=False):
    """Read exactly count bytes; clean EOF is allowed only before a new header."""
    result = bytearray()
    while len(result) < count:
        part = sock.recv(min(count - len(result), 65_536))
        if not part:
            if clean_eof and not result:
                return None
            raise ProtocolError('unexpected EOF inside packet')
        result.extend(part)
    return bytes(result)


def recv_packet(sock):
    header = recv_exact(sock, HEADER.size, clean_eof=True)
    if header is None:
        return None
    kind, metadata_length, payload_length = _header(header)
    meta = _json(recv_exact(sock, metadata_length))
    validate_metadata(kind, meta, payload_length)
    payload = recv_exact(sock, payload_length)
    return Packet(kind, meta, payload)


def slice_frame(packet):
    """Return validated zero-copy modality views, with absent depth kept as None."""
    _require(packet.message_type == MessageType.FRAME, 'expected FRAME')
    validate_metadata(packet.message_type, packet.metadata, len(packet.payload))
    view = memoryview(packet.payload)
    offset = packet.metadata['rgb']['length']
    rgb = view[:offset]
    depth = confidence = None
    if packet.metadata['depth'] is not None:
        end = offset + packet.metadata['depth']['length']
        depth = view[offset:end]
        offset = end
    if packet.metadata['confidence'] is not None:
        confidence = view[offset:]
    return FrameParts(rgb, depth, confidence)
