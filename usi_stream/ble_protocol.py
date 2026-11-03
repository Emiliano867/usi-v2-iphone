"""Version-one USI BLE logical messages and ATT notification fragments.

The firmware's quality byte is an ERROR mask; collection/UI quality is a VALID mask.
Clock t4 is captured by the phone on receipt and is intentionally absent on this wire.
"""
from dataclasses import dataclass
import struct


class BLEError(ValueError):
    pass


def _check(ok):
    if not ok:
        raise BLEError('invalid BLE message')


@dataclass(frozen=True)
class PressureSample:
    raw_sequence: int
    source_time_us: int
    pressures_centi_pa: tuple
    quality_error_mask: int

    @property
    def quality_mask(self): return (~self.quality_error_mask) & 7

    @property
    def pressures_kpa_abs(self): return tuple(x / 100000 for x in self.pressures_centi_pa)


@dataclass(frozen=True)
class PressureEvent:
    boot_id: int
    samples: tuple


@dataclass(frozen=True)
class TriggerEvent:
    boot_id: int
    raw_sequence: int
    source_time_us: int
    pressed: bool
    suction_on: bool
    heartbeat: bool


@dataclass(frozen=True)
class ClockEvent:
    boot_id: int
    request_id: int
    t1_phone_ns: int
    t2_device_us: int
    t3_device_us: int
    snapshot_device_us: int
    pressure_acquired: int
    trigger_acquired: int
    pressure_overflow: int
    trigger_overflow: int
    pressure_disconnected: int
    trigger_disconnected: int
    scheduler_skips: int
    pressure_notify_lost: int
    trigger_notify_lost: int
    notify_calls: int
    notify_failures: int
    disconnects: int


def decode(data):
    data = bytes(data)
    _check(5 <= len(data) <= 256 and data[0] in (1, 2, 3))
    kind, boot = struct.unpack_from('<BI', data)
    _check(boot != 0)
    if kind == 1:
        _check(len(data) >= 6)
        count = data[5]
        _check(1 <= count <= 10 and len(data) == 6 + count * 25)
        samples = []
        for i in range(count):
            seq, time_us, p0, p1, p2, error = struct.unpack_from('<IQiiiB', data, 6 + i * 25)
            _check(error <= 7 and all((p == -100) if error & (1 << j) else (p >= 0)
                                      for j, p in enumerate((p0, p1, p2))))
            samples.append(PressureSample(seq, time_us, (p0, p1, p2), error))
        return PressureEvent(boot, tuple(samples))
    if kind == 2:
        _check(len(data) == 19)
        seq, time_us, pressed, heartbeat = struct.unpack_from('<IQBB', data, 5)
        _check(pressed <= 1 and heartbeat <= 1)
        return TriggerEvent(boot, seq, time_us, bool(pressed), not bool(pressed), bool(heartbeat))
    _check(len(data) == 137)
    values = struct.unpack_from('<I' + 'Q' * 16, data, 5)
    request, t1, t2, t3, snapshot, *counters = values
    _check(t1 > 0 and t2 <= snapshot <= t3)
    return ClockEvent(boot, request, t1, t2, t3, snapshot, *counters)


def clock_request(request_id, t1_phone_ns):
    _check(type(request_id) is int and 0 <= request_id <= 0xffffffff and
           type(t1_phone_ns) is int and 0 < t1_phone_ns <= 0xffffffffffffffff)
    return struct.pack('<BBBBIQ', 0xc7, 1, 4, 0, request_id, t1_phone_ns)


def fragment(message, message_id, payload_size=20):
    message = bytes(message)
    _check(1 <= len(message) <= 256 and type(message_id) is int and
           0 <= message_id <= 0xffffffff and 20 <= payload_size <= 244)
    # This validates the complete logical payload, including its version and bounds.
    decode(message)
    return [struct.pack('<BBIHH', 0xc7, 1, message_id, len(message), offset) +
            message[offset:offset + payload_size - 10]
            for offset in range(0, len(message), payload_size - 10)]


class Reassembler:
    def __init__(self):
        self.discarded = 0
        self.reset()

    def reset(self):
        self._id = None
        self._last_id = None
        self._buffer = bytearray()
        self._total = 0
        self._started = 0
        self._last_received = 0

    def _abort(self):
        if self._id is not None: self.discarded += 1
        self._id = None
        self._buffer.clear()

    def feed(self, part, received_ns):
        part = bytes(part)
        try:
            _check(type(received_ns) is int and received_ns >= 0 and 10 < len(part) <= 244)
            magic, version, msg_id, total, offset = struct.unpack_from('<BBIHH', part)
            _check(magic == 0xc7 and version == 1 and 1 <= total <= 256 and offset < total and
                   offset + len(part) - 10 <= total)
            if self._id is not None and received_ns - self._started > 500_000_000:
                raise BLEError('fragment timeout')
            if self._id is not None and received_ns < self._last_received:
                raise BLEError('fragment time reversed')
            if self._id is not None and msg_id != self._id:
                self._abort()
            if self._id is None:
                _check(offset == 0 and (self._last_id is None or
                       0 < ((msg_id - self._last_id) & 0xffffffff) < 0x80000000))
                self._id, self._total, self._started = msg_id, total, received_ns
            _check(msg_id == self._id and total == self._total and offset == len(self._buffer))
            self._buffer.extend(part[10:])
            self._last_received = received_ns
            if len(self._buffer) == self._total:
                result = bytes(self._buffer)
                decode(result)
                self._last_id = self._id
                self._id = None
                self._buffer.clear()
                return result
            return None
        except (BLEError, struct.error):
            self._abort()
            raise BLEError('invalid BLE fragment') from None
