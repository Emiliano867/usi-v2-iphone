"""Synthetic BLE golden vectors; no hardware evidence."""
from pathlib import Path
import struct
import pytest
from usi_stream import ble_protocol as ble
from usi_stream.collection_state import SequenceHistory, SealModel

FIX = Path(__file__).parent / 'fixtures'
def golden(name):
    return bytes.fromhex((FIX / ('ble_' + name + '.hex')).read_text())
def parts():
    return [bytes.fromhex(s) for s in (FIX / 'ble_pressure_mtu20.hex').read_text().splitlines()]

def test_pressure_units_quality_wrap_and_reboot():
    event = ble.decode(golden('pressure'))
    assert event.boot_id == 0x12345678
    assert event.samples[0].pressures_centi_pa == (10132500, -100, 9000000)
    assert event.samples[0].quality_error_mask == 2
    assert event.samples[0].quality_mask == 5
    assert event.samples[0].pressures_kpa_abs == (101.325, -0.001, 90.0)
    history = SequenceHistory()
    assert history.observe('a', event.samples[0].raw_sequence).sequence == 0xffffffff
    assert history.observe('a', event.samples[1].raw_sequence).sequence == 0x100000000
    assert history.observe('b', 0).sequence == 0
    assert history.observe('a', 1).disposition == 'old_epoch'
    seal = SealModel()
    seal.update(event.samples[0].pressures_kpa_abs, quality_mask=5, received_ns=1)
    assert seal.snapshot(2).states[1] == 'invalid'
    assert seal.snapshot(250000002).states == ('stale',)*3

def test_trigger_clock_and_request():
    trigger = ble.decode(golden('trigger'))
    assert (trigger.raw_sequence, trigger.source_time_us, trigger.pressed, trigger.suction_on, trigger.heartbeat) == (7,1000001,True,False,False)
    clock = ble.decode(golden('clock'))
    assert (clock.request_id, clock.t1_phone_ns, clock.t2_device_us, clock.t3_device_us, clock.snapshot_device_us) == (42,1000000000,1000100,1000300,1000200)
    assert (clock.pressure_acquired, clock.trigger_acquired, clock.pressure_overflow, clock.pressure_notify_lost, clock.notify_failures) == (0x100000001,8,2,5,2)
    assert ble.clock_request(42,1000000000) == golden('request')

def test_safe_default_mtu_and_larger_payload():
    assert ble.fragment(golden('pressure'),9,20) == parts()
    for size in (20,21,64,244):
        r = ble.Reassembler()
        fragments=ble.fragment(golden('pressure'),9,size)
        for i, part in enumerate(fragments):
            got=r.feed(part, i)
            assert got == (golden('pressure') if i==len(fragments)-1 else None)
        assert r.discarded == 0

@pytest.mark.parametrize('mode',['duplicate','order','oversized','offset','version','total','empty'])
def test_malformed_fragments_abort_partial(mode):
    r=ble.Reassembler(); p=parts(); assert r.feed(p[0],0) is None
    bad={'duplicate':p[0], 'order':p[2], 'oversized':p[1]+bytes(245), 'offset':p[1][:8]+b'\xff\xff'+p[1][10:], 'version':bytes([0xc7,2])+p[1][2:], 'total':p[1][:6]+b'\x01\x01'+p[1][8:], 'empty':p[1][:10]}[mode]
    with pytest.raises(ble.BLEError): r.feed(bad,1)
    assert r.discarded == 1
    with pytest.raises(ble.BLEError): r.feed(p[1],2)

def test_fragment_timeout_new_message_disconnect_and_id_wrap():
    r=ble.Reassembler(); p=parts(); r.feed(p[0],0)
    with pytest.raises(ble.BLEError): r.feed(p[1],500000001)
    assert r.discarded == 1
    for msg_id in (10,11):
        for part in ble.fragment(golden('trigger'),msg_id,20): result=r.feed(part,500000002)
        assert result == golden('trigger')
    r.reset()
    for msg_id in (0xffffffff,0):
        for part in ble.fragment(golden('trigger'),msg_id,20): result=r.feed(part,500000002)
        assert result == golden('trigger')
    with pytest.raises(ble.BLEError): r.feed(ble.fragment(golden('trigger'),0,20)[0],500000003)
    r.reset()
    for part in ble.fragment(golden('trigger'),0,20): result=r.feed(part,1)
    assert result == golden('trigger')
    r.feed(p[0],2)
    for part in ble.fragment(golden('trigger'),10,20): result=r.feed(part,3)
    assert result == golden('trigger') and r.discarded == 2

@pytest.mark.parametrize('name',['pressure','trigger','clock'])
def test_truncation_and_unknown_values(name):
    raw=golden(name)
    for n in range(len(raw)):
        with pytest.raises(ble.BLEError): ble.decode(raw[:n])
    for bad in (raw+b'\x00', b'\x7f'+raw[1:],raw[:1]+bytes(4)+raw[5:]):
        with pytest.raises(ble.BLEError): ble.decode(bad)

def test_semantic_rejections_and_bounds():
    p=bytearray(golden('pressure')); p[30]=8
    with pytest.raises(ble.BLEError): ble.decode(p)
    p=bytearray(golden('pressure')); p[18:22]=struct.pack('<i',-100)
    with pytest.raises(ble.BLEError): ble.decode(p)  # valid-bit channel cannot be negative
    t=bytearray(golden('trigger')); t[17]=2
    with pytest.raises(ble.BLEError): ble.decode(t)
    c=bytearray(golden('clock')); c[25:33]=struct.pack('<Q',1)
    with pytest.raises(ble.BLEError): ble.decode(c)
    for args in ((b'',0,20),(bytes(257),0,20),(b'x',0,19),(b'x',0,245)):
        with pytest.raises(ble.BLEError): ble.fragment(*args)
    with pytest.raises(ble.BLEError): ble.clock_request(True,1)

def test_reassembler_rejects_time_reversal():
    r=ble.Reassembler(); p=parts(); r.feed(p[0],100)
    with pytest.raises(ble.BLEError): r.feed(p[1],99)
    assert r.discarded == 1


def test_inflight_ids_advance_even_when_abandoned():
    trigger=golden('trigger')
    def first(ident): return ble.fragment(trigger,ident,20)[0]
    for previous, candidate in ((10,9),(10,10),(10,10+0x80000000)):
        r=ble.Reassembler(); r.feed(first(previous),0)
        with pytest.raises(ble.BLEError): r.feed(first(candidate),1)
        assert r.discarded==1
        with pytest.raises(ble.BLEError): r.feed(first(previous),2)
    r=ble.Reassembler()
    for part in ble.fragment(trigger,8,20): r.feed(part,0)
    r.feed(first(10),1)
    with pytest.raises(ble.BLEError): r.feed(first(9),2)
    r=ble.Reassembler(); r.feed(first(10),0)
    assert r.feed(first(11),1) is None and r.discarded==1
    with pytest.raises(ble.BLEError): r.feed(first(10),2)
    r=ble.Reassembler(); r.feed(first(0xffffffff),0)
    assert r.feed(first(0),1) is None and r.discarded==1
    for part in ble.fragment(trigger,0,20)[1:]: result=r.feed(part,2)
    assert result==trigger
    r=ble.Reassembler(); r.feed(first(10),0)
    with pytest.raises(ble.BLEError): r.feed(ble.fragment(trigger,10,20)[1],500000001)
    with pytest.raises(ble.BLEError): r.feed(first(9),500000002)
    assert r.feed(first(11),500000003) is None
