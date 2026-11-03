"""Generated records; no hardware source is inferred."""
import pytest
import threading
from usi_stream.recorder import BoundedRecorder, Record


class Store:
    def __init__(self, fail=False):
        self.items=[]; self.closed=False; self.fail=fail
    def open(self, path): self.path=path
    def write(self, record):
        if self.fail: raise OSError('full')
        self.items.append(record)
    def close(self): self.closed=True
    def scan(self): return list(self.items)


def test_single_worker_drains_and_closes(tmp_path):
    store=Store()
    writer=BoundedRecorder(store,tmp_path/'bag',capacity=2)
    writer.open()
    for n in range(2):
        assert writer.submit(Record('/test','std_msgs/msg/String',b'abc',n,'pressures','esp','boot',n))
    writer.close()
    assert store.closed
    assert [r.sequence for r in store.scan()] == [0,1]


def test_write_failure_is_reported_after_join(tmp_path):
    writer=BoundedRecorder(Store(fail=True),tmp_path/'bag',capacity=2)
    writer.open()
    writer.submit(Record('/test','std_msgs/msg/String',b'abc',0,'pressures','esp','boot',0))
    with pytest.raises(OSError,match='full'):
        writer.close()


def test_bounded_queue_reports_overflow_without_silent_acceptance(tmp_path):
    entered=threading.Event(); release=threading.Event()
    class SlowStore(Store):
        def write(self,record):
            entered.set(); release.wait(2)
            super().write(record)
    writer=BoundedRecorder(SlowStore(),tmp_path/'bag',capacity=1)
    writer.open()
    first=Record('/test','std_msgs/msg/String',b'a',0,'pressures','esp','boot',0)
    assert writer.submit(first)
    assert entered.wait(1)
    assert writer.submit(Record('/test','std_msgs/msg/String',b'b',1,'pressures','esp','boot',1))
    assert not writer.submit(Record('/test','std_msgs/msg/String',b'c',2,'pressures','esp','boot',2))
    assert writer.overflow==1
    release.set(); writer.close()
