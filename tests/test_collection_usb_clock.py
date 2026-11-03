"""Host side of the USB four timestamp clock exchange."""
from usi_stream.collection_protocol import MessageType, Packet, validate_metadata
from usi_stream.collector import UsbClock


def test_host_ping_pong_emits_completed_unfitted_usb_exchange():
    clock=UsbClock('host-session')
    ping=clock.ping(100)
    assert ping=={'ping_id':0,'host_send_ns':100}
    validate_metadata(MessageType.PING,ping)
    pong=dict(ping_id=0,host_send_ns=100,phone_receive_ns=140,
              phone_send_ns=160,session_id='phone-session')
    completion=clock.complete(pong,200)
    validate_metadata(MessageType.BLE_CLOCK,completion)
    assert completion['link']=='usb'
    assert [completion[k] for k in ('t1_ns','t2_ns','t3_ns','t4_ns')]==[100,140,160,200]
    assert completion['source_id']=='phone-session' and completion['epoch_id']=='phone-session'
    assert completion['mapping']==dict(valid=False,scale=None,offset_ns=None,uncertainty_ns=None)
    assert clock.complete(pong,201) is None


def test_host_rejects_pong_with_wrong_original_send_time():
    clock=UsbClock('host-session'); clock.ping(100)
    pong=dict(ping_id=0,host_send_ns=101,phone_receive_ns=140,
              phone_send_ns=160,session_id='phone-session')
    try: clock.complete(pong,200)
    except ValueError as exc: assert 'PING' in str(exc)
    else: raise AssertionError('mismatched PONG accepted')
