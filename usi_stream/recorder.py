"""One bounded, direct MCAP writer owner. ROS monitoring is a separate optional callback."""
from dataclasses import dataclass, replace
import json
from pathlib import Path
from queue import Queue, Full
from threading import Event, Thread


@dataclass(frozen=True)
class Record:
    topic: str
    type_name: str
    serialized: bytes
    stamp_ns: int
    stream_id: str
    source_id: str
    epoch_id: str
    sequence: int
    details: str | None = None


class BoundedRecorder:
    def __init__(self, store, path, *, capacity=256, mirror=None):
        self.store=store; self.path=Path(path); self.queue=Queue(capacity)
        self.mirror=mirror; self.error=None; self.accepted=0; self.accepted_by_stream={}; self.overflow=0; self.overflow_by_stream={}
        self._opened=Event(); self._stop=object(); self._thread=None

    def open(self,timeout=5.0):
        if self._thread is not None: raise RuntimeError('writer already opened')
        self._thread=Thread(target=self._run,daemon=True,name='usi-mcap-writer')
        self._thread.start()
        if not self._opened.wait(timeout): raise TimeoutError('writer open timed out')
        if self.error: raise self.error

    def _run(self):
        try:
            self.store.open(self.path)
            self._opened.set()
            while True:
                item=self.queue.get()
                if item is self._stop: break
                if isinstance(item,Event):
                    item.set(); continue
                if self.error: continue
                try:
                    self.store.write(item)
                    self.accepted += 1
                    if item.stream_id:
                        self.accepted_by_stream[item.stream_id]=self.accepted_by_stream.get(item.stream_id,0)+1
                    if self.mirror:
                        try: self.mirror(item)
                        except Exception: pass  # monitoring cannot invalidate the bag
                except Exception as exc:
                    self.error=exc
        except Exception as exc:
            self.error=exc
        finally:
            self._opened.set()
            try: self.store.close()
            except Exception as exc: self.error=exc

    def submit(self, record):
        if self.error or self._thread is None or not self._thread.is_alive(): return False
        try: self.queue.put_nowait(record); return True
        except Full:
            self.overflow += 1
            self.overflow_by_stream[record.stream_id]=self.overflow_by_stream.get(record.stream_id,0)+1
            return False

    def flush(self,timeout=5.0):
        if self._thread is None: raise RuntimeError('writer not opened')
        barrier=Event()
        try: self.queue.put(barrier,timeout=timeout)
        except Full as exc: raise TimeoutError('writer flush queue timed out') from exc
        if not barrier.wait(timeout): raise TimeoutError('writer flush timed out')
        if self.error: raise self.error

    def close(self,timeout=5.0):
        if self._thread is None: return
        try: self.queue.put(self._stop,timeout=timeout)
        except Full as exc: raise TimeoutError('writer close queue timed out') from exc
        self._thread.join(timeout)
        if self._thread.is_alive(): raise TimeoutError('writer close timed out')
        if self.error: raise self.error


class JazzyMcapStore:
    """Lazy ROS imports permit pure state tests without sourcing the overlay."""
    def __init__(self): self.writer=None; self.topics=set(); self.path=None

    def open(self,path):
        import rosbag2_py
        self.path=Path(path)
        self.writer=rosbag2_py.SequentialWriter()
        config=Path(__file__).with_name('mcap_storage.yaml')
        self.writer.open(rosbag2_py.StorageOptions(uri=str(path),storage_id='mcap',
            storage_config_uri=str(config)),
                         rosbag2_py.ConverterOptions('cdr','cdr'))

    def write(self,record):
        import rosbag2_py
        if record.topic not in self.topics:
            self.writer.create_topic(rosbag2_py.TopicMetadata(id=0,name=record.topic,
                type=record.type_name,serialization_format='cdr'))
            self.topics.add(record.topic)
        self.writer.write(record.topic,record.serialized,record.stamp_ns)

    def close(self):
        if self.writer:
            self.writer.close(); self.writer=None

    def scan(self):
        import rosbag2_py
        from rclpy.serialization import deserialize_message
        from rosidl_runtime_py.utilities import get_message
        reader=rosbag2_py.SequentialReader()
        reader.open(rosbag2_py.StorageOptions(uri=str(self.path),storage_id='mcap'),
                    rosbag2_py.ConverterOptions('cdr','cdr'))
        types={t.name:t.type for t in reader.get_all_topics_and_types()}
        result=[]; decoded=[]
        try:
            while reader.has_next():
                topic,data,stamp=reader.read_next()
                msg=deserialize_message(data,get_message(types[topic]))
                if types[topic]=='usi_collection_msgs/msg/FrameRecord':
                    from .ros_messages import validate_reopened_frame
                    validate_reopened_frame(msg)
                source=getattr(msg,'source',msg)
                stream=getattr(source,'stream_id','')
                if not stream and topic.startswith('/usi_collection/'):
                    stream=topic.removeprefix('/usi_collection/')
                result.append(Record(topic,types[topic],b'',stamp,
                    stream,getattr(source,'source_id',''),
                    getattr(source,'epoch_id',''),getattr(source,'sequence',0),
                    getattr(source,'metadata_json',None) if stream in ('camera_calibration','tracking','seal') else None))
                decoded.append(msg)
        finally: reader.close()
        from .ros_messages import _legacy_boot_number
        by_identity={(r.stream_id,r.source_id,r.epoch_id,r.sequence):i for i,r in enumerate(result) if r.stream_id}
        trials=[decoded[i] for i,r in enumerate(result) if r.stream_id=='trial_metadata']
        trial_calibration_id=trials[0].calibration_id or None if len(trials)==1 else None
        for index,record in enumerate(result):
            if record.stream_id not in ('tracking','seal'): continue
            parent_stream='camera_pose' if record.stream_id=='tracking' else 'pressures'
            parent_index=by_identity.get((parent_stream,record.source_id,record.epoch_id,record.sequence))
            if parent_index is None: raise ValueError('derived join missing parent: '+record.stream_id)
            content=json.loads(record.details)
            if record.stream_id=='tracking':
                pose=json.loads(decoded[parent_index].metadata_json)
                if any(content.get(field)!=pose[field] for field in ('tracking_state','tracking_reason','pose_valid')):
                    raise ValueError('tracking content differs from pose')
            elif (content.get('pressure_sequence')!=record.sequence or
                  content.get('calibration_id')!=trial_calibration_id):
                raise ValueError('seal calibration/pressure join mismatch')
        for topic,parent_stream in (('/pressure','pressures'),('/pressure_timing','pressures'),
                                    ('/trigger','trigger'),('/trigger_timing','trigger')):
            parents={}
            for index,record in enumerate(result):
                if record.stream_id==parent_stream:
                    parents.setdefault(record.stamp_ns,[]).append(index)
            used={}
            for index,record in enumerate(result):
                if record.topic!=topic: continue
                key=record.stamp_ns; offset=used.get(key,0); matches=parents.get(key,[])
                if offset>=len(matches): raise ValueError('legacy join missing parent: '+topic)
                used[key]=offset+1; parent_index=matches[offset]
                parent=result[parent_index]; original=decoded[parent_index]; legacy=decoded[index]
                if topic=='/pressure':
                    expected=[value/100 for value in original.pressure_centi_pa]
                    actual=[legacy.vector.x,legacy.vector.y,legacy.vector.z]
                    if any(abs(a-b)>1e-6 for a,b in zip(actual,expected)):
                        raise ValueError('legacy pressure value mismatch')
                elif topic=='/trigger':
                    if list(legacy.buttons)!=[int(original.pressed),int(original.suction_on)] or list(legacy.axes):
                        raise ValueError('legacy trigger value mismatch')
                else:
                    source=original.source
                    expected=[source.source_time_us,parent.stamp_ns,1]
                    if topic=='/pressure_timing': expected.append(original.quality_mask)
                    expected.extend((_legacy_boot_number(parent.epoch_id),source.raw_sequence))
                    if len(legacy.data)!=len(expected)+1 or list(legacy.data)[1:]!=expected:
                        raise ValueError('legacy timing value mismatch: '+topic)
                result[index]=replace(record,source_id=parent.source_id,
                                      epoch_id=parent.epoch_id,sequence=parent.sequence)
            if sum(record.topic==topic for record in result)!=sum(record.stream_id==parent_stream for record in result):
                raise ValueError('legacy join count mismatch: '+topic)
        return result
