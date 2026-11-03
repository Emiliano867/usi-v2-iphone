# ROS 2 Jazzy collection host

The collection host consumes the strict v2 protocol on the iPhone's USB listener at port 5559. It writes serialized ROS messages directly to one MCAP worker and can mirror those same serialized records to a caller supplied monitor callback. ROS discovery is outside the recording path. This host is separate from the existing diagnostic receiver on port 5558.

## Build and run

From the repository root, with ROS 2 Jazzy installed:

```bash
source /opt/ros/jazzy/setup.bash
colcon --log-base /home/emi-linux/usi_ws/usi_v2/collection-ros/log build \
  --base-paths ros --packages-select usi_collection_msgs \
  --build-base /home/emi-linux/usi_ws/usi_v2/collection-ros/build \
  --install-base /home/emi-linux/usi_ws/usi_v2/collection-ros/install
source /home/emi-linux/usi_ws/usi_v2/collection-ros/install/usi_collection_msgs/share/usi_collection_msgs/local_setup.bash
python3 -m usi_stream.collector --output-root /path/to/bags
```

The explicit `--tcp HOST:PORT` option connects to a test listener or already forwarded port. Without it, the collector calls `usbmux.connect_usb(port=5559)` and reconnects after a USB break. It never needs a device identifier or private pairing file. The host sends a v2 HELLO, then TRIAL_STATUS every 0.5 seconds and after each command or final outcome. A phone listener must send v2 HELLO/FRAME/POSES/PRESSURE/TRIGGER/BLE_CLOCK/HEALTH and TRIAL_COMMAND on that same connection. A partial-packet timeout ends the connection; it is never treated as a fresh packet boundary.

The isolated build and install paths above are examples for this workspace; point them to another directory outside any existing ROS overlay when deploying elsewhere. `ros2 interface show usi_collection_msgs/msg/FrameRecord` should resolve after sourcing the package overlay. The `usi_stream/mcap_storage.yaml` writer configuration uses 4 MiB indexed chunks with chunk and summary CRCs, without compression. Test throughput on the actual camera/host before choosing another configuration.

## Phone control contract

The exact JSON schemas and header limits are in [collection-protocol-v2.md](collection-protocol-v2.md). The host uses those validators for every inbound packet and every outbound TRIAL_STATUS. `request_id` is idempotent against the entire normalized command; reusing it with changed contents is a conflict. A new mutating request needs the current `expected_revision`. `status` ignores that revision and can recover a lost acknowledgment. The ledger refuses new IDs at 4096 entries rather than evicting an ID and risking duplicate execution.

The phone must send fresh lane packets before `prepare`. A Core snapshot lists the 12 Core required streams and `missing_modalities:["ultrawide"]`; Full lists all 13 and no required stream in `missing_modalities`. Every required capability must be `available:true`, have an actual `source_id` and `epoch_id`, and use schema `usi.collection.v2` with the following exact units:

| Stream | Unit | Stream | Unit |
| --- | --- | --- | --- |
| `main_rgb`, `ultrawide` | `jpeg` | `raw_depth` | `m` |
| `depth_confidence` | `level` | `camera_pose` | `m` |
| `tracking`, `seal` | `state` | `camera_calibration` | `pixel` |
| `pressures` | `kPa_abs` | `trigger` | `boolean` |
| `trial_metadata` | `json` | `timing` | `ns` |
| `health` | `count` | | |

The four Core or five Full fence lanes are `main_rgb`, `camera_pose`, optional `ultrawide`, `pressures`, and `trigger`. Every Begin and Stop command must have each applicable lane exactly once. Fence source/epoch IDs must match the prepared capabilities and incoming packet identities. Begin uses the next acquisition sequence before encoding replacement. Stop uses the next acquisition sequence at stop time. The host records `[begin.next_sequence, stop.next_sequence)`, accepts packets that arrive after Stop while draining, and fails an interval with a missing sequence after a bounded deadline. Depth and confidence inherit the main frame identity; a required missing actual modality fails final verification. The host does not synthesize an ultrawide frame.

For a Core trial whose four next acquisition sequences are 42, 42, 900 and 12, a valid Begin body is:

```json
{"action":"begin","request_id":"begin-17","trial_id":"trial-17","expected_revision":1,"fences":[{"stream_id":"main_rgb","source_id":"phone-session-1","epoch_id":"world-1","next_sequence":42},{"stream_id":"camera_pose","source_id":"phone-session-1","epoch_id":"world-1","next_sequence":42},{"stream_id":"pressures","source_id":"esp-1","epoch_id":"boot-1","next_sequence":900},{"stream_id":"trigger","source_id":"esp-1","epoch_id":"boot-1","next_sequence":12}]}
```

The corresponding Stop uses `action:"stop"`, a new `request_id`, the revision from the Recording acknowledgment, all four **end** fences, and `counters` (an array, empty only when no source counter snapshot exists). A counter has exactly `stream_id`, `source_id`, `epoch_id`, `source_count`, `received_count`, `writer_accepted_count`, `queue_overflow_count`, `rejected_count`, `duplicate_count` and `missing_ranges`; each unknown count is JSON `null`. For example:

```json
{"stream_id":"pressures","source_id":"esp-1","epoch_id":"boot-1","source_count":905,"received_count":905,"writer_accepted_count":null,"queue_overflow_count":0,"rejected_count":0,"duplicate_count":0,"missing_ranges":[]}
```

These source counters are cumulative within their source epoch. Send a HEALTH snapshot before Begin so the host can compare its baseline to the final Stop counters. Known increases in overflow/rejected counts or a missing range intersecting the trial fence make the trial Incomplete. A known source count delta must equal the interval length; a known phone received delta must cover it. The host leaves unobserved totals null and uses its own received/writer/reopened counts separately.

With the same frozen source identities and a Recording revision of 2, a Stop body is:

```json
{"action":"stop","request_id":"stop-17","trial_id":"trial-17","expected_revision":2,"fences":[{"stream_id":"main_rgb","source_id":"phone-session-1","epoch_id":"world-1","next_sequence":43},{"stream_id":"camera_pose","source_id":"phone-session-1","epoch_id":"world-1","next_sequence":43},{"stream_id":"pressures","source_id":"esp-1","epoch_id":"boot-1","next_sequence":905},{"stream_id":"trigger","source_id":"esp-1","epoch_id":"boot-1","next_sequence":13}],"counters":[{"stream_id":"pressures","source_id":"esp-1","epoch_id":"boot-1","source_count":905,"received_count":905,"writer_accepted_count":null,"queue_overflow_count":0,"rejected_count":0,"duplicate_count":0,"missing_ranges":[]}]}
```

`prepare` checks capabilities, supported schema/units, source freshness and free disk, then opens one writer. It replies `preparing` with an incremented revision or `incomplete` with a concrete reason and `missing_required_streams`. `begin` writes the frozen metadata, flushes it through the worker and replies `recording` only if the writer accepted it. `stop` replies `finalizing`; a later heartbeat or `status` reply carries `saved` or `incomplete`. `saved` requires closed MCAP, independent reader deserialization and a passing verification manifest. A duplicate Stop request can retrieve the current final state. A disconnected or stale required source, changed epoch, source loss, queue overflow, write/close/reopen failure, or missing required record cannot remain Recording or become Saved. Artifacts are retained on error.

`TRIAL_STATUS.counters` reports each required stream's host received, writer accepted, queue overflow, rejected and duplicate counts. `source_count` is null unless the phone supplied an actual final source count; missing source totals are never zero-filled. `missing_modalities` is the selected profile's declared exclusions, while `missing_required_streams` lists required capabilities currently unavailable. Each saved bag has `verification.json` with begin/end fences, final source counters, per-stream received/writer/reopened counts, observed host receipt rates when measurable, errors, file sizes and SHA-256 hashes. The manifest's `generated_test_data` flag is true for generated integration fixtures only.

For trials of at least one second, the verifier checks both source timestamp cadence and source sample count over the host Begin-to-Stop interval for main RGB and independent pose (also ultrawide in Full). Each must reach at least 90% of the configured `target_fps`; a measured shortfall makes the trial Incomplete even if all assigned sequences are present. The manifest labels shorter trials `rate_check:"not_measured_short_trial"` and leaves unavailable rates null. Host receipt rate is reported separately and never substituted for ARKit or ultrawide source cadence. No sustained 60 FPS claim follows from a short generated fixture.

## ROS records and clocks

The four legacy topic names/types remain: `/pressure` (`geometry_msgs/msg/Vector3Stamped`), `/pressure_timing` (`std_msgs/msg/UInt64MultiArray`), `/trigger` (`sensor_msgs/msg/Joy`) and `/trigger_timing` (`std_msgs/msg/UInt64MultiArray`). `/pressure` values are absolute Pa as in the legacy bridge; typed `/usi_collection/pressures` carries original integer centiPa and derived kPa absolute. The timing array layouts remain `[bridge_seq, device_us, host_wall_ns, device_time_valid, quality, boot_number, device_seq]` for pressure and `[bridge_seq, device_us, host_wall_ns, device_time_valid, boot_number, device_seq]` for trigger. The bridge sequence is host owned and independent per sensor stream. If a v2 boot ID is not a decimal uint64, the legacy `boot_number` is a stable SHA-256-derived uint64 surrogate; the original string boot ID remains authoritative in the typed record. `/trigger` preserves pressed and trigger-derived suction state, without claiming measured pump feedback. New `/usi_collection/*` topics use the public `usi_collection_msgs` package for frame planes, source identity, ARKit time, phone uptime, raw BLE time, host receipt monotonic/wall time, health counters and frozen trial metadata. Raw depth is `32FC1` little-endian meters with stride `width*4`; confidence is separate mono8 levels 0/1/2. Frames are decoded/checked when accepted and again after reopening. ROS Header stamps and MCAP record times use host complete-packet wall receipt; no phone or ESP uptime is passed off as a ROS epoch. Raw clocks remain available in typed fields and exact JSON metadata.

The raw depth bytes are preserved exactly, including IEEE754 NaN or infinity pixels. `FrameRecord.depth_valid_mask` has one byte per depth pixel: 1 only for finite, positive meter values; 0 otherwise. Confidence remains an independent source level and is never used to rewrite the depth plane. A NaN with confidence 0 is accepted as an invalid raw depth pixel and rechecked after reopening. The host rejects confidence levels outside 0/1/2 and malformed dimensions or stride.

A BLE or USB clock observation must keep `link`, `exchange_id`, `source_id`, `epoch_id`, `t1_ns`, `t2_ns`, `t3_ns`, `t4_ns`, and `mapping:{valid,scale,offset_ns,uncertainty_ns}`. The last three mapping fields can be null when unvalidated. The companion `ClockRecord` stores all four raw timestamps, host receipt clocks, validity and optional-field presence flags; it does not claim fitted synchronization merely because an exchange was recorded.

```json
{"link":"ble","exchange_id":"clock-17","source_id":"esp-1","epoch_id":"boot-1","t1_ns":100,"t2_ns":110,"t3_ns":120,"t4_ns":130,"mapping":{"valid":false,"scale":null,"offset_ns":null,"uncertainty_ns":null}}
```

Generated tests are run with:

```bash
source /opt/ros/jazzy/setup.bash
source /home/emi-linux/usi_ws/usi_v2/collection-ros/install/usi_collection_msgs/share/usi_collection_msgs/local_setup.bash
python3 -m pytest -q tests/test_collection_recorder.py tests/test_collection_collector.py tests/ros/test_mcap_recording.py
ros2 bag info -s mcap /path/to/generated/trial-.../trial-..._0.mcap
```

These tests prove software behavior only. No physical phone, BLE link, concurrent ultrawide capability, sustained 60 FPS, calibration accuracy, clock fit, or camera-to-tool transform is established by a generated MCAP.
