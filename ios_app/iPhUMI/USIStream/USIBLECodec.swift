import Foundation

/// Version-one logical BLE messages. Device quality bits mark errors; qualityMask marks validity.
enum USIBLEError: Error { case invalid }
struct USIBLEPressureSample {
    let rawSequence: UInt32
    let sourceTimeUs: UInt64
    let pressuresCentiPa: [Int32]
    let qualityErrorMask: UInt8
    var qualityMask: UInt8 { (~qualityErrorMask) & 7 }
    var pressuresKPaAbs: [Double] { pressuresCentiPa.map { Double($0) / 100_000 } }
}
struct USIBLETrigger {
    let rawSequence: UInt32
    let sourceTimeUs: UInt64
    let pressed: Bool
    let heartbeat: Bool
    var suctionOn: Bool { !pressed }
}
struct USIBLEClock {
    let requestID: UInt32
    let t1PhoneNs: UInt64
    let t2DeviceUs: UInt64
    let t3DeviceUs: UInt64
    let snapshotDeviceUs: UInt64
    let pressureAcquired: UInt64
    let triggerAcquired: UInt64
    let pressureOverflow: UInt64
    let triggerOverflow: UInt64
    let pressureDisconnected: UInt64
    let triggerDisconnected: UInt64
    let schedulerSkips: UInt64
    let pressureNotifyLost: UInt64
    let triggerNotifyLost: UInt64
    let notifyCalls: UInt64
    let notifyFailures: UInt64
    let disconnects: UInt64
}
enum USIBLEEvent {
    case pressure(UInt32, [USIBLEPressureSample])
    case trigger(UInt32, USIBLETrigger)
    case clock(UInt32, USIBLEClock)
}
private struct BLEReader {
    let data: [UInt8]
    var offset = 0
    init(_ data: Data) { self.data = Array(data) }
    mutating func read(_ count: Int) throws -> UInt64 {
        guard count <= 8, count >= 1, offset + count <= data.count else { throw USIBLEError.invalid }
        var value: UInt64 = 0
        for n in 0..<count { value |= UInt64(data[offset+n]) << (8*n) }
        offset += count
        return value
    }
    var atEnd: Bool { offset == data.count }
}
private func appendLE<T: FixedWidthInteger>(_ value: T, count: Int, to bytes: inout [UInt8]) {
    for i in 0..<count { bytes.append(UInt8(truncatingIfNeeded: value >> (i*8))) }
}
enum USIBLECodec {
    static func decode(_ data: Data) throws -> USIBLEEvent {
        guard data.count >= 5, data.count <= 256 else { throw USIBLEError.invalid }
        var r = BLEReader(data)
        let kind = try r.read(1), boot = UInt32(try r.read(4))
        guard boot != 0 else { throw USIBLEError.invalid }
        switch kind {
        case 1:
            let count = Int(try r.read(1))
            guard count > 0, count <= 10, data.count == 6 + count*25 else { throw USIBLEError.invalid }
            var samples: [USIBLEPressureSample] = []
            for _ in 0..<count {
                let sequence = UInt32(try r.read(4)), time = try r.read(8)
                var pressures: [Int32] = []
                for _ in 0..<3 { pressures.append(Int32(bitPattern: UInt32(try r.read(4)))) }
                let error = UInt8(try r.read(1))
                guard error <= 7 else { throw USIBLEError.invalid }
                for i in 0..<3 {
                    guard (error & (1 << i) != 0) ? pressures[i] == -100 : pressures[i] >= 0
                    else { throw USIBLEError.invalid }
                }
                samples.append(USIBLEPressureSample(rawSequence: sequence, sourceTimeUs: time,
                    pressuresCentiPa: pressures, qualityErrorMask: error))
            }
            return .pressure(boot, samples)
        case 2:
            guard data.count == 19 else { throw USIBLEError.invalid }
            let sequence = UInt32(try r.read(4)), time = try r.read(8)
            let pressed = try r.read(1), heartbeat = try r.read(1)
            guard pressed <= 1, heartbeat <= 1 else { throw USIBLEError.invalid }
            return .trigger(boot, USIBLETrigger(rawSequence: sequence, sourceTimeUs: time,
                pressed: pressed == 1, heartbeat: heartbeat == 1))
        case 3:
            guard data.count == 137 else { throw USIBLEError.invalid }
            let request = UInt32(try r.read(4))
            var v: [UInt64] = []
            for _ in 0..<16 { v.append(try r.read(8)) }
            guard v[0] > 0, v[1] <= v[3], v[3] <= v[2] else { throw USIBLEError.invalid }
            return .clock(boot, USIBLEClock(requestID: request, t1PhoneNs: v[0],
                t2DeviceUs: v[1], t3DeviceUs: v[2], snapshotDeviceUs: v[3],
                pressureAcquired: v[4], triggerAcquired: v[5], pressureOverflow: v[6],
                triggerOverflow: v[7], pressureDisconnected: v[8], triggerDisconnected: v[9],
                schedulerSkips: v[10], pressureNotifyLost: v[11], triggerNotifyLost: v[12],
                notifyCalls: v[13], notifyFailures: v[14], disconnects: v[15]))
        default: throw USIBLEError.invalid
        }
    }
    static func clockRequest(requestID: UInt32, t1PhoneNs: UInt64) -> Data {
        var bytes: [UInt8] = [0xc7, 1, 4, 0]
        appendLE(requestID, count: 4, to: &bytes)
        appendLE(t1PhoneNs, count: 8, to: &bytes)
        return Data(bytes)
    }
    static func fragment(_ message: Data, messageID: UInt32, payloadSize: Int = 20) throws -> [Data] {
        guard (20...244).contains(payloadSize), (1...256).contains(message.count) else { throw USIBLEError.invalid }
        _ = try decode(message)
        let bytes = Array(message), chunk = payloadSize - 10
        return stride(from: 0, to: bytes.count, by: chunk).map { offset in
            var part: [UInt8] = [0xc7, 1]
            appendLE(messageID, count: 4, to: &part)
            appendLE(UInt16(bytes.count), count: 2, to: &part)
            appendLE(UInt16(offset), count: 2, to: &part)
            part.append(contentsOf: bytes[offset..<min(offset+chunk,bytes.count)])
            return Data(part)
        }
    }
}
struct USIBLEReassembler {
    private var currentID: UInt32?
    private var latestStartedID: UInt32?
    private var buffer = Data()
    private var total = 0
    private var startedNs: UInt64 = 0
    private var lastReceivedNs: UInt64 = 0
    private(set) var discarded = 0
    mutating func reset() { currentID=nil; latestStartedID=nil; buffer.removeAll(); total=0 }
    private mutating func abort() {
        if currentID != nil { discarded += 1 }
        currentID = nil; buffer.removeAll(); total=0
    }
    mutating func feed(_ part: Data, receivedNs: UInt64) throws -> Data? {
        do {
            guard part.count > 10, part.count <= 244 else { throw USIBLEError.invalid }
            var r = BLEReader(part)
            guard try r.read(1) == 0xc7, try r.read(1) == 1 else { throw USIBLEError.invalid }
            let id = UInt32(try r.read(4)), length = Int(try r.read(2)), offset = Int(try r.read(2))
            guard (1...256).contains(length), offset < length, offset+part.count-10 <= length else { throw USIBLEError.invalid }
            if currentID != nil && receivedNs >= startedNs && receivedNs-startedNs > 500_000_000 { throw USIBLEError.invalid }
            if currentID != nil && receivedNs < lastReceivedNs { throw USIBLEError.invalid }
            if let currentID, id != currentID {
                let distance = id &- currentID
                guard distance > 0, distance < 0x80000000 else { throw USIBLEError.invalid }
                abort()
            }
            if currentID == nil {
                if let latestStartedID {
                    let distance = id &- latestStartedID
                    guard distance > 0, distance < 0x80000000 else { throw USIBLEError.invalid }
                }
                guard offset == 0 else { throw USIBLEError.invalid }
                currentID=id; latestStartedID=id; total=length; startedNs=receivedNs
            }
            guard id == currentID, length == total, offset == buffer.count else { throw USIBLEError.invalid }
            buffer.append(part.dropFirst(10))
            lastReceivedNs=receivedNs
            if buffer.count == total {
                let result=buffer
                _ = try USIBLECodec.decode(result)
                currentID=nil; buffer.removeAll(); return result
            }
            return nil
        } catch {
            abort(); throw USIBLEError.invalid
        }
    }
}

/// Single-owner source identity bootstrap. Buffer notifications until the ordered
/// CLOCK barrier supplies the actual next acquisition sequence for this boot.
/// A caller must discard this instance on disconnect or source epoch change.
struct USIBLEProgressTracker {
    private static let modulus: UInt64 = 1 << 32
    private static let half: UInt64 = 1 << 31
    private let capacity: Int
    private var buffered: [UInt32] = []
    private var next: UInt64?
    init(capacity: Int) throws {
        guard capacity > 0 else { throw USIBLEError.invalid }
        self.capacity = capacity
    }
    mutating func receive(raw: UInt32) throws -> UInt64? {
        guard let floor = next else {
            guard buffered.count < capacity else { throw USIBLEError.invalid }
            buffered.append(raw)
            return nil
        }
        let delta = (UInt64(raw) &+ Self.modulus &- (floor % Self.modulus)) % Self.modulus
        guard delta < Self.half else { throw USIBLEError.invalid }
        let (sequence, overflow) = floor.addingReportingOverflow(delta)
        guard !overflow, sequence < UInt64.max else { throw USIBLEError.invalid }
        next = sequence + 1
        return sequence
    }
    mutating func seed(nextSourceCount: UInt64) throws -> [UInt64] {
        guard next == nil else { throw USIBLEError.invalid }
        var result = [UInt64](repeating: 0, count: buffered.count)
        var boundary = nextSourceCount
        for i in buffered.indices.reversed() {
            guard boundary > 0 else { throw USIBLEError.invalid }
            let latest = boundary - 1
            let distance = (latest % Self.modulus &+ Self.modulus &- UInt64(buffered[i])) % Self.modulus
            guard distance < Self.half, distance <= latest else { throw USIBLEError.invalid }
            result[i] = latest - distance
            boundary = result[i]
        }
        buffered.removeAll()
        next = nextSourceCount
        return result
    }
}
