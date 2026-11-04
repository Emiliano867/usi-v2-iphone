"""Read-only raw-episode inspection. No clock alignment or robot actions are inferred."""
import argparse
from collections import Counter
from contextlib import ExitStack
import csv
import json
from pathlib import Path


SOURCE_FIELDS=['source_id','epoch_id','sequence','raw_sequence','source_time_us',
    'phone_receive_ns','phone_uptime_ns','arkit_timestamp_s',
    'host_receive_monotonic_ns','host_receive_wall_ns','connection_id','phone_session_id']
TABLES={
    'frames':SOURCE_FIELDS+['stream_id','encoding','width','height','metadata_json'],
    'camera_pose':SOURCE_FIELDS+['x_m','y_m','z_m','qx','qy','qz','qw',
        'tracking_state','tracking_reason','pose_valid'],
    'pressures':SOURCE_FIELDS+['quality_mask','raw_c1_centi_pa','raw_c2_centi_pa','raw_c3_centi_pa',
        'c1_kpa_abs','c2_kpa_abs','c3_kpa_abs','valid_c1','valid_c2','valid_c3'],
    'trigger':SOURCE_FIELDS+['pressed','trigger_derived_suction_on','event'],
    'recorded_seal':SOURCE_FIELDS+['metadata_json'],
    'clock_exchanges':['link','exchange_id','source_id','epoch_id','t1_ns','t2_ns','t3_ns','t4_ns',
        'mapping_valid','host_receive_monotonic_ns','host_receive_wall_ns','metadata_json'],
}


def _source_values(source):
    result={field:getattr(source,field) for field in SOURCE_FIELDS}
    for field,flag in [('raw_sequence','has_raw_sequence'),('source_time_us','has_source_time_us'),
        ('phone_receive_ns','has_phone_receive_ns'),('phone_uptime_ns','has_phone_uptime_ns'),
        ('arkit_timestamp_s','has_arkit_timestamp')]:
        if not getattr(source,flag): result[field]=''
    return result


def export_episode(bag_path,output_path):
    """Export scalar tables/frame indices into a NEW directory outside the raw bag.

    Images remain in MCAP; frames.csv identifies them by source/epoch/sequence.
    The returned report explicitly refuses to treat these exports as policy actions.
    """
    bag=Path(bag_path).resolve(); output=Path(output_path).resolve()
    if output.is_relative_to(bag): raise ValueError('output must be outside the original bag')
    if output.exists(): raise FileExistsError(output)
    if not bag.is_dir() or not (bag/'metadata.yaml').is_file() or not list(bag.glob('*.mcap')):
        raise ValueError('expected a closed ROS 2 MCAP bag directory')
    manifest_path=bag/'verification.json'
    manifest=json.loads(manifest_path.read_text()) if manifest_path.exists() else None

    # Inspection does not change the ROS installation or import image libraries at startup.
    import rosbag2_py
    from rclpy.serialization import deserialize_message
    from rosidl_runtime_py.utilities import get_message

    reader=rosbag2_py.SequentialReader()
    reader.open(rosbag2_py.StorageOptions(uri=str(bag),storage_id='mcap'),
        rosbag2_py.ConverterOptions('cdr','cdr'))
    try:
        types={topic.name:topic.type for topic in reader.get_all_topics_and_types()}
        message_types={topic:get_message(kind) for topic,kind in types.items()
            if topic.startswith('/usi_collection/')}
        output.mkdir(parents=True,mode=0o700)
        streams=Counter(); topics=Counter(); quality=Counter(); tracking=Counter()
        seals=Counter(); clock_links=Counter(); clock_mapped=Counter(); epochs={}
        calibration=[]; trials=[]; dimensions=set()
        with ExitStack() as stack:
            writers={}
            for name,fields in TABLES.items():
                file=stack.enter_context((output/(name+'.csv')).open('w',newline=''))
                writers[name]=csv.DictWriter(file,fieldnames=fields)
                writers[name].writeheader()
            while reader.has_next():
                topic,data,_=reader.read_next(); topics[topic]+=1
                if topic not in message_types: continue
                msg=deserialize_message(data,message_types[topic])
                stream=topic.removeprefix('/usi_collection/'); streams[stream]+=1
                if stream=='trial_metadata':
                    trials.append(dict(trial_id=msg.trial_id,session_id=msg.session_id,
                        task_label=msg.task_label,gripper_id=msg.gripper_id,profile=msg.profile,
                        calibration_id=msg.calibration_id,snapshot=json.loads(msg.snapshot_json)))
                    continue
                if stream=='timing':
                    row={field:getattr(msg,field) for field in TABLES['clock_exchanges']}
                    row['mapping_valid']=int(msg.mapping_valid)
                    writers['clock_exchanges'].writerow(row)
                    clock_links[msg.link]+=1; clock_mapped[msg.link]+=int(msg.mapping_valid)
                    continue
                if not hasattr(msg,'source'):
                    if stream=='camera_calibration': calibration.append(json.loads(msg.metadata_json))
                    if stream=='camera_pose':
                        source=msg; row=_source_values(source); meta=json.loads(source.metadata_json)
                        row.update(zip(['x_m','y_m','z_m'],meta['position_m']))
                        row.update(zip(['qx','qy','qz','qw'],meta['quaternion_xyzw']))
                        row.update(tracking_state=meta['tracking_state'],tracking_reason=meta['tracking_reason'],
                            pose_valid=int(meta['pose_valid']))
                        writers['camera_pose'].writerow(row)
                        tracking[meta['tracking_state']]+=1
                        epochs.setdefault(stream,set()).add((source.source_id,source.epoch_id))
                    elif stream=='seal':
                        row=_source_values(msg); row['metadata_json']=msg.metadata_json
                        writers['recorded_seal'].writerow(row)
                        seals['/'.join(json.loads(msg.metadata_json)['states'])]+=1
                    continue
                source=msg.source; row=_source_values(source)
                epochs.setdefault(stream,set()).add((source.source_id,source.epoch_id))
                if stream in ('main_rgb','raw_depth','depth_confidence','ultrawide'):
                    row.update(stream_id=stream,encoding=msg.encoding,width=msg.width,height=msg.height,
                        metadata_json=source.metadata_json)
                    writers['frames'].writerow(row)
                    dimensions.add((stream,msg.width,msg.height))
                elif stream=='pressures':
                    mask=int(msg.quality_mask); quality[str(mask)]+=1; row['quality_mask']=mask
                    for i,value in enumerate(msg.pressure_centi_pa):
                        valid=bool(mask & (1<<i))
                        row[f'raw_c{i+1}_centi_pa']=int(value)
                        row[f'c{i+1}_kpa_abs']=int(value)/100000 if valid else ''
                        row[f'valid_c{i+1}']=int(valid)
                    writers['pressures'].writerow(row)
                elif stream=='trigger':
                    row.update(pressed=int(msg.pressed),trigger_derived_suction_on=int(msg.suction_on),event=msg.event)
                    writers['trigger'].writerow(row)
                # Release decoded images before reading the next message.
                del msg
    finally:
        reader.close()

    blockers=['camera_to_tool_calibration_unavailable','clock_alignment_not_exported',
        'suction_command_mapping_unverified','task_outcome_annotation_missing']
    verification=manifest.get('verification') if manifest else None
    if verification!='passed': blockers.append('raw_recording_verification_unavailable_or_failed')
    expected=manifest.get('reopened_counts') if manifest else None
    count_match=(dict(streams)==expected) if expected is not None else None
    if count_match is False: blockers.append('recording_inventory_differs_from_verification')
    if not quality.get('7',0): blockers.append('no_fully_valid_pressure_triples')
    if any(state!='normal' and count for state,count in tracking.items()):
        blockers.append('tracking_quality_requires_filtering')
    if any(len(values)>1 for values in epochs.values()): blockers.append('multiple_source_epochs_require_splitting')
    if seals.get('invalid/invalid/invalid',0)>quality.get('0',0):
        blockers.append('recorded_seal_labels_require_review')
    report=dict(format_version=1,processing_stage='raw_episode_inspection',source_bag=str(bag),
        training_ready=False,training_blockers=blockers,raw_verification=verification,
        generated_test_data=manifest.get('generated_test_data') if manifest else None,
        inventory_matches_verification=count_match,stream_counts=dict(streams),topic_counts=dict(topics),
        pressure_quality_masks=dict(quality),tracking_states=dict(tracking),recorded_seal_states=dict(seals),
        clock_exchanges=dict(clock_links),source_reported_valid_clock_mappings=dict(clock_mapped),
        source_epochs={key:[list(pair) for pair in sorted(values)] for key,values in epochs.items()},
        image_dimensions=[dict(stream_id=s,width=w,height=h) for s,w,h in sorted(dimensions)],
        trials=trials,camera_calibration=calibration,
        notes=['Images and raw depth remain in the source MCAP; frames.csv is their source-identity index.',
            'CSV timestamps retain their original clock domains; rows have not been synchronized.',
            'Blank pressure values mean invalid measurements; original centiPa and validity bits remain.',
            'trigger_derived_suction_on is not measured pump feedback or a verified actuation command.',
            'Recorded seal labels are preserved as written, not replaced by recomputed labels.',
            'No tool poses or policy actions are synthesized without calibration.'])
    (output/'episode_report.json').write_text(json.dumps(report,indent=2,allow_nan=False)+'\n')
    return report


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bag',type=Path)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    try: report=export_episode(args.bag,args.output)
    except (OSError,ValueError,RuntimeError) as exc: parser.exit(1,str(exc)+'\n')
    print(args.output/'episode_report.json')
    print('Raw inspection exported; training preparation still required: '+', '.join(report['training_blockers']))


if __name__=='__main__': main()
