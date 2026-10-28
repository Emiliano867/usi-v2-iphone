# USI Stream G3 implementation plan

> **For agentic workers:** Use subagent-driven-development for the independent host receiver task and scoped reviews. Root implements the iOS integration against the same frozen contract. Do not dispatch multiple implementation agents concurrently.

**Goal:** Add a versioned live USB ARKit RGB/depth/pose mode and a tested Ubuntu receiver.

**Architecture:** Preserve stock modes, add a single-session ARKit controller and bounded encoder/USB sender on port5558. A stdlib Python host uses usbmuxd directly, preserves packets/timing metadata and optionally previews images.

**Tech stack:** Swift5/iOS18+/ARKit/Network.framework; Python3.12/unittest, optional OpenCV/NumPy; macOS26/Xcode26.6 CI.

**Spec:** `docs/superpowers/specs/2026-10-27-usi-stream-design.md` (wire field names/constants are binding).

## Global constraints

- ROS2 Jazzy only; no legacy pressure firmware/ROS edits.
- ESP32 BLE → iPhone → live USB → Ubuntu MCAP remains the final runtime topology.
- Preserve raw ARKit time, frame sequence/session epoch, tracking and intrinsics; no numeric `Header.frame_id`, fabricated TCP or clock accuracy.
- Bounded capture/encode/send queues with explicit losses; no private ultrawide API.
- Keep stock5555–5557 unchanged; use5558 and explicit USI2/version1 handshake.
- No account secrets, pairing files or phone UDIDs in source/logs.

### Task 1: Host protocol, usbmuxd transport and receiver

**Files:** create `usi_stream/{__init__,protocol,usbmux,receiver}.py`, `tests/test_usi_{protocol,usbmux,receiver}.py`, `tests/fixtures/usi_hello_v1.hex`.

**Interfaces:** consumes frozen spec. Produces `MessageType`, `Packet`, `ProtocolError`, `encode_packet`, `decode_packet`, `recv_packet` plus validated frame slicing; `connect_usb(port=5558)` socket connector; `python -m usi_stream.receiver` CLI.

- [x] Write failing unittest cases for fragmented packets, bounded lengths and malformed frame metadata; run red before implementing.
- [x] Implement strict framing/metadata validation, frame modality slicing and EOF behavior; run tests green.
- [x] Test usbmuxd little-endian plist header, bounded replies and Connect network-order port with fake socket servers; implement without logging identifiers.
- [x] Implement headless/preview receiver, handshake, per-session gaps, periodic raw ping observations and metadata JSONL. Add meaningful fixtures for reconnect/clock/session behavior.
- [x] Run unittest, imports/CLI help and review. No hardware success claim.

### Task 2: iOS wire and bounded ARKit capture

**Files:** create `ios_app/iPhUMI/USIStream/{USIWireProtocol,USIUSBServer,USIFrameEncoder,USIStreamViewController}.swift`, `Package.swift`, `tests/swift/USIWireTests.swift`.

**Interfaces:** emits exact Task1 protocol. Swift wire type offers packet encode/decode/header parse without UIKit; server negotiates and bounds pending data; frame encoder owns retained CVPixelBuffers and packs rows.

- [x] Write Swift framing/mailbox tests with the shared golden HELLO vector, truncated/oversized/bad header/JSON and coalescing/reset cases. Local Swift/Xcode unavailable.
- [ ] Execute Swift tests in the macOS workflow.
- [x] Implement Foundation framing and serial-queue Network.framework server, bounded handshake/control/frame behavior and four-timestamp response fields.
- [x] Implement one ARSession camera/pose/depth capture, requested30FPS, per-acquisition sequence, queue replacement counters, reset epochs, tracking/intrinsics and independent preview throttle.
- [x] Review buffer ownership, row strides, serial state ownership, cancellation and old-session suppression; fix findings.
- [ ] Validate pure wire and native app through custom cloud CI before claiming build success.

### Task 3: Entry, cloud build and hardware handoff

**Files:** modify `HomeScreen/RootViewController.swift`, `Base.lproj/Main.storyboard`, `iPhUMI.xcodeproj/project.pbxproj`; create `.github/workflows/usi-stream-ios-build.yml`, `docs/usi-stream.md`; extend `.gitignore` for build/test artifacts.

- [x] Add a third USI Stream entry without altering collection/deployment capture code; include the new source folder in the Xcode target.
- [x] Create manual current-source CI: Python tests, Swift wire tests, locked pods and unsigned archive with valid build version; retain diagnostics/IPA. Keep original stock CI pinned.
- [x] Run local tests/static checks; obtain scoped and whole-change review; fix findings and record limitations.
- [x] Commit reviewed changes and prepare an incremental Git bundle for the authenticated Codespace. Root lacks GitHub write/dispatch authentication, so actual publication/run/install needs the user's existing path.
- [ ] After a real cloud build, guide install and a measured G3 phone test: RGB/depth + XYZ/quaternion/source times, tracking, reset/reconnect and packet gaps. Leave TCP/pressure/MCAP outside G3 acceptance.
