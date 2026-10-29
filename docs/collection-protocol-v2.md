# Collection protocol v2 (port 5559)

This contract supplies transport validation and pure collection state. It does not implement a camera, BLE client, clock fitter, ROS publisher or bag writer. Diagnostic v1 remains unchanged on port 5558. All `collection_*.hex` vectors and JSON examples here are synthetic software tests, never calibration or hardware evidence.

## Framing and limits

The 16-byte header is network byte order `!4sHHII`: magic `USI2`, version **2**, message type (uint16), JSON byte length (uint32), payload byte length (uint32). Metadata is UTF-8 JSON, length **2…65,536** bytes, depth at most **32**. Payload is at most **16,777,216** bytes. Only FRAME has payload. A sensor or pose batch contains **1…64** samples and still must fit the metadata byte bound. All objects reject unknown fields and duplicate JSON keys; missing required fields, nonfinite numbers, booleans in numeric fields, invalid enum values and incompatible v1 headers are errors. Integer fields require integer JSON tokens, are bounded as shown below, and never accept booleans. JSON Schema integer validation alone is weaker than this token rule. Receiver validation precedes reading/allocating image payload. An unconsumed socket timeout requires closing/reconnecting because restarting a reader mid-packet loses framing.

| ID | Type | Metadata definition |
|---|---|---|
| 1 | HELLO | role/version, optional initial capability inventory/profile support/session |
| 2 | FRAME | main ARKit RGB/depth/confidence **or** independent ultrawide, discriminated by stream_id |
| 3 | PING | host ping ID and host send monotonic time |
| 4 | PONG | phone receive/send times and originating host ping |
| 5 | HEALTH | event/message, per-stream counters, optional changed capabilities/thermal status |
| 6 | POSES | phone/world epoch, independent ARFrame pose batch |
| 7 | PRESSURES | ESP source/boot and phone/BLE connection IDs, three-channel sample batch |
| 8 | TRIGGER | independent trigger identity/time, transition or heartbeat, pressed boolean |
| 9 | CLOCK | completed BLE or USB four-timestamp exchange and explicit fit validity |
| 10 | TRIAL_REQUEST | prepare/begin/stop/status discriminated request |
| 11 | TRIAL_STATUS | authoritative host state/revision, provisional counters and final verification |

Swift sorted JSON and Python sorted compact JSON agree byte-for-byte on the committed vectors. Other legal floating-point/Unicode JSON spellings need not have identical bytes; compare decoded values. The wire does not impose JSON canonicalization.

## Stream inventory and identities

The exact Full inventory is `main_rgb`, `raw_depth`, `depth_confidence`, `camera_pose`, `tracking`, `camera_calibration`, `ultrawide`, `pressures`, `trigger`, `seal`, `trial_metadata`, `timing`, `health`. Core requires the same inventory except `ultrawide`, which its snapshot must explicitly list in `missing_modalities`. Additional named modalities are `pump_command`, `pump_feedback`, `tcp`, `raw_imu`, `audio`. Declare absent capabilities with `available:false` and a concrete `reason`; never infer instrumented pump state from trigger. Available capabilities identify both source and epoch. `schema` and `units` describe the actual implementation; the host must check its supported schemas/units before enabling Start. A syntactically valid prepare request is not a readiness claim.

A sample identity is `(stream_id, source_id, epoch_id, sequence)`:

| Lane | source_id | epoch_id | sequence |
|---|---|---|---|
| main_rgb | FRAME.session_id (phone session) | FRAME.world_epoch_id | FRAME.frame_seq |
| camera_pose | POSES.session_id | POSES.world_epoch_id | sample.frame_seq |
| ultrawide | FRAME.session_id | FRAME.world_epoch_id (capture/world epoch) | independent FRAME.frame_seq |
| pressures | PRESSURES.source_id | PRESSURES.boot_id | sample.sequence |
| trigger | TRIGGER.source_id | TRIGGER.boot_id | TRIGGER.sequence, independently counted |

Phone `session_id` must change on a process/session restart. World/capture epoch changes on tracking reset/session interruption that invalidates continuity. ESP `boot_id` changes on reboot. BLE `connection_id` changes on each connection, but does not reset the device sample identity or erase a gap. `phone_session_id` records which phone received the sensor data. Never treat a delayed prior-epoch packet as current telemetry.

Sensor `sequence` is an extended uint64; `raw_sequence` is uint32 and must equal `sequence % 2**32`. Pressure and trigger have **separate** sequence histories. The pure history unwraps forward differences smaller than half the modulus, counts forward gaps, detects immediate duplicates/out-of-order packets and rejects retired epochs. A disconnect spanning half a counter cycle is ambiguous; fail continuity rather than guessing a wrap. A bounded history refuses its 65th distinct epoch until the owning session is deliberately replaced. It is not a general deduplication database for arbitrarily delayed historical packets; host identity sets/fences determine final completeness.

Pressure integers retain original **0.01 Pa absolute** values; divide by **100,000** to obtain kPa absolute. Quality bit `i` describes raw sensor index `i` (bit set means valid). It never follows display order. Original `source_time_us`, `phone_receive_ns`, ARFrame `arkit_timestamp_s`, phone `phone_uptime_ns`, host complete-packet receive monotonic/wall time, and bag record time remain distinct. The host adds its own receive/bag times; it must not overwrite the source fields or use device uptime as a ROS epoch.

## Camera variants

Main FRAME preserves every required audited v1 frame metadata field and packed payload `rgb || depth? || confidence?`, adding `stream_id:"main_rgb"` and `world_epoch_id`. JPEG length is explicit. Raw depth is tightly packed little-endian float32 meters with `same_arframe_no_independent_timestamp`; confidence is one byte per depth pixel, with matching dimensions. These validators enforce declared sizes/encodings, not actual JPEG decoding, float content validity or confidence values. The host's decoder/final verifier must validate those contents and publish an explicit valid/missing mask. No v1 `16UC1` reinterpretation is permitted.

Ultrawide uses the separate FRAME definition with `stream_id:"ultrawide"`, `camera_frame:"ultrawide_camera"`, **independent** `frame_seq`, `source_timestamp_s`, named `source_clock`, `phone_uptime_ns`, actual source `intrinsics_row_major` and `source_image_size`, resized `rgb_intrinsics_row_major`, and its own `rgb` descriptor/counters. Payload is only its JPEG. It has no ARFrame timestamp, depth, confidence or invented camera transform. A real capability probe must establish advancing independent source timestamps/content and accurate intrinsics before enabling it. The presence of this schema does not establish capture availability or camera-to-camera extrinsics. Never fill it using a repeated main RGB frame or unsupported ARKit internals.

POSES is captured and queued before image encoding. Each sample preserves transform/position/normalized quaternion, tracking state/reason and pose validity. Its world and camera conventions are the audited ARKit conventions (`arkit_world`, `arkit_camera`); conversions to ROS optical axes require physical validation. No default TCP transform is introduced. Pose batches must have strictly increasing frame_seq; pressure batches strictly increasing extended sequence. Gaps remain visible.

## Trial control, counters and fences

`prepare` freezes the complete snapshot and expected host revision. Host prepares destination/topics/writer after validating readiness. `begin` supplies begin fences; **only a host TRIAL_STATUS Recording acknowledgment permits a red dot/Recording assurance**. `stop` supplies end fences and final source counter snapshots, enters Finalizing, and drains delayed queued data. `status` queries an existing outcome after lost acknowledgment; it never starts/resumes a trial.

A fence uses `(stream_id,source_id,epoch_id,next_sequence)`. The five valid fenced lanes are `main_rgb`, `camera_pose`, `ultrawide`, `pressures`, `trigger`. The trial interval is `[begin.next_sequence,end.next_sequence)`. At Begin, snapshot each source's **next acquisition identity**, before image replacement/encoding; at Stop snapshot it again. Do not use “last encoded” or “last transmitted” as an acquisition fence. A zero-length interval is representable by equal fences; a required empty stream fails host readiness/final verification. The same source/epoch must appear at both boundaries; a reboot/reset ends continuity.

An explicitly selected Core trial omits only the ultrawide lane. The host must require all remaining lane fences exactly once, matching prepared capabilities; the generic codec permits a nonempty subset for protocol tests and leaves readiness/coverage checks to the trial controller. Fences for static/derived stream names are rejected by the codec.

`raw_depth`/`depth_confidence` inherit the main RGB frame identity/fence; each carries only the samples actually delivered by the configured ARKit path and joins on frame_seq. Tracking inherits the independent pose lane; derived seal inherits pressure sample identities plus calibration ID. Do not demand a newly exposed depth sample at each RGB exposure. Camera calibration and trial metadata are immutable prepared snapshots written at trial start. HEALTH counters/capability changes and CLOCK exchange IDs are ordered control evidence, bounded by trial control processing; the host records relevant exchanges/health while draining and writes final counters/verification before closure. They do not acquire camera-style fences. Count every enabled topic independently in the reopened bag, and verify derived joins as well as lane boundaries.

Final source counters are per `(stream_id,source_id,epoch_id)`, not one shared image count. Counter values are cumulative within that source epoch (including the captured trial-end snapshot); obtain trial counts by subtracting the prepared/begin baseline for that identity. `source_count`, `received_count`, `writer_accepted_count`, `queue_overflow_count`, `rejected_count`, `duplicate_count` explicitly admit **null** (Unavailable). Do not replace a missing counter with zero. Missing ranges use `[start,end_exclusive)`, sorted, nonoverlapping. Final source snapshots may have `writer_accepted_count:null`; the host supplies its authoritative counters later. Successful writes remain provisional until reopening/deserialization/decoding and manifest verification. A missing image, pose or pressure sample inside the source fences, any source overflow, failed closure or failed required modality/rate check means Incomplete.

Host request idempotency is scoped to `request_id` and the exact normalized request contents. Repeating an identical request returns its existing result/state without creating another writer. Reusing an ID with different contents is a conflict. `expected_revision` must equal the current host state revision for a **new mutating** request; duplicate retries resolve before this check. `status` is read-only and ignores expected_revision. It still carries request/trial IDs for correlation. The host owns this bounded request/outcome ledger and disk lifecycle (Task 2); the pure phone model only guarantees idempotent repeated local request submission and revision-safe status acceptance. Host heartbeat `host_time_ns` advances independently; revision advances when semantic state changes, not on heartbeat. Same-revision duplicate statuses must agree on state and verification. A lower-revision status must not refresh liveness.

TRIAL_STATUS `ready` advertises idle preparation capability, not an open bag. An idle heartbeat has `trial_id:null`, `request_id:null`, `state:"idle"`, `verification:"pending"`, a revision, current host time and counters. `saved` requires a non-null bag path and `verification:"passed"`; only Saved can carry Passed. Incomplete should carry Failed and a concrete reason. Host heartbeats/statuses are trusted only within the current connection/host session and the selected trial; the phone model rejects a new host attempting to continue an active trial as Recording. It accepts the new host's Incomplete outcome. Finalizing and terminal outcomes cannot regress to Recording. Status stale after 2 s removes Recording assurance (`host_stale`), while Stop remains reachable. Opening Data/Diagnostics must not replace this model or camera ownership.

## Clock and calibration semantics

PING/PONG preserve the first three USB timestamps; the host records receipt and emits/persists CLOCK with all four. USB CLOCK: `t1_ns` host send, `t2_ns` phone receipt, `t3_ns` phone send, `t4_ns` host receipt. BLE CLOCK: `t1_ns` phone send, `t2_ns` ESP receipt, `t3_ns` ESP send, `t4_ns` phone receipt. ESP microseconds are multiplied exactly by 1,000 for these CLOCK fields; retain the raw exchange/source fields in provenance. `source_id` identifies the responding clock owner and `epoch_id` its boot/session epoch. The affine mapping maps responder monotonic nanoseconds to initiator monotonic nanoseconds: `initiator_ns = scale * responder_ns + offset_ns`. This is not an epoch mapping. For valid fits, scale must be positive and scale/offset/uncertainty all known; `valid:false` with null fit fields is the initial honest state. BLE and USB mappings are independent evidence; shared bag membership never implies synchronization. Wall-time mapping, fit residuals/estimator provenance and final clock validity belong in host manifests/typed metadata.

Pressure calibration is explicit validated data: nonempty calibration ID, three C1/C2/C3 ordered chamber mappings, sensor/sector indices each a permutation of 0/1/2, nonnegative finite `seal_on_kpa_abs < seal_off_kpa_abs`, and per-channel persistence. Sector index identifies one of three equal 120° sectors; physical orientation/provenance must be measured, not copied from a mockup. The wire snapshot also includes optional measured ambient absolute pressure and provenance. The pure seal model does not use ambient to invent differential measurements. Raw pressure works without calibration. Valid fresh samples without calibration remain Uncalibrated/gray. Invalid/missing/stale stay gray with no stale numeric measurement presented as current. Known unsealed is red; sealed is green. A low reading seals only after persistence; hysteresis retains the prior known state between thresholds. Staleness/invalidity resets persistence. Full/Partial/None is reported only when all three channels are known; otherwise aggregate Unavailable. Pressed trigger means suction Off, released means On, and stale/missing means Unknown, independently of pressure and without claiming measured motor behavior.

Operational configuration is recorded explicitly in `snapshot.configuration`: pressure stale 250,000,000 ns; vision stale 500,000,000 ns; trigger stale 1,000,000,000 ns; host stale 2,000,000,000 ns; mandatory stale grace 1,000,000,000 ns; host heartbeat 500,000,000 ns; trigger heartbeat 250,000,000 ns. These are operational defaults, not pressure thresholds. The caller enforces mandatory-source grace/incomplete policy, tracks gaps even if a stream recovers, and injects monotonic now/receipt times. The pure models enforce freshness/hysteresis only and do not silently finalize or resume a bag.

## Python API

```python
encode_packet(message_type: MessageType | int, metadata: dict, payload=b'') -> bytes
decode_packet(data: bytes) -> Packet
recv_packet(sock) -> Packet | None  # sock.recv(count), clean EOF only at new header
validate_metadata(kind: MessageType | int, metadata: dict, payload_length=0) -> None
slice_frame(packet: Packet) -> legacy.FrameParts  # rgb/depth/confidence memoryviews, absent = None
# ProtocolError(ValueError); Packet(message_type, metadata, payload)
# SCHEMAS, REQUESTS, FRAMES; FULL_REQUIRED_STREAMS, CORE_REQUIRED_STREAMS, FENCED_STREAMS

SampleIdentity(stream_id, source_id, epoch_id, sequence)
StreamCounters(source_count=None, received_count=None, writer_accepted_count=None,
               queue_overflow_count=None, rejected_count=None, duplicate_count=None)
ChamberCalibration(sensor_index, sector_index, seal_on_kpa_abs, seal_off_kpa_abs, persistence_ns)
PressureCalibration(calibration_id, chambers)  # immutable tuple, C1/C2/C3 order
SealModel(calibration=None, *, stale_ns=250_000_000)
SealModel.update(pressures_kpa_abs, *, quality_mask, received_ns) -> None
SealModel.snapshot(now_ns) -> SealSnapshot
# snapshot: states, aggregate, sealed_count, known_count, pressures_kpa_abs, calibration_id
TriggerModel(*, stale_ns=1_000_000_000)
TriggerModel.update(*, pressed, received_ns) -> None
TriggerModel.state(now_ns) -> str  # unknown/on/off
SequenceHistory(*, modulus=2**32, max_epochs=64)
SequenceHistory.observe(epoch, raw_sequence) -> SequenceObservation
# disposition new_epoch/accepted/duplicate/out_of_order/old_epoch; sequence; missing tuple or None
BoundedQueue(capacity)
BoundedQueue.offer(item) -> bool  # rejects newest, increments overflow_count
BoundedQueue.pop() -> object | None
TrialModel(*, host_stale_ns=2_000_000_000)
TrialModel.begin_request(request_id, trial_id) -> None
TrialModel.apply_status(*, host_session_id, trial_id, revision, state, verification, received_ns) -> bool
TrialModel.display_state(now_ns) -> str
```

Models raise ValueError on invalid input. Queues/models have one owner; callers synchronize access and use independent instances per sensor/pose/control lane. Seal snapshots advance persistence using injected monotonic time and therefore mutate internal state. Replace the seal model when changing frozen calibration. Final saved assurance requires passing a codec-validated TRIAL_STATUS to the phone model; its smaller method signature is not a substitute for validating bag_path and complete wire metadata.

## Foundation Swift API

```swift
USICollectionWire.encode(type: USICollectionMessageType, metadata: [String:Any], payload: Data = Data()) throws -> Data
USICollectionWire.parseHeader(_ data: Data) throws -> USICollectionHeader
USICollectionWire.decode(_ data: Data) throws -> USICollectionPacket
USICollectionWire.recvPacket(read: (Int) throws -> Data) throws -> USICollectionPacket?
USICollectionWire.validateMetadata(type: USICollectionMessageType, metadata: [String:Any], payloadLength: Int = 0) throws
USICollectionWire.sliceFrame(_ packet: USICollectionPacket) throws -> USICollectionFrameParts
// cases hello/frame/ping/pong/health/poses/pressures/trigger/clock/trialRequest/trialStatus
// USICollectionError.invalid(String); packet.type/metadata/payload; frameParts.rgb/depth/confidence (Data?)
// fullRequiredStreams/coreRequiredStreams/fencedStreams; port/headerLength/maxMetadataLength/maxPayloadLength/maxBatch/maxNesting

USISampleIdentity.init(stream: USICollectionStream, sourceID: String, epochID: String, sequence: UInt64) throws
USIStreamCounters() // optional UInt64 properties sourceCount/receivedCount/writerAcceptedCount/queueOverflowCount/rejectedCount/duplicateCount
USIChamberCalibration.init(sensorIndex: Int, sectorIndex: Int, sealOnKPaAbs: Double, sealOffKPaAbs: Double, persistenceNs: UInt64) throws
USIPressureCalibration.init(id: String, chambers: [USIChamberCalibration]) throws
USISealModel.init(calibration: USIPressureCalibration?, staleNs: UInt64 = 250_000_000)
mutating USISealModel.update(pressuresKPaAbs: [Double], qualityMask: UInt8, receivedNs: UInt64) throws
mutating USISealModel.snapshot(nowNs: UInt64) -> USISealSnapshot
// states/aggregate/sealedCount/knownCount/pressuresKPaAbs/calibrationID
USITriggerModel.init(staleNs: UInt64 = 1_000_000_000)
mutating USITriggerModel.update(pressed: Bool, receivedNs: UInt64) throws
USITriggerModel.state(nowNs: UInt64) -> USISuctionState
USISequenceHistory.init(modulus: UInt64 = 1 << 32, maxEpochs: Int = 64)
mutating USISequenceHistory.observe(epoch: String, rawSequence: UInt64) throws -> USISequenceObservation
// disposition newEpoch/accepted/duplicate/outOfOrder/oldEpoch; sequence UInt64; missing Range<UInt64>?
USIBoundedQueue<Element>.init(capacity: Int) throws
mutating USIBoundedQueue.offer(_ item: Element) -> Bool
mutating USIBoundedQueue.pop() -> Element? // count, overflowCount are readable
USITrialModel.init(hostStaleNs: UInt64 = 2_000_000_000)
mutating USITrialModel.beginRequest(requestID: String, trialID: String) throws
mutating USITrialModel.applyStatus(hostSessionID: String, trialID: String?, revision: UInt64,
    state: USITrialState, verification: USIVerification, receivedNs: UInt64) throws -> Bool
USITrialModel.displayState(nowNs: UInt64) -> USITrialState
```

USISealChannelState cases match Python states. USISealAggregate cases unavailable/none/partial/full. USISuctionState unknown/on/off. USIVerification pending/passed/failed. USITrialState notConnected/idle/preparing/recording/finalizing/saved/incomplete/hostStale, with snake_case raw strings where needed. Swift history supports an even representable UInt64 modulus; camera's already-extended frame_seq bypasses unwrap. Queue overflow count saturates at UInt64.max; it never wraps to zero. All APIs intentionally use the same module-internal visibility as the audited Foundation wire types; iPhone app sources share their app target.

## Complete metadata schemas

The following JSON Schema 2020-12 `$defs` are complete for every message metadata object. Select by header type; FRAME and TRIAL_REQUEST are discriminated unions. Runtime also enforces the semantic joins/order/fences/quality/raw-sequence/calibration/profile/saved/clock checks described above, finite JSON and depth/byte limits. Definitions are derived directly from `collection_protocol.SCHEMAS`, not a looser hand-maintained example.

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$defs": {
    "UInt64": {
      "type": "integer",
      "minimum": 0,
      "maximum": 18446744073709551615
    },
    "FiniteNumber": {
      "type": "number"
    },
    "Timestamp": {
      "type": "number",
      "minimum": 0
    },
    "NonemptyString": {
      "type": "string",
      "minLength": 1,
      "maxLength": 512
    },
    "Text": {
      "type": "string",
      "maxLength": 4096
    },
    "Boolean": {
      "type": "boolean"
    },
    "StreamID": {
      "enum": [
        "main_rgb",
        "raw_depth",
        "depth_confidence",
        "camera_pose",
        "tracking",
        "camera_calibration",
        "ultrawide",
        "pressures",
        "trigger",
        "seal",
        "trial_metadata",
        "timing",
        "health",
        "pump_command",
        "pump_feedback",
        "tcp",
        "raw_imu",
        "audio"
      ]
    },
    "Vec3": {
      "type": "array",
      "items": {
        "$ref": "#/$defs/FiniteNumber"
      },
      "minItems": 3,
      "maxItems": 3
    },
    "Quaternion": {
      "type": "array",
      "items": {
        "$ref": "#/$defs/FiniteNumber"
      },
      "minItems": 4,
      "maxItems": 4
    },
    "Mat3": {
      "type": "array",
      "items": {
        "$ref": "#/$defs/FiniteNumber"
      },
      "minItems": 9,
      "maxItems": 9
    },
    "Mat4": {
      "type": "array",
      "items": {
        "$ref": "#/$defs/FiniteNumber"
      },
      "minItems": 16,
      "maxItems": 16
    },
    "Counter": {
      "type": "object",
      "properties": {
        "stream_id": {
          "$ref": "#/$defs/StreamID"
        },
        "source_id": {
          "$ref": "#/$defs/NonemptyString"
        },
        "epoch_id": {
          "$ref": "#/$defs/NonemptyString"
        },
        "source_count": {
          "anyOf": [
            {
              "$ref": "#/$defs/UInt64"
            },
            {
              "type": "null"
            }
          ]
        },
        "received_count": {
          "anyOf": [
            {
              "$ref": "#/$defs/UInt64"
            },
            {
              "type": "null"
            }
          ]
        },
        "writer_accepted_count": {
          "anyOf": [
            {
              "$ref": "#/$defs/UInt64"
            },
            {
              "type": "null"
            }
          ]
        },
        "queue_overflow_count": {
          "anyOf": [
            {
              "$ref": "#/$defs/UInt64"
            },
            {
              "type": "null"
            }
          ]
        },
        "rejected_count": {
          "anyOf": [
            {
              "$ref": "#/$defs/UInt64"
            },
            {
              "type": "null"
            }
          ]
        },
        "duplicate_count": {
          "anyOf": [
            {
              "$ref": "#/$defs/UInt64"
            },
            {
              "type": "null"
            }
          ]
        },
        "missing_ranges": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "start": {
                "$ref": "#/$defs/UInt64"
              },
              "end_exclusive": {
                "$ref": "#/$defs/UInt64"
              }
            },
            "required": [
              "start",
              "end_exclusive"
            ],
            "additionalProperties": false
          },
          "minItems": 0,
          "maxItems": 256
        }
      },
      "required": [
        "stream_id",
        "source_id",
        "epoch_id",
        "source_count",
        "received_count",
        "writer_accepted_count",
        "queue_overflow_count",
        "rejected_count",
        "duplicate_count",
        "missing_ranges"
      ],
      "additionalProperties": false
    },
    "Fence": {
      "type": "object",
      "properties": {
        "stream_id": {
          "enum": [
            "main_rgb",
            "camera_pose",
            "ultrawide",
            "pressures",
            "trigger"
          ]
        },
        "source_id": {
          "$ref": "#/$defs/NonemptyString"
        },
        "epoch_id": {
          "$ref": "#/$defs/NonemptyString"
        },
        "next_sequence": {
          "$ref": "#/$defs/UInt64"
        }
      },
      "required": [
        "stream_id",
        "source_id",
        "epoch_id",
        "next_sequence"
      ],
      "additionalProperties": false
    },
    "Capability": {
      "type": "object",
      "properties": {
        "stream_id": {
          "$ref": "#/$defs/StreamID"
        },
        "available": {
          "$ref": "#/$defs/Boolean"
        },
        "reason": {
          "anyOf": [
            {
              "$ref": "#/$defs/Text"
            },
            {
              "type": "null"
            }
          ]
        },
        "schema": {
          "$ref": "#/$defs/NonemptyString"
        },
        "units": {
          "$ref": "#/$defs/NonemptyString"
        },
        "source_id": {
          "anyOf": [
            {
              "$ref": "#/$defs/NonemptyString"
            },
            {
              "type": "null"
            }
          ]
        },
        "epoch_id": {
          "anyOf": [
            {
              "$ref": "#/$defs/NonemptyString"
            },
            {
              "type": "null"
            }
          ]
        }
      },
      "required": [
        "stream_id",
        "available",
        "reason",
        "schema",
        "units",
        "source_id",
        "epoch_id"
      ],
      "additionalProperties": false
    },
    "ChamberCalibration": {
      "type": "object",
      "properties": {
        "sensor_index": {
          "type": "integer",
          "minimum": 0,
          "maximum": 2
        },
        "sector_index": {
          "type": "integer",
          "minimum": 0,
          "maximum": 2
        },
        "seal_on_kpa_abs": {
          "$ref": "#/$defs/Timestamp"
        },
        "seal_off_kpa_abs": {
          "$ref": "#/$defs/Timestamp"
        },
        "persistence_ns": {
          "$ref": "#/$defs/UInt64"
        }
      },
      "required": [
        "sensor_index",
        "sector_index",
        "seal_on_kpa_abs",
        "seal_off_kpa_abs",
        "persistence_ns"
      ],
      "additionalProperties": false
    },
    "PressureCalibration": {
      "type": "object",
      "properties": {
        "calibration_id": {
          "$ref": "#/$defs/NonemptyString"
        },
        "chambers": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/ChamberCalibration"
          },
          "minItems": 3,
          "maxItems": 3
        },
        "ambient_kpa_abs": {
          "anyOf": [
            {
              "$ref": "#/$defs/Timestamp"
            },
            {
              "type": "null"
            }
          ]
        },
        "provenance": {
          "$ref": "#/$defs/Text"
        }
      },
      "required": [
        "calibration_id",
        "chambers",
        "ambient_kpa_abs",
        "provenance"
      ],
      "additionalProperties": false
    },
    "Configuration": {
      "type": "object",
      "properties": {
        "pressure_stale_ns": {
          "$ref": "#/$defs/UInt64"
        },
        "trigger_stale_ns": {
          "$ref": "#/$defs/UInt64"
        },
        "vision_stale_ns": {
          "$ref": "#/$defs/UInt64"
        },
        "host_status_stale_ns": {
          "$ref": "#/$defs/UInt64"
        },
        "mandatory_stale_grace_ns": {
          "$ref": "#/$defs/UInt64"
        },
        "host_heartbeat_ns": {
          "$ref": "#/$defs/UInt64"
        },
        "trigger_heartbeat_ns": {
          "$ref": "#/$defs/UInt64"
        },
        "target_fps": {
          "type": "number",
          "exclusiveMinimum": 0,
          "maximum": 240
        }
      },
      "required": [
        "pressure_stale_ns",
        "trigger_stale_ns",
        "vision_stale_ns",
        "host_status_stale_ns",
        "mandatory_stale_grace_ns",
        "host_heartbeat_ns",
        "trigger_heartbeat_ns",
        "target_fps"
      ],
      "additionalProperties": false
    },
    "TrialSnapshot": {
      "type": "object",
      "properties": {
        "session_id": {
          "$ref": "#/$defs/NonemptyString"
        },
        "task_label": {
          "$ref": "#/$defs/NonemptyString"
        },
        "gripper_id": {
          "$ref": "#/$defs/NonemptyString"
        },
        "profile": {
          "enum": [
            "full",
            "core"
          ]
        },
        "calibration": {
          "anyOf": [
            {
              "$ref": "#/$defs/PressureCalibration"
            },
            {
              "type": "null"
            }
          ]
        },
        "configuration": {
          "$ref": "#/$defs/Configuration"
        },
        "capabilities": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/Capability"
          },
          "minItems": 1,
          "maxItems": 32
        },
        "required_streams": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/StreamID"
          },
          "minItems": 1,
          "maxItems": 32
        },
        "missing_modalities": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/StreamID"
          },
          "minItems": 0,
          "maxItems": 32
        }
      },
      "required": [
        "session_id",
        "task_label",
        "gripper_id",
        "profile",
        "calibration",
        "configuration",
        "capabilities",
        "required_streams",
        "missing_modalities"
      ],
      "additionalProperties": false
    },
    "PoseSample": {
      "type": "object",
      "properties": {
        "frame_seq": {
          "$ref": "#/$defs/UInt64"
        },
        "arkit_timestamp_s": {
          "$ref": "#/$defs/Timestamp"
        },
        "phone_uptime_ns": {
          "$ref": "#/$defs/UInt64"
        },
        "camera_transform_row_major": {
          "$ref": "#/$defs/Mat4"
        },
        "position_m": {
          "$ref": "#/$defs/Vec3"
        },
        "quaternion_xyzw": {
          "$ref": "#/$defs/Quaternion"
        },
        "tracking_state": {
          "enum": [
            "normal",
            "limited",
            "not_available"
          ]
        },
        "tracking_reason": {
          "$ref": "#/$defs/Text"
        },
        "pose_valid": {
          "$ref": "#/$defs/Boolean"
        }
      },
      "required": [
        "frame_seq",
        "arkit_timestamp_s",
        "phone_uptime_ns",
        "camera_transform_row_major",
        "position_m",
        "quaternion_xyzw",
        "tracking_state",
        "tracking_reason",
        "pose_valid"
      ],
      "additionalProperties": false
    },
    "PressureSample": {
      "type": "object",
      "properties": {
        "sequence": {
          "$ref": "#/$defs/UInt64"
        },
        "raw_sequence": {
          "type": "integer",
          "minimum": 0,
          "maximum": 4294967295
        },
        "source_time_us": {
          "$ref": "#/$defs/UInt64"
        },
        "phone_receive_ns": {
          "$ref": "#/$defs/UInt64"
        },
        "pressure_centi_pa": {
          "type": "array",
          "items": {
            "type": "integer",
            "minimum": -2147483648,
            "maximum": 2147483647
          },
          "minItems": 3,
          "maxItems": 3
        },
        "quality_mask": {
          "type": "integer",
          "minimum": 0,
          "maximum": 7
        }
      },
      "required": [
        "sequence",
        "raw_sequence",
        "source_time_us",
        "phone_receive_ns",
        "pressure_centi_pa",
        "quality_mask"
      ],
      "additionalProperties": false
    },
    "ImageDescriptor": {
      "type": "object",
      "properties": {
        "encoding": {
          "$ref": "#/$defs/NonemptyString"
        },
        "width": {
          "type": "integer",
          "minimum": 1,
          "maximum": 8192
        },
        "height": {
          "type": "integer",
          "minimum": 1,
          "maximum": 8192
        },
        "length": {
          "type": "integer",
          "minimum": 1,
          "maximum": 16777216
        }
      },
      "required": [
        "encoding",
        "width",
        "height",
        "length"
      ],
      "additionalProperties": false
    },
    "DepthDescriptor": {
      "type": "object",
      "properties": {
        "encoding": {
          "$ref": "#/$defs/NonemptyString"
        },
        "width": {
          "type": "integer",
          "minimum": 1,
          "maximum": 8192
        },
        "height": {
          "type": "integer",
          "minimum": 1,
          "maximum": 8192
        },
        "length": {
          "type": "integer",
          "minimum": 1,
          "maximum": 16777216
        },
        "association": {
          "enum": [
            "same_arframe_no_independent_timestamp"
          ]
        }
      },
      "required": [
        "encoding",
        "width",
        "height",
        "length",
        "association"
      ],
      "additionalProperties": false
    },
    "MainFrame": {
      "type": "object",
      "properties": {
        "session_id": {
          "$ref": "#/$defs/NonemptyString"
        },
        "world_epoch_id": {
          "$ref": "#/$defs/NonemptyString"
        },
        "stream_id": {
          "enum": [
            "main_rgb"
          ]
        },
        "frame_seq": {
          "$ref": "#/$defs/UInt64"
        },
        "arkit_timestamp_s": {
          "$ref": "#/$defs/Timestamp"
        },
        "phone_uptime_ns": {
          "$ref": "#/$defs/UInt64"
        },
        "world_frame": {
          "enum": [
            "arkit_world"
          ]
        },
        "camera_frame": {
          "enum": [
            "arkit_camera"
          ]
        },
        "image_orientation": {
          "enum": [
            "sensor_native"
          ]
        },
        "camera_transform_row_major": {
          "$ref": "#/$defs/Mat4"
        },
        "position_m": {
          "$ref": "#/$defs/Vec3"
        },
        "quaternion_xyzw": {
          "$ref": "#/$defs/Quaternion"
        },
        "tracking_state": {
          "enum": [
            "normal",
            "limited",
            "not_available"
          ]
        },
        "tracking_reason": {
          "$ref": "#/$defs/Text"
        },
        "pose_valid": {
          "$ref": "#/$defs/Boolean"
        },
        "intrinsics_row_major": {
          "$ref": "#/$defs/Mat3"
        },
        "source_image_size": {
          "type": "array",
          "items": {
            "type": "integer",
            "minimum": 1,
            "maximum": 8192
          },
          "minItems": 2,
          "maxItems": 2
        },
        "rgb_intrinsics_row_major": {
          "$ref": "#/$defs/Mat3"
        },
        "rgb": {
          "$ref": "#/$defs/ImageDescriptor"
        },
        "depth": {
          "anyOf": [
            {
              "$ref": "#/$defs/DepthDescriptor"
            },
            {
              "type": "null"
            }
          ]
        },
        "confidence": {
          "anyOf": [
            {
              "$ref": "#/$defs/ImageDescriptor"
            },
            {
              "type": "null"
            }
          ]
        },
        "counters": {
          "type": "object",
          "properties": {
            "acquired_frames": {
              "$ref": "#/$defs/UInt64"
            },
            "encode_drops": {
              "$ref": "#/$defs/UInt64"
            },
            "transport_drops": {
              "$ref": "#/$defs/UInt64"
            }
          },
          "required": [
            "acquired_frames",
            "encode_drops",
            "transport_drops"
          ],
          "additionalProperties": false
        },
        "thermal_state": {
          "enum": [
            "nominal",
            "fair",
            "serious",
            "critical",
            "unknown"
          ]
        }
      },
      "required": [
        "session_id",
        "world_epoch_id",
        "stream_id",
        "frame_seq",
        "arkit_timestamp_s",
        "phone_uptime_ns",
        "world_frame",
        "camera_frame",
        "image_orientation",
        "camera_transform_row_major",
        "position_m",
        "quaternion_xyzw",
        "tracking_state",
        "tracking_reason",
        "pose_valid",
        "intrinsics_row_major",
        "source_image_size",
        "rgb_intrinsics_row_major",
        "rgb",
        "depth",
        "confidence",
        "counters",
        "thermal_state"
      ],
      "additionalProperties": false
    },
    "UltrawideFrame": {
      "type": "object",
      "properties": {
        "session_id": {
          "$ref": "#/$defs/NonemptyString"
        },
        "world_epoch_id": {
          "$ref": "#/$defs/NonemptyString"
        },
        "stream_id": {
          "enum": [
            "ultrawide"
          ]
        },
        "frame_seq": {
          "$ref": "#/$defs/UInt64"
        },
        "source_timestamp_s": {
          "$ref": "#/$defs/Timestamp"
        },
        "source_clock": {
          "$ref": "#/$defs/NonemptyString"
        },
        "phone_uptime_ns": {
          "$ref": "#/$defs/UInt64"
        },
        "camera_frame": {
          "enum": [
            "ultrawide_camera"
          ]
        },
        "image_orientation": {
          "enum": [
            "sensor_native"
          ]
        },
        "intrinsics_row_major": {
          "$ref": "#/$defs/Mat3"
        },
        "source_image_size": {
          "type": "array",
          "items": {
            "type": "integer",
            "minimum": 1,
            "maximum": 8192
          },
          "minItems": 2,
          "maxItems": 2
        },
        "rgb_intrinsics_row_major": {
          "$ref": "#/$defs/Mat3"
        },
        "rgb": {
          "$ref": "#/$defs/ImageDescriptor"
        },
        "counters": {
          "type": "object",
          "properties": {
            "acquired_frames": {
              "$ref": "#/$defs/UInt64"
            },
            "encode_drops": {
              "$ref": "#/$defs/UInt64"
            },
            "transport_drops": {
              "$ref": "#/$defs/UInt64"
            }
          },
          "required": [
            "acquired_frames",
            "encode_drops",
            "transport_drops"
          ],
          "additionalProperties": false
        },
        "thermal_state": {
          "enum": [
            "nominal",
            "fair",
            "serious",
            "critical",
            "unknown"
          ]
        }
      },
      "required": [
        "session_id",
        "world_epoch_id",
        "stream_id",
        "frame_seq",
        "source_timestamp_s",
        "source_clock",
        "phone_uptime_ns",
        "camera_frame",
        "image_orientation",
        "intrinsics_row_major",
        "source_image_size",
        "rgb_intrinsics_row_major",
        "rgb",
        "counters",
        "thermal_state"
      ],
      "additionalProperties": false
    },
    "PrepareRequest": {
      "type": "object",
      "properties": {
        "action": {
          "enum": [
            "prepare"
          ]
        },
        "request_id": {
          "$ref": "#/$defs/NonemptyString"
        },
        "trial_id": {
          "$ref": "#/$defs/NonemptyString"
        },
        "expected_revision": {
          "$ref": "#/$defs/UInt64"
        },
        "snapshot": {
          "$ref": "#/$defs/TrialSnapshot"
        }
      },
      "required": [
        "action",
        "request_id",
        "trial_id",
        "expected_revision",
        "snapshot"
      ],
      "additionalProperties": false
    },
    "BeginRequest": {
      "type": "object",
      "properties": {
        "action": {
          "enum": [
            "begin"
          ]
        },
        "request_id": {
          "$ref": "#/$defs/NonemptyString"
        },
        "trial_id": {
          "$ref": "#/$defs/NonemptyString"
        },
        "expected_revision": {
          "$ref": "#/$defs/UInt64"
        },
        "fences": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/Fence"
          },
          "minItems": 1,
          "maxItems": 32
        }
      },
      "required": [
        "action",
        "request_id",
        "trial_id",
        "expected_revision",
        "fences"
      ],
      "additionalProperties": false
    },
    "StopRequest": {
      "type": "object",
      "properties": {
        "action": {
          "enum": [
            "stop"
          ]
        },
        "request_id": {
          "$ref": "#/$defs/NonemptyString"
        },
        "trial_id": {
          "$ref": "#/$defs/NonemptyString"
        },
        "expected_revision": {
          "$ref": "#/$defs/UInt64"
        },
        "fences": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/Fence"
          },
          "minItems": 1,
          "maxItems": 32
        },
        "counters": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/Counter"
          },
          "minItems": 0,
          "maxItems": 32
        }
      },
      "required": [
        "action",
        "request_id",
        "trial_id",
        "expected_revision",
        "fences",
        "counters"
      ],
      "additionalProperties": false
    },
    "StatusRequest": {
      "type": "object",
      "properties": {
        "action": {
          "enum": [
            "status"
          ]
        },
        "request_id": {
          "$ref": "#/$defs/NonemptyString"
        },
        "trial_id": {
          "$ref": "#/$defs/NonemptyString"
        },
        "expected_revision": {
          "$ref": "#/$defs/UInt64"
        }
      },
      "required": [
        "action",
        "request_id",
        "trial_id",
        "expected_revision"
      ],
      "additionalProperties": false
    },
    "HELLO": {
      "type": "object",
      "properties": {
        "role": {
          "enum": [
            "host",
            "phone"
          ]
        },
        "protocol_version": {
          "enum": [
            2
          ]
        },
        "session_id": {
          "$ref": "#/$defs/NonemptyString"
        },
        "capabilities": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/Capability"
          },
          "minItems": 0,
          "maxItems": 32
        },
        "profiles": {
          "type": "array",
          "items": {
            "enum": [
              "full",
              "core"
            ]
          },
          "minItems": 0,
          "maxItems": 2
        }
      },
      "required": [
        "role",
        "protocol_version"
      ],
      "additionalProperties": false
    },
    "FRAME": {
      "anyOf": [
        {
          "$ref": "#/$defs/MainFrame"
        },
        {
          "$ref": "#/$defs/UltrawideFrame"
        }
      ]
    },
    "PING": {
      "type": "object",
      "properties": {
        "ping_id": {
          "$ref": "#/$defs/UInt64"
        },
        "host_send_ns": {
          "$ref": "#/$defs/UInt64"
        }
      },
      "required": [
        "ping_id",
        "host_send_ns"
      ],
      "additionalProperties": false
    },
    "PONG": {
      "type": "object",
      "properties": {
        "ping_id": {
          "$ref": "#/$defs/UInt64"
        },
        "host_send_ns": {
          "$ref": "#/$defs/UInt64"
        },
        "phone_receive_ns": {
          "$ref": "#/$defs/UInt64"
        },
        "phone_send_ns": {
          "$ref": "#/$defs/UInt64"
        },
        "session_id": {
          "$ref": "#/$defs/NonemptyString"
        }
      },
      "required": [
        "ping_id",
        "host_send_ns",
        "phone_receive_ns",
        "phone_send_ns",
        "session_id"
      ],
      "additionalProperties": false
    },
    "HEALTH": {
      "type": "object",
      "properties": {
        "session_id": {
          "$ref": "#/$defs/NonemptyString"
        },
        "event": {
          "$ref": "#/$defs/NonemptyString"
        },
        "message": {
          "$ref": "#/$defs/Text"
        },
        "counters": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/Counter"
          },
          "minItems": 0,
          "maxItems": 32
        },
        "capabilities": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/Capability"
          },
          "minItems": 0,
          "maxItems": 32
        },
        "thermal_state": {
          "enum": [
            "nominal",
            "fair",
            "serious",
            "critical",
            "unknown"
          ]
        }
      },
      "required": [
        "session_id",
        "event",
        "message",
        "counters"
      ],
      "additionalProperties": false
    },
    "POSES": {
      "type": "object",
      "properties": {
        "session_id": {
          "$ref": "#/$defs/NonemptyString"
        },
        "world_epoch_id": {
          "$ref": "#/$defs/NonemptyString"
        },
        "samples": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/PoseSample"
          },
          "minItems": 1,
          "maxItems": 64
        }
      },
      "required": [
        "session_id",
        "world_epoch_id",
        "samples"
      ],
      "additionalProperties": false
    },
    "PRESSURES": {
      "type": "object",
      "properties": {
        "source_id": {
          "$ref": "#/$defs/NonemptyString"
        },
        "boot_id": {
          "$ref": "#/$defs/NonemptyString"
        },
        "connection_id": {
          "$ref": "#/$defs/NonemptyString"
        },
        "phone_session_id": {
          "$ref": "#/$defs/NonemptyString"
        },
        "samples": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/PressureSample"
          },
          "minItems": 1,
          "maxItems": 64
        }
      },
      "required": [
        "source_id",
        "boot_id",
        "connection_id",
        "phone_session_id",
        "samples"
      ],
      "additionalProperties": false
    },
    "TRIGGER": {
      "type": "object",
      "properties": {
        "source_id": {
          "$ref": "#/$defs/NonemptyString"
        },
        "boot_id": {
          "$ref": "#/$defs/NonemptyString"
        },
        "connection_id": {
          "$ref": "#/$defs/NonemptyString"
        },
        "phone_session_id": {
          "$ref": "#/$defs/NonemptyString"
        },
        "sequence": {
          "$ref": "#/$defs/UInt64"
        },
        "raw_sequence": {
          "type": "integer",
          "minimum": 0,
          "maximum": 4294967295
        },
        "source_time_us": {
          "$ref": "#/$defs/UInt64"
        },
        "phone_receive_ns": {
          "$ref": "#/$defs/UInt64"
        },
        "pressed": {
          "$ref": "#/$defs/Boolean"
        },
        "event": {
          "enum": [
            "transition",
            "heartbeat"
          ]
        }
      },
      "required": [
        "source_id",
        "boot_id",
        "connection_id",
        "phone_session_id",
        "sequence",
        "raw_sequence",
        "source_time_us",
        "phone_receive_ns",
        "pressed",
        "event"
      ],
      "additionalProperties": false
    },
    "CLOCK": {
      "type": "object",
      "properties": {
        "link": {
          "enum": [
            "ble",
            "usb"
          ]
        },
        "exchange_id": {
          "$ref": "#/$defs/NonemptyString"
        },
        "source_id": {
          "$ref": "#/$defs/NonemptyString"
        },
        "epoch_id": {
          "$ref": "#/$defs/NonemptyString"
        },
        "t1_ns": {
          "$ref": "#/$defs/UInt64"
        },
        "t2_ns": {
          "$ref": "#/$defs/UInt64"
        },
        "t3_ns": {
          "$ref": "#/$defs/UInt64"
        },
        "t4_ns": {
          "$ref": "#/$defs/UInt64"
        },
        "mapping": {
          "type": "object",
          "properties": {
            "valid": {
              "$ref": "#/$defs/Boolean"
            },
            "scale": {
              "anyOf": [
                {
                  "$ref": "#/$defs/FiniteNumber"
                },
                {
                  "type": "null"
                }
              ]
            },
            "offset_ns": {
              "anyOf": [
                {
                  "$ref": "#/$defs/FiniteNumber"
                },
                {
                  "type": "null"
                }
              ]
            },
            "uncertainty_ns": {
              "anyOf": [
                {
                  "$ref": "#/$defs/Timestamp"
                },
                {
                  "type": "null"
                }
              ]
            }
          },
          "required": [
            "valid",
            "scale",
            "offset_ns",
            "uncertainty_ns"
          ],
          "additionalProperties": false
        }
      },
      "required": [
        "link",
        "exchange_id",
        "source_id",
        "epoch_id",
        "t1_ns",
        "t2_ns",
        "t3_ns",
        "t4_ns",
        "mapping"
      ],
      "additionalProperties": false
    },
    "TRIAL_REQUEST": {
      "anyOf": [
        {
          "$ref": "#/$defs/PrepareRequest"
        },
        {
          "$ref": "#/$defs/BeginRequest"
        },
        {
          "$ref": "#/$defs/StopRequest"
        },
        {
          "$ref": "#/$defs/StatusRequest"
        }
      ]
    },
    "TRIAL_STATUS": {
      "type": "object",
      "properties": {
        "host_session_id": {
          "$ref": "#/$defs/NonemptyString"
        },
        "host_time_ns": {
          "$ref": "#/$defs/UInt64"
        },
        "request_id": {
          "anyOf": [
            {
              "$ref": "#/$defs/NonemptyString"
            },
            {
              "type": "null"
            }
          ]
        },
        "trial_id": {
          "anyOf": [
            {
              "$ref": "#/$defs/NonemptyString"
            },
            {
              "type": "null"
            }
          ]
        },
        "revision": {
          "$ref": "#/$defs/UInt64"
        },
        "state": {
          "enum": [
            "idle",
            "preparing",
            "recording",
            "finalizing",
            "saved",
            "incomplete"
          ]
        },
        "ready": {
          "$ref": "#/$defs/Boolean"
        },
        "reason": {
          "anyOf": [
            {
              "$ref": "#/$defs/Text"
            },
            {
              "type": "null"
            }
          ]
        },
        "bag_path": {
          "anyOf": [
            {
              "$ref": "#/$defs/NonemptyString"
            },
            {
              "type": "null"
            }
          ]
        },
        "verification": {
          "enum": [
            "pending",
            "passed",
            "failed"
          ]
        },
        "counters": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/Counter"
          },
          "minItems": 0,
          "maxItems": 32
        }
      },
      "required": [
        "host_session_id",
        "host_time_ns",
        "request_id",
        "trial_id",
        "revision",
        "state",
        "ready",
        "reason",
        "bag_path",
        "verification",
        "counters"
      ],
      "additionalProperties": false
    }
  }
}
```

## Complete synthetic wire examples

Each example is the decoded metadata for its correspondingly named shared hex fixture. FRAME payload bytes are explicitly synthetic `jpg1234567812` (main) and `jpg` (ultrawide), not decodable camera evidence. All identities, capabilities and measured-looking values are test-only.

### collection_begin (TRIAL_REQUEST)

```json
{
  "action": "begin",
  "expected_revision": 2,
  "fences": [
    {
      "epoch_id": "world-A",
      "next_sequence": 9,
      "source_id": "phone-A",
      "stream_id": "camera_pose"
    }
  ],
  "request_id": "req-A",
  "trial_id": "trial-A"
}
```

### collection_clock (CLOCK)

```json
{
  "epoch_id": "phone-A",
  "exchange_id": "exchange-A",
  "link": "usb",
  "mapping": {
    "offset_ns": null,
    "scale": null,
    "uncertainty_ns": null,
    "valid": false
  },
  "source_id": "phone-A",
  "t1_ns": 100,
  "t2_ns": 200,
  "t3_ns": 210,
  "t4_ns": 120
}
```

### collection_frame (FRAME)

```json
{
  "arkit_timestamp_s": 123.125,
  "camera_frame": "arkit_camera",
  "camera_transform_row_major": [
    1,
    0,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    0,
    1
  ],
  "confidence": {
    "encoding": "uint8",
    "height": 1,
    "length": 2,
    "width": 2
  },
  "counters": {
    "acquired_frames": 1,
    "encode_drops": 0,
    "transport_drops": 0
  },
  "depth": {
    "association": "same_arframe_no_independent_timestamp",
    "encoding": "float32_le_m",
    "height": 1,
    "length": 8,
    "width": 2
  },
  "frame_seq": 0,
  "image_orientation": "sensor_native",
  "intrinsics_row_major": [
    100,
    0,
    2,
    0,
    100,
    1,
    0,
    0,
    1
  ],
  "phone_uptime_ns": 987654321,
  "pose_valid": true,
  "position_m": [
    0,
    0,
    0
  ],
  "quaternion_xyzw": [
    0,
    0,
    0,
    1
  ],
  "rgb": {
    "encoding": "jpeg",
    "height": 2,
    "length": 3,
    "width": 4
  },
  "rgb_intrinsics_row_major": [
    100,
    0,
    2,
    0,
    100,
    1,
    0,
    0,
    1
  ],
  "session_id": "session-A",
  "source_image_size": [
    4,
    2
  ],
  "stream_id": "main_rgb",
  "thermal_state": "nominal",
  "tracking_reason": "",
  "tracking_state": "normal",
  "world_epoch_id": "world-A",
  "world_frame": "arkit_world"
}
```

### collection_health (HEALTH)

```json
{
  "counters": [
    {
      "duplicate_count": 0,
      "epoch_id": "world-A",
      "missing_ranges": [
        {
          "end_exclusive": 8,
          "start": 7
        }
      ],
      "queue_overflow_count": 0,
      "received_count": 8,
      "rejected_count": 0,
      "source_count": 9,
      "source_id": "phone-A",
      "stream_id": "camera_pose",
      "writer_accepted_count": null
    }
  ],
  "event": "status",
  "message": "Synthetic fixture only",
  "session_id": "phone-A"
}
```

### collection_hello (HELLO)

```json
{
  "protocol_version": 2,
  "role": "host"
}
```

### collection_ping (PING)

```json
{
  "host_send_ns": 100,
  "ping_id": 1
}
```

### collection_pong (PONG)

```json
{
  "host_send_ns": 100,
  "phone_receive_ns": 200,
  "phone_send_ns": 210,
  "ping_id": 1,
  "session_id": "phone-A"
}
```

### collection_poses (POSES)

```json
{
  "samples": [
    {
      "arkit_timestamp_s": 123.125,
      "camera_transform_row_major": [
        1,
        0,
        0,
        0,
        0,
        1,
        0,
        0,
        0,
        0,
        1,
        0,
        0,
        0,
        0,
        1
      ],
      "frame_seq": 0,
      "phone_uptime_ns": 987654321,
      "pose_valid": true,
      "position_m": [
        0,
        0,
        0
      ],
      "quaternion_xyzw": [
        0,
        0,
        0,
        1
      ],
      "tracking_reason": "",
      "tracking_state": "normal"
    }
  ],
  "session_id": "phone-A",
  "world_epoch_id": "world-A"
}
```

### collection_prepare (TRIAL_REQUEST)

```json
{
  "action": "prepare",
  "expected_revision": 2,
  "request_id": "req-A",
  "snapshot": {
    "calibration": null,
    "capabilities": [
      {
        "available": true,
        "epoch_id": "epoch-A",
        "reason": null,
        "schema": "test-only",
        "source_id": "source-A",
        "stream_id": "main_rgb",
        "units": "test-only"
      },
      {
        "available": true,
        "epoch_id": "epoch-A",
        "reason": null,
        "schema": "test-only",
        "source_id": "source-A",
        "stream_id": "raw_depth",
        "units": "test-only"
      },
      {
        "available": true,
        "epoch_id": "epoch-A",
        "reason": null,
        "schema": "test-only",
        "source_id": "source-A",
        "stream_id": "depth_confidence",
        "units": "test-only"
      },
      {
        "available": true,
        "epoch_id": "epoch-A",
        "reason": null,
        "schema": "test-only",
        "source_id": "source-A",
        "stream_id": "camera_pose",
        "units": "test-only"
      },
      {
        "available": true,
        "epoch_id": "epoch-A",
        "reason": null,
        "schema": "test-only",
        "source_id": "source-A",
        "stream_id": "tracking",
        "units": "test-only"
      },
      {
        "available": true,
        "epoch_id": "epoch-A",
        "reason": null,
        "schema": "test-only",
        "source_id": "source-A",
        "stream_id": "camera_calibration",
        "units": "test-only"
      },
      {
        "available": true,
        "epoch_id": "epoch-A",
        "reason": null,
        "schema": "test-only",
        "source_id": "source-A",
        "stream_id": "ultrawide",
        "units": "test-only"
      },
      {
        "available": true,
        "epoch_id": "epoch-A",
        "reason": null,
        "schema": "test-only",
        "source_id": "source-A",
        "stream_id": "pressures",
        "units": "test-only"
      },
      {
        "available": true,
        "epoch_id": "epoch-A",
        "reason": null,
        "schema": "test-only",
        "source_id": "source-A",
        "stream_id": "trigger",
        "units": "test-only"
      },
      {
        "available": true,
        "epoch_id": "epoch-A",
        "reason": null,
        "schema": "test-only",
        "source_id": "source-A",
        "stream_id": "seal",
        "units": "test-only"
      },
      {
        "available": true,
        "epoch_id": "epoch-A",
        "reason": null,
        "schema": "test-only",
        "source_id": "source-A",
        "stream_id": "trial_metadata",
        "units": "test-only"
      },
      {
        "available": true,
        "epoch_id": "epoch-A",
        "reason": null,
        "schema": "test-only",
        "source_id": "source-A",
        "stream_id": "timing",
        "units": "test-only"
      },
      {
        "available": true,
        "epoch_id": "epoch-A",
        "reason": null,
        "schema": "test-only",
        "source_id": "source-A",
        "stream_id": "health",
        "units": "test-only"
      }
    ],
    "configuration": {
      "host_heartbeat_ns": 500000000,
      "host_status_stale_ns": 2000000000,
      "mandatory_stale_grace_ns": 1000000000,
      "pressure_stale_ns": 250000000,
      "target_fps": 60,
      "trigger_heartbeat_ns": 250000000,
      "trigger_stale_ns": 1000000000,
      "vision_stale_ns": 500000000
    },
    "gripper_id": "fixture-tool",
    "missing_modalities": [],
    "profile": "full",
    "required_streams": [
      "main_rgb",
      "raw_depth",
      "depth_confidence",
      "camera_pose",
      "tracking",
      "camera_calibration",
      "ultrawide",
      "pressures",
      "trigger",
      "seal",
      "trial_metadata",
      "timing",
      "health"
    ],
    "session_id": "phone-A",
    "task_label": "synthetic protocol test"
  },
  "trial_id": "trial-A"
}
```

### collection_pressures (PRESSURES)

```json
{
  "boot_id": "boot-A",
  "connection_id": "ble-A",
  "phone_session_id": "phone-A",
  "samples": [
    {
      "phone_receive_ns": 200,
      "pressure_centi_pa": [
        10000000,
        9000000,
        8000000
      ],
      "quality_mask": 7,
      "raw_sequence": 0,
      "sequence": 0,
      "source_time_us": 100
    }
  ],
  "source_id": "esp"
}
```

### collection_status (TRIAL_STATUS)

```json
{
  "bag_path": null,
  "counters": [],
  "host_session_id": "host-A",
  "host_time_ns": 100,
  "ready": true,
  "reason": null,
  "request_id": "req-A",
  "revision": 2,
  "state": "recording",
  "trial_id": "trial-A",
  "verification": "pending"
}
```

### collection_status_request (TRIAL_REQUEST)

```json
{
  "action": "status",
  "expected_revision": 2,
  "request_id": "req-A",
  "trial_id": "trial-A"
}
```

### collection_stop (TRIAL_REQUEST)

```json
{
  "action": "stop",
  "counters": [
    {
      "duplicate_count": 0,
      "epoch_id": "world-A",
      "missing_ranges": [
        {
          "end_exclusive": 8,
          "start": 7
        }
      ],
      "queue_overflow_count": 0,
      "received_count": 8,
      "rejected_count": 0,
      "source_count": 9,
      "source_id": "phone-A",
      "stream_id": "camera_pose",
      "writer_accepted_count": null
    }
  ],
  "expected_revision": 2,
  "fences": [
    {
      "epoch_id": "world-A",
      "next_sequence": 9,
      "source_id": "phone-A",
      "stream_id": "camera_pose"
    }
  ],
  "request_id": "req-A",
  "trial_id": "trial-A"
}
```

### collection_trigger (TRIGGER)

```json
{
  "boot_id": "boot-A",
  "connection_id": "ble-A",
  "event": "heartbeat",
  "phone_receive_ns": 222,
  "phone_session_id": "phone-A",
  "pressed": true,
  "raw_sequence": 3,
  "sequence": 3,
  "source_id": "esp",
  "source_time_us": 111
}
```

### collection_ultrawide (FRAME)

```json
{
  "camera_frame": "ultrawide_camera",
  "counters": {
    "acquired_frames": 9,
    "encode_drops": 0,
    "transport_drops": 0
  },
  "frame_seq": 8,
  "image_orientation": "sensor_native",
  "intrinsics_row_major": [
    2,
    0,
    1,
    0,
    2,
    1,
    0,
    0,
    1
  ],
  "phone_uptime_ns": 999,
  "rgb": {
    "encoding": "jpeg",
    "height": 2,
    "length": 3,
    "width": 2
  },
  "rgb_intrinsics_row_major": [
    2,
    0,
    1,
    0,
    2,
    1,
    0,
    0,
    1
  ],
  "session_id": "phone-A",
  "source_clock": "verified-camera-source",
  "source_image_size": [
    2,
    2
  ],
  "source_timestamp_s": 321.125,
  "stream_id": "ultrawide",
  "thermal_state": "nominal",
  "world_epoch_id": "capture-A"
}
```

## Regenerating the embedded Swift schemas

Python `SCHEMAS` is the editable source of truth. After updating schemas and their red/green tests, regenerate the exact embedded Foundation definitions with the following repository-root command, then run both suites. The docs' complete definitions/examples must also be updated when changing the contract.

```python
from pathlib import Path
import json
from usi_stream.collection_protocol import SCHEMAS
path = Path('ios_app/iPhUMI/USIStream/USICollectionWire.swift')
source = path.read_text()
marker = '    private static let schemaJSON = #"""\n'
start = source.index(marker) + len(marker)
end = source.index('\n"""#', start)
path.write_text(source[:start] + json.dumps(SCHEMAS, sort_keys=True, separators=(',', ':')) + source[end:])
```
