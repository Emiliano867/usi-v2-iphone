import Foundation
import CoreFoundation

private func collectionJSONObject(_ data: Data, options: JSONSerialization.ReadingOptions = []) throws -> Any {
    do { return try JSONSerialization.jsonObject(with:data,options:options) }
    catch { throw USICollectionError.invalid("invalid JSON metadata") }
}

enum USICollectionMessageType: UInt16, CaseIterable {
    case hello = 1, frame, ping, pong, health, poses, pressure, trigger, bleClock, trialCommand, trialStatus
    var schemaName: String {
        ["HELLO","FRAME","PING","PONG","HEALTH","POSES","PRESSURE","TRIGGER","BLE_CLOCK","TRIAL_COMMAND","TRIAL_STATUS"][Int(rawValue)-1]
    }
}
struct USICollectionHeader {
    let type: USICollectionMessageType
    let metadataLength: Int
    let payloadLength: Int
    var totalLength: Int { 16 + metadataLength + payloadLength }
}
struct USICollectionPacket {
    let type: USICollectionMessageType
    let metadata: [String: Any]
    let payload: Data
}
struct USICollectionFrameParts { let rgb: Data; let depth: Data?; let confidence: Data? }
enum USICollectionError: Error { case invalid(String) }

enum USICollectionWire {
    static let port: UInt16 = 5559
    static let headerLength = 16
    static let maxMetadataLength = 65_536
    static let maxPayloadLength = 16_777_216
    static let maxBatch = 64
    static let maxNesting = 32

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw USICollectionError.invalid(message) }
    }
    private static func number(_ value: Any) -> NSNumber? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n
    }
    private static func integer(_ value: Any) -> Bool {
        guard let n = number(value) else { return false }
        return !["f","d"].contains(String(cString:n.objCType))
    }
    private static func finite(_ value: Any, depth: Int = 0) throws {
        try require(depth <= maxNesting, "metadata nesting exceeds 32")
        if let dictionary = value as? [String:Any] {
            for child in dictionary.values { try finite(child, depth:depth+1) }
        } else if let array = value as? [Any] {
            for child in array { try finite(child,depth:depth+1) }
        } else if let n = value as? NSNumber {
            try require(n.doubleValue.isFinite, "nonfinite JSON")
        } else { try require(value is String || value is NSNull, "invalid JSON value") }
    }
    private static func equalEnum(_ value: Any, _ candidate: Any) -> Bool {
        if let a = value as? String, let b = candidate as? String { return a == b }
        if let a = value as? NSNumber, let b = candidate as? NSNumber {
            guard CFGetTypeID(a) == CFGetTypeID(b) ||
                    (CFGetTypeID(a) != CFBooleanGetTypeID() && CFGetTypeID(b) != CFBooleanGetTypeID()) else { return false }
            return integer(value) == integer(candidate) && a == b
        }
        return value is NSNull && candidate is NSNull
    }
    private static func validate(_ value: Any, schema: [String:Any]) throws {
        if let choices = schema["anyOf"] as? [[String:Any]] {
            for choice in choices { if (try? validate(value,schema:choice)) != nil { return } }
            throw USICollectionError.invalid("no matching schema")
        }
        if let choices = schema["enum"] as? [Any] {
            try require(choices.contains { equalEnum(value,$0) }, "invalid enum"); return
        }
        switch schema["type"] as? String {
        case "object":
            guard let dictionary = value as? [String:Any], let properties = schema["properties"] as? [String:[String:Any]],
                  let required = schema["required"] as? [String] else { throw USICollectionError.invalid("expected object") }
            try require(required.allSatisfy { dictionary[$0] != nil }, "missing required field")
            try require(dictionary.keys.allSatisfy { properties[$0] != nil }, "unknown field")
            for (key,child) in dictionary { try validate(child,schema:properties[key]!) }
        case "array":
            guard let array = value as? [Any], let items = schema["items"] as? [String:Any] else { throw USICollectionError.invalid("expected array") }
            try require(array.count >= (schema["minItems"] as! Int) && array.count <= (schema["maxItems"] as! Int), "array length")
            for child in array { try validate(child,schema:items) }
        case "string":
            guard let string = value as? String else { throw USICollectionError.invalid("expected string") }
            try require(string.unicodeScalars.count >= (schema["minLength"] as? Int ?? 0) && string.unicodeScalars.count <= (schema["maxLength"] as! Int), "string length")
        case "integer", "number":
            guard let n = number(value) else { throw USICollectionError.invalid("expected number") }
            try require(schema["type"] as? String != "integer" || integer(value), "expected integer")
            if schema["type"] as? String == "number" {
                if let minimum=schema["minimum"] as? NSNumber { try require(n.doubleValue >= minimum.doubleValue,"below minimum") }
                if let maximum=schema["maximum"] as? NSNumber { try require(n.doubleValue <= maximum.doubleValue,"above maximum") }
                if let minimum=schema["exclusiveMinimum"] as? NSNumber { try require(n.doubleValue > minimum.doubleValue,"below exclusive minimum") }
                return
            }
            let decimal = n.decimalValue
            if let minimum = schema["minimum"] as? NSNumber { try require(decimal >= minimum.decimalValue,"below minimum") }
            if let maximum = schema["maximum"] as? NSNumber { try require(decimal <= maximum.decimalValue,"above maximum") }
            if let minimum = schema["exclusiveMinimum"] as? NSNumber { try require(decimal > minimum.decimalValue,"below exclusive minimum") }
        case "boolean":
            guard let n = value as? NSNumber else { throw USICollectionError.invalid("expected boolean") }
            try require(CFGetTypeID(n) == CFBooleanGetTypeID(), "expected boolean")
        case "null": try require(value is NSNull,"expected null")
        default: throw USICollectionError.invalid("unknown schema type")
        }
    }
    static let fullRequiredStreams = ["main_rgb","raw_depth","depth_confidence","camera_pose","tracking","camera_calibration","ultrawide","pressures","trigger","seal","trial_metadata","timing","health"]
    static let coreRequiredStreams = fullRequiredStreams.filter { $0 != "ultrawide" }
    static let fencedStreams = ["main_rgb","camera_pose","ultrawide","pressures","trigger"]
    private static func capabilities(_ values: [[String:Any]]) throws {
        for value in values {
            let available=value["available"] as! Bool
            try require(available || !(value["reason"] as? String ?? "").isEmpty,"unavailable capability needs reason")
            try require(!available || (value["source_id"] is String && value["epoch_id"] is String),"available capability needs source identity")
        }
    }
    private static func unique(_ values: [[String:Any]], _ keys: [String]) throws {
        let identities = values.map { item in keys.map { String(describing:item[$0]!) } }
        try require(Set(identities).count == identities.count,"duplicate identities")
    }
    private static func pose(_ metadata: [String:Any]) throws {
        let q = metadata["quaternion_xyzw"] as! [NSNumber]
        let norm = q.reduce(0.0) { hypot($0,$1.doubleValue) }
        try require(abs(norm-1) <= 1e-3,"quaternion must be normalized")
        try require(metadata["tracking_state"] as! String != "not_available" || !(metadata["pose_valid"] as! Bool),"unavailable valid pose")
    }
    static func validateMetadata(type: USICollectionMessageType, metadata m: [String:Any], payloadLength: Int = 0) throws {
        try finite(m)
        try require(payloadLength >= 0 && payloadLength <= maxPayloadLength,"invalid payload length")
        try require(type == .frame || payloadLength == 0,"only FRAME carries payload")
        try validate(m,schema:schemas[type.schemaName]!)
        if type == .frame {
            if m["stream_id"] as! String == "main_rgb" { try pose(m) }
            let rgb = m["rgb"] as! [String:Any]
            try require(rgb["encoding"] as! String == "jpeg","invalid RGB encoding")
            var total = rgb["length"] as! Int
            let depth = m["depth"] as? [String:Any], confidence = m["confidence"] as? [String:Any]
            if let d = depth {
                try require(d["encoding"] as! String == "float32_le_m", "invalid depth encoding")
                let length = d["length"] as! Int
                try require(length == (d["width"] as! Int)*(d["height"] as! Int)*4,"invalid depth length")
                total += length
            }
            if let c = confidence {
                guard let d = depth else { throw USICollectionError.invalid("confidence needs depth") }
                try require(c["encoding"] as! String == "uint8" && (c["width"] as! Int) == (d["width"] as! Int) &&
                    (c["height"] as! Int) == (d["height"] as! Int),"invalid confidence")
                try require(c["length"] as! Int == (c["width"] as! Int)*(c["height"] as! Int),"invalid confidence length")
                total += c["length"] as! Int
            }
            try require(total == payloadLength,"FRAME payload length mismatch")
            try require(m["stream_id"] as! String != "ultrawide" || (depth == nil && confidence == nil),"ultrawide cannot carry main depth")
            let seq = (m["frame_seq"] as! NSNumber).uint64Value
            let counters = m["counters"] as! [String:Any]
            try require(seq < UInt64.max && (counters["acquired_frames"] as! NSNumber).uint64Value >= seq+1,"acquired counter precedes frame")
        }
        if type == .poses {
            let samples = m["samples"] as! [[String:Any]]
            var last: UInt64?
            for sample in samples {
                try pose(sample)
                let sequence = (sample["frame_seq"] as! NSNumber).uint64Value
                try require(last == nil || last! < sequence,"pose batch order"); last=sequence
            }
        }
        if type == .pressure || type == .trigger {
            let samples = type == .pressure ? m["samples"] as! [[String:Any]] : [m]
            var last: UInt64?
            for sample in samples {
                let sequence = (sample["sequence"] as! NSNumber).uint64Value
                try require(sequence % (1 << 32) == (sample["raw_sequence"] as! NSNumber).uint64Value,"raw sequence mismatch")
                try require(last == nil || last! < sequence,"sensor batch order"); last=sequence
            }
        }
        if let fences = m["fences"] as? [[String:Any]] { try unique(fences,["stream_id"]) }
        if let counters = m["counters"] as? [[String:Any]] {
            try unique(counters,["stream_id","source_id","epoch_id"])
            for counter in counters {
                var previousEnd: UInt64 = 0
                for gap in counter["missing_ranges"] as! [[String:Any]] {
                    let start = (gap["start"] as! NSNumber).uint64Value, end = (gap["end_exclusive"] as! NSNumber).uint64Value
                    try require(previousEnd <= start && start < end,"invalid missing range"); previousEnd=end
                }
            }
        }
        if type == .bleClock {
            try require((m["t3_ns"] as! NSNumber).uint64Value >= (m["t2_ns"] as! NSNumber).uint64Value &&
                (m["t4_ns"] as! NSNumber).uint64Value >= (m["t1_ns"] as! NSNumber).uint64Value,"invalid exchange ordering")
            let mapping = m["mapping"] as! [String:Any]
            if mapping["valid"] as! Bool {
                try require(["scale","offset_ns","uncertainty_ns"].allSatisfy { mapping[$0] is NSNumber } &&
                    (mapping["scale"] as? NSNumber)?.doubleValue ?? 0 > 0,"invalid valid clock mapping")
            }
        }
        if let values=m["capabilities"] as? [[String:Any]] { try capabilities(values) }
        if type == .trialCommand, m["action"] as! String == "prepare" {
            let snap = m["snapshot"] as! [String:Any]
            try unique(snap["capabilities"] as! [[String:Any]],["stream_id"])
            try capabilities(snap["capabilities"] as! [[String:Any]])
            let required = snap["required_streams"] as! [String], missing = snap["missing_modalities"] as! [String]
            let mandatory = snap["profile"] as! String == "full" ? fullRequiredStreams : coreRequiredStreams
            try require(Set(mandatory).isSubset(of:Set(required)),"profile missing required inventory")
            try require(Set(required).count == required.count && Set(missing).count == missing.count && Set(required).isDisjoint(with:missing),"invalid required/missing streams")
            try require(snap["profile"] as! String != "full" || required.contains("ultrawide"),"full requires ultrawide")
            try require(snap["profile"] as! String != "core" || missing.contains("ultrawide"),"core declares ultrawide missing")
            if let cal = snap["calibration"] as? [String:Any] {
                let chambers = cal["chambers"] as! [[String:Any]]
                try unique(chambers,["sensor_index"]); try unique(chambers,["sector_index"])
                for chamber in chambers { try require((chamber["seal_on_kpa_abs"] as! NSNumber).doubleValue <
                    (chamber["seal_off_kpa_abs"] as! NSNumber).doubleValue,"invalid calibration thresholds") }
            }
        }
        if type == .trialStatus {
            let required=m["required_streams"] as! [String], missing=m["missing_modalities"] as! [String]
            let unavailable=m["missing_required_streams"] as! [String]
            try require(Set(required).count == required.count && Set(missing).count == missing.count &&
                Set(unavailable).count == unavailable.count && Set(required).isDisjoint(with:missing),"invalid status inventory")
            try require(Set(unavailable).isSubset(of:Set(required)),"unavailable stream must be required")
            let currentState=m["state"] as! String
            if currentState == "recording" || currentState == "saved" {
                try require(unavailable.isEmpty,"recording/saved assurance requires all required streams")
            }
            if m["profile"] is NSNull {
                try require(currentState == "idle" && required.isEmpty && missing.isEmpty && unavailable.isEmpty,"unselected profile only allowed for empty idle inventory")
            } else {
                let profile=m["profile"] as! String
                let mandatory=profile == "full" ? fullRequiredStreams : coreRequiredStreams
                try require(Set(mandatory).isSubset(of:Set(required)),"status profile missing required inventory")
                try require(profile != "core" || missing.contains("ultrawide"),"core status declares ultrawide missing")
            }
            let state = m["state"] as! String, verification = m["verification"] as! String
            try require(state == "idle" || !(m["trial_id"] is NSNull),"active trial needs ID")
            if state == "saved" { try require(verification == "passed" && !(m["bag_path"] is NSNull),"saved requires verified bag") }
            try require(verification != "passed" || state == "saved","passed without saved")
        }
    }
    static func encode(type: USICollectionMessageType, metadata: [String:Any], payload: Data = Data()) throws -> Data {
        try validateMetadata(type:type,metadata:metadata,payloadLength:payload.count)
        let json: Data
        do { json = try JSONSerialization.data(withJSONObject:metadata,options:[.sortedKeys,.withoutEscapingSlashes]) }
        catch { throw USICollectionError.invalid("invalid JSON metadata") }
        try require(json.count <= maxMetadataLength,"metadata too large")
        var result = Data("USI2".utf8)
        appendBE(UInt16(2),to:&result); appendBE(type.rawValue,to:&result)
        appendBE(UInt32(json.count),to:&result); appendBE(UInt32(payload.count),to:&result)
        result.append(json); result.append(payload); return result
    }
    static func parseHeader(_ data: Data) throws -> USICollectionHeader {
        try require(data.count == headerLength,"truncated header")
        let b = [UInt8](data)
        func word(_ start: Int, _ count: Int) -> UInt32 { b[start..<start+count].reduce(0) { ($0 << 8) | UInt32($1) } }
        try require(Array(b[0..<4]) == Array("USI2".utf8),"bad magic")
        try require(word(4,2) == 2,"bad version")
        guard let type = USICollectionMessageType(rawValue:UInt16(word(6,2))) else { throw USICollectionError.invalid("bad type") }
        let ml = Int(word(8,4)), pl = Int(word(12,4))
        try require(ml >= 2 && ml <= maxMetadataLength && pl <= maxPayloadLength,"invalid length")
        try require(type == .frame || pl == 0,"unexpected payload")
        return USICollectionHeader(type:type,metadataLength:ml,payloadLength:pl)
    }
    static func decode(_ data: Data) throws -> USICollectionPacket {
        let header = try parseHeader(Data(data.prefix(headerLength)))
        try require(data.count == header.totalLength,"packet length mismatch")
        let json = data.subdata(in:headerLength..<headerLength+header.metadataLength)
        var scanner = CollectionJSONPreflight(bytes:Array(json)); try scanner.run()
        guard let metadata = try collectionJSONObject(json) as? [String:Any] else { throw USICollectionError.invalid("expected object") }
        try validateMetadata(type:header.type,metadata:metadata,payloadLength:header.payloadLength)
        return USICollectionPacket(type:header.type,metadata:metadata,payload:data.subdata(in:headerLength+header.metadataLength..<data.count))
    }
    /// Reader must return 1...count bytes, or empty Data for EOF. Own it until complete;
    /// a thrown timeout requires closing the connection, never restarting mid-packet.
    static func recvPacket(read: (Int) throws -> Data) throws -> USICollectionPacket? {
        func exact(_ count: Int, cleanEOF: Bool = false) throws -> Data? {
            var result=Data()
            while result.count < count {
                let part = try read(min(count-result.count,65_536))
                if part.isEmpty {
                    if cleanEOF && result.isEmpty { return nil }
                    throw USICollectionError.invalid("EOF inside packet")
                }
                try require(part.count <= count-result.count,"reader exceeded requested count")
                result.append(part)
            }
            return result
        }
        guard let rawHeader = try exact(headerLength,cleanEOF:true) else { return nil }
        let header = try parseHeader(rawHeader)
        let rawJSON = try exact(header.metadataLength)!
        var scanner=CollectionJSONPreflight(bytes:Array(rawJSON)); try scanner.run()
        guard let metadata = try collectionJSONObject(rawJSON) as? [String:Any] else { throw USICollectionError.invalid("expected object") }
        try validateMetadata(type:header.type,metadata:metadata,payloadLength:header.payloadLength)
        return USICollectionPacket(type:header.type,metadata:metadata,payload:try exact(header.payloadLength)!)
    }
    static func sliceFrame(_ packet: USICollectionPacket) throws -> USICollectionFrameParts {
        try require(packet.type == .frame,"expected FRAME")
        try validateMetadata(type:.frame,metadata:packet.metadata,payloadLength:packet.payload.count)
        let m=packet.metadata, rgbLength=(m["rgb"] as! [String:Any])["length"] as! Int
        var offset=rgbLength; var depth: Data?, confidence: Data?
        if let d=m["depth"] as? [String:Any] {
            let end=offset+(d["length"] as! Int); depth=packet.payload.subdata(in:offset..<end); offset=end
        }
        if m["confidence"] is [String:Any] { confidence=packet.payload.subdata(in:offset..<packet.payload.count) }
        return USICollectionFrameParts(rgb:packet.payload.subdata(in:0..<rgbLength),depth:depth,confidence:confidence)
    }
    private static func appendBE<T:FixedWidthInteger>(_ value: T, to data: inout Data) {
        var big=value.bigEndian; withUnsafeBytes(of:&big) { data.append(contentsOf:$0) }
    }
    // Generated from collection_protocol.SCHEMAS; regenerate using the command in collection-protocol-v2.md.
    private static let schemas: [String:[String:Any]] = try! JSONSerialization.jsonObject(with:Data(schemaJSON.utf8)) as! [String:[String:Any]]
    private static let schemaJSON = #"""
{"BLE_CLOCK":{"additionalProperties":false,"properties":{"epoch_id":{"maxLength":512,"minLength":1,"type":"string"},"exchange_id":{"maxLength":512,"minLength":1,"type":"string"},"link":{"enum":["ble","usb"]},"mapping":{"additionalProperties":false,"properties":{"offset_ns":{"anyOf":[{"type":"number"},{"type":"null"}]},"scale":{"anyOf":[{"type":"number"},{"type":"null"}]},"uncertainty_ns":{"anyOf":[{"minimum":0,"type":"number"},{"type":"null"}]},"valid":{"type":"boolean"}},"required":["valid","scale","offset_ns","uncertainty_ns"],"type":"object"},"source_id":{"maxLength":512,"minLength":1,"type":"string"},"t1_ns":{"maximum":18446744073709551615,"minimum":0,"type":"integer"},"t2_ns":{"maximum":18446744073709551615,"minimum":0,"type":"integer"},"t3_ns":{"maximum":18446744073709551615,"minimum":0,"type":"integer"},"t4_ns":{"maximum":18446744073709551615,"minimum":0,"type":"integer"}},"required":["link","exchange_id","source_id","epoch_id","t1_ns","t2_ns","t3_ns","t4_ns","mapping"],"type":"object"},"FRAME":{"anyOf":[{"additionalProperties":false,"properties":{"arkit_timestamp_s":{"minimum":0,"type":"number"},"camera_frame":{"enum":["arkit_camera"]},"camera_transform_row_major":{"items":{"type":"number"},"maxItems":16,"minItems":16,"type":"array"},"confidence":{"anyOf":[{"additionalProperties":false,"properties":{"encoding":{"maxLength":512,"minLength":1,"type":"string"},"height":{"maximum":8192,"minimum":1,"type":"integer"},"length":{"maximum":16777216,"minimum":1,"type":"integer"},"width":{"maximum":8192,"minimum":1,"type":"integer"}},"required":["encoding","width","height","length"],"type":"object"},{"type":"null"}]},"counters":{"additionalProperties":false,"properties":{"acquired_frames":{"maximum":18446744073709551615,"minimum":0,"type":"integer"},"encode_drops":{"maximum":18446744073709551615,"minimum":0,"type":"integer"},"transport_drops":{"maximum":18446744073709551615,"minimum":0,"type":"integer"}},"required":["acquired_frames","encode_drops","transport_drops"],"type":"object"},"depth":{"anyOf":[{"additionalProperties":false,"properties":{"association":{"enum":["same_arframe_no_independent_timestamp"]},"encoding":{"maxLength":512,"minLength":1,"type":"string"},"height":{"maximum":8192,"minimum":1,"type":"integer"},"length":{"maximum":16777216,"minimum":1,"type":"integer"},"width":{"maximum":8192,"minimum":1,"type":"integer"}},"required":["encoding","width","height","length","association"],"type":"object"},{"type":"null"}]},"frame_seq":{"maximum":18446744073709551615,"minimum":0,"type":"integer"},"image_orientation":{"enum":["sensor_native"]},"intrinsics_row_major":{"items":{"type":"number"},"maxItems":9,"minItems":9,"type":"array"},"phone_uptime_ns":{"maximum":18446744073709551615,"minimum":0,"type":"integer"},"pose_valid":{"type":"boolean"},"position_m":{"items":{"type":"number"},"maxItems":3,"minItems":3,"type":"array"},"quaternion_xyzw":{"items":{"type":"number"},"maxItems":4,"minItems":4,"type":"array"},"rgb":{"additionalProperties":false,"properties":{"encoding":{"maxLength":512,"minLength":1,"type":"string"},"height":{"maximum":8192,"minimum":1,"type":"integer"},"length":{"maximum":16777216,"minimum":1,"type":"integer"},"width":{"maximum":8192,"minimum":1,"type":"integer"}},"required":["encoding","width","height","length"],"type":"object"},"rgb_intrinsics_row_major":{"items":{"type":"number"},"maxItems":9,"minItems":9,"type":"array"},"session_id":{"maxLength":512,"minLength":1,"type":"string"},"source_image_size":{"items":{"maximum":8192,"minimum":1,"type":"integer"},"maxItems":2,"minItems":2,"type":"array"},"stream_id":{"enum":["main_rgb"]},"thermal_state":{"enum":["nominal","fair","serious","critical","unknown"]},"tracking_reason":{"maxLength":4096,"type":"string"},"tracking_state":{"enum":["normal","limited","not_available"]},"world_epoch_id":{"maxLength":512,"minLength":1,"type":"string"},"world_frame":{"enum":["arkit_world"]}},"required":["session_id","world_epoch_id","stream_id","frame_seq","arkit_timestamp_s","phone_uptime_ns","world_frame","camera_frame","image_orientation","camera_transform_row_major","position_m","quaternion_xyzw","tracking_state","tracking_reason","pose_valid","intrinsics_row_major","source_image_size","rgb_intrinsics_row_major","rgb","depth","confidence","counters","thermal_state"],"type":"object"},{"additionalProperties":false,"properties":{"camera_frame":{"enum":["ultrawide_camera"]},"counters":{"additionalProperties":false,"properties":{"acquired_frames":{"maximum":18446744073709551615,"minimum":0,"type":"integer"},"encode_drops":{"maximum":18446744073709551615,"minimum":0,"type":"integer"},"transport_drops":{"maximum":18446744073709551615,"minimum":0,"type":"integer"}},"required":["acquired_frames","encode_drops","transport_drops"],"type":"object"},"frame_seq":{"maximum":18446744073709551615,"minimum":0,"type":"integer"},"image_orientation":{"enum":["sensor_native"]},"intrinsics_row_major":{"items":{"type":"number"},"maxItems":9,"minItems":9,"type":"array"},"phone_uptime_ns":{"maximum":18446744073709551615,"minimum":0,"type":"integer"},"rgb":{"additionalProperties":false,"properties":{"encoding":{"maxLength":512,"minLength":1,"type":"string"},"height":{"maximum":8192,"minimum":1,"type":"integer"},"length":{"maximum":16777216,"minimum":1,"type":"integer"},"width":{"maximum":8192,"minimum":1,"type":"integer"}},"required":["encoding","width","height","length"],"type":"object"},"rgb_intrinsics_row_major":{"items":{"type":"number"},"maxItems":9,"minItems":9,"type":"array"},"session_id":{"maxLength":512,"minLength":1,"type":"string"},"source_clock":{"maxLength":512,"minLength":1,"type":"string"},"source_image_size":{"items":{"maximum":8192,"minimum":1,"type":"integer"},"maxItems":2,"minItems":2,"type":"array"},"source_timestamp_s":{"minimum":0,"type":"number"},"stream_id":{"enum":["ultrawide"]},"thermal_state":{"enum":["nominal","fair","serious","critical","unknown"]},"world_epoch_id":{"maxLength":512,"minLength":1,"type":"string"}},"required":["session_id","world_epoch_id","stream_id","frame_seq","source_timestamp_s","source_clock","phone_uptime_ns","camera_frame","image_orientation","intrinsics_row_major","source_image_size","rgb_intrinsics_row_major","rgb","counters","thermal_state"],"type":"object"}]},"HEALTH":{"additionalProperties":false,"properties":{"capabilities":{"items":{"additionalProperties":false,"properties":{"available":{"type":"boolean"},"epoch_id":{"anyOf":[{"maxLength":512,"minLength":1,"type":"string"},{"type":"null"}]},"reason":{"anyOf":[{"maxLength":4096,"type":"string"},{"type":"null"}]},"schema":{"maxLength":512,"minLength":1,"type":"string"},"source_id":{"anyOf":[{"maxLength":512,"minLength":1,"type":"string"},{"type":"null"}]},"stream_id":{"enum":["main_rgb","raw_depth","depth_confidence","camera_pose","tracking","camera_calibration","ultrawide","pressures","trigger","seal","trial_metadata","timing","health","pump_command","pump_feedback","tcp","raw_imu","audio"]},"units":{"maxLength":512,"minLength":1,"type":"string"}},"required":["stream_id","available","reason","schema","units","source_id","epoch_id"],"type":"object"},"maxItems":32,"minItems":0,"type":"array"},"counters":{"items":{"additionalProperties":false,"properties":{"duplicate_count":{"anyOf":[{"maximum":18446744073709551615,"minimum":0,"type":"integer"},{"type":"null"}]},"epoch_id":{"maxLength":512,"minLength":1,"type":"string"},"missing_ranges":{"items":{"additionalProperties":false,"properties":{"end_exclusive":{"maximum":18446744073709551615,"minimum":0,"type":"integer"},"start":{"maximum":18446744073709551615,"minimum":0,"type":"integer"}},"required":["start","end_exclusive"],"type":"object"},"maxItems":256,"minItems":0,"type":"array"},"queue_overflow_count":{"anyOf":[{"maximum":18446744073709551615,"minimum":0,"type":"integer"},{"type":"null"}]},"received_count":{"anyOf":[{"maximum":18446744073709551615,"minimum":0,"type":"integer"},{"type":"null"}]},"rejected_count":{"anyOf":[{"maximum":18446744073709551615,"minimum":0,"type":"integer"},{"type":"null"}]},"source_count":{"anyOf":[{"maximum":18446744073709551615,"minimum":0,"type":"integer"},{"type":"null"}]},"source_id":{"maxLength":512,"minLength":1,"type":"string"},"stream_id":{"enum":["main_rgb","raw_depth","depth_confidence","camera_pose","tracking","camera_calibration","ultrawide","pressures","trigger","seal","trial_metadata","timing","health","pump_command","pump_feedback","tcp","raw_imu","audio"]},"writer_accepted_count":{"anyOf":[{"maximum":18446744073709551615,"minimum":0,"type":"integer"},{"type":"null"}]}},"required":["stream_id","source_id","epoch_id","source_count","received_count","writer_accepted_count","queue_overflow_count","rejected_count","duplicate_count","missing_ranges"],"type":"object"},"maxItems":32,"minItems":0,"type":"array"},"event":{"maxLength":512,"minLength":1,"type":"string"},"message":{"maxLength":4096,"type":"string"},"session_id":{"maxLength":512,"minLength":1,"type":"string"},"thermal_state":{"enum":["nominal","fair","serious","critical","unknown"]}},"required":["session_id","event","message","counters"],"type":"object"},"HELLO":{"additionalProperties":false,"properties":{"capabilities":{"items":{"additionalProperties":false,"properties":{"available":{"type":"boolean"},"epoch_id":{"anyOf":[{"maxLength":512,"minLength":1,"type":"string"},{"type":"null"}]},"reason":{"anyOf":[{"maxLength":4096,"type":"string"},{"type":"null"}]},"schema":{"maxLength":512,"minLength":1,"type":"string"},"source_id":{"anyOf":[{"maxLength":512,"minLength":1,"type":"string"},{"type":"null"}]},"stream_id":{"enum":["main_rgb","raw_depth","depth_confidence","camera_pose","tracking","camera_calibration","ultrawide","pressures","trigger","seal","trial_metadata","timing","health","pump_command","pump_feedback","tcp","raw_imu","audio"]},"units":{"maxLength":512,"minLength":1,"type":"string"}},"required":["stream_id","available","reason","schema","units","source_id","epoch_id"],"type":"object"},"maxItems":32,"minItems":0,"type":"array"},"profiles":{"items":{"enum":["full","core"]},"maxItems":2,"minItems":0,"type":"array"},"protocol_version":{"enum":[2]},"role":{"enum":["host","phone"]},"session_id":{"maxLength":512,"minLength":1,"type":"string"}},"required":["role","protocol_version"],"type":"object"},"PING":{"additionalProperties":false,"properties":{"host_send_ns":{"maximum":18446744073709551615,"minimum":0,"type":"integer"},"ping_id":{"maximum":18446744073709551615,"minimum":0,"type":"integer"}},"required":["ping_id","host_send_ns"],"type":"object"},"PONG":{"additionalProperties":false,"properties":{"host_send_ns":{"maximum":18446744073709551615,"minimum":0,"type":"integer"},"phone_receive_ns":{"maximum":18446744073709551615,"minimum":0,"type":"integer"},"phone_send_ns":{"maximum":18446744073709551615,"minimum":0,"type":"integer"},"ping_id":{"maximum":18446744073709551615,"minimum":0,"type":"integer"},"session_id":{"maxLength":512,"minLength":1,"type":"string"}},"required":["ping_id","host_send_ns","phone_receive_ns","phone_send_ns","session_id"],"type":"object"},"POSES":{"additionalProperties":false,"properties":{"samples":{"items":{"additionalProperties":false,"properties":{"arkit_timestamp_s":{"minimum":0,"type":"number"},"camera_transform_row_major":{"items":{"type":"number"},"maxItems":16,"minItems":16,"type":"array"},"frame_seq":{"maximum":18446744073709551615,"minimum":0,"type":"integer"},"phone_uptime_ns":{"maximum":18446744073709551615,"minimum":0,"type":"integer"},"pose_valid":{"type":"boolean"},"position_m":{"items":{"type":"number"},"maxItems":3,"minItems":3,"type":"array"},"quaternion_xyzw":{"items":{"type":"number"},"maxItems":4,"minItems":4,"type":"array"},"tracking_reason":{"maxLength":4096,"type":"string"},"tracking_state":{"enum":["normal","limited","not_available"]}},"required":["frame_seq","arkit_timestamp_s","phone_uptime_ns","camera_transform_row_major","position_m","quaternion_xyzw","tracking_state","tracking_reason","pose_valid"],"type":"object"},"maxItems":64,"minItems":1,"type":"array"},"session_id":{"maxLength":512,"minLength":1,"type":"string"},"world_epoch_id":{"maxLength":512,"minLength":1,"type":"string"}},"required":["session_id","world_epoch_id","samples"],"type":"object"},"PRESSURE":{"additionalProperties":false,"properties":{"boot_id":{"maxLength":512,"minLength":1,"type":"string"},"connection_id":{"maxLength":512,"minLength":1,"type":"string"},"phone_session_id":{"maxLength":512,"minLength":1,"type":"string"},"samples":{"items":{"additionalProperties":false,"properties":{"phone_receive_ns":{"maximum":18446744073709551615,"minimum":0,"type":"integer"},"pressure_centi_pa":{"items":{"maximum":2147483647,"minimum":-2147483648,"type":"integer"},"maxItems":3,"minItems":3,"type":"array"},"quality_mask":{"maximum":7,"minimum":0,"type":"integer"},"raw_sequence":{"maximum":4294967295,"minimum":0,"type":"integer"},"sequence":{"maximum":18446744073709551615,"minimum":0,"type":"integer"},"source_time_us":{"maximum":18446744073709551615,"minimum":0,"type":"integer"}},"required":["sequence","raw_sequence","source_time_us","phone_receive_ns","pressure_centi_pa","quality_mask"],"type":"object"},"maxItems":64,"minItems":1,"type":"array"},"source_id":{"maxLength":512,"minLength":1,"type":"string"}},"required":["source_id","boot_id","connection_id","phone_session_id","samples"],"type":"object"},"TRIAL_COMMAND":{"anyOf":[{"additionalProperties":false,"properties":{"action":{"enum":["prepare"]},"expected_revision":{"maximum":18446744073709551615,"minimum":0,"type":"integer"},"request_id":{"maxLength":512,"minLength":1,"type":"string"},"snapshot":{"additionalProperties":false,"properties":{"calibration":{"anyOf":[{"additionalProperties":false,"properties":{"ambient_kpa_abs":{"anyOf":[{"minimum":0,"type":"number"},{"type":"null"}]},"calibration_id":{"maxLength":512,"minLength":1,"type":"string"},"chambers":{"items":{"additionalProperties":false,"properties":{"persistence_ns":{"maximum":18446744073709551615,"minimum":0,"type":"integer"},"seal_off_kpa_abs":{"minimum":0,"type":"number"},"seal_on_kpa_abs":{"minimum":0,"type":"number"},"sector_index":{"maximum":2,"minimum":0,"type":"integer"},"sensor_index":{"maximum":2,"minimum":0,"type":"integer"}},"required":["sensor_index","sector_index","seal_on_kpa_abs","seal_off_kpa_abs","persistence_ns"],"type":"object"},"maxItems":3,"minItems":3,"type":"array"},"provenance":{"maxLength":4096,"type":"string"}},"required":["calibration_id","chambers","ambient_kpa_abs","provenance"],"type":"object"},{"type":"null"}]},"capabilities":{"items":{"additionalProperties":false,"properties":{"available":{"type":"boolean"},"epoch_id":{"anyOf":[{"maxLength":512,"minLength":1,"type":"string"},{"type":"null"}]},"reason":{"anyOf":[{"maxLength":4096,"type":"string"},{"type":"null"}]},"schema":{"maxLength":512,"minLength":1,"type":"string"},"source_id":{"anyOf":[{"maxLength":512,"minLength":1,"type":"string"},{"type":"null"}]},"stream_id":{"enum":["main_rgb","raw_depth","depth_confidence","camera_pose","tracking","camera_calibration","ultrawide","pressures","trigger","seal","trial_metadata","timing","health","pump_command","pump_feedback","tcp","raw_imu","audio"]},"units":{"maxLength":512,"minLength":1,"type":"string"}},"required":["stream_id","available","reason","schema","units","source_id","epoch_id"],"type":"object"},"maxItems":32,"minItems":1,"type":"array"},"configuration":{"additionalProperties":false,"properties":{"host_heartbeat_ns":{"maximum":18446744073709551615,"minimum":0,"type":"integer"},"host_status_stale_ns":{"maximum":18446744073709551615,"minimum":0,"type":"integer"},"mandatory_stale_grace_ns":{"maximum":18446744073709551615,"minimum":0,"type":"integer"},"pressure_stale_ns":{"maximum":18446744073709551615,"minimum":0,"type":"integer"},"target_fps":{"exclusiveMinimum":0,"maximum":240,"type":"number"},"trigger_heartbeat_ns":{"maximum":18446744073709551615,"minimum":0,"type":"integer"},"trigger_stale_ns":{"maximum":18446744073709551615,"minimum":0,"type":"integer"},"vision_stale_ns":{"maximum":18446744073709551615,"minimum":0,"type":"integer"}},"required":["pressure_stale_ns","trigger_stale_ns","vision_stale_ns","host_status_stale_ns","mandatory_stale_grace_ns","host_heartbeat_ns","trigger_heartbeat_ns","target_fps"],"type":"object"},"gripper_id":{"maxLength":512,"minLength":1,"type":"string"},"missing_modalities":{"items":{"enum":["main_rgb","raw_depth","depth_confidence","camera_pose","tracking","camera_calibration","ultrawide","pressures","trigger","seal","trial_metadata","timing","health","pump_command","pump_feedback","tcp","raw_imu","audio"]},"maxItems":32,"minItems":0,"type":"array"},"profile":{"enum":["full","core"]},"required_streams":{"items":{"enum":["main_rgb","raw_depth","depth_confidence","camera_pose","tracking","camera_calibration","ultrawide","pressures","trigger","seal","trial_metadata","timing","health","pump_command","pump_feedback","tcp","raw_imu","audio"]},"maxItems":32,"minItems":1,"type":"array"},"session_id":{"maxLength":512,"minLength":1,"type":"string"},"task_label":{"maxLength":512,"minLength":1,"type":"string"}},"required":["session_id","task_label","gripper_id","profile","calibration","configuration","capabilities","required_streams","missing_modalities"],"type":"object"},"trial_id":{"maxLength":512,"minLength":1,"type":"string"}},"required":["action","request_id","trial_id","expected_revision","snapshot"],"type":"object"},{"additionalProperties":false,"properties":{"action":{"enum":["begin"]},"expected_revision":{"maximum":18446744073709551615,"minimum":0,"type":"integer"},"fences":{"items":{"additionalProperties":false,"properties":{"epoch_id":{"maxLength":512,"minLength":1,"type":"string"},"next_sequence":{"maximum":18446744073709551615,"minimum":0,"type":"integer"},"source_id":{"maxLength":512,"minLength":1,"type":"string"},"stream_id":{"enum":["main_rgb","camera_pose","ultrawide","pressures","trigger"]}},"required":["stream_id","source_id","epoch_id","next_sequence"],"type":"object"},"maxItems":32,"minItems":1,"type":"array"},"request_id":{"maxLength":512,"minLength":1,"type":"string"},"trial_id":{"maxLength":512,"minLength":1,"type":"string"}},"required":["action","request_id","trial_id","expected_revision","fences"],"type":"object"},{"additionalProperties":false,"properties":{"action":{"enum":["stop"]},"counters":{"items":{"additionalProperties":false,"properties":{"duplicate_count":{"anyOf":[{"maximum":18446744073709551615,"minimum":0,"type":"integer"},{"type":"null"}]},"epoch_id":{"maxLength":512,"minLength":1,"type":"string"},"missing_ranges":{"items":{"additionalProperties":false,"properties":{"end_exclusive":{"maximum":18446744073709551615,"minimum":0,"type":"integer"},"start":{"maximum":18446744073709551615,"minimum":0,"type":"integer"}},"required":["start","end_exclusive"],"type":"object"},"maxItems":256,"minItems":0,"type":"array"},"queue_overflow_count":{"anyOf":[{"maximum":18446744073709551615,"minimum":0,"type":"integer"},{"type":"null"}]},"received_count":{"anyOf":[{"maximum":18446744073709551615,"minimum":0,"type":"integer"},{"type":"null"}]},"rejected_count":{"anyOf":[{"maximum":18446744073709551615,"minimum":0,"type":"integer"},{"type":"null"}]},"source_count":{"anyOf":[{"maximum":18446744073709551615,"minimum":0,"type":"integer"},{"type":"null"}]},"source_id":{"maxLength":512,"minLength":1,"type":"string"},"stream_id":{"enum":["main_rgb","raw_depth","depth_confidence","camera_pose","tracking","camera_calibration","ultrawide","pressures","trigger","seal","trial_metadata","timing","health","pump_command","pump_feedback","tcp","raw_imu","audio"]},"writer_accepted_count":{"anyOf":[{"maximum":18446744073709551615,"minimum":0,"type":"integer"},{"type":"null"}]}},"required":["stream_id","source_id","epoch_id","source_count","received_count","writer_accepted_count","queue_overflow_count","rejected_count","duplicate_count","missing_ranges"],"type":"object"},"maxItems":32,"minItems":0,"type":"array"},"expected_revision":{"maximum":18446744073709551615,"minimum":0,"type":"integer"},"fences":{"items":{"additionalProperties":false,"properties":{"epoch_id":{"maxLength":512,"minLength":1,"type":"string"},"next_sequence":{"maximum":18446744073709551615,"minimum":0,"type":"integer"},"source_id":{"maxLength":512,"minLength":1,"type":"string"},"stream_id":{"enum":["main_rgb","camera_pose","ultrawide","pressures","trigger"]}},"required":["stream_id","source_id","epoch_id","next_sequence"],"type":"object"},"maxItems":32,"minItems":1,"type":"array"},"request_id":{"maxLength":512,"minLength":1,"type":"string"},"trial_id":{"maxLength":512,"minLength":1,"type":"string"}},"required":["action","request_id","trial_id","expected_revision","fences","counters"],"type":"object"},{"additionalProperties":false,"properties":{"action":{"enum":["status"]},"expected_revision":{"maximum":18446744073709551615,"minimum":0,"type":"integer"},"request_id":{"maxLength":512,"minLength":1,"type":"string"},"trial_id":{"maxLength":512,"minLength":1,"type":"string"}},"required":["action","request_id","trial_id","expected_revision"],"type":"object"}]},"TRIAL_STATUS":{"additionalProperties":false,"properties":{"bag_path":{"anyOf":[{"maxLength":512,"minLength":1,"type":"string"},{"type":"null"}]},"counters":{"items":{"additionalProperties":false,"properties":{"duplicate_count":{"anyOf":[{"maximum":18446744073709551615,"minimum":0,"type":"integer"},{"type":"null"}]},"epoch_id":{"maxLength":512,"minLength":1,"type":"string"},"missing_ranges":{"items":{"additionalProperties":false,"properties":{"end_exclusive":{"maximum":18446744073709551615,"minimum":0,"type":"integer"},"start":{"maximum":18446744073709551615,"minimum":0,"type":"integer"}},"required":["start","end_exclusive"],"type":"object"},"maxItems":256,"minItems":0,"type":"array"},"queue_overflow_count":{"anyOf":[{"maximum":18446744073709551615,"minimum":0,"type":"integer"},{"type":"null"}]},"received_count":{"anyOf":[{"maximum":18446744073709551615,"minimum":0,"type":"integer"},{"type":"null"}]},"rejected_count":{"anyOf":[{"maximum":18446744073709551615,"minimum":0,"type":"integer"},{"type":"null"}]},"source_count":{"anyOf":[{"maximum":18446744073709551615,"minimum":0,"type":"integer"},{"type":"null"}]},"source_id":{"maxLength":512,"minLength":1,"type":"string"},"stream_id":{"enum":["main_rgb","raw_depth","depth_confidence","camera_pose","tracking","camera_calibration","ultrawide","pressures","trigger","seal","trial_metadata","timing","health","pump_command","pump_feedback","tcp","raw_imu","audio"]},"writer_accepted_count":{"anyOf":[{"maximum":18446744073709551615,"minimum":0,"type":"integer"},{"type":"null"}]}},"required":["stream_id","source_id","epoch_id","source_count","received_count","writer_accepted_count","queue_overflow_count","rejected_count","duplicate_count","missing_ranges"],"type":"object"},"maxItems":32,"minItems":0,"type":"array"},"host_session_id":{"maxLength":512,"minLength":1,"type":"string"},"host_time_ns":{"maximum":18446744073709551615,"minimum":0,"type":"integer"},"missing_modalities":{"items":{"enum":["main_rgb","raw_depth","depth_confidence","camera_pose","tracking","camera_calibration","ultrawide","pressures","trigger","seal","trial_metadata","timing","health","pump_command","pump_feedback","tcp","raw_imu","audio"]},"maxItems":32,"minItems":0,"type":"array"},"missing_required_streams":{"items":{"enum":["main_rgb","raw_depth","depth_confidence","camera_pose","tracking","camera_calibration","ultrawide","pressures","trigger","seal","trial_metadata","timing","health","pump_command","pump_feedback","tcp","raw_imu","audio"]},"maxItems":32,"minItems":0,"type":"array"},"profile":{"anyOf":[{"enum":["full","core"]},{"type":"null"}]},"ready":{"type":"boolean"},"reason":{"anyOf":[{"maxLength":4096,"type":"string"},{"type":"null"}]},"request_id":{"anyOf":[{"maxLength":512,"minLength":1,"type":"string"},{"type":"null"}]},"required_streams":{"items":{"enum":["main_rgb","raw_depth","depth_confidence","camera_pose","tracking","camera_calibration","ultrawide","pressures","trigger","seal","trial_metadata","timing","health","pump_command","pump_feedback","tcp","raw_imu","audio"]},"maxItems":32,"minItems":0,"type":"array"},"revision":{"maximum":18446744073709551615,"minimum":0,"type":"integer"},"state":{"enum":["idle","preparing","recording","finalizing","saved","incomplete"]},"trial_id":{"anyOf":[{"maxLength":512,"minLength":1,"type":"string"},{"type":"null"}]},"verification":{"enum":["pending","passed","failed"]}},"required":["host_session_id","host_time_ns","request_id","trial_id","revision","state","ready","profile","required_streams","missing_modalities","missing_required_streams","reason","bag_path","verification","counters"],"type":"object"},"TRIGGER":{"additionalProperties":false,"properties":{"boot_id":{"maxLength":512,"minLength":1,"type":"string"},"connection_id":{"maxLength":512,"minLength":1,"type":"string"},"event":{"enum":["transition","heartbeat"]},"phone_receive_ns":{"maximum":18446744073709551615,"minimum":0,"type":"integer"},"phone_session_id":{"maxLength":512,"minLength":1,"type":"string"},"pressed":{"type":"boolean"},"raw_sequence":{"maximum":4294967295,"minimum":0,"type":"integer"},"sequence":{"maximum":18446744073709551615,"minimum":0,"type":"integer"},"source_id":{"maxLength":512,"minLength":1,"type":"string"},"source_time_us":{"maximum":18446744073709551615,"minimum":0,"type":"integer"}},"required":["source_id","boot_id","connection_id","phone_session_id","sequence","raw_sequence","source_time_us","phone_receive_ns","pressed","event"],"type":"object"}}
"""#
}

/// Enforces duplicate-key and depth limits before Foundation allocates nested objects.
private struct CollectionJSONPreflight {
    let bytes: [UInt8]
    var index=0
    mutating func run() throws {
        try value(depth:0); whitespace()
        guard index == bytes.count else { throw USICollectionError.invalid("trailing JSON") }
    }
    mutating func whitespace() { while index < bytes.count && [9,10,13,32].contains(bytes[index]) { index += 1 } }
    mutating func take(_ byte: UInt8) throws {
        whitespace()
        guard index < bytes.count && bytes[index] == byte else { throw USICollectionError.invalid("malformed JSON") }
        index += 1
    }
    mutating func string() throws -> String {
        whitespace(); let start=index; try take(34)
        while index < bytes.count {
            let byte=bytes[index]; index += 1
            if byte == 92 { guard index < bytes.count else { break }; index += 1 }
            else if byte == 34 {
                guard let value = try collectionJSONObject(Data(bytes[start..<index]),options:[.fragmentsAllowed]) as? String else { break }
                return value
            }
        }
        throw USICollectionError.invalid("malformed JSON string")
    }
    mutating func value(depth: Int) throws {
        guard depth <= USICollectionWire.maxNesting else { throw USICollectionError.invalid("metadata nesting exceeds 32") }
        whitespace(); guard index < bytes.count else { throw USICollectionError.invalid("missing JSON value") }
        if bytes[index] == 123 {
            index += 1; whitespace(); var keys=Set<String>()
            if index < bytes.count && bytes[index] == 125 { index += 1; return }
            while true {
                let key=try string()
                guard keys.insert(key).inserted else { throw USICollectionError.invalid("duplicate JSON key") }
                try take(58); try value(depth:depth+1); whitespace()
                if index < bytes.count && bytes[index] == 125 { index += 1; return }
                try take(44)
            }
        } else if bytes[index] == 91 {
            index += 1; whitespace()
            if index < bytes.count && bytes[index] == 93 { index += 1; return }
            while true {
                try value(depth:depth+1); whitespace()
                if index < bytes.count && bytes[index] == 93 { index += 1; return }
                try take(44)
            }
        } else if bytes[index] == 34 { _ = try string() }
        else {
            let start=index
            while index < bytes.count && ![9,10,13,32,44,93,125].contains(bytes[index]) { index += 1 }
            guard index > start else { throw USICollectionError.invalid("missing JSON primitive") }
            let token=String(decoding:bytes[start..<index],as:UTF8.self)
            if bytes[start] == 45 || (48...57).contains(bytes[start]) {
                if !token.contains(".") && !token.contains("e") && !token.contains("E") {
                    let inRange = token.hasPrefix("-") ? Int64(token) != nil : UInt64(token) != nil
                    guard inRange else { throw USICollectionError.invalid("integer token outside signed/unsigned 64-bit domain") }
                } else {
                    guard let value=Double(token), value.isFinite else { throw USICollectionError.invalid("nonfinite JSON number") }
                }
            }
        }
    }
}
