# Suction UMI v2: integrated demonstration collection

Date: 2026-10-28. Status: **revised layout and integration design approved by the user; implementation in progress**. Approval: “ok the image you made makes sense and looks good”. Synthetic browser examples are design references, not hardware evidence.

## Outcome

Provide one main **Collect Demonstrations** workflow combining live iPhone vision and ARKit tracking, three ESP32 pressure channels and trigger, trial labeling, and authoritative Ubuntu MCAP recording. Keep the simple text and controls familiar from iPhUMI. A researcher must be able to see what is available, what is arriving, what the recorder is accepting, and whether the saved trial passed verification.

The user's latest clarification requires **one circle divided into three equal 120-degree sectors**, each representing one pressure chamber. This replaces the previous proposal's three separate circles and agrees with the guide's original shape. The request also includes visible ultrawide capture and a 60 FPS target. The required data path remains ESP32 → BLE → iPhone → live USB → Ubuntu ROS 2 Jazzy → MCAP.

## What the installed build actually does

Audited baseline: `322ad1acd5f4158b51e62a0eeaa21f2ac589e22e`, installed UI build 3.3.

- **Live USB Stream** is a custom ARKit transport diagnostic. It selects a 30 FPS format, encodes RGB at up to 640 pixels wide, carries depth/confidence and camera pose, and displays a JPEG preview capped separately at 10 FPS. It has no BLE subscriber, seal indicators or recorder control. Pose currently shares the image replacement queues, so image backpressure can discard pose too.
- **Collect Demonstrations** is the inherited iPhone-local demonstration recorder. It does not implement the suction BLE-to-host dataset workflow.
- **Deployment Mode** is the inherited camera streamer. It does not establish complete suction collection or ARKit pose recording.
- The custom Ubuntu receiver previews RGB/depth and logs diagnostic metadata. It **does not write the new MCAP dataset**. A connected USB status is not evidence of a recorded trial.

These gaps explain the user's observations. Neither the completed UI build nor the earlier stock camera test establishes completion of this integration.

## Approach

**Recommended: a dedicated integrated collector using the existing ARKit and USB modules.** Adapt familiar task/session/start/stop concepts from iPhUMI, while giving camera acquisition, BLE reception, preview and recording separate responsibilities. One ARSession owns the cameras. Preserve inherited modes under **Advanced** for regression.

Two alternatives were considered:

1. Retrofit the inherited local collection controller. This preserves more existing behavior but also brings parallel-jaw, multi-phone, local-file and undocumented ultrawide dependencies into the new collection path. Its recording state would still need replacement with host acknowledgment.
2. Add pressure indicators to the current diagnostic streamer. This is smaller visually but leaves trial management, recording assurance and pose loss under image backpressure unresolved.

The recommended approach reuses useful modules without treating either existing mode as a complete suction collector.

## Main screen and navigation

Home presents **Collect Demonstrations** as the main action. **Advanced** contains the inherited local collector, deployment streamer and USB diagnostics with explicit descriptions. There is no competing main action called Live Demonstration or Live USB Stream.

The landscape collection screen contains:

- **Live RGB and ARKit:** a large native camera preview, camera XYZ, tracking quality and selected capture profile. Switching RGB/Depth/Ultrawide changes the visible preview only; it does not turn off acquisition of a required stream.
- **Grasp seal:** one circle divided into three equal 120-degree sectors labeled C1, C2 and C3. Each sector follows its physically mapped chamber. Green means a fresh, valid, calibrated pressure seal; red means a fresh, valid, calibrated reading without a seal; gray means missing, stale, invalid or uncalibrated. Show **Full seal · 3/3** only when all three sectors are green, **Partial seal · 1/3 or 2/3** when all readings are known but only some chambers are sealed, and **No seal · 0/3** when all are valid and unsealed. Any unknown sector makes the aggregate **Seal unavailable**, with the known count available in Data. A pressure seal classification is not a measurement of holding force. No measurements or thresholds are simulated in a real trial.
- **Pressure readings:** a clearly labeled **Pressure · kPa absolute** column next to the circle, with one numeric row and text state for each matching C1/C2/C3 label. Include freshness in Data and show Stale/Invalid in the main row when needed. Do not display an old numeric value as a fresh measurement. Add ambient-referenced vacuum differential only after an ambient baseline is measured and identified. Chamber-to-sensor and angular mapping belong to the calibration snapshot; sector positions in the mockup are provisional.
- **Suction ON/OFF:** a large text status distinct from both seal color and recording state. In the audited apparatus this is a read-only **trigger-derived** indication: released trigger corresponds to suction on, held/pressed corresponds to suction off. Use the actual fresh telemetry field and its documented semantics, not pressure threshold or UI button state. Missing/stale trigger data shows **Suction unknown**. This indication does not claim measured pump operation, and the UI does not add a remote motor-control command.
- **Depth and ultrawide thumbnails:** tap to enlarge. Depth is a visualization of the raw depth/confidence, with units and unavailable/invalid pixels identified. RGB, depth and ultrawide each show their own observed rate.
- **Connections and recording:** separate BLE, USB, AR tracking and Ubuntu recorder states. Live preview can run while the recorder is idle. A stale host status removes the Recording assurance visibly.
- **Trial controls:** keep the familiar iPhUMI session, task label, gripper/calibration identity and large Start/Stop concept. The fixed bottom bar shows **Trial number · Ready/Preparing/Recording/Finalizing/Saved/Incomplete**, elapsed time and Ubuntu recorder status. Use **Start trial** and **Stop trial** consistently; Start is enabled only after the selected profile is ready. A red recording dot and the word Recording appear only after host acknowledgment. Stop remains reachable while recording or if a stream becomes unavailable. The latest saved-trial result remains visible while idle; full sample counts and the host bag location are one tap away in Data.
- **Data:** one tap opens a readable list of every stream, requirement status, freshness, source/received/writer-accepted counts, gaps and save-verification result. Missing or unknown counters display `Unavailable`, not zero or a fabricated rate. Detailed timestamps, quaternions, transforms and calibration provenance belong here rather than covering the camera.
- **Settings/Diagnostics:** capture profile, calibration selection, clock status and errors. World tracking reset is unavailable during a normal trial; restarting tracking ends the affected trial as incomplete and begins a new world epoch after confirmation.

An idle host advertises whether it can prepare a trial; this enables Start without requiring an already-open bag. Pressing Start enters Preparing and freezes the trial label/profile/calibration snapshot. Changing the task or capture profile takes effect on the next trial. Leaving the screen during a trial requires Stop and finalization; opening Data or Diagnostics must not stop or reset the camera session.

Use native UIKit text, system buttons, safe areas, at least 44-point touch targets, Dynamic Type and VoiceOver. Keep Start/Stop reachable in landscape and at large text sizes; allow the secondary data panel to scroll. UI graphics are never burned into the recorded camera images.

Retain iPhUMI's useful collection presentation: prominent camera view, session/task context, explicit recording readiness, gripper identity in settings and an obvious Start/Stop action. Do not inherit parallel-jaw width, left/right jaw controls or unrelated multi-phone controls for this single suction tool. Suction state, chamber pressure, grasp seal and trial recording are separate signals and remain visually separate.

The accompanying local HTML proposal v2 is a **design preview**, not an implemented data path or a screenshot of a live phone. Its explicitly labeled synthetic examples show partial/full seal, suction off, recording and unavailable states. Example colors and pressures illustrate the layout; they do not define calibration thresholds or prove hardware behavior. Production code must not substitute these examples for real telemetry.

## Camera, pose, depth and ultrawide

Select a supported ARKit 60 FPS format when available and expose the exact selected resolution and rate. Measure camera acquisition, native preview presentation, encoding, USB receipt and MCAP storage independently. A 60 FPS setting alone is not an acceptance result. Preserve every delivered ARFrame's pose metadata through a separate bounded queue before submitting images to encoding; carry it through an independent USB batch lane as well.

Native preview should consume bounded camera pixel buffers through a rendering path independent of JPEG encoding and USB. Never hold an unbounded number of ARFrames. Pressure/pose collection must continue when the preview is hidden. Image queues may replace pending frames only with explicit per-stage loss counters; pressure or pose overflow invalidates a complete trial rather than silently discarding samples.

Keep one camera-session owner. Raw scene depth remains float32 meters, with original confidence and associated ARFrame ID. Do not invent an independent depth exposure timestamp or assume each RGB exposure has a new depth sample. Smoothed depth may be an explicitly labeled preview option; preserve the raw source for recording.

Ultrawide is a requested modality, not assumed working. The inherited ARKit ultrawide access uses undocumented internals and cannot be treated as reliable just because a stock setting exists. First probe actual availability on the installed iOS/device: valid buffers, dimensions, intrinsics, independent advancing source timestamps, changing content and observed cadence while ARKit/main RGB/depth run. Reject stale/repeated buffers and unsafe unsupported access. Do not start another camera pipeline that steals ARKit's session.

The requested **Full collection** profile includes ultrawide. If concurrent ultrawide cannot be proven, show a specific unavailable reason and block that profile. A separately selected **Core collection** diagnostic profile may omit it only with an explicit missing-modality manifest and user choice; it cannot be reported as the requested full result. Raw IMU and audio remain separately identified future modalities unless added and verified.

The last measured link was 480 Mb/s. Benchmark selected resolution, encoding, CPU and storage under simultaneous load; do not promise uncompressed full-resolution RGB at 60 FPS or USB 3 speed. Report failure to sustain the requested profile rather than silently changing to 30 FPS. A lower-rate profile is an explicit setting.

## ESP32 and live chamber data

Add a separate private BLE firmware variant without modifying the validated UDP reference or publishing firmware credentials. Reuse the audited acquisition, sensor conversion and trigger semantics. Aim to preserve the existing approximately 144 Hz acquisition baseline and benchmark each stage under BLE load.

Capabilities identify firmware/configuration, units, sensor mapping and implemented command/feedback fields. Samples retain boot ID, sample sequence, original ESP32 microseconds, all three absolute pressures and per-channel quality. Proposed pressure representation is signed int32 in 0.01 Pa units, preserving the audited source precision. Trigger events and periodic current-state heartbeats have their own identity and source time. Legacy inverse-trigger `suction_on` remains a trigger observation, not measured motor state.

Use a versioned, bounded binary BLE batch protocol with explicit lengths, sample count, byte order and negotiated payload capacity. Account for acquisition skips, queue overflow, notification submission failures, sample gaps, duplicates and reconnect epochs. No inferred interpolation replaces raw missing pressure samples. BLE reception and forwarding run independently of UI and image encoding.

Seal thresholds, hysteresis, persistence, stale timeout, ambient baseline and physical chamber mapping are calibration data. Raw pressure recording must work before calibration; affected circle sectors stay gray/Uncalibrated until the calibration is valid. Calibration collection does not require three green sectors. Pump command is included only if implemented; actual pump current/state only if instrumented. Tool TCP pose is included only after camera-to-tool calibration. None are fabricated from trigger state or camera XYZ. Turning the trigger-derived suction indication on or off does not directly recolor sectors: their state follows actual calibrated pressure independently.

## Dataset contract

The Data panel and trial manifest use the same stream inventory as the recorder. Each enabled stream has schema, units, source identity, time provenance, validity and counters. Stream names below describe the contract; preserve audited legacy ROS names/types and add typed companion metadata rather than silently changing them.

| Stream | Authoritative contents | Required for the requested full profile |
| --- | --- | --- |
| Main RGB | Encoded image, actual dimensions/codec, source ARFrame ID/time, camera intrinsics | Yes |
| Raw depth | `32FC1`, little-endian float32 meters, dimensions/stride and ARFrame association | Yes |
| Depth confidence | Raw levels 0/1/2, explicit missing/valid mask and association | Yes on the supported ARKit path |
| Camera pose | XYZ, quaternion, full transform, raw ARFrame time and sample identity, independent of image encoding | Yes |
| Tracking/epochs | Tracking quality/reason, interruption/relocalization/reset, phone session and world epoch | Yes |
| Camera calibration | RGB/depth intrinsics and applicable resolutions/configuration; frame conventions | Yes |
| Ultrawide | Actual image, resolution, intrinsics, independent source time/identity and measured cadence | Yes; capability-gated |
| Three pressures | Original samples, absolute units, ESP32 boot/sequence/time and per-channel quality | Yes |
| Trigger | Transitions plus current-state heartbeat, original source time/identity | Yes |
| Seal state | Derived C1/C2/C3 states, original pressure sample reference and calibration version, including Uncalibrated | Yes |
| Trial metadata | Session/trial/task/gripper IDs, selected profile, configuration and calibration snapshot | Yes |
| Timing | Raw BLE and USB clock exchanges, mapping parameters/validity/uncertainty and receive-time provenance | Yes |
| Health/loss | Per-stage sample counts, missing ranges, rejected/duplicate data, disconnects and phone thermal state | Yes |
| Pump command/feedback | Distinct implemented command and separately measured feedback | Only when implemented/instrumented; declare absent otherwise |
| Calibrated TCP/TF | Verified camera-to-tool transform and resulting tool pose | Only after physical calibration; camera pose stays available beforehand |
| Raw IMU/audio | Separately acquired and timed raw measurements | Outside this first integration; explicitly declared absent |

Never reinterpret the legacy `16UC1` millimeter depth as the new `32FC1` meter stream. Keep source profiles mutually exclusive on conflicting topic names and update downstream readers to check encoding. Confidence is a separate mono8 image. Use named spatial `Header.frame_id` values, with sequences in metadata. Validate ARKit-to-ROS optical-frame axes before publishing converted transforms; no default jaw/tool transform is reused.

Retain original ESP32 time, phone BLE receipt uptime, original ARFrame timestamp, phone delegate receipt uptime, host complete-packet monotonic/wall time and bag record time as distinct fields. Record four-timestamp exchanges across both BLE and USB, with affine mapping validity and uncertainty. Until validated, use explicitly identified host receipt time for ROS epoch stamps, not a device uptime. A shared bag does not prove temporal alignment.

## USB and host recorder

Freeze the diagnostic protocol v1 on port 5558 and its fixtures. Use port **5559** for the explicit collection v2 connection, with capabilities, schemas, units and required modalities. Only the selected mode starts its listener; the host chooses the requested profile's endpoint. A v1 peer remains diagnostic and cannot claim complete collection.

V2 includes image payloads, independent pose batches, pressure batches, trigger/status, clock observations, health counters and trial control/acknowledgments. Every payload remains length-bounded and validated before allocation. Use independent bounded queues and send short pose/pressure/control messages between bounded image payloads; account for TCP head-of-line latency. Never route sensor batches through the existing small health/control queue or let whole-frame replacement erase independent pose samples.

One Ubuntu collector validates packets, constructs and serializes ROS messages, and submits them to a bounded worker owning `rosbag2_py.SequentialWriter` with MCAP storage. Publish the same messages for ROS monitoring, independently of the authoritative write. This avoids making dataset completeness depend on subscriber discovery or whether a monitor is running. Choose and benchmark an explicit MCAP configuration with chunk integrity/index support; do not assume storage defaults are sufficient.

Host recording state is authoritative:

1. **Idle / Not connected:** live preview may run; no recording claim.
2. **Preparing:** phone submits idempotent `request_id`, `trial_id`, expected state revision, profile and metadata. Host validates fresh mandatory streams, capabilities, destination and free space; opens the writer, registers topics and writes the configuration. Failure gives a visible reason.
3. **Recording:** ordered begin fences establish each source's trial boundary. Host acknowledges Recording only when accepting trial samples. UI shows elapsed time and per-stream writer-accepted counts, labeled provisional until final verification.
4. **Finalizing:** Stop supplies end fences/final source counters. Host drains through known boundaries, closes the writer, reopens with a new reader, deserializes records and compares stream counts, IDs, timestamps, gaps, dimensions, encodings and joins. Check image/depth decoding and bag playability. Write the final verification manifest atomically beside the closed bag, including file sizes/hashes.
5. **Saved — verified:** all required streams and boundaries pass checks. In the Full profile, all samples delivered by the configured acquisition paths within the trial fences must reach the reopened bag; a known missing image, pose or pressure sample makes that trial incomplete. Independently observed source cadence shortfalls also fail the requested profile's rate check. Do not equate a complete sequence after assignment with proof that the device acquired every physical exposure. The phone shows the host trial name, bag location and verification summary, with clock-fit validity separately identified.
6. **Incomplete / Error:** preserve partial data, missing ranges and concrete failure reasons. A missing acknowledgment, source interruption, overflow, disk failure or failed verification must never become Saved. Successful writer calls alone do not prove closure or power-loss durability.

Duplicate requests return existing trial state instead of creating a second bag. Resolve a lost acknowledgment with a status query. Initial operational defaults are a 500 ms host-status heartbeat, host-status stale after 2 s, pressure stale after 250 ms, vision stale after 500 ms, and trigger status heartbeat every 250 ms/stale after 1 s. These values are configuration recorded per trial and must be checked under hardware load; they are not calibrated seal thresholds. Gray pressure indicators immediately on staleness. A mandatory source remaining stale for a further 1 s ends the trial as incomplete; recovery inside that grace interval still preserves any gaps and does not erase a completeness failure. Reconnection queries that outcome, then creates a new linked trial instead of hiding the gap. Do not automatically resume an apparently continuous trial across a reboot or tracking reset.

## Implementation boundaries and verification

Implement this as coordinated, reviewable stages while keeping the full dataset as the completion criterion:

1. Camera/profile capability probe, native preview, independent pose capture/transport, truthful per-stream counters and the complete main-screen/data-panel layout. Pressure remains visibly unavailable until its real path exists.
2. Private BLE firmware variant, CoreBluetooth subscriber, raw sample forwarding and live three-chamber UI with calibration/stale behavior.
3. Collection v2 host bridge, typed ROS metadata, recorder preparation/start/stop/status protocol and MCAP validation.
4. Simultaneous physical-phone/ESP32/USB/MCAP tests, then calibration and sustained-load validation. Do not describe an intermediate UI build as a finished collector.

Required software evidence includes cross-language v2 golden vectors and malformed input limits; pose retention during slow JPEG/socket tests; pressure batch fragmentation, gaps, wrapping, reboot/reconnect and stale state; native landscape/large-text layout; start/stop races, duplicate requests and lost acknowledgments; deterministic generated-stream counts through reopened MCAP; depth encoding/stride/endian checks; disk/write/queue failure tests with no false Saved state.

Required hardware evidence begins with a short actual trial: camera/depth/ultrawide capability and observed rates, all three pressure streams and trigger, preserved raw times/clock observations, matching source/receiver/writer/reopened identities, decoded images/depth, readable ROS types, and a verified closed MCAP. Then run the full profile for ten minutes with thermal/memory/throughput telemetry and exercise BLE/USB disconnect recovery. Any sustained 60 FPS claim must name resolution/encoding and include captured, received and saved rates. Software-generated test packets are labeled and never counted as hardware validation.

The integration is complete only when the phone controls a real Ubuntu recording and its required signals are independently verified in the saved bag. Hardware availability, concurrent ultrawide compatibility, physical chamber mapping, measured pressure calibration and tool calibration remain evidence gates rather than invented values.

## Source basis

- User guide, especially §§0, 2, 5–9C; latest requests promote ultrawide and clarify one circle with three equal sectors, prominent pressure readings, suction ON/OFF and trial status.
- Audited local files: `USIInterface.swift`, `USIStreamViewController.swift`, `USIFrameEncoder.swift`, `USIUSBServer.swift`, `USIWireProtocol.swift`, inherited `DataCollection/ViewController.swift`, `usi_stream/receiver.py` and `usi_stream/protocol.py` at the baseline above.
- [ARKit video formats](https://developer.apple.com/documentation/arkit/arconfiguration/videoformat-swift.class) and [scene-depth rendering](https://developer.apple.com/documentation/arkit/displaying-a-point-cloud-using-scene-depth): use supported formats and separate raw capture from visualization.
- [ROS 2 Jazzy Python writer bindings](https://github.com/ros2/rosbag2/blob/jazzy/rosbag2_py/src/rosbag2_py/_writer.cpp) and [MCAP storage configuration](https://github.com/ros2/rosbag2/blob/jazzy/rosbag2_storage_mcap/README.md): explicit writer lifecycle and configurable storage integrity/performance.
