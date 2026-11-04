"""Authoritative v2 collection endpoint. The phone never self-confirms a saved bag."""
import argparse
import copy
import hashlib
import json
import os
import shutil
import socket
import sys
import threading
import time
import uuid
from pathlib import Path

from .collection_protocol import (MessageType, Packet, FULL_REQUIRED_STREAMS,
    CORE_REQUIRED_STREAMS, FENCED_STREAMS, PORT, recv_packet, encode_packet,
    validate_metadata)
from .recorder import BoundedRecorder, JazzyMcapStore
from .usbmux import connect_usb, USBMuxError

SCHEMA='usi.collection.v2'
UNITS={'main_rgb':'jpeg','raw_depth':'m','depth_confidence':'level','camera_pose':'m',
       'tracking':'state','camera_calibration':'pixel','ultrawide':'jpeg',
       'pressures':'kPa_abs','trigger':'boolean','seal':'state',
       'trial_metadata':'json','timing':'ns','health':'count'}
LANES={'core':('main_rgb','camera_pose','pressures','trigger'),
       'full':('main_rgb','camera_pose','ultrawide','pressures','trigger')}


class Collector:
    def __init__(self, output_root, *, storage_factory=JazzyMcapStore,
                 record_factory=None, now_ns=time.monotonic_ns, wall_ns=time.time_ns,
                 drain_timeout_s=2.0, queue_capacity=256, min_free_bytes=16*1024*1024,
                 on_status=None, mirror=None, generated_test_data=False,
                 static_record_factory=None):
        self.root=Path(output_root); self.storage_factory=storage_factory
        if record_factory is None: record_factory=self._ros_records
        self.record_factory=record_factory; self.now_ns=now_ns; self.wall_ns=wall_ns
        self.static_record_factory=static_record_factory or self._ros_static_record
        self.drain_timeout_s=drain_timeout_s; self.queue_capacity=queue_capacity
        self.min_free_bytes=min_free_bytes; self.on_status=on_status; self.mirror=mirror
        self.generated_test_data=generated_test_data
        self.host_session_id=str(uuid.uuid4()); self.revision=0; self.state='idle'
        self.trial_id=None; self.snapshot=None; self.reason=None; self.verification='pending'
        self.bag_path=None; self.store=None; self.writer=None; self.begin_fences={}; self.end_fences={}
        self.fresh={}; self.received={}; self._ledger={}; self._final_thread=None
        self._outcomes={}
        self.received_counts={}; self.record_identities={}; self.duplicate_counts={}; self.rejected_counts={}
        self._lock=threading.RLock(); self._condition=threading.Condition(self._lock)
        self._source_counters=[]; self._failures=[]; self._last_trial_id=None
        self.seal_model=None; self._latest_frame_counters={}; self._begin_frame_counters={}
        self._accepting=False
        self._source_times={}; self._begin_ns=None; self._end_ns=None
        self._latest_source_counters={}; self._begin_source_counters={}
        self._observed_missing_ranges=set()
        self._legacy_bridge_counts={'pressures':0,'trigger':0}
        self._camera_calibrations={}; self._prepared_camera_calibration=None

    def _abort_active(self,reason):
        if self.state!='recording': return
        self._failures.append(reason)
        self._accepting=False
        self.end_fences={lane:(src,epoch,start) for lane,(src,epoch,start) in self.begin_fences.items()}
        self.state='finalizing'; self.revision+=1
        self._final_thread=threading.Thread(target=self._finalize,daemon=True)
        self._final_thread.start()

    def _expire_if_needed(self):
        if self.state!='recording': return
        if self._failures or (self.writer and (self.writer.error or self.writer.overflow)):
            self._abort_active(self._failures[0] if self._failures else 'writer failure')
            return
        config=self.snapshot['configuration']; now=self.now_ns()
        for lane,(source,epoch,_) in self.begin_fences.items():
            last=self.fresh.get((lane,source,epoch))
            limit=(config['pressure_stale_ns'] if lane=='pressures' else
                   config['trigger_stale_ns'] if lane=='trigger' else config['vision_stale_ns'])
            if last is None or now-last>limit+config['mandatory_stale_grace_ns']:
                self._abort_active('stale required source: '+lane); return

    def _ros_records(self,packet,monotonic_ns,wall_ns):
        from .ros_messages import records_for_packet
        return records_for_packet(packet,monotonic_ns,wall_ns,self.seal_model,self._legacy_bridge_counts)

    def _status(self, request_id=None):
        required=list(self.snapshot['required_streams']) if self.snapshot else []
        missing=list(self.snapshot['missing_modalities']) if self.snapshot else []
        unavailable=[]
        if self.snapshot and self.state in ('preparing','incomplete'):
            unavailable=self._unavailable()
        counters=[]
        caps={c['stream_id']:c for c in self.snapshot['capabilities']} if self.snapshot else {}
        final_counters={c['stream_id']:c for c in self._source_counters}
        for stream in required:
            cap=caps.get(stream)
            if cap is None or cap['source_id'] is None or cap['epoch_id'] is None: continue
            source,epoch=self.record_identities.get(stream,(cap['source_id'],cap['epoch_id']))
            final=final_counters.get(stream)
            counters.append(dict(stream_id=stream,source_id=source,epoch_id=epoch,
                source_count=final['source_count'] if final and final['source_id']==source and final['epoch_id']==epoch else None,
                received_count=self.received_counts.get(stream,0),
                writer_accepted_count=self.writer.accepted_by_stream.get(stream,0) if self.writer else 0,
                queue_overflow_count=self.writer.overflow_by_stream.get(stream,0) if self.writer else 0,
                rejected_count=self.rejected_counts.get(stream,0),duplicate_count=self.duplicate_counts.get(stream,0),
                missing_ranges=final['missing_ranges'] if final and final['source_id']==source and final['epoch_id']==epoch else []))
        result=dict(host_session_id=self.host_session_id,host_time_ns=self.now_ns(),
            request_id=request_id,trial_id=self.trial_id,revision=self.revision,
            state=self.state,ready=self.state in ('idle','saved','incomplete') or (self.state=='preparing' and not unavailable and self.writer is not None and not self.writer.error),
            profile=self.snapshot['profile'] if self.snapshot else None,
            required_streams=required,missing_modalities=missing,
            missing_required_streams=unavailable,reason=self.reason,
            bag_path=str(self.bag_path) if self.bag_path else None,
            verification=self.verification,counters=counters)
        validate_metadata(MessageType.TRIAL_STATUS,result)
        return result

    def status(self,request_id=None):
        with self._lock:
            self._expire_if_needed()
            return self._status(request_id)

    def _unavailable(self):
        if not self.snapshot: return []
        caps={c['stream_id']:c for c in self.snapshot['capabilities']}
        missing=[]; now=self.now_ns(); config=self.snapshot['configuration']
        for stream in self.snapshot['required_streams']:
            cap=caps.get(stream)
            if cap is None or not cap['available'] or cap['schema']!=SCHEMA or cap['units']!=UNITS.get(stream):
                missing.append(stream)
        for lane in LANES[self.snapshot['profile']]:
            cap=caps.get(lane)
            if cap is None or not cap['available']: continue
            stamp=self.fresh.get((lane,cap['source_id'],cap['epoch_id']))
            limit=(config['pressure_stale_ns'] if lane=='pressures' else
                   config['trigger_stale_ns'] if lane=='trigger' else config['vision_stale_ns'])
            if stamp is None or stamp>now or now-stamp>limit: missing.append(lane)
        if self._prepared_camera_calibration is None: missing.append('camera_calibration')
        return sorted(set(missing))

    def command(self,meta):
        validate_metadata(MessageType.TRIAL_COMMAND,meta)
        with self._lock:
            self._expire_if_needed()
            signature=json.dumps(meta,sort_keys=True,separators=(',',':'))
            previous=self._ledger.get(meta['request_id'])
            if previous is not None:
                if previous!=signature: raise ValueError('request_id reused with different contents')
                return self._status_for_trial(meta['trial_id'],meta['request_id'])
            action=meta['action']
            if action=='status':
                if len(self._ledger)>=4096: raise ValueError('request ledger full')
                result=self._status_for_trial(meta['trial_id'],meta['request_id'])
                self._ledger[meta['request_id']]=signature
                return result
            if len(self._ledger)>=4096: raise ValueError('request ledger full')
            if action=='stop' and self.state in ('finalizing','incomplete') and meta['trial_id']==self.trial_id:
                self._ledger[meta['request_id']]=signature
                return self._status(meta['request_id'])
            if meta['expected_revision']!=self.revision: raise ValueError('revision conflict')
            if action=='prepare': result=self._prepare(meta)
            elif action=='begin': result=self._begin(meta)
            else: result=self._stop(meta)
            self._ledger[meta['request_id']]=signature
            return result

    def _status_for_trial(self,trial_id,request_id):
        if trial_id==self.trial_id: return self._status(request_id)
        outcome=self._outcomes.get(trial_id)
        if outcome is None: raise ValueError('unknown or retired trial_id')
        result=copy.deepcopy(outcome); result['request_id']=request_id
        result['host_time_ns']=self.now_ns()
        validate_metadata(MessageType.TRIAL_STATUS,result)
        return result

    def _remember_outcome(self):
        if self.trial_id is not None: self._outcomes[self.trial_id]=copy.deepcopy(self._status())

    def _prepare(self,meta):
        if self.state not in ('idle','saved','incomplete'): raise ValueError('trial already active')
        if meta['trial_id'] in self._outcomes or meta['trial_id']==self.trial_id: raise ValueError('trial_id already used')
        if len(self._outcomes)>=256: raise ValueError('trial outcome ledger full')
        self.trial_id=meta['trial_id']; self.snapshot=meta['snapshot']; self.state='preparing'
        self.reason=None; self.verification='pending'; self.begin_fences={}; self.end_fences={}
        self.received={}; self.received_counts={}; self.record_identities={}
        self.duplicate_counts={}; self.rejected_counts={}
        self._source_counters=[]; self._failures=[]; self.writer=None; self.store=None; self.bag_path=None
        self._source_times={}; self._begin_ns=None; self._end_ns=None
        self._observed_missing_ranges=set()
        self.seal_model=None
        main=next((c for c in self.snapshot['capabilities'] if c['stream_id']=='main_rgb'),None)
        self._prepared_camera_calibration=copy.deepcopy(
            self._camera_calibrations.get((main['source_id'],main['epoch_id'])) if main else None)
        if self.snapshot['calibration']:
            from .collection_state import ChamberCalibration, PressureCalibration, SealModel
            calibration=self.snapshot['calibration']
            chambers=tuple(ChamberCalibration(**c) for c in sorted(calibration['chambers'],key=lambda c:c['sector_index']))
            self.seal_model=SealModel(PressureCalibration(calibration['calibration_id'],chambers),
                                      stale_ns=self.snapshot['configuration']['pressure_stale_ns'])
        self.revision+=1
        unavailable=self._unavailable()
        if unavailable:
            self.reason='required streams unavailable: '+','.join(unavailable)
            self.state='incomplete'; self.verification='failed'; self.revision+=1
            self._remember_outcome()
            return self._status(meta['request_id'])
        self.root.mkdir(parents=True,exist_ok=True)
        if shutil.disk_usage(self.root).free<self.min_free_bytes:
            self.reason='insufficient disk space'; self.state='incomplete'
            self.verification='failed'; self.revision+=1
            self._remember_outcome()
            return self._status(meta['request_id'])
        name='trial-'+hashlib.sha256(self.trial_id.encode()).hexdigest()[:16]
        self.bag_path=self.root/name
        if self.bag_path.exists():
            self.reason='bag path already exists'; self.state='incomplete'
            self.verification='failed'; self.revision+=1
            self._remember_outcome()
            return self._status(meta['request_id'])
        try:
            self.store=self.storage_factory()
            self.writer=BoundedRecorder(self.store,self.bag_path,capacity=self.queue_capacity,mirror=self.mirror)
            self.writer.open()
        except Exception as exc:
            self.state='incomplete'; self.verification='failed'; self.reason='writer open: '+str(exc)
            self.revision+=1
            self._remember_outcome()
        return self._status(meta['request_id'])

    def _fence_map(self,fences):
        assert self.snapshot
        lanes=LANES[self.snapshot['profile']]
        if {f['stream_id'] for f in fences}!=set(lanes): raise ValueError('wrong fenced lane set')
        caps={c['stream_id']:c for c in self.snapshot['capabilities']}
        result={}
        for f in fences:
            lane=f['stream_id']; cap=caps[lane]
            if (f['source_id'],f['epoch_id'])!=(cap['source_id'],cap['epoch_id']):
                raise ValueError('fence source/epoch mismatch')
            result[lane]=(f['source_id'],f['epoch_id'],f['next_sequence'])
        return result

    def _begin(self,meta):
        if self.state!='preparing' or meta['trial_id']!=self.trial_id: raise ValueError('trial not prepared')
        try: fences=self._fence_map(meta['fences'])
        except ValueError as exc:
            self.reason=str(exc); return self._status(meta['request_id'])
        unavailable=self._unavailable()
        if unavailable or self.writer is None or self.writer.error:
            self.reason='required streams unavailable: '+','.join(unavailable) if unavailable else 'writer unavailable'
            return self._status(meta['request_id'])
        self.begin_fences=fences; self.state='recording'; self.reason=None; self.revision+=1
        self._accepting=True
        self._begin_ns=self.now_ns(); self._end_ns=None
        self._begin_frame_counters=copy.deepcopy(self._latest_frame_counters)
        self._begin_source_counters=copy.deepcopy(self._latest_source_counters)
        self._write_static()
        try: self.writer.flush()
        except Exception as exc: self._abort_active('writer metadata: '+str(exc))
        if self._failures: self._abort_active(self._failures[0])
        return self._status(meta['request_id'])

    def _write_static(self):
        stamp=self.wall_ns(); snap=self.snapshot
        records=self.static_record_factory(snap,self.trial_id,stamp,
            self._prepared_camera_calibration,self.begin_fences['main_rgb'][2])
        for record in records:
            if not self.writer.submit(record):
                self._failures.append('writer queue overflow at '+record.stream_id)
            else:
                self.received_counts[record.stream_id]=1
                self.record_identities[record.stream_id]=(record.source_id,record.epoch_id)

    @staticmethod
    def _ros_static_record(snap,trial_id,stamp,calibration,begin_sequence):
        from usi_collection_msgs.msg import TrialRecord, SourceRecord
        from rclpy.serialization import serialize_message
        from .recorder import Record
        msg=TrialRecord(); msg.header.stamp.sec=stamp//10**9; msg.header.stamp.nanosec=stamp%10**9
        msg.trial_id=trial_id; msg.session_id=snap['session_id']; msg.task_label=snap['task_label']
        msg.gripper_id=snap['gripper_id']; msg.profile=snap['profile']
        msg.calibration_id=snap['calibration']['calibration_id'] if snap['calibration'] else ''
        msg.snapshot_json=json.dumps(snap,sort_keys=True)
        trial=Record('/usi_collection/trial_metadata','usi_collection_msgs/msg/TrialRecord',
            serialize_message(msg),stamp,'trial_metadata',snap['session_id'],snap['session_id'],0)
        cap=next(c for c in snap['capabilities'] if c['stream_id']=='camera_calibration')
        cal=SourceRecord(); cal.header.stamp.sec=stamp//10**9; cal.header.stamp.nanosec=stamp%10**9
        cal.header.frame_id='arkit_camera'; cal.stream_id='camera_calibration'
        cal.source_id=cap['source_id']; cal.epoch_id=cap['epoch_id']; cal.sequence=begin_sequence
        cal.phone_session_id=snap['session_id']; cal.host_receive_wall_ns=stamp
        cal.metadata_json=json.dumps(calibration,sort_keys=True,separators=(',',':'))
        camera=Record('/usi_collection/camera_calibration','usi_collection_msgs/msg/SourceRecord',
            serialize_message(cal),stamp,'camera_calibration',cal.source_id,cal.epoch_id,begin_sequence,
            cal.metadata_json)
        return [trial,camera]

    def _stop(self,meta):
        if self.state!='recording' or meta['trial_id']!=self.trial_id: raise ValueError('trial not recording')
        try: end=self._fence_map(meta['fences'])
        except ValueError as exc: raise ValueError('invalid end fences: '+str(exc)) from exc
        for lane,(_,_,sequence) in end.items():
            if sequence<self.begin_fences[lane][2]: raise ValueError('end fence before begin')
            if sequence-self.begin_fences[lane][2]>1_000_000: raise ValueError('fence interval exceeds verifier bound')
        for counter in meta['counters']:
            lane=counter['stream_id']
            if lane in end and (counter['source_id'],counter['epoch_id'])!=end[lane][:2]:
                raise ValueError('source counter identity mismatch')
        self.end_fences=end; self._source_counters=meta['counters']
        self._end_ns=self.now_ns()
        self.state='finalizing'; self.revision+=1
        self._final_thread=threading.Thread(target=self._finalize,daemon=True)
        self._final_thread.start()
        return self._status(meta['request_id'])

    def ingest(self,packet,*,received_ns=None,wall_ns=None):
        kind=MessageType(packet.message_type)
        validate_metadata(kind,packet.metadata,len(packet.payload))
        received_ns=self.now_ns() if received_ns is None else received_ns
        wall_ns=self.wall_ns() if wall_ns is None else wall_ns
        meta=packet.metadata
        identities=[]
        if kind==MessageType.FRAME:
            identities=[(meta['stream_id'],meta['session_id'],meta['world_epoch_id'],meta['frame_seq'])]
        elif kind==MessageType.POSES:
            identities=[('camera_pose',meta['session_id'],meta['world_epoch_id'],s['frame_seq']) for s in meta['samples']]
        elif kind==MessageType.PRESSURE:
            identities=[('pressures',meta['source_id'],meta['boot_id'],s['sequence']) for s in meta['samples']]
        elif kind==MessageType.TRIGGER: identities=[('trigger',meta['source_id'],meta['boot_id'],meta['sequence'])]
        with self._lock:
            for lane,source,epoch,sequence in identities: self.fresh[(lane,source,epoch)]=received_ns
            if kind==MessageType.FRAME and meta['stream_id']=='main_rgb' and self.state in ('idle','saved','incomplete'):
                from .ros_messages import camera_calibration_snapshot
                key=(meta['session_id'],meta['world_epoch_id'])
                if key not in self._camera_calibrations and len(self._camera_calibrations)>=32:
                    self._camera_calibrations.pop(next(iter(self._camera_calibrations)))
                self._camera_calibrations[key]=camera_calibration_snapshot(meta)
            if kind==MessageType.HEALTH:
                for counter in meta['counters']:
                    key=(counter['stream_id'],counter['source_id'],counter['epoch_id'])
                    self._latest_source_counters[key]=counter
                    if self._accepting and self.state in ('recording','finalizing'):
                        for gap in counter['missing_ranges']:
                            evidence=(*key,gap['start'],gap['end_exclusive'])
                            if len(self._observed_missing_ranges)>=4096 and evidence not in self._observed_missing_ranges:
                                self._failures.append('source missing-range evidence limit')
                            else: self._observed_missing_ranges.add(evidence)
            if kind==MessageType.HEALTH and self.snapshot and self.state in ('recording','finalizing'):
                required=set(self.snapshot['required_streams'])
                prepared={c['stream_id']:c for c in self.snapshot['capabilities']}
                for cap in meta.get('capabilities',[]):
                    old=prepared.get(cap['stream_id'])
                    if cap['stream_id'] in required and (not cap['available'] or
                            (old and (cap['source_id'],cap['epoch_id'])!=(old['source_id'],old['epoch_id']))):
                        self._failures.append('required capability changed: '+cap['stream_id'])
                for counter in meta['counters']:
                    if counter['stream_id'] in required and self._counter_loss(counter):
                        self._failures.append('reported source loss: '+counter['stream_id'])
            if kind==MessageType.FRAME:
                self._latest_frame_counters[meta['stream_id']]=meta['counters']
            if self.state not in ('recording','finalizing'): return
            if not self._accepting:
                return
            if kind in (MessageType.HELLO,MessageType.PING,MessageType.PONG): return
            accepted=[]
            for lane,source,epoch,sequence in identities:
                fence=self.begin_fences.get(lane)
                if fence is None or (source,epoch)!=fence[:2]:
                    self._failures.append('source epoch changed: '+lane)
                    self.rejected_counts[lane]=self.rejected_counts.get(lane,0)+1
                    continue
                if sequence<fence[2]: continue
                end=self.end_fences.get(lane)
                if end and sequence>=end[2]: continue
                key=(lane,source,epoch,sequence)
                if key in self.received:
                    self._failures.append('duplicate identity: '+lane)
                    self.duplicate_counts[lane]=self.duplicate_counts.get(lane,0)+1
                    continue
                accepted.append(key)
            if identities and not accepted:
                self._expire_if_needed(); return
            if kind==MessageType.FRAME:
                lane=meta['stream_id']
                key=(lane,meta['session_id'],meta['world_epoch_id'])
                # Explicit acquisition-prefix counters can be unknown while an older
                # encoder ticket is pending. Its later failure raises FRAME lifetime
                # totals without losing an in-trial identity. Use prefix counters and
                # complete [Begin,Stop) identity coverage in that case, not lifetime deltas.
                if key not in self._begin_source_counters:
                    baseline=self._begin_frame_counters.get(lane,meta['counters'])
                    if any(meta['counters'][field]>baseline[field] for field in ('encode_drops','transport_drops')):
                        self._failures.append('image source loss: '+lane)
            if kind==MessageType.FRAME and meta['stream_id']=='main_rgb':
                from .ros_messages import camera_calibration_snapshot,compatible_camera_format
                current=camera_calibration_snapshot(meta)
                if not compatible_camera_format(current,self._prepared_camera_calibration):
                    self._failures.append('camera calibration changed')
                    self._expire_if_needed(); return
            if kind in (MessageType.POSES,MessageType.PRESSURE) and len(accepted)!=len(identities):
                selected={key[3] for key in accepted}
                meta=dict(meta,samples=[sample for sample in meta['samples']
                    if sample['frame_seq' if kind==MessageType.POSES else 'sequence'] in selected])
                packet=Packet(kind,meta,packet.payload)
            try: records=self.record_factory(packet,received_ns,wall_ns)
            except Exception as exc:
                self._failures.append('record conversion failed: '+str(exc))
                self._expire_if_needed()
                raise
            accepted_set=set(accepted)
            for record in records:
                lane=self._record_parent(record)
                if lane and (lane,record.source_id,record.epoch_id,record.sequence) not in accepted_set:
                    self._failures.append('record parent identity mismatch: '+record.topic)
                    continue
                if record.stream_id:
                    self.received_counts[record.stream_id]=self.received_counts.get(record.stream_id,0)+1
                    self.record_identities[record.stream_id]=(record.source_id,record.epoch_id)
                if not self.writer or not self.writer.submit(record):
                    self._failures.append('writer queue overflow or failure')
            for key in accepted:
                self.received[key]=received_ns
                lane,_,_,seq=key
                if lane=='main_rgb': self._source_times.setdefault(lane,{})[seq]=meta['arkit_timestamp_s']
                elif lane=='ultrawide': self._source_times.setdefault(lane,{})[seq]=meta['source_timestamp_s']
                elif lane=='camera_pose':
                    sample=next(s for s in meta['samples'] if s['frame_seq']==seq)
                    self._source_times.setdefault(lane,{})[seq]=sample['arkit_timestamp_s']
            self._condition.notify_all()
            self._expire_if_needed()

    @staticmethod
    def _record_parent(record):
        return {'raw_depth':'main_rgb','depth_confidence':'main_rgb',
                'tracking':'camera_pose','seal':'pressures',
                '/pressure':'pressures','/pressure_timing':'pressures',
                '/trigger':'trigger','/trigger_timing':'trigger'}.get(record.stream_id or record.topic,
                    record.stream_id if record.stream_id in FENCED_STREAMS else None)

    def _counter_loss(self,counter):
        key=(counter['stream_id'],counter['source_id'],counter['epoch_id'])
        baseline=self._begin_source_counters.get(key)
        for field in ('queue_overflow_count','rejected_count'):
            current=counter[field]; previous=baseline[field] if baseline else None
            # Explicit unknown prefix counters include unfinished pre-Begin work.
            # They cannot establish a lifetime delta; exact fence coverage still
            # rejects every missing in-trial identity when the bag is reopened.
            if current is not None and (current>previous if previous is not None else baseline is None and current>0): return True
        lane=counter['stream_id']
        if lane in self.begin_fences:
            start=self.begin_fences[lane][2]
            end=(self.end_fences[lane][2] if lane in self.end_fences else
                 max((key[3]+1 for key in self.received if key[0]==lane),default=start))
            if any(g['end_exclusive']>start and g['start']<end
                   for g in counter['missing_ranges']): return True
        return False

    def _ranges_present(self,records):
        identities={(r.stream_id,r.source_id,r.epoch_id,r.sequence) for r in records}
        missing=[]
        for lane,(source,epoch,start) in self.begin_fences.items():
            end=self.end_fences[lane][2]
            if end==start: missing.append(lane+' empty')
            for seq in range(start,end):
                if (lane,source,epoch,seq) not in identities: missing.append(lane+':'+str(seq))
        return missing

    def _boundary_and_join_errors(self,records):
        errors=[]
        identities={(r.stream_id,r.source_id,r.epoch_id,r.sequence) for r in records}
        derived={'raw_depth':'main_rgb','depth_confidence':'main_rgb',
                 'tracking':'camera_pose','seal':'pressures'}
        for record in records:
            parent=self._record_parent(record)
            if parent is None: continue
            fence=self.begin_fences[parent]; end=self.end_fences[parent][2]
            if ((record.source_id,record.epoch_id)!=fence[:2] or
                    not fence[2]<=record.sequence<end):
                errors.append('reopened identity outside fence: '+record.topic)
            if record.stream_id in derived and (parent,record.source_id,record.epoch_id,record.sequence) not in identities:
                errors.append('derived join mismatch: '+record.stream_id)
        for lane in ('camera_pose','pressures'):
            child='tracking' if lane=='camera_pose' else 'seal'
            for stream,source,epoch,sequence in identities:
                if stream==lane and (child,source,epoch,sequence) not in identities:
                    errors.append('derived join missing: '+child)
        calibration=[r for r in records if r.stream_id=='camera_calibration']
        cap=next(c for c in self.snapshot['capabilities'] if c['stream_id']=='camera_calibration')
        expected=(cap['source_id'],cap['epoch_id'],self.begin_fences['main_rgb'][2])
        if len(calibration)!=1 or (calibration[0].source_id,calibration[0].epoch_id,calibration[0].sequence)!=expected:
            errors.append('frozen camera calibration mismatch')
        elif calibration[0].details!=json.dumps(self._prepared_camera_calibration,sort_keys=True,separators=(',',':')):
            errors.append('frozen camera calibration content mismatch')
        return errors

    def _finalize(self):
        deadline=time.monotonic()+self.drain_timeout_s
        with self._lock:
            while time.monotonic()<deadline:
                if not self._accepting: break
                if not self._ranges_present([_identity_record(k) for k in self.received]):
                    break
                self._condition.wait(timeout=min(0.05,max(0,deadline-time.monotonic())))
            self._accepting=False
            errors=list(self._failures)
        closed=True
        try: self.writer.close()
        except Exception as exc: errors.append('writer close/write: '+str(exc)); closed=False
        if closed:
            try: records=self.store.scan()
            except Exception as exc: records=[]; errors.append('reopen: '+str(exc))
        else: records=[]
        errors+=self._ranges_present(records)
        errors+=self._boundary_and_join_errors(records)
        if self.bag_path is None or not self.bag_path.is_dir() or not list(self.bag_path.glob('*.mcap')):
            errors.append('MCAP artifact absent')
        seen=set()
        for record in records:
            if not record.stream_id: continue
            identity=(record.stream_id,record.source_id,record.epoch_id,record.sequence)
            if identity in seen and (record.stream_id in FENCED_STREAMS or record.stream_id in ('raw_depth','depth_confidence','tracking','seal','camera_calibration')):
                errors.append('duplicate reopened identity: '+record.stream_id)
            seen.add(identity)
        required=set(self.snapshot['required_streams'])
        present={r.stream_id for r in records}
        errors+=['missing required stream: '+s for s in sorted(required-present)]
        for stream,accepted in self.writer.accepted_by_stream.items():
            if sum(r.stream_id==stream for r in records)!=accepted:
                errors.append('writer/reopen count mismatch: '+stream)
        for counter in self._source_counters:
            key=(counter['stream_id'],counter['source_id'],counter['epoch_id'])
            baseline=self._begin_source_counters.get(key)
            lane=counter['stream_id']
            for field in ('queue_overflow_count','rejected_count'):
                final=counter[field]
                prior=baseline[field] if baseline else None
                if final is not None and (final>prior if prior is not None else baseline is None and final>0):
                    errors.append('source loss '+field+': '+lane)
            if lane in self.begin_fences:
                start=self.begin_fences[lane][2]; end=self.end_fences[lane][2]
                if any(g['start']<end and g['end_exclusive']>start for g in counter['missing_ranges']):
                    errors.append('source missing range: '+lane)
                if baseline and baseline['source_count'] is not None and counter['source_count'] is not None:
                    if counter['source_count']-baseline['source_count']!=end-start:
                        errors.append('source count delta differs from fence: '+lane)
                if baseline and baseline['received_count'] is not None and counter['received_count'] is not None:
                    if counter['received_count']-baseline['received_count']<end-start:
                        errors.append('phone received count shortfall: '+lane)
        for lane,source,epoch,gap_start,gap_end in self._observed_missing_ranges:
            fence=self.begin_fences.get(lane)
            if fence and (source,epoch)==fence[:2] and gap_start<self.end_fences[lane][2] and gap_end>fence[2]:
                errors.append('observed source missing range: '+lane)
        if self.writer.overflow: errors.append('writer queue overflow')
        counts={s:sum(r.stream_id==s for r in records) for s in sorted(present) if s}
        legacy_topic_counts={topic:sum(r.topic==topic for r in records)
            for topic in ('/pressure','/pressure_timing','/trigger','/trigger_timing')}
        host_rates={}; source_rates={}; interval_rates={}; rate_check='not_measured_short_trial'
        duration_ns=(self._end_ns-self._begin_ns) if self._end_ns is not None and self._begin_ns is not None else 0
        for lane in LANES[self.snapshot['profile']]:
            stamps=[receipt for (stream,_,_,_),receipt in self.received.items() if stream==lane]
            span=max(stamps)-min(stamps) if len(stamps)>1 else 0
            host_rates[lane]=(len(stamps)-1)*1e9/span if span>0 else None
            source,epoch,start=self.begin_fences[lane]; end=self.end_fences[lane][2]
            times=[value for seq,value in sorted(self._source_times.get(lane,{}).items()) if start<=seq<end]
            elapsed=times[-1]-times[0] if len(times)>1 else 0
            source_rates[lane]=(len(times)-1)/elapsed if elapsed>0 else None
            interval_rates[lane]=len(times)*1e9/duration_ns if duration_ns>0 else None
        if duration_ns>=1_000_000_000:
            rate_check='passed'
            target=self.snapshot['configuration']['target_fps']*0.9
            for lane in ('main_rgb','camera_pose')+ (('ultrawide',) if self.snapshot['profile']=='full' else ()):
                source_rate=source_rates[lane]; interval_rate=interval_rates[lane]
                if source_rate is None or source_rate<target or interval_rate is None or interval_rate<target:
                    errors.append('source cadence shortfall: '+lane)
                    rate_check='failed'
        with self._lock:
            for failure in self._failures:
                if failure not in errors: errors.append(failure)
            manifest=dict(trial_id=self.trial_id,profile=self.snapshot['profile'],generated_test_data=self.generated_test_data,
            reopened_counts=counts,writer_accepted_counts=dict(self.writer.accepted_by_stream),
            received_counts=dict(self.received_counts),observed_host_receive_hz=host_rates,
            observed_source_hz=source_rates,observed_interval_hz=interval_rates,rate_check=rate_check,
            legacy_topic_counts=legacy_topic_counts,
            begin_fences=self.begin_fences,end_fences=self.end_fences,
            begin_source_counters=list(self._begin_source_counters.values()),
            observed_source_counters=list(self._latest_source_counters.values()),
            observed_missing_ranges=[dict(stream_id=lane,source_id=source,epoch_id=epoch,
                start=start,end_exclusive=end) for lane,source,epoch,start,end in sorted(self._observed_missing_ranges)],
            expected_fences=self.end_fences,source_counters=self._source_counters,errors=errors,
            verification='failed' if errors else 'passed')
            try:
                if self.bag_path and self.bag_path.exists():
                    manifest['files']={p.name:dict(size=p.stat().st_size,sha256=_sha256_file(p))
                        for p in self.bag_path.iterdir() if p.is_file()}
                    temporary=self.bag_path/'verification.json.tmp'; temporary.write_text(json.dumps(manifest,indent=2,sort_keys=True))
                    os.replace(temporary,self.bag_path/'verification.json')
            except Exception as exc: errors.append('manifest write: '+str(exc))
            self.state='incomplete' if errors else 'saved'; self.verification='failed' if errors else 'passed'
            self.reason='; '.join(errors[:8]) if errors else None
            self.revision+=1; self._last_trial_id=self.trial_id
            result=self._status()
            self._remember_outcome()
        if self.on_status: self.on_status(result)

    def await_final(self,timeout=None):
        thread=self._final_thread
        if thread: thread.join(timeout)
        return self.status()

    def disconnect(self):
        with self._lock:
            if self.state=='preparing':
                self.reason='phone disconnected before begin'; self.state='incomplete'
                self.verification='failed'; self.revision+=1
                if self.writer:
                    try: self.writer.close()
                    except Exception as exc: self.reason+='; writer close: '+str(exc)
                self._remember_outcome()
            elif self.state=='finalizing':
                self._failures.append('phone disconnected during finalization')
                self._accepting=False
                self._condition.notify_all()
            else: self._abort_active('phone disconnected before stop')


def _identity_record(key):
    from .recorder import Record
    return Record('','',b'',0,*key)


def _sha256_file(path):
    digest=hashlib.sha256()
    with open(path,'rb') as source:
        while chunk:=source.read(1024*1024): digest.update(chunk)
    return digest.hexdigest()


class UsbClock:
    """Bounded per-connection host PING ledger; an exchange is not a clock fit."""
    def __init__(self,host_session_id):
        self.host_session_id=host_session_id
        self._next_id=0; self._pending={}; self._lock=threading.Lock()

    def ping(self,send_ns):
        with self._lock:
            ping_id=self._next_id; self._next_id+=1
            if len(self._pending)>=64: self._pending.pop(next(iter(self._pending)))
            self._pending[ping_id]=send_ns
        return dict(ping_id=ping_id,host_send_ns=send_ns)

    def complete(self,pong,receipt_ns):
        validate_metadata(MessageType.PONG,pong)
        with self._lock: sent=self._pending.pop(pong['ping_id'],None)
        if sent is None: return None
        if sent!=pong['host_send_ns']: raise ValueError('PONG does not match host PING')
        clock=dict(link='usb',exchange_id=f'usb:{self.host_session_id}:{pong["ping_id"]}',
            source_id=pong['session_id'],epoch_id=pong['session_id'],
            t1_ns=sent,t2_ns=pong['phone_receive_ns'],t3_ns=pong['phone_send_ns'],t4_ns=receipt_ns,
            mapping=dict(valid=False,scale=None,offset_ns=None,uncertainty_ns=None))
        validate_metadata(MessageType.BLE_CLOCK,clock)
        return clock


def serve(output_root,*,tcp=None,port=PORT,retry_s=1.0):
    """Connect outbound to the phone's USB listener; --tcp is an explicit test path."""
    # Load the vectorized depth converter before connecting, outside frame intake.
    import numpy
    collector=Collector(output_root)
    while True:
        try:
            peer=socket.create_connection(tcp,timeout=3) if tcp else connect_usb(port=port)
        except (OSError,USBMuxError) as exc:
            print('collection transport unavailable: '+str(exc),file=sys.stderr)
            time.sleep(retry_s); continue
        with peer:
                send_lock=threading.Lock(); stopped=threading.Event()
                last_status=[None]
                usb_clock=UsbClock(collector.host_session_id)
                def send_status(status):
                    summary=(status['trial_id'],status['revision'],status['state'],status['verification'],status['reason'],status['bag_path'])
                    if summary!=last_status[0]:
                        last_status[0]=summary
                        print('collection '+status['state']+
                              (' | '+status['reason'] if status['reason'] else '')+
                              (' | '+status['bag_path'] if status['bag_path'] else ''),flush=True)
                    try:
                        with send_lock: peer.sendall(encode_packet(MessageType.TRIAL_STATUS,status))
                    except OSError: stopped.set()
                collector.on_status=send_status
                hello=dict(role='host',protocol_version=2,session_id=collector.host_session_id,
                           capabilities=[],profiles=['full','core'])
                try: peer.sendall(encode_packet(MessageType.HELLO,hello))
                except OSError:
                    collector.on_status=None
                    collector.disconnect()
                    continue
                def heartbeat():
                    while not stopped.wait(0.5):
                        send_status(collector.status())
                        try:
                            ping=usb_clock.ping(collector.now_ns())
                            with send_lock: peer.sendall(encode_packet(MessageType.PING,ping))
                        except OSError: stopped.set()
                pulse=threading.Thread(target=heartbeat,daemon=True); pulse.start()
                peer.settimeout(5.0)
                while True:
                    try: packet=recv_packet(peer)
                    except (OSError,ValueError): break
                    if packet is None: break
                    try:
                        if packet.message_type==MessageType.TRIAL_COMMAND:
                            status=collector.command(packet.metadata)
                            send_status(status)
                        elif packet.message_type==MessageType.PONG:
                            receipt_ns=collector.now_ns()
                            complete=usb_clock.complete(packet.metadata,receipt_ns)
                            if complete is not None:
                                collector.ingest(Packet(MessageType.BLE_CLOCK,complete),received_ns=receipt_ns)
                                with send_lock: peer.sendall(encode_packet(MessageType.BLE_CLOCK,complete))
                        else: collector.ingest(packet)
                    except (OSError,ValueError) as exc:
                        if packet.message_type==MessageType.TRIAL_COMMAND:
                            status=collector.status(packet.metadata['request_id'])
                            status['reason']=str(exc)
                            send_status(status)
                        else: break
                stopped.set(); pulse.join(1)
        collector.on_status=None
        collector.disconnect()


def main():
    parser=argparse.ArgumentParser(description='USI v2 authoritative ROS 2 MCAP collector')
    parser.add_argument('--output-root',required=True,type=Path)
    parser.add_argument('--tcp',metavar='HOST:PORT',help='explicit direct TCP path for testing/forwarding')
    parser.add_argument('--port',type=int,default=PORT)
    args=parser.parse_args()
    tcp=None
    if args.tcp:
        host,separator,tcp_port=args.tcp.rpartition(':')
        if not separator or not host: parser.error('--tcp must be HOST:PORT')
        try: tcp=(host,int(tcp_port))
        except ValueError: parser.error('--tcp port must be an integer')
        if not 1<=tcp[1]<=65535: parser.error('--tcp port must be in 1..65535')
    serve(args.output_root,tcp=tcp,port=args.port)

if __name__=='__main__': main()
