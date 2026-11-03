import Foundation

/// Immutable validated wire bytes. Production never sends an unchecked dictionary.
struct USICollectionOutbound {
    let bytes: Data
    let type: USICollectionMessageType
    let identities: [USISampleIdentity]
    let requestID: String?
    init(type: USICollectionMessageType, metadata: [String: Any], payload: Data = Data(),
         identities: [USISampleIdentity] = [], requestID: String? = nil) throws {
        self.bytes = try USICollectionWire.encode(type: type, metadata: metadata, payload: payload)
        self.type = type; self.identities = identities; self.requestID = requestID
    }
}

struct USICameraPose {
    var arkitTimestampS: Double
    var phoneUptimeNs: UInt64
    var transform: [Double]
    var positionM: [Double]
    var quaternionXYZW: [Double]
    var trackingState: String
    var trackingReason: String
    var valid: Bool
    func metadata(sequence: UInt64) -> [String: Any] {
        ["frame_seq": sequence, "arkit_timestamp_s": arkitTimestampS, "phone_uptime_ns": phoneUptimeNs,
         "camera_transform_row_major": transform, "position_m": positionM, "quaternion_xyzw": quaternionXYZW,
         "tracking_state": trackingState, "tracking_reason": trackingReason, "pose_valid": valid]
    }
}
struct USICameraPlane {
    let width: Int
    let height: Int
    let bytes: Data
    func descriptor(encoding: String) -> [String: Any] {
        ["encoding": encoding, "width": width, "height": height, "length": bytes.count]
    }
}
struct USICameraImage {
    var intrinsics: [Double]
    var sourceSize: [Int]
    var rgbIntrinsics: [Double]
    var rgbWidth: Int
    var rgbHeight: Int
    var jpeg: Data
    var depth: USICameraPlane?
    var confidence: USICameraPlane?
    var thermalState: String
}
struct USICollectionFence: Equatable {
    let stream: USICollectionStream
    let sourceID: String
    let epochID: String
    let nextSequence: UInt64
    init(stream: USICollectionStream, sourceID: String, epochID: String, nextSequence: UInt64) throws {
        guard [.mainRGB,.cameraPose,.ultrawide,.pressures,.trigger].contains(stream),
              !sourceID.isEmpty, !epochID.isEmpty else { throw USICollectionError.invalid("invalid fence") }
        self.stream = stream; self.sourceID = sourceID; self.epochID = epochID; self.nextSequence = nextSequence
    }
    var metadata: [String: Any] {
        ["stream_id": stream.rawValue, "source_id": sourceID, "epoch_id": epochID, "next_sequence": nextSequence]
    }
}
struct USICollectionCounter {
    let stream: USICollectionStream
    let sourceID: String
    let epochID: String
    var counts = USIStreamCounters()
    var missingRanges: [Range<UInt64>] = []
    var metadata: [String: Any] {
        ["stream_id": stream.rawValue, "source_id": sourceID, "epoch_id": epochID,
         "source_count": counts.sourceCount as Any? ?? NSNull(),
         "received_count": counts.receivedCount as Any? ?? NSNull(),
         "writer_accepted_count": counts.writerAcceptedCount as Any? ?? NSNull(),
         "queue_overflow_count": counts.queueOverflowCount as Any? ?? NSNull(),
         "rejected_count": counts.rejectedCount as Any? ?? NSNull(),
         "duplicate_count": counts.duplicateCount as Any? ?? NSNull(),
         "missing_ranges": missingRanges.map { ["start": $0.lowerBound, "end_exclusive": $0.upperBound] }]
    }
}
struct USICollectionCapability {
    let stream: USICollectionStream
    let available: Bool
    let reason: String?
    let sourceID: String?
    let epochID: String?
    static let units: [USICollectionStream: String] = [
        .mainRGB:"jpeg", .ultrawide:"jpeg", .rawDepth:"m", .depthConfidence:"level", .cameraPose:"m",
        .tracking:"state", .cameraCalibration:"pixel", .pressures:"kPa_abs", .trigger:"boolean",
        .seal:"state", .trialMetadata:"json", .timing:"ns", .health:"count"]
    var metadata: [String: Any] {
        ["stream_id": stream.rawValue, "available": available, "reason": reason as Any? ?? NSNull(),
         "source_id": sourceID as Any? ?? NSNull(), "epoch_id": epochID as Any? ?? NSNull(),
         "schema":"usi.collection.v2", "units": Self.units[stream] ?? "unavailable"]
    }
}
struct USICollectionConfiguration {
    var pressureStaleNs: UInt64 = 250_000_000
    var triggerStaleNs: UInt64 = 1_000_000_000
    var visionStaleNs: UInt64 = 500_000_000
    var hostStatusStaleNs: UInt64 = 2_000_000_000
    var mandatoryStaleGraceNs: UInt64 = 1_000_000_000
    var hostHeartbeatNs: UInt64 = 500_000_000
    var triggerHeartbeatNs: UInt64 = 250_000_000
    var targetFPS: Double = 60
    var metadata: [String: Any] {
        ["pressure_stale_ns":pressureStaleNs, "trigger_stale_ns":triggerStaleNs, "vision_stale_ns":visionStaleNs,
         "host_status_stale_ns":hostStatusStaleNs, "mandatory_stale_grace_ns":mandatoryStaleGraceNs,
         "host_heartbeat_ns":hostHeartbeatNs, "trigger_heartbeat_ns":triggerHeartbeatNs, "target_fps":targetFPS]
    }
}
struct USICollectionSnapshot {
    let sessionID: String
    let taskLabel: String
    let gripperID: String
    let profile: String
    let calibration: USIPressureCalibration?
    let ambientKPaAbs: Double?
    let calibrationProvenance: String
    let capabilities: [USICollectionCapability]
    var configuration = USICollectionConfiguration()
    var requiredStreams: [String] { profile == "full" ? USICollectionWire.fullRequiredStreams : USICollectionWire.coreRequiredStreams }
    var metadata: [String: Any] {
        var cal: Any = NSNull()
        if let calibration {
            cal = ["calibration_id":calibration.id, "ambient_kpa_abs":ambientKPaAbs as Any? ?? NSNull(),
                   "provenance":calibrationProvenance, "chambers":calibration.chambers.map {
                ["sensor_index":$0.sensorIndex, "sector_index":$0.sectorIndex,
                 "seal_on_kpa_abs":$0.sealOnKPaAbs, "seal_off_kpa_abs":$0.sealOffKPaAbs,
                 "persistence_ns":$0.persistenceNs] as [String:Any]
            }] as [String:Any]
        }
        return ["session_id":sessionID, "task_label":taskLabel, "gripper_id":gripperID, "profile":profile,
                "calibration":cal, "configuration":configuration.metadata, "capabilities":capabilities.map(\.metadata),
                "required_streams":requiredStreams, "missing_modalities":profile == "core" ? ["ultrawide"] : []]
    }
}

enum USICollectionPackets {
    static func hello(session: String, capabilities: [USICollectionCapability], profiles: [String]) throws -> USICollectionOutbound {
        try USICollectionOutbound(type:.hello, metadata:["role":"phone", "protocol_version":2,
            "session_id":session, "capabilities":capabilities.map(\.metadata), "profiles":profiles])
    }
    static func pong(session: String, pingID: UInt64, hostSendNs: UInt64, receivedNs: UInt64, sentNs: UInt64) throws -> USICollectionOutbound {
        try USICollectionOutbound(type:.pong, metadata:["session_id":session, "ping_id":pingID,
            "host_send_ns":hostSendNs, "phone_receive_ns":receivedNs, "phone_send_ns":sentNs])
    }
    static func clock(link: String, exchange: String, source: String, epoch: String, times: [UInt64]) throws -> USICollectionOutbound {
        guard times.count == 4 else { throw USICollectionError.invalid("four clock times required") }
        return try USICollectionOutbound(type:.bleClock, metadata:["link":link, "exchange_id":exchange,
            "source_id":source, "epoch_id":epoch, "t1_ns":times[0], "t2_ns":times[1], "t3_ns":times[2], "t4_ns":times[3],
            "mapping":["valid":false, "scale":NSNull(), "offset_ns":NSNull(), "uncertainty_ns":NSNull()]])
    }
    static func health(session: String, event: String, message: String, counters: [USICollectionCounter],
                       capabilities: [USICollectionCapability]? = nil) throws -> USICollectionOutbound {
        var m: [String:Any] = ["session_id":session, "event":event, "message":message, "counters":counters.map(\.metadata)]
        if let capabilities { m["capabilities"] = capabilities.map(\.metadata) }
        return try USICollectionOutbound(type:.health, metadata:m)
    }
    static func poses(session: String, epoch: String, samples: [(UInt64, USICameraPose)]) throws -> USICollectionOutbound {
        try USICollectionOutbound(type:.poses, metadata:["session_id":session, "world_epoch_id":epoch,
            "samples":samples.map { $0.1.metadata(sequence:$0.0) }], identities: samples.map {
                try USISampleIdentity(stream:.cameraPose, sourceID:session, epochID:epoch, sequence:$0.0)
            })
    }
    private static func imageMetadata(_ image: USICameraImage, acquired: UInt64, encodeDrops: UInt64, transportDrops: UInt64) -> [String:Any] {
        ["intrinsics_row_major":image.intrinsics, "source_image_size":image.sourceSize,
         "rgb_intrinsics_row_major":image.rgbIntrinsics, "rgb":["encoding":"jpeg", "width":image.rgbWidth,
            "height":image.rgbHeight, "length":image.jpeg.count], "thermal_state":image.thermalState,
         "image_orientation":"sensor_native", "counters":["acquired_frames":acquired,
            "encode_drops":encodeDrops, "transport_drops":transportDrops]]
    }
    static func mainFrame(session: String, epoch: String, sequence: UInt64, pose: USICameraPose,
                          image: USICameraImage, acquired: UInt64, encodeDrops: UInt64, transportDrops: UInt64) throws -> USICollectionOutbound {
        var m = imageMetadata(image, acquired:acquired, encodeDrops:encodeDrops, transportDrops:transportDrops)
        m.merge(pose.metadata(sequence:sequence)) { _, new in new }
        m["session_id"] = session; m["world_epoch_id"] = epoch; m["stream_id"] = "main_rgb"
        m["world_frame"] = "arkit_world"; m["camera_frame"] = "arkit_camera"
        if let depth = image.depth {
            var d = depth.descriptor(encoding:"float32_le_m"); d["association"] = "same_arframe_no_independent_timestamp"
            m["depth"] = d
        } else { m["depth"] = NSNull() }
        m["confidence"] = image.confidence?.descriptor(encoding:"uint8") as Any? ?? NSNull()
        var payload = image.jpeg
        if let depth = image.depth { payload.append(depth.bytes) }
        if let confidence = image.confidence { payload.append(confidence.bytes) }
        return try USICollectionOutbound(type:.frame, metadata:m, payload:payload,
            identities:[try USISampleIdentity(stream:.mainRGB, sourceID:session, epochID:epoch, sequence:sequence)])
    }
    static func ultrawide(session: String, epoch: String, sequence: UInt64, sourceTimestampS: Double,
                          sourceClock: String, phoneUptimeNs: UInt64, image: USICameraImage,
                          acquired: UInt64, encodeDrops: UInt64, transportDrops: UInt64) throws -> USICollectionOutbound {
        guard image.depth == nil, image.confidence == nil else { throw USICollectionError.invalid("ultrawide cannot carry ARFrame planes") }
        var m = imageMetadata(image, acquired:acquired, encodeDrops:encodeDrops, transportDrops:transportDrops)
        m.merge(["session_id":session, "world_epoch_id":epoch, "stream_id":"ultrawide", "frame_seq":sequence,
                 "camera_frame":"ultrawide_camera", "source_timestamp_s":sourceTimestampS,
                 "source_clock":sourceClock, "phone_uptime_ns":phoneUptimeNs]) { _, new in new }
        return try USICollectionOutbound(type:.frame, metadata:m, payload:image.jpeg,
            identities:[try USISampleIdentity(stream:.ultrawide, sourceID:session, epochID:epoch, sequence:sequence)])
    }
    static func pressure(source: String, boot: String, connection: String, phone: String,
                         samples: [(UInt64, USIBLEPressureSample, UInt64)]) throws -> USICollectionOutbound {
        try USICollectionOutbound(type:.pressure, metadata:["source_id":source, "boot_id":boot,
            "connection_id":connection, "phone_session_id":phone, "samples":samples.map {
                ["sequence":$0.0, "raw_sequence":$0.1.rawSequence, "source_time_us":$0.1.sourceTimeUs,
                 "phone_receive_ns":$0.2, "pressure_centi_pa":$0.1.pressuresCentiPa, "quality_mask":$0.1.qualityMask] as [String:Any]
            }], identities:samples.map { try USISampleIdentity(stream:.pressures, sourceID:source, epochID:boot, sequence:$0.0) })
    }
    static func trigger(source: String, boot: String, connection: String, phone: String, sequence: UInt64,
                        sample: USIBLETrigger, receivedNs: UInt64) throws -> USICollectionOutbound {
        try USICollectionOutbound(type:.trigger, metadata:["source_id":source, "boot_id":boot,
            "connection_id":connection, "phone_session_id":phone, "sequence":sequence, "raw_sequence":sample.rawSequence,
            "source_time_us":sample.sourceTimeUs, "phone_receive_ns":receivedNs, "pressed":sample.pressed,
            "event":sample.heartbeat ? "heartbeat" : "transition"],
            identities:[try USISampleIdentity(stream:.trigger, sourceID:source, epochID:boot, sequence:sequence)])
    }
    static func prepare(request: String, trial: String, revision: UInt64, snapshot: USICollectionSnapshot) throws -> USICollectionOutbound {
        try USICollectionOutbound(type:.trialCommand, metadata:["action":"prepare", "request_id":request,
            "trial_id":trial, "expected_revision":revision, "snapshot":snapshot.metadata], requestID:request)
    }
    static func command(action: String, request: String, trial: String, revision: UInt64,
                        fences: [USICollectionFence]? = nil, counters: [USICollectionCounter]? = nil) throws -> USICollectionOutbound {
        var m: [String:Any] = ["action":action, "request_id":request, "trial_id":trial, "expected_revision":revision]
        if let fences { m["fences"] = fences.map(\.metadata) }
        if let counters { m["counters"] = counters.map(\.metadata) }
        return try USICollectionOutbound(type:.trialCommand, metadata:m, requestID:request)
    }
}
