import Foundation

private func collectionCheck(_ condition: Bool, _ message: String) throws {
    if !condition { throw USICollectionError.invalid(message) }
}
private func collectionFresh(_ received: UInt64?, _ now: UInt64, _ stale: UInt64) -> Bool {
    guard let received, received <= now else { return false }
    return now-received <= stale
}

enum USICollectionStream: String, CaseIterable, Codable {
    case mainRGB="main_rgb", rawDepth="raw_depth", depthConfidence="depth_confidence", cameraPose="camera_pose"
    case tracking, cameraCalibration="camera_calibration", ultrawide, pressures, trigger, seal
    case trialMetadata="trial_metadata", timing, health, pumpCommand="pump_command", pumpFeedback="pump_feedback", tcp
    case rawIMU="raw_imu", audio
}
struct USISampleIdentity: Equatable, Hashable {
    let stream: USICollectionStream
    let sourceID: String
    let epochID: String
    let sequence: UInt64
    init(stream: USICollectionStream, sourceID: String, epochID: String, sequence: UInt64) throws {
        try collectionCheck(!sourceID.isEmpty && !epochID.isEmpty,"invalid identity")
        self.stream=stream; self.sourceID=sourceID; self.epochID=epochID; self.sequence=sequence
    }
}
struct USIStreamCounters: Equatable {
    var sourceCount: UInt64? = nil
    var receivedCount: UInt64? = nil
    var writerAcceptedCount: UInt64? = nil
    var queueOverflowCount: UInt64? = nil
    var rejectedCount: UInt64? = nil
    var duplicateCount: UInt64? = nil
}
struct USIChamberCalibration: Equatable {
    let sensorIndex: Int
    let sectorIndex: Int
    let sealOnKPaAbs: Double
    let sealOffKPaAbs: Double
    let persistenceNs: UInt64
    init(sensorIndex: Int, sectorIndex: Int, sealOnKPaAbs: Double, sealOffKPaAbs: Double, persistenceNs: UInt64) throws {
        try collectionCheck((0..<3).contains(sensorIndex) && (0..<3).contains(sectorIndex),"invalid chamber mapping")
        try collectionCheck(sealOnKPaAbs.isFinite && sealOffKPaAbs.isFinite && sealOnKPaAbs >= 0 && sealOnKPaAbs < sealOffKPaAbs,"invalid thresholds")
        self.sensorIndex=sensorIndex; self.sectorIndex=sectorIndex; self.sealOnKPaAbs=sealOnKPaAbs
        self.sealOffKPaAbs=sealOffKPaAbs; self.persistenceNs=persistenceNs
    }
}
struct USIPressureCalibration: Equatable {
    let id: String
    /// Array order is C1,C2,C3; sectorIndex assigns each chamber's 120° sector.
    let chambers: [USIChamberCalibration]
    init(id: String, chambers: [USIChamberCalibration]) throws {
        try collectionCheck(!id.isEmpty && chambers.count == 3 && Set(chambers.map(\.sensorIndex)) == Set(0..<3) &&
            Set(chambers.map(\.sectorIndex)) == Set(0..<3),"invalid calibration mapping")
        self.id=id; self.chambers=chambers
    }
}
enum USISealChannelState: String { case unknown, stale, invalid, uncalibrated, sealed, unsealed }
enum USISealAggregate: String { case unavailable, none, partial, full }
struct USISealSnapshot {
    let states: [USISealChannelState]
    let aggregate: USISealAggregate
    let sealedCount: Int
    let knownCount: Int
    let pressuresKPaAbs: [Double?]
    let calibrationID: String?
}
struct USISealModel {
    let calibration: USIPressureCalibration?
    let staleNs: UInt64
    private var receivedNs: UInt64?
    private var pressures=[Double](repeating:0,count:3)
    private var qualityMask: UInt8=0
    private var sealed=[Bool](repeating:false,count:3)
    private var pending: [(Bool,UInt64)?]=[nil,nil,nil]
    init(calibration: USIPressureCalibration?, staleNs: UInt64 = 250_000_000) {
        self.calibration=calibration; self.staleNs=staleNs
    }
    private mutating func advance(_ now: UInt64) {
        guard collectionFresh(receivedNs,now,staleNs) else {
            sealed=[false,false,false]; pending=[nil,nil,nil]; return
        }
        guard let calibration else { return }
        for index in 0..<3 {
            if let candidate=pending[index], now >= candidate.1 && now-candidate.1 >= calibration.chambers[index].persistenceNs {
                sealed[index]=candidate.0; pending[index]=nil
            }
        }
    }
    mutating func update(pressuresKPaAbs: [Double], qualityMask: UInt8, receivedNs: UInt64) throws {
        try collectionCheck(pressuresKPaAbs.count == 3 && qualityMask <= 7 && (self.receivedNs == nil || receivedNs >= self.receivedNs!),"invalid pressure sample")
        advance(receivedNs)
        self.receivedNs=receivedNs; pressures=pressuresKPaAbs; self.qualityMask=qualityMask
        guard let calibration else { return }
        for index in 0..<3 {
            let chamber=calibration.chambers[index], pressure=pressures[chamber.sensorIndex]
            guard qualityMask & (1 << chamber.sensorIndex) != 0 && pressure.isFinite && pressure >= 0 else {
                sealed[index]=false; pending[index]=nil; continue
            }
            var target=sealed[index]
            if pressure <= chamber.sealOnKPaAbs { target=true }
            else if pressure >= chamber.sealOffKPaAbs { target=false }
            if target == sealed[index] { pending[index]=nil }
            else if pending[index] == nil || pending[index]!.0 != target { pending[index]=(target,receivedNs) }
        }
        advance(receivedNs)
    }
    mutating func snapshot(nowNs: UInt64) -> USISealSnapshot {
        advance(nowNs)
        var states=[USISealChannelState](), numbers=[Double?]()
        for index in 0..<3 {
            let sensor=calibration?.chambers[index].sensorIndex ?? index, pressure=pressures[sensor]
            let valid=qualityMask & (1 << sensor) != 0 && pressure.isFinite && pressure >= 0
            let fresh=collectionFresh(receivedNs,nowNs,staleNs)
            numbers.append(fresh && valid ? pressure : nil)
            if receivedNs == nil { states.append(.unknown) }
            else if !fresh { states.append(.stale) }
            else if !valid { states.append(.invalid) }
            else if calibration == nil { states.append(.uncalibrated) }
            else { states.append(sealed[index] ? .sealed : .unsealed) }
        }
        let known=states.filter { $0 == .sealed || $0 == .unsealed }.count, count=states.filter { $0 == .sealed }.count
        let aggregate: USISealAggregate = known < 3 ? .unavailable : count == 3 ? .full : count == 0 ? .none : .partial
        return USISealSnapshot(states:states,aggregate:aggregate,sealedCount:count,knownCount:known,
            pressuresKPaAbs:numbers,calibrationID:calibration?.id)
    }
}
enum USISuctionState: String { case unknown, on, off }
struct USITriggerModel {
    let staleNs: UInt64
    private var receivedNs: UInt64?
    private var pressed=false
    init(staleNs: UInt64 = 1_000_000_000) { self.staleNs=staleNs }
    mutating func update(pressed: Bool, receivedNs: UInt64) throws {
        try collectionCheck(self.receivedNs == nil || receivedNs >= self.receivedNs!,"out-of-order trigger")
        self.pressed=pressed; self.receivedNs=receivedNs
    }
    func state(nowNs: UInt64) -> USISuctionState {
        guard collectionFresh(receivedNs,nowNs,staleNs) else { return .unknown }
        return pressed ? .off : .on
    }
}
enum USISequenceDisposition: String { case newEpoch="new_epoch", accepted, duplicate, outOfOrder="out_of_order", oldEpoch="old_epoch" }
struct USISequenceObservation { let disposition: USISequenceDisposition; let sequence: UInt64; let missing: Range<UInt64>? }
struct USISequenceHistory {
    let modulus: UInt64
    let maxEpochs: Int
    private var epoch: String?
    private var sequence: UInt64=0
    private var seen=Set<String>()
    // UInt64.max cannot represent 2^64; use nonwrapping frame_seq directly for camera identities.
    init(modulus: UInt64 = 1 << 32, maxEpochs: Int = 64) {
        self.modulus=modulus; self.maxEpochs=maxEpochs
    }
    mutating func observe(epoch: String, rawSequence: UInt64) throws -> USISequenceObservation {
        try collectionCheck(modulus >= 2 && modulus % 2 == 0 && maxEpochs > 0 && !epoch.isEmpty && rawSequence < modulus,"invalid sequence/history")
        if epoch != self.epoch {
            if seen.contains(epoch) { return USISequenceObservation(disposition:.oldEpoch,sequence:rawSequence,missing:nil) }
            try collectionCheck(seen.count < maxEpochs,"epoch history exhausted")
            seen.insert(epoch); self.epoch=epoch; sequence=rawSequence
            return USISequenceObservation(disposition:.newEpoch,sequence:sequence,missing:nil)
        }
        let lastRaw=sequence % modulus
        let delta=rawSequence >= lastRaw ? rawSequence-lastRaw : modulus-(lastRaw-rawSequence)
        if delta == 0 { return USISequenceObservation(disposition:.duplicate,sequence:sequence,missing:nil) }
        if delta >= modulus/2 { return USISequenceObservation(disposition:.outOfOrder,sequence:rawSequence,missing:nil) }
        let (extended,overflow)=sequence.addingReportingOverflow(delta)
        try collectionCheck(!overflow,"extended sequence overflow")
        let missing: Range<UInt64>? = delta > 1 ? sequence+1..<extended : nil
        sequence=extended
        return USISequenceObservation(disposition:.accepted,sequence:sequence,missing:missing)
    }
}
/// Single-owner FIFO. Rejects newest on overflow; each caller owns synchronization.
struct USIBoundedQueue<Element> {
    let capacity: Int
    private(set) var overflowCount: UInt64=0
    private var slots: [Element?]
    private var head=0
    private(set) var count=0
    init(capacity: Int) throws {
        try collectionCheck(capacity > 0,"invalid queue capacity")
        self.capacity=capacity; slots=Array(repeating:nil,count:capacity)
    }
    mutating func offer(_ item: Element) -> Bool {
        if count == capacity { if overflowCount < UInt64.max { overflowCount += 1 }; return false }
        slots[(head+count)%capacity]=item; count += 1; return true
    }
    mutating func pop() -> Element? {
        guard count > 0 else { return nil }
        let item=slots[head]; slots[head]=nil; head=(head+1)%capacity; count -= 1; return item
    }
}
enum USITrialState: String {
    case notConnected="not_connected", idle, preparing, recording, finalizing, saved, incomplete, hostStale="host_stale"
}
enum USIVerification: String { case pending, passed, failed }
struct USITrialModel {
    let hostStaleNs: UInt64
    private(set) var hostSessionID: String?
    private(set) var trialID: String?
    private(set) var revision: UInt64?
    private(set) var state: USITrialState = .notConnected
    private(set) var verification: USIVerification = .pending
    private var receivedNs: UInt64?
    private var requestID: String?
    private var retiredHosts=Set<String>()
    init(hostStaleNs: UInt64 = 2_000_000_000) { self.hostStaleNs=hostStaleNs }
    mutating func beginRequest(requestID: String, trialID: String) throws {
        try collectionCheck(!requestID.isEmpty && !trialID.isEmpty,"invalid request")
        if requestID == self.requestID { try collectionCheck(trialID == self.trialID,"request reused"); return }
        try collectionCheck([.notConnected,.idle,.saved,.incomplete].contains(state),"trial already active")
        self.requestID=requestID; self.trialID=trialID; state = .preparing; revision=nil; receivedNs=nil; verification = .pending
    }
    @discardableResult
    mutating func applyStatus(hostSessionID: String, trialID: String?, revision: UInt64, state: USITrialState,
                             verification: USIVerification, receivedNs: UInt64) throws -> Bool {
        try collectionCheck(!hostSessionID.isEmpty && ![.notConnected,.hostStale].contains(state),"invalid status")
        try collectionCheck(state != .saved || verification == .passed,"saved needs verification")
        try collectionCheck(verification != .passed || state == .saved,"passed needs saved")
        try collectionCheck(state == .idle || (trialID != nil && !trialID!.isEmpty),"active trial needs ID")
        if [.saved,.incomplete].contains(self.state) && state != self.state { return false }
        if self.state == .finalizing && [.idle,.preparing,.recording].contains(state) { return false }
        if let expected=self.trialID, trialID != expected { return false }
        if retiredHosts.contains(hostSessionID) { return false }
        if self.hostSessionID == hostSessionID {
            if let previous=receivedNsValue, receivedNs < previous { return false }
            if let previous=self.revision {
                if [.saved,.incomplete].contains(self.state) && state != self.state { return false }
                if revision < previous { return false }
                if revision == previous && (state != self.state || verification != self.verification) { return false }
            }
        } else if let previous=self.hostSessionID {
            try collectionCheck(retiredHosts.count < 64,"host history exhausted")
            if [.preparing,.recording,.finalizing].contains(self.state) && state != .incomplete { return false }
            retiredHosts.insert(previous)
        }
        self.hostSessionID=hostSessionID; self.trialID=trialID; self.revision=revision
        self.state=state; self.verification=verification; self.receivedNs=receivedNs; return true
    }
    private var receivedNsValue: UInt64? { receivedNs }
    func displayState(nowNs: UInt64) -> USITrialState {
        guard receivedNs != nil else { return state }
        return collectionFresh(receivedNs,nowNs,hostStaleNs) ? state : .hostStale
    }
}
