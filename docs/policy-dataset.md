# From raw recordings to a suction manipulation policy

The first proposed benchmark is extracting a book from a crowded bookshelf using the suction tool. The deployment robot is the user's FANUC CRX-10iA. The iPhone is not physically mounted to the handheld yet; the mounting interfaces are available. Robot computer control is being handled separately by the user's lab.

## Current reader

The raw episode reader is the first processing stage. It opens the MCAP read-only and creates a new inspection directory. It does not create tool actions, align independent clocks, train a policy, or communicate with the robot.

From the repository root, source Jazzy and the existing message overlay:

```bash
source /opt/ros/jazzy/setup.bash
source /home/emi-linux/usi_ws/usi_v2/collection-ros/install/usi_collection_msgs/share/usi_collection_msgs/local_setup.bash
python3 -m usi_stream.dataset_reader /absolute/path/to/trial-bag \
  --output /absolute/path/outside-the-bag/inspection
```

The output directory must not already exist and must be outside the raw bag. Images and exact raw depth remain in the MCAP; the frame index identifies them by stream/source/epoch/sequence. No original bag or verification file is modified.

| File | Contents |
| --- | --- |
| `episode_report.json` | Observed message inventory, recording verification comparison, pressure quality, tracking states, calibration/snapshot, source epochs, clock counts and training blockers. |
| `frames.csv` | RGB/depth/confidence identity index, dimensions, encoding, original frame metadata and clocks. |
| `camera_pose.csv` | Camera XYZ/quaternion, tracking state/reason, pose-valid flag and original clocks. These are camera poses, not suction-tip poses. |
| `pressures.csv` | Original integer centiPa values, kPa absolute values only when valid, per-channel validity and all recorded source/receipt clocks. |
| `trigger.csv` | Recorded trigger and trigger-derived suction state. It does not assert that the pump was physically switched. |
| `clock_exchanges.csv` | Original four-timestamp exchanges and source-reported mapping validity. No fit or uncertainty is invented. |
| `recorded_seal.csv` | Seal metadata exactly as recorded, including incorrect/invalid labels when present in an older bag. |

Blank optional timestamps mean the original field was absent. Blank pressure display values mean the original quality bit was invalid; the raw integer is still preserved. CSV rows have separate clock domains and must not be interpreted as synchronized training steps. The report always has `training_ready: false` for this raw-inspection stage. A successful export means the inspection files were produced, not that the data can train a policy yet.

## Remaining processing

1. Attach the phone rigidly to the handheld and measure **camera-to-suction-tip** position and orientation. Measure **robot-flange-to-suction-tip** separately for the robot mount. Record units, axes and calibration IDs. Having mounting brackets does not supply these transforms.
2. Define and record actual suction command transitions. Verify the relationship between the physical trigger, pump/valve switching and recorded command; preserve command and pressure as different signals.
3. Fit clock mappings from the recorded BLE/USB exchanges, retain uncertainty, and align observations on a documented policy timeline. Keep epochs separate, preserve raw pressure, and mask missing/invalid intervals.
4. Derive calibrated tool poses, a documented motion-action representation and suction-command actions. Export training episodes to suction-specific Zarr. Do not reuse stock finger-width action semantics.
5. Collect complete book-extraction demonstrations with task/outcome annotations and normal ARKit tracking. Split training and validation by whole trials. Include varied book locations/spacing and appropriate examples of recovery as the task protocol is developed.
6. Train a first baseline, inspect predicted trajectories offline, and integrate the learned tool-space actions with the FANUC controller through the lab's selected interface. A low training loss is not evidence of robot task success.

The current 70%/50% pressure-drop thresholds produce pressure-seal labels. Successful book extraction and retention require a separate observed task outcome.

## FANUC integration reference

The official [FANUC ROS 2 driver](https://github.com/FANUC-CORPORATION/fanuc_driver) main branch targets Jazzy/Ubuntu 24.04 and its [current quick start](https://fanuc-corporation.github.io/fanuc_driver_doc/main/docs/quick_start/quick_start.html) lists CRX-10iA. Physical support depends on controller software and installed external-control options (J519 and R912, or S636); those have not been checked on this robot. No robot connection, configuration change or motion is performed by the dataset reader. The lab can verify its selected control route separately while preprocessing proceeds.

The upstream [iPhUMI training pipeline](https://github.com/real-stanford/behavior_prompting/blob/main/docs/iphumi.md) is a candidate starting point, requiring a suction-specific dataset/config adaptation. The acquisition ROS environment remains Jazzy; keep training dependencies isolated from the recorder.
