import Foundation

struct USICollectionBLESourceSnapshot {
    let sourceID: String
    let bootID: UInt32
    let connectionID: String
    let firstReceivedNs: UInt64
    let completedNs: UInt64
    let clock: USIBLEClock
}

/// Ordered BLE source progress, not a radio-delivery estimate. Call only on the admission owner.
/// connect is required after every disconnect; a CLOCK barrier must seed each connection.
struct USICollectionBLEProgress {
    private let capacity: Int
    private var pressure: USIBLEProgressTracker
    private var trigger: USIBLEProgressTracker
    private var pendingPressure: [(USIBLEPressureSample,UInt64)] = []
    private var pendingTrigger: [(USIBLETrigger,UInt64)] = []
    private(set) var source = ""
    private(set) var boot: UInt32 = 0
    private(set) var connection = ""
    private var phone = ""
    private(set) var synchronized = false
    private(set) var lastCompleteNs: UInt64?
    private(set) var pressureNext: UInt64?
    private(set) var triggerNext: UInt64?
    private(set) var pressureReceived: UInt64 = 0
    private(set) var triggerReceived: UInt64 = 0
    private var pressureObservedNext: UInt64 = 0
    private var triggerObservedNext: UInt64 = 0
    private var clocks: [String:USIBLEClock] = [:]
    private var retired = Set<String>()
    private var currentKey = ""
    private var pressureSourceTime: UInt64?
    private var triggerSourceTime: UInt64?
    init(capacity: Int = 128) throws {
        self.capacity = capacity; pressure = try USIBLEProgressTracker(capacity:capacity)
        trigger = try USIBLEProgressTracker(capacity:capacity)
    }
    mutating func connect(source: String, boot: UInt32, connection: String, phone: String) throws {
        guard !source.isEmpty, boot != 0, !connection.isEmpty, !phone.isEmpty else { throw USIBLEError.invalid }
        let key = "\(source):\(boot)"
        guard !retired.contains(key), retired.count < 64, clocks.count < 64 || clocks[key] != nil else { throw USIBLEError.invalid }
        if !currentKey.isEmpty && currentKey != key {
            retired.insert(currentKey); pressureReceived = 0; triggerReceived = 0
            pressureObservedNext = 0; triggerObservedNext = 0; pressureSourceTime = nil; triggerSourceTime = nil
        }
        currentKey = key; self.source = source; self.boot = boot; self.connection = connection; self.phone = phone
        pressure = try USIBLEProgressTracker(capacity:capacity); trigger = try USIBLEProgressTracker(capacity:capacity)
        pendingPressure.removeAll(); pendingTrigger.removeAll(); synchronized = false; lastCompleteNs = nil
    }
    mutating func disconnect() { synchronized = false; lastCompleteNs = nil }
    mutating func receive(_ event: USIBLEEvent, firstReceivedNs: UInt64, completedNs: UInt64) throws -> [USICollectionOutbound] {
        guard boot != 0, firstReceivedNs <= completedNs, lastCompleteNs == nil || completedNs >= lastCompleteNs! else { throw USIBLEError.invalid }
        var packets: [USICollectionOutbound] = []
        switch event {
        case let .pressure(epoch, samples):
            guard epoch == boot, (1...10).contains(samples.count) else { throw USIBLEError.invalid }
            for sample in samples {
                if let sequence = try pressure.receive(raw:sample.rawSequence) {
                    packets.append(try pressurePacket(sequence, sample, firstReceivedNs))
                } else {
                    guard pendingPressure.count < capacity else { throw USIBLEError.invalid }
                    pendingPressure.append((sample,firstReceivedNs))
                }
            }
        case let .trigger(epoch, sample):
            guard epoch == boot else { throw USIBLEError.invalid }
            if let sequence = try trigger.receive(raw:sample.rawSequence) {
                packets.append(try triggerPacket(sequence, sample, firstReceivedNs))
            } else {
                guard pendingTrigger.count < capacity else { throw USIBLEError.invalid }
                pendingTrigger.append((sample,firstReceivedNs))
            }
        case .clock: throw USIBLEError.invalid // Owner must correlate the outstanding clock request first.
        }
        lastCompleteNs = completedNs
        return packets
    }
    mutating func barrier(_ clock: USIBLEClock, firstReceivedNs: UInt64, completedNs: UInt64) throws -> [USICollectionOutbound] {
        guard boot != 0, firstReceivedNs <= completedNs,
              lastCompleteNs == nil || completedNs >= lastCompleteNs!,
              clock.pressureAcquired >= pressureObservedNext, clock.triggerAcquired >= triggerObservedNext
        else { throw USIBLEError.invalid }
        if let previous = clocks[currentKey] {
            let before = values(previous), after = values(clock)
            guard zip(before,after).allSatisfy({ $0 <= $1 }),
                  clock.pressureAcquired - previous.pressureAcquired < 1 << 31,
                  clock.triggerAcquired - previous.triggerAcquired < 1 << 31 else { throw USIBLEError.invalid }
        }
        // Work on copies so an impossible seed does not partially consume pending samples.
        var p = pressure, t = trigger
        let ps = synchronized ? [] : try p.seed(nextSourceCount:clock.pressureAcquired)
        let ts = synchronized ? [] : try t.seed(nextSourceCount:clock.triggerAcquired)
        var packets: [USICollectionOutbound] = []
        for (i,sequence) in ps.enumerated() { packets.append(try pressurePacket(sequence,pendingPressure[i].0,pendingPressure[i].1)) }
        for (i,sequence) in ts.enumerated() { packets.append(try triggerPacket(sequence,pendingTrigger[i].0,pendingTrigger[i].1)) }
        pressure = try USIBLEProgressTracker(capacity:capacity); _ = try pressure.seed(nextSourceCount:clock.pressureAcquired)
        trigger = try USIBLEProgressTracker(capacity:capacity); _ = try trigger.seed(nextSourceCount:clock.triggerAcquired)
        pendingPressure.removeAll(); pendingTrigger.removeAll()
        pressureNext = clock.pressureAcquired; triggerNext = clock.triggerAcquired
        clocks[currentKey] = clock; synchronized = true; lastCompleteNs = completedNs
        return packets
    }
    private func values(_ c: USIBLEClock) -> [UInt64] {
        [c.pressureAcquired,c.triggerAcquired,c.pressureOverflow,c.triggerOverflow,c.pressureDisconnected,
         c.triggerDisconnected,c.schedulerSkips,c.pressureNotifyLost,c.triggerNotifyLost,c.notifyCalls,c.notifyFailures,c.disconnects,
         c.t2DeviceUs,c.t3DeviceUs,c.snapshotDeviceUs]
    }
    private mutating func pressurePacket(_ sequence: UInt64, _ sample: USIBLEPressureSample, _ received: UInt64) throws -> USICollectionOutbound {
        guard sequence >= pressureObservedNext, pressureSourceTime == nil || sample.sourceTimeUs >= pressureSourceTime! else { throw USIBLEError.invalid }
        let packet = try USICollectionPackets.pressure(source:source, boot:String(boot), connection:connection,
            phone:phone, samples:[(sequence,sample,received)])
        guard pressureReceived < UInt64.max else { throw USIBLEError.invalid }
        pressureReceived += 1; pressureObservedNext = sequence + 1; pressureSourceTime = sample.sourceTimeUs
        return packet
    }
    private mutating func triggerPacket(_ sequence: UInt64, _ sample: USIBLETrigger, _ received: UInt64) throws -> USICollectionOutbound {
        guard sequence >= triggerObservedNext, triggerSourceTime == nil || sample.sourceTimeUs >= triggerSourceTime! else { throw USIBLEError.invalid }
        let packet = try USICollectionPackets.trigger(source:source, boot:String(boot), connection:connection,
            phone:phone, sequence:sequence, sample:sample, receivedNs:received)
        guard triggerReceived < UInt64.max else { throw USIBLEError.invalid }
        triggerReceived += 1; triggerObservedNext = sequence + 1; triggerSourceTime = sample.sourceTimeUs
        return packet
    }
    func counter(_ stream: USICollectionStream) throws -> USICollectionCounter {
        guard synchronized, let clock = clocks[currentKey], [.pressures,.trigger].contains(stream) else { throw USIBLEError.invalid }
        let p = stream == .pressures
        let metrics = p ? [clock.pressureOverflow,clock.pressureDisconnected,clock.pressureNotifyLost,clock.schedulerSkips]
                        : [clock.triggerOverflow,clock.triggerDisconnected,clock.triggerNotifyLost]
        var loss: UInt64 = 0
        for value in metrics { let (sum,overflow) = loss.addingReportingOverflow(value); guard !overflow else { throw USIBLEError.invalid }; loss = sum }
        var result = USICollectionCounter(stream:stream, sourceID:source, epochID:String(boot))
        result.counts = USIStreamCounters(sourceCount:p ? clock.pressureAcquired : clock.triggerAcquired,
            receivedCount:p ? pressureReceived : triggerReceived, queueOverflowCount:loss, rejectedCount:0, duplicateCount:0)
        return result
    }
}
