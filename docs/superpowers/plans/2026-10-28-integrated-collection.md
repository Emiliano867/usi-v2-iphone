# Integrated Suction Collection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the approved live iPhone collection workflow, real BLE telemetry integration and host-authoritative ROS 2 Jazzy MCAP recording, with truthful capability/data-loss reporting and a reviewable installation handoff.

**Architecture:** Keep the existing diagnostic v1 path intact and add a collection v2 transport on 5559. Isolate pure wire/state models, private BLE acquisition, camera/native preview, UIKit presentation and the host recorder. The phone aggregates data; one host writer records and independently verifies the MCAP before reporting Saved.

**Tech Stack:** Swift/Foundation/UIKit/ARKit/Metal/CoreBluetooth/Network; Python 3.12, ROS 2 Jazzy, rosbag2 MCAP; private Arduino ESP32-S3 BLE firmware. iOS builds use the existing macOS/Xcode GitHub workflow. Foundation tests can also run using the local official Swift Linux toolchain.

**Spec:** `docs/superpowers/specs/2026-10-28-integrated-suction-collection-design.md`

## Global Constraints

- Required data path: ESP32 → BLE → iPhone → live USB → Ubuntu ROS 2 Jazzy → MCAP.
- One circle divided into three equal 120-degree sectors labeled C1, C2 and C3.
- Green means fresh valid calibrated pressure seal; red means fresh valid calibrated unsealed; gray means missing, stale, invalid or uncalibrated.
- Pressure numeric values use kPa absolute. Full seal · 3/3 requires all three known/green.
- Suction ON/OFF is read-only and trigger-derived; no measured motor feedback or new remote actuation is invented.
- ARKit camera pose stays required and independent of image encoding/transport replacement. Target capture 60 FPS; report measured rates and selected format, never silently promise sustained throughput.
- Raw depth is 32FC1 little-endian meters; legacy 16UC1 millimeters remains unchanged. Confidence levels 0/1/2 are separate.
- Full profile requires ultrawide; unsupported concurrent capture blocks Full with a reason. A separately selected Core profile must explicitly declare its missing ultrawide. Never invent access through unsafe object offsets.
- Preserve raw source/receive clocks, boot/session/world epochs, sequences, quality and loss counters. No fabricated synchronization or calibrated TCP.
- Real production UI contains no synthetic sensor/recording state. Simulator fixtures and software-generated MCAP are explicitly labeled test data.
- Existing protocol v1, legacy pressure firmware/source hashes, stock collection/deployment and prior build/install path remain regression references.
- Never publish private firmware, Wi-Fi credentials, pairing files, device UDIDs, Apple secrets or legacy confidential research source in the public fork.
- Host acknowledgment is required for Recording; closing and reopening MCAP with verified stream identities/counts is required for Saved. Preserve incomplete artifacts on failures.

## Shared interface boundaries

The contract task freezes a collection packet enum and JSON field schemas in `docs/collection-protocol-v2.md`. Keep the existing 16-byte USI2 header layout but require version 2 on collection packets; existing version-1 APIs stay unchanged. Collection messages are HELLO=1, FRAME=2, PING=3, PONG=4, HEALTH=5, POSES=6, PRESSURE=7, TRIGGER=8, BLE_CLOCK=9, TRIAL_COMMAND=10, TRIAL_STATUS=11. Payload is allowed only for FRAME. Maximum metadata 65536 bytes, payload 16777216 bytes; reject booleans masquerading as integers, nonfinite values and excessive nesting. Collection frame metadata retains the audited v1 image representation and original source timestamps.

POSES carries a bounded list of independent ARFrame pose records. PRESSURE carries bounded raw samples with ESP32 boot/sequence/microseconds, three absolute Pa values, quality and phone receipt time. TRIGGER carries original observed pressed/suction_on plus identity/source/receipt time. BLE_CLOCK preserves raw four-timestamp observations. Each source retains its own epochs and sequence.

TRIAL_COMMAND carries request_id, trial_id, operation (prepare/begin/stop/status), expected_revision, session/task/gripper/calibration/profile snapshot and source sequence/counter fences appropriate to that operation. TRIAL_STATUS carries revision, state, reason, stream counts, required/missing modalities and final verification result. No request is executed twice. Recording boundaries must work even when control overtakes pending image sends: drain the known end fences before verifying or explicitly report incomplete after a bounded deadline.

Task 1's implementation report is the authoritative exact API/schema handoff to later tasks; later tasks must consume those names, not independently redefine incompatible models. The private BLE packet layout is frozen by Task 3 and covered by C++/Swift/Python shared fixtures before CoreBluetooth integration.

## Task 1: Collection contract, loss accounting and pure state models

**Files:**
- Create `docs/collection-protocol-v2.md`.
- Create `usi_stream/collection_protocol.py` and `usi_stream/collection_state.py`.
- Create `ios_app/iPhUMI/USIStream/USICollectionWire.swift` and `USICollectionState.swift`.
- Create `tests/test_collection_protocol.py`, `tests/test_collection_state.py`, `tests/swift/USICollectionTests.swift`, shared `tests/fixtures/collection_*.hex`.
- Modify `Package.swift` only to include the new Foundation sources/tests.

**Interfaces:** Consume the legacy frame schema without changing it. Produce strict `encode_packet`, `decode_packet`, `recv_packet` collection APIs; exact message/type and payload validators; Foundation Swift equivalent; pressure/trigger/calibration/seal/trial state types used by Task 4. Record actual signatures and JSON examples in the report.

- [ ] Write tests first for a cross-language HELLO fixture, malformed header/lengths/version, frame slices, boolean/NaN rejection, nested metadata limit and bounded sensor batches. Example expected interface:

```python
packet = decode_packet(encode_packet(MessageType.HELLO, {
    'role': 'host', 'protocol_version': 2,
}))
self.assertEqual(packet.metadata['protocol_version'], 2)
```

- [ ] Write pressure seal tests proving unknown/stale/invalid/uncalibrated → gray, threshold hysteresis and persistence, correct per-channel quality mask, partial/all-green aggregate, and stale trigger → Unknown independently of pressure. Model calibration as explicit validated data, not guessed defaults.
- [ ] Run focused Python tests and Swift tests against missing implementation, recording the expected red results. Swift compiler is `/home/emi-linux/usi_ws/usi_v2/.toolchains/swift-6.0.3-RELEASE-ubuntu24.04/usr/bin/swift`; if not yet available wait for its root-managed download, not a second download.
- [ ] Implement the smallest bounded codecs and state transitions satisfying those behavioral tests; use independent sequence histories and explicit queue overflow counts. Include idempotent trial-state semantics and stale host status handling without claiming a writer exists.
- [ ] Run focused tests, then the existing/new full Python and Foundation Swift suites. Self-review both language fixtures and document exact downstream APIs. Commit this task's paths only and report red/green evidence.

## Task 2: ROS message definitions and authoritative MCAP collector

**Files:**
- Create `ros/usi_collection_msgs/{CMakeLists.txt,package.xml,msg/*.msg}` for typed source/timing/frame/pressure/trigger/seal/trial metadata.
- Create `usi_stream/ros_messages.py`, `usi_stream/recorder.py`, `usi_stream/collector.py`.
- Create `tests/test_collection_recorder.py`, `tests/test_collection_collector.py`, `tests/ros/test_mcap_recording.py` and `docs/collection-host.md`.

**Interfaces:** Consume Task 1's v2 packets exactly. Produce a single collector CLI (`python3 -m usi_stream.collector --output-root PATH`), host replies usable by Task 4, direct writer callbacks and explicit post-close validation manifests. Preserve legacy topic names/types; use typed companion messages for identities/time/quality. Do not copy private ROS implementation source.

- [ ] Write failing recorder tests with deterministic packet IDs and an injectable storage adapter for control-state tests. Exercise duplicate prepare/begin/stop/status requests, wrong revisions, missing required streams, delayed final frames, queue overflow, dropped samples, disk/write failure and lost acknowledgments. Assert one artifact per trial and no false Saved.
- [ ] Add a Jazzy integration test using the actual MCAP writer and an independently created reader, not a mock writer. Generate valid tiny JPEG, raw float32 depth/confidence, pose, pressure and trigger records, close/reopen and deserialize/count them. Mark generated recordings as test fixtures. A mutation that omits a pressure/frame record must change verified success into Incomplete.
- [ ] Run focused tests red; then implement transport-independent validation, typed ROS conversion and one bounded writer worker. Write the same serialized ROS messages to MCAP and optionally mirror them for monitoring. Keep DDS discovery outside the authoritative data path.
- [ ] Implement readiness, idempotent two-phase trial control/fences, fresh required streams, a provisional writer-accepted count, final drain/close/reopen scan, independent verification manifest and preserve-on-error behavior. A Full trial with known loss or a missing enabled modality is incomplete. Detect host/phone disconnect and never silently resume a continuous trial after a reset.
- [ ] Build only the new message package in an isolated build/install location, source it, run the real integration test and inspect generated `ros2 bag info`. Validate depth encoding/stride/endianness and preserve raw times rather than invent epoch stamps. Record commands/results and downstream CLI/status schema in the report; commit this task's public files only.

## Task 3: Private BLE acquisition variant and shared sensor codec

**Files:**
- Create private `/home/emi-linux/usi_ws/firmware/esp32_direct_mprls_ble/` firmware variant and private build instructions; keep existing reference files/hash manifest unchanged.
- Create public `ios_app/iPhUMI/USIStream/USIBLECodec.swift`, `usi_stream/ble_protocol.py`, `tests/fixtures/ble_*.hex`, `tests/swift/USIBLETests.swift`, `tests/test_ble_protocol.py`, `docs/collection-ble-protocol.md`.
- Add a private host-compilable firmware codec test under `/home/emi-linux/usi_ws/analysis/tests/` where appropriate. Add the pure Swift codec to `Package.swift`.

**Interfaces:** Consume the audited private acquisition semantics and Task 1's pressure/trigger model. Produce a versioned binary BLE service contract, exact service/characteristic UUIDs, golden binary vectors shared across firmware/Swift/Python, bounded fragmentation/reassembly and typed decoded events for Task 4. No credentials in public sources or command output. Report the precise CoreBluetooth callback API to Task 4.

- [ ] Read private source audit, current hardware constraints and only necessary acquisition/conversion/trigger code; do not print Wi-Fi settings. Confirm source SHA-256 before any changes. Keep current channels p0=U3/ch0, p1=U4/ch5, p2=U5/ch6 and requested acquisition interval 6944 microseconds.
- [ ] Freeze a bounded BLE layout preserving original uint32 boot/sequence and uint64 device microseconds, three signed int32 pressures in 0.01 Pa units, quality bits and separate trigger heartbeat. Define four-timestamp clock exchanges and bounded fragments for a negotiated payload including a safe default-MTU path. Keep invalid pressure/quality semantics intact.
- [ ] Write failing C++/Swift/Python tests for shared golden samples, partial/duplicate/out-of-order/oversized fragment rejection, sequence wrap/reboot, stale/invalid pressure and clock exchange layout. Run them red before implementation.
- [ ] Add a separate private BLE variant that reuses the acquisition behavior, single-owner sensor access and local trigger semantics, with bounded queues and explicit acquisition/notification/queue loss counters. Never introduce motor output. Use an available supported Arduino BLE library pinned in the private build recipe and verify its exact APIs against primary documentation.
- [ ] Compile host codec tests and the firmware using an isolated Arduino CLI/toolchain if available; report a missing compile dependency honestly rather than presenting source review as firmware build success. Run Swift/Python tests and recheck all protected hashes. Do not flash the board. Commit only public codec/docs/tests; retain private firmware/build evidence outside the fork.

## Task 4: Real iPhone collection UI, native camera/depth preview, BLE and trial control

**Files:**
- Create `USICollectionView.swift`, `USISealView.swift`, `USICollectionViewController.swift`, `USICameraCapture.swift`, `USINativePreview.swift`, `USIBLECentral.swift`, `USICollectionServer.swift` in `ios_app/iPhUMI/USIStream/`, split further only by clearly reported responsibility.
- Modify `USIInterface.swift`, `HomeScreen/RootViewController.swift`, `Info.plist`, Xcode project source membership and `tests/ios-layout/{ProbeApp.swift,run.sh}`.
- Add focused Foundation state/concurrency tests and camera-preview fixture checks where they can execute. Modify no legacy camera controller.

**Interfaces:** Consume Task 1 state/packet APIs, Task 2 host command/status contract and Task 3 BLE codec/UUIDs. Produce the approved native collection screen with actual ARKit RGB/depth preview and live CoreBluetooth data, a 5559 listener and host-controlled Start/Stop. Preserve the 5558 diagnostic listener as an Advanced mode. Report runtime limitations and the exact data path; no synthetic production feed.

- [ ] Add failing behavioral tests for state rendering inputs (one 3-sector seal, gray until calibrated/fresh, pressure units, trigger-independent suction, host-acknowledged recording and recording timeout) and independent pose retention under image backpressure. Add native layout cases for normal/large text, partial/full/unknown data, long missing-capability reasons and recording/stop reachability on both existing simulator models.
- [ ] Implement the approved native landscape layout: large preview with RGB/Depth/Ultrawide selector, one 120-degree-sector circle, numeric pressures, read-only suction status, session/task/gripper/calibration settings, fixed trial number/state/timer/Start/Stop bar and readable Data/Diagnostics. Retain last-save result and all required per-stream status/count fields. Use accessibility text, safe areas and scroll fallback. Do not use browser HTML in the app.
- [ ] Implement one ARSession selecting a supported 60 FPS format or reporting the limitation. Render bounded native pixel buffers independent of JPEG compression; show raw depth/confidence through a correctly labeled visualization without changing recorded bytes. Extract value-only pose records before image encode, use an independent bounded transport lane and report overflow. Capture preview FPS, acquisition, encode, host-reported receive/write rates separately.
- [ ] Probe ultrawide safely on the actual supported APIs; do not copy unsafe private ivar-offset code. If the public capture path cannot supply a concurrent ultrawide image with valid independent timing/intrinsics, advertise unavailable, show the reason and block Full. Core requires explicit selection and records the missing-modality manifest. No hidden downgrade.
- [ ] Implement CoreBluetooth scanning/filtering, service discovery/subscription, decode/reassembly, raw sample/clock forwarding, freshness and reconnect state. Add real Bluetooth usage description. Show gray until real calibration is selected; offer explicit numeric calibration import/entry with validation rather than guessed thresholds. Acquisition/BLE continue with Data open.
- [ ] Implement bounded v2 listener/queues, HELLO, independent sensor/pose data, clock PING/PONG and trial requests with idempotency/revision/fences. Update Recording only from fresh host status. Block editing of the active trial snapshot; Stop remains reachable; disconnect/background/reset gives explicit incomplete/unknown status and preserves epochs.
- [ ] Run Foundation/Python tests; update layout probe compilation for every real UI dependency and simulator fixtures. Self-review Xcode membership and Info.plist. Linux verification cannot claim native UIKit compilation. Commit and report native build work remaining for the cloud handoff.

## Task 5: Integration verification, review and installation handoff

**Files:**
- Modify `.github/workflows/usi-stream-ios-build.yml`, `docs/usi-stream.md`, `docs/collection-host.md` and relevant regression/integration tests.
- Create `docs/collection-acceptance.md` and a portable Git bundle in Downloads; private evidence remains `/home/emi-linux/usi_ws/docs/usi_v2_20261027/`.

**Interfaces:** Consume all completed components. Produce a reproducible source bundle/build workflow and documented real-phone/ESP32/USB/MCAP acceptance procedure. Keep the separate app ID `com.emiliano867.suctionumiv2` and display name `Suction UMI v2`. No credentials or physical flashing/install are automated.

- [ ] Run existing/new Python suites, Foundation Swift suites, typed-message build and actual MCAP generated-stream integration. Inject slow image encoding/socket/writer behavior and confirm independent pose/sensor counters and no false Saved result.
- [ ] Wire new sources/layout cases into cloud CI, retain unsigned IPA plus screenshots/diagnostics, and validate separate app identity. Native build/simulator tests must execute on the user's next authenticated GitHub run; report that gate as pending until its actual result is observed.
- [ ] Run a broad branch review and address load-bearing findings, rerunning only covering tests after fixes. Recheck protected legacy hashes and review staged filenames/secrets before producing the bundle. Verify the bundle in a temporary checkout rooted at published base 322ad1a and perform a real fast-forward import test.
- [ ] Write installation and acceptance steps for the next source revision, accurate artifact name and private firmware build location. The first physical trial verifies all enabled raw streams, rates, IDs, depth encoding and reopened bag counts. Then test ten minutes with thermal/load and BLE/USB interruptions. These hardware steps remain unverified until actually performed; preserve this status prominently in reports and the final handoff.

## Completion evidence

Record each stage's commits/tests/review status in this plan's ignored SDD ledger. Separate code completion, cloud native build, phone installation, firmware flash and full physical collection proof. The app must never label the full dataset ready when a required stream is unavailable. If physical capability or authenticated cloud access prevents final verification, finish the authorized local code/tests/review/bundle first and report the exact remaining action; do not stop at a cosmetic UI patch or claim hardware success.
