# USI Stream G3 design and wire contract

The user authorized continuation of the supplied USI v2 revision-2 guide after real stock USB RGB/depth succeeded. This implements its G3 camera/pose stream, preserving stock collection/deployment and all legacy USI firmware/ROS. No calibrated suction pose, BLE, clock-fit accuracy, or MCAP success is claimed here.

## Scope and capture

Add a third **USI Stream** mode. One `ARSession` owns rear RGB, world-tracked camera pose and optional raw `sceneDepth`/confidence; no competing AVCapture session, private ultrawide access, jaw calibration or microphone is needed. Prefer a supported 30-FPS ARKit video format for the first test. Each acquired frame gets a sequence before bounded encoding; dropped acquisitions remain visible in counters and sequence gaps. Preview is outside raw data and throttled independently.

Use one encoding worker and one pending retained snapshot; replacing the pending snapshot increments `encode_drops`. Transport keeps one send in flight and one pending encoded frame; replacing it increments `transport_drops`. Control packets have a small bounded queue, and overload/disconnect closes the connection rather than growing indefinitely. A tracking reset starts a new UUID session/world epoch and sequence zero. Old-epoch queued encodes must not appear after the new epoch. Background/interruption and thermal state are visible; no background recording guarantee.

## Transport and framing (frozen v1 interface)

Dedicated USB-forwarded phone port **5558**, separate from stock 5555–5557. Host uses the local usbmuxd daemon over AF_UNIX and selects a USB device by its ephemeral numeric DeviceID, never logging phone UDIDs. After usbmuxd Connect succeeds the socket carries this protocol directly, **without PeerTalk framing**.

All packets: `magic[4]='USI2'`, `version:u16be=1`, `type:u16be`, `metadata_length:u32be`, `payload_length:u32be`, UTF-8 JSON object metadata, payload bytes. Header is exactly 16 bytes. Metadata <=65,536 bytes, payload <=16,777,216 bytes. Reject bad magic/version/type, nonobject/nonfinite JSON and lengths before allocation. Host JSON nesting is limited to 64 levels. Known types: HELLO=1, FRAME=2, PING=3, PONG=4, HEALTH=5. Only FRAME may carry a payload. One reader must preserve partial/coalesced TCP packets correctly.

Host sends HELLO metadata `{"role":"host","protocol_version":1}`. Phone responds with `role="phone"`, `protocol_version=1`, `session_id` UUID, `camera_frame="arkit_camera"`, `world_frame="arkit_world"`, `arkit_clock="ARFrame.timestamp_seconds"`, `phone_clock="ProcessInfo.systemUptime_ns"`. No frames are sent before this handshake. Incompatible peers are closed; stock streams must fail magic/version checks.

PING metadata: `ping_id` unsigned integer, `host_send_ns` unsigned host monotonic integer. PONG echoes both and adds `phone_receive_ns`, `phone_send_ns` unsigned system-uptime integers, plus `session_id`. Host logs `host_receive_monotonic_ns` and `host_receive_wall_ns` at complete packet receipt. This supplies raw four-timestamp observations; **no synchronized Header stamps or accuracy claim** are produced. Preserve ARKit and system-uptime clocks separately until their relationship is verified.

HEALTH is optional bounded metadata (`event`, `session_id`, `message`); frame/session changes remain authoritative even if no health event was received.

## FRAME metadata (frozen v1 interface)

All numeric arrays contain finite JSON numbers. Integers are not booleans. Session identifiers are nonempty strings (phone emits UUIDs). Camera pose is ARKit `W_T_C`; no ROS-axis conversion or TCP transform is applied.

| Key | Required value |
| --- | --- |
| `session_id`, `frame_seq` | session string, unsigned integer; sequence assigned at ARFrame acquisition |
| `arkit_timestamp_s`, `phone_uptime_ns` | original nonnegative finite ARFrame Double seconds, unsigned uptime at delegate receipt |
| `world_frame`, `camera_frame`, `image_orientation` | `arkit_world`, `arkit_camera`, `sensor_native` |
| `camera_transform_row_major` | 16 numbers, 4x4 `W_T_C` serialized by rows |
| `position_m`, `quaternion_xyzw` | 3 translation numbers in meters, 4 unit-quaternion numbers in x,y,z,w order |
| `tracking_state`, `tracking_reason`, `pose_valid` | `normal`/`limited`/`not_available`, reason string, bool (`not_available` => false) |
| `intrinsics_row_major`, `source_image_size` | full-resolution camera K as 9 row-major numbers; [width,height] positive integers |
| `rgb_intrinsics_row_major` | 9 numbers with K scaled to transmitted RGB dimensions |
| `rgb` | object: `encoding="jpeg"`, positive `width`, `height`, positive `length` |
| `depth` | null or object: `encoding="float32_le_m"`, positive dimensions, `length=width*height*4`, `association="same_arframe_no_independent_timestamp"` |
| `confidence` | null or object: `encoding="uint8"`, depth-matching dimensions, `length=width*height`; only present with depth |
| `counters` | object with unsigned `acquired_frames`, `encode_drops`, `transport_drops`; acquired >=frame_seq+1 |
| `thermal_state` | `nominal`/`fair`/`serious`/`critical`/`unknown` |

Payload concatenates JPEG, tightly packed raw Float32 little-endian depth in meters, tightly packed UInt8 confidence, in that order. Its total length equals the declared modality lengths exactly; dimensions <=8192 each and bounded payload limits must be checked before reshaping. Copy depth/confidence row-by-row using actual CVPixelBuffer stride and retain/copy source buffers safely across callbacks. Missing depth is null, never a synthetic repeat; no independent depth capture time is invented. JPEG width starts at <=640 pixels with native aspect preserved. Confidence values are ARKit's 0/1/2 levels, not a binary seal flag.

## Host and tests

Create a standard-library packet parser and usbmuxd connector under `usi_stream/`, with an optional OpenCV/NumPy preview CLI `python -m usi_stream.receiver`. `--headless` works without image libraries; `--metadata-log PATH` writes JSONL events with raw frame metadata and host receive provenance. This is a diagnostic log, not the final authoritative MCAP dataset. Reconnects/session changes, sequence gaps, tracking and rate are reported. A one-second PING interval logs observations; no affine fit is invented.

Tests cover fragmented/coalesced framing, invalid lengths/magic/version/type/JSON, EOF, modality sizes, NaN/pose/quaternion validity, source-time preservation, session/sequence gap tracking and usbmuxd request/reply parsing using real socket pairs. Swift pure-Foundation wire tests share a golden HELLO vector with Python. A custom cloud workflow tests Python/Swift framing then builds the current custom app; the stock workflow remains pinned to upstream.

## Acceptance limits

Local Python tests, static configuration checks and source review precede cloud compilation. Actual ARKit+USB operation, pose motion/rotation signs, world resets, depth association, reconnects and measured rates require installing the new build on the real phone. No defaults from the original jaw gripper become suction calibration. Existing pressure firmware remains byte-identical.
