"""Clock-injected collection state. No hardware, motor command or writer exists here."""
from collections import deque
from dataclasses import dataclass
import math
from .collection_protocol import STREAM_IDS, U64_MAX


def _uint(value): return type(value) is int and 0 <= value <= U64_MAX

def _check(ok, message):
    if not ok: raise ValueError(message)


def _fresh(received, now, stale):
    return received is not None and received <= now and now-received <= stale


@dataclass(frozen=True)
class SampleIdentity:
    stream_id: str
    source_id: str
    epoch_id: str
    sequence: int

    def __post_init__(self):
        _check(self.stream_id in STREAM_IDS and isinstance(self.source_id,str) and bool(self.source_id) and isinstance(self.epoch_id,str) and bool(self.epoch_id) and _uint(self.sequence),'invalid identity')


@dataclass(frozen=True)
class StreamCounters:
    """None means unavailable, never an inferred zero."""
    source_count: object = None
    received_count: object = None
    writer_accepted_count: object = None
    queue_overflow_count: object = None
    rejected_count: object = None
    duplicate_count: object = None

    def __post_init__(self):
        _check(all(value is None or _uint(value) for value in vars(self).values()), 'invalid counter')


@dataclass(frozen=True)
class ChamberCalibration:
    sensor_index: int
    sector_index: int
    seal_on_kpa_abs: float
    seal_off_kpa_abs: float
    persistence_ns: int

    def __post_init__(self):
        _check(type(self.sensor_index) is int and 0 <= self.sensor_index < 3 and
               type(self.sector_index) is int and 0 <= self.sector_index < 3,'invalid chamber mapping')
        _check(all(type(x) in (int,float) and math.isfinite(x) for x in (self.seal_on_kpa_abs,self.seal_off_kpa_abs))
               and 0 <= self.seal_on_kpa_abs < self.seal_off_kpa_abs and _uint(self.persistence_ns),'invalid thresholds')


@dataclass(frozen=True)
class PressureCalibration:
    calibration_id: str
    chambers: tuple

    def __post_init__(self):
        _check(isinstance(self.calibration_id,str) and bool(self.calibration_id) and len(self.chambers) == 3
               and all(isinstance(c,ChamberCalibration) for c in self.chambers),'invalid calibration')
        _check({c.sensor_index for c in self.chambers} == {0,1,2} and
               {c.sector_index for c in self.chambers} == {0,1,2},'mapping must be permutations')
        object.__setattr__(self,'chambers',tuple(self.chambers))


@dataclass(frozen=True)
class SealSnapshot:
    states: tuple
    aggregate: str
    sealed_count: int
    known_count: int
    pressures_kpa_abs: tuple
    calibration_id: object


class SealModel:
    def __init__(self, calibration=None, *, stale_ns=250_000_000):
        _check(calibration is None or isinstance(calibration,PressureCalibration),'invalid calibration')
        _check(_uint(stale_ns),'invalid stale timeout')
        self.calibration = calibration
        self.stale_ns = stale_ns
        self.received_ns = None
        self.pressures = (None,)*3
        self.quality_mask = 0
        self._sealed = [False]*3
        self._pending = [None]*3

    def _advance(self, now_ns):
        if not _fresh(self.received_ns,now_ns,self.stale_ns):
            self._sealed = [False]*3; self._pending = [None]*3
            return
        for index, pending in enumerate(self._pending):
            if pending is not None and now_ns-pending[1] >= self.calibration.chambers[index].persistence_ns:
                self._sealed[index] = pending[0]; self._pending[index] = None

    def update(self, pressures_kpa_abs, *, quality_mask, received_ns):
        _check(len(pressures_kpa_abs) == 3 and type(quality_mask) is int and 0 <= quality_mask <= 7
               and _uint(received_ns),'invalid pressure sample')
        _check(self.received_ns is None or received_ns >= self.received_ns,'out-of-order pressure receipt')
        self._advance(received_ns)
        self.received_ns = received_ns
        self.pressures = tuple(pressures_kpa_abs)
        self.quality_mask = quality_mask
        if self.calibration is None: return
        for index,chamber in enumerate(self.calibration.chambers):
            pressure = self.pressures[chamber.sensor_index]
            valid = bool(quality_mask & (1 << chamber.sensor_index)) and type(pressure) in (int,float) and math.isfinite(pressure) and pressure >= 0
            if not valid:
                self._sealed[index] = False; self._pending[index] = None; continue
            target = self._sealed[index]
            if pressure <= chamber.seal_on_kpa_abs: target = True
            elif pressure >= chamber.seal_off_kpa_abs: target = False
            if target == self._sealed[index]: self._pending[index] = None
            elif self._pending[index] is None or self._pending[index][0] != target:
                self._pending[index] = (target,received_ns)
        self._advance(received_ns)

    def snapshot(self, now_ns):
        _check(_uint(now_ns),'invalid time')
        self._advance(now_ns)
        states=[]; pressures=[]
        for index in range(3):
            sensor = self.calibration.chambers[index].sensor_index if self.calibration else index
            pressure = self.pressures[sensor]
            valid = bool(self.quality_mask & (1 << sensor)) and type(pressure) in (int,float) and math.isfinite(pressure) and pressure >= 0
            fresh = _fresh(self.received_ns,now_ns,self.stale_ns)
            pressures.append(pressure if fresh and valid else None)
            if self.received_ns is None: state='unknown'
            elif not fresh: state='stale'
            elif not valid: state='invalid'
            elif self.calibration is None: state='uncalibrated'
            else: state='sealed' if self._sealed[index] else 'unsealed'
            states.append(state)
        known = sum(state in ('sealed','unsealed') for state in states)
        count = states.count('sealed')
        aggregate = 'unavailable' if known < 3 else 'full' if count == 3 else 'none' if count == 0 else 'partial'
        return SealSnapshot(tuple(states),aggregate,count,known,tuple(pressures),self.calibration.calibration_id if self.calibration else None)


class TriggerModel:
    def __init__(self, *, stale_ns=1_000_000_000):
        _check(_uint(stale_ns),'invalid timeout')
        self.stale_ns=stale_ns; self.received_ns=None; self.pressed=None

    def update(self, *, pressed, received_ns):
        _check(type(pressed) is bool and _uint(received_ns) and
               (self.received_ns is None or received_ns >= self.received_ns),'invalid trigger')
        self.pressed=pressed; self.received_ns=received_ns

    def state(self, now_ns):
        _check(_uint(now_ns),'invalid time')
        if not _fresh(self.received_ns,now_ns,self.stale_ns): return 'unknown'
        return 'off' if self.pressed else 'on'


@dataclass(frozen=True)
class SequenceObservation:
    disposition: str
    sequence: int
    missing: object = None  # half-open (start, end), only established gaps


class SequenceHistory:
    """One stream/source history. Wrap inference needs forward distance < modulus/2.

    Separate pressure and trigger instances; boot/world IDs define epochs. Old
    epochs cannot silently become current again. Exhausted epoch memory raises.
    """
    def __init__(self, *, modulus=2**32, max_epochs=64):
        _check(type(modulus) is int and 2 <= modulus <= 2**64 and modulus % 2 == 0 and
               type(max_epochs) is int and max_epochs > 0,'invalid history bounds')
        self.modulus=modulus; self.max_epochs=max_epochs; self.epoch=None; self.sequence=None; self._seen=set()

    def observe(self, epoch, raw_sequence):
        _check(isinstance(epoch,str) and bool(epoch) and type(raw_sequence) is int and 0 <= raw_sequence < self.modulus,'invalid sequence')
        if epoch != self.epoch:
            if epoch in self._seen: return SequenceObservation('old_epoch',raw_sequence)
            _check(len(self._seen) < self.max_epochs,'epoch history exhausted')
            self._seen.add(epoch); self.epoch=epoch; self.sequence=raw_sequence
            return SequenceObservation('new_epoch',raw_sequence)
        delta=(raw_sequence-self.sequence % self.modulus) % self.modulus
        if delta == 0: return SequenceObservation('duplicate',self.sequence)
        if delta >= self.modulus//2: return SequenceObservation('out_of_order',raw_sequence)
        sequence=self.sequence+delta
        _check(sequence <= U64_MAX,'extended sequence overflow')
        missing=(self.sequence+1,sequence) if delta > 1 else None
        self.sequence=sequence
        return SequenceObservation('accepted',sequence,missing)


class BoundedQueue:
    """Single-owner FIFO; overflow rejects newest and is always counted."""
    def __init__(self, capacity):
        _check(type(capacity) is int and capacity > 0,'invalid queue capacity')
        self.capacity=capacity; self.overflow_count=0; self._items=deque()

    def offer(self, item):
        if len(self._items) == self.capacity:
            self.overflow_count += 1; return False
        self._items.append(item); return True

    def pop(self): return self._items.popleft() if self._items else None
    def __len__(self): return len(self._items)


class TrialModel:
    """Phone presentation model, never opens a writer or self-acknowledges Recording."""
    def __init__(self, *, host_stale_ns=2_000_000_000):
        _check(_uint(host_stale_ns),'invalid timeout')
        self.host_stale_ns=host_stale_ns; self.host_session_id=None; self.trial_id=None
        self.revision=None; self.state='not_connected'; self.verification='pending'; self.received_ns=None
        self._request_id=None; self._retired_hosts=set()

    def begin_request(self, request_id, trial_id):
        _check(isinstance(request_id,str) and bool(request_id) and isinstance(trial_id,str) and bool(trial_id),'invalid request')
        if request_id == self._request_id:
            _check(trial_id == self.trial_id,'request ID reused for another trial'); return
        _check(self.state in ('not_connected','idle','saved','incomplete'),'trial already active')
        if trial_id != self.trial_id:
            self.host_session_id=None; self._retired_hosts.clear()
        self._request_id=request_id; self.trial_id=trial_id; self.state='preparing'; self.revision=None
        self.received_ns=None; self.verification='pending'

    def apply_status(self, *, host_session_id, trial_id, revision, state, verification, received_ns):
        _check(isinstance(host_session_id,str) and bool(host_session_id) and _uint(revision) and _uint(received_ns)
               and state in ('idle','preparing','recording','finalizing','saved','incomplete')
               and verification in ('pending','passed','failed'),'invalid status')
        _check(state != 'saved' or verification == 'passed','saved needs verification')
        _check(verification != 'passed' or state == 'saved','passed needs saved')
        _check(state == 'idle' or isinstance(trial_id,str) and bool(trial_id),'missing trial ID')
        if self.state in ('saved','incomplete') and state != self.state: return False
        if self.state == 'finalizing' and state in ('idle','preparing','recording'): return False
        if self.trial_id is not None and trial_id != self.trial_id: return False
        if host_session_id in self._retired_hosts: return False
        if self.host_session_id == host_session_id:
            if self.received_ns is not None and received_ns < self.received_ns: return False
            if self.revision is not None:
                if self.state in ('saved','incomplete') and state != self.state: return False
                if revision < self.revision: return False
                if revision == self.revision and (state != self.state or verification != self.verification): return False
        elif self.host_session_id is not None:
            _check(len(self._retired_hosts) < 64,'host history exhausted')
            # Host restart cannot restore a continuous recording assurance.
            if self.state in ('preparing','recording','finalizing') and state != 'incomplete': return False
            self._retired_hosts.add(self.host_session_id)
        self.host_session_id=host_session_id; self.trial_id=trial_id; self.revision=revision
        self.state=state; self.verification=verification; self.received_ns=received_ns
        return True

    def display_state(self, now_ns):
        _check(_uint(now_ns),'invalid time')
        if self.received_ns is None: return self.state
        if not _fresh(self.received_ns,now_ns,self.host_stale_ns): return 'host_stale'
        return self.state
