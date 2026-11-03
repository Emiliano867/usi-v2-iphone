import Foundation

enum USICollectionLane: CaseIterable { case image, pose, sensor, control }
/// Single-owner admission queues, bounded in both records and bytes. No replacement/coalescing.
/// The adapter may call takeNext only when the previous whole packet send has completed.
struct USICollectionTransport {
    private let capacities: [USICollectionLane: Int]
    private let byteLimit: Int
    private var queues: [USICollectionLane: [USICollectionOutbound]] = [:]
    private var bytes: [USICollectionLane: Int] = [:]
    private var cursor = 0
    private(set) var overflowCount: [USICollectionLane: UInt64] = [:]
    init(imageCapacity: Int = 4, poseCapacity: Int = 128, sensorCapacity: Int = 128,
         controlCapacity: Int = 32, byteLimitPerLane: Int = 20_000_000) throws {
        guard [imageCapacity,poseCapacity,sensorCapacity,controlCapacity,byteLimitPerLane].allSatisfy({ $0 > 0 })
        else { throw USICollectionError.invalid("invalid transport capacity") }
        capacities = [.image:imageCapacity, .pose:poseCapacity, .sensor:sensorCapacity, .control:controlCapacity]
        byteLimit = byteLimitPerLane
    }
    static func lane(_ packet: USICollectionOutbound) -> USICollectionLane {
        switch packet.type {
        case .frame: return .image
        case .poses: return .pose
        case .pressure,.trigger: return .sensor
        default: return .control
        }
    }
    @discardableResult mutating func offer(_ packet: USICollectionOutbound) -> Bool {
        let lane = Self.lane(packet)
        // A retry already waiting in the bounded control queue needs no second copy.
        if let id = packet.requestID, queues[lane, default: []].contains(where: { $0.requestID == id && $0.bytes == packet.bytes }) { return true }
        guard queues[lane, default: []].count < capacities[lane]!,
              packet.bytes.count <= byteLimit - bytes[lane, default: 0] else {
            if overflowCount[lane, default: 0] < UInt64.max { overflowCount[lane, default: 0] += 1 }
            return false
        }
        queues[lane, default: []].append(packet); bytes[lane, default: 0] += packet.bytes.count
        return true
    }
    mutating func takeNext(allowData: Bool) -> USICollectionOutbound? {
        if let packet = pop(.control) { return packet }
        guard allowData else { return nil }
        let lanes: [USICollectionLane] = [.pose,.sensor,.image]
        for _ in 0..<3 {
            let lane = lanes[cursor]; cursor = (cursor+1)%3
            if let packet = pop(lane) { return packet }
        }
        return nil
    }
    private mutating func pop(_ lane: USICollectionLane) -> USICollectionOutbound? {
        guard var q = queues[lane], !q.isEmpty else { return nil }
        let packet = q.removeFirst(); queues[lane] = q; bytes[lane, default: 0] -= packet.bytes.count
        return packet
    }
    mutating func retainData(where keep: (USISampleIdentity) -> Bool) {
        for lane in [USICollectionLane.image,.pose,.sensor] {
            // Runtime packets contain one source record, so no partial batches are silently removed.
            let retained = queues[lane, default: []].filter { $0.identities.allSatisfy(keep) }
            queues[lane] = retained; bytes[lane] = retained.reduce(0) { $0 + $1.bytes.count }
        }
    }
    mutating func clear() { queues.removeAll(); bytes.removeAll() }
    var queuedCount: Int { queues.values.reduce(0) { $0 + $1.count } }
}
