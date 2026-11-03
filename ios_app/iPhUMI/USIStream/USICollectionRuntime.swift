import Foundation
import Dispatch

enum USICollectionEffect {
    case requestBLEClock(requestID: UInt32, t1PhoneNs: UInt64)
    case disconnectTransport(reason: String)
}
struct USICollectionSend { let token: UInt64; let packet: USICollectionOutbound }
struct USICameraEncodeTicket: Hashable { let identity: USISampleIdentity; fileprivate let token: UInt64 }
struct USICameraAdmission { let encodeTicket: USICameraEncodeTicket?; let posePacket: USICollectionOutbound }

/// One admission owner for camera callbacks, BLE, user actions, timer, and socket completions.
/// Native adapters supply the same dedicated serial queue as ownerQueue. Tests call serially.
/// No method waits for JPEG, network, another queue, or a BLE response.
final class USICollectionRuntime {
    enum Phase { case live, preparing, beginBarrier, awaitRecording, recording, stopBarrier, finalizing, unknown }
    private enum Boundary { case synchronize, begin, stop }
    private struct ClockRequest { let id: UInt32; let sent: UInt64; let boundary: Boundary }
    private struct EncodeWork { let pose: USICameraPose?; let sourceTimestamp: Double?; let sourceClock: String?; let uptime: UInt64 }
    private struct Request { let packet: USICollectionOutbound; let trial: String; var attempts: Int; var lastSent: UInt64; var acknowledged = false }
    let sessionID: String
    private(set) var worldEpochID: String
    private let ownerQueue: DispatchQueue?
    private let encoderCapacity: Int
    private let barrierTimeoutNs: UInt64
    private var transport: USICollectionTransport
    private var ble: USICollectionBLEProgress
    private var bleConnected = false
    private var nextCamera: UInt64 = 0
    private var nextUltra: UInt64 = 0
    private var ultraEpoch: String?
    private var token: UInt64 = 0
    private var encodeWork: [USICameraEncodeTicket:EncodeWork] = [:]
    private var inFlight: USICollectionSend?
    private var effects: [USICollectionEffect] = []
    private var disconnectedEffect = false
    private var clockID: UInt32 = 0
    private var clockRequest: ClockRequest?
    private var deferredBoundary: Boundary?
    private var requests: [String:Request] = [:]
    private var latestRequestID: String?
    private var prepareRequestID: String?
    private var stopRequestID: String?
    private var beginFences: [USICollectionFence] = []
    private var endFences: [USICollectionFence] = []
    private var cameraBoundary: [USICollectionCounter] = []
    private var beginBaseline: [USICollectionCounter] = []
    private var endSnapshot: [USICollectionCounter] = []
    private var intervalLoss: [USICollectionStream:USIStreamCounters] = [:]
    private var local: [USICollectionStream:USICollectionCounter] = [:]
    private var phoneBLEOverflow: [USICollectionStream:UInt64] = [:]
    private(set) var lastFresh: [USICollectionStream:UInt64] = [:]
    private(set) var phase: Phase = .live
    private(set) var connected = false
    private(set) var frozen: USICollectionSnapshot?
    private(set) var activeTrialID: String?
    private(set) var hostID: String?
    private(set) var hostRevision: UInt64 = 0
    private(set) var hostState: USITrialState = .notConnected
    private(set) var hostVerification: USIVerification = .pending
    private(set) var hostBagPath: String?
    private(set) var hostReceivedNs: UInt64?
    private(set) var hostTimeNs: UInt64?
    private(set) var hostReady = false
    private(set) var hostMissing: [String] = []
    private(set) var excluded: [String] = []
    private(set) var hostCounters: [[String:Any]] = []
    private(set) var unknownReason: String?
    private(set) var recordingStartNs: UInt64?
    private(set) var recordingEndNs: UInt64?
    private(set) var lastSave: USICollectionSave?
    private(set) var seal = USISealModel(calibration:nil)
    private(set) var trigger = USITriggerModel()
    private(set) var configured = USICollectionConfiguration()
    private(set) var rates: [USICollectionStream:USICollectionRates] = [:]
    private(set) var lossTotals: [USICollectionStream:USICollectionLossTotals] = [:]
    private(set) var latestBLESourceProgress: USICollectionBLESourceSnapshot?
    private(set) var latestUSBClock: USICollectionPacket?
    private(set) var latestBLEClock: USICollectionPacket?
    private var reassembler = USIBLEReassembler()
    private var fragmentFirstNs: UInt64?
    private var lastPressure: ([Double],UInt8,UInt64)?
    private var lastTrigger: (Bool,UInt64)?

    init(sessionID: String, worldEpochID: String, ownerQueue: DispatchQueue? = nil,
         encoderCapacity: Int = 4, barrierTimeoutNs: UInt64 = 1_000_000_000,
         transport: USICollectionTransport? = nil) throws {
        guard !sessionID.isEmpty, !worldEpochID.isEmpty, encoderCapacity > 0, barrierTimeoutNs > 0
        else { throw USICollectionError.invalid("invalid runtime configuration") }
        self.sessionID = sessionID; self.worldEpochID = worldEpochID; self.ownerQueue = ownerQueue
        self.encoderCapacity = encoderCapacity; self.barrierTimeoutNs = barrierTimeoutNs
        self.transport = try transport ?? USICollectionTransport(); ble = try USICollectionBLEProgress()
        initializeCameraCounters()
    }
    private func checkOwner() { if let ownerQueue { dispatchPrecondition(condition:.onQueue(ownerQueue)) } }
    private func initializeCameraCounters() {
        for stream in [USICollectionStream.mainRGB,.cameraPose] {
            var c = USICollectionCounter(stream:stream, sourceID:sessionID, epochID:worldEpochID)
            c.counts = USIStreamCounters(sourceCount:0, receivedCount:0, queueOverflowCount:0, rejectedCount:0, duplicateCount:0)
            local[stream] = c; lossTotals[stream] = USICollectionLossTotals()
        }
    }
    private func nextToken() -> UInt64 { precondition(token < UInt64.max); token += 1; return token }
    var outstandingEncodeTickets: [USICameraEncodeTicket] { checkOwner(); return Array(encodeWork.keys) }
    var encodingRecommended: Bool {
        checkOwner(); return connected && unknownReason == nil && ![.stopBarrier,.finalizing,.unknown].contains(phase)
    }
    var beginCounterSnapshot: [USICollectionCounter] { checkOwner(); return beginBaseline }
    var endCounterSnapshot: [USICollectionCounter] { checkOwner(); return endSnapshot }
    var trialLossCounters: [USICollectionStream:USIStreamCounters] { checkOwner(); return intervalLoss }
    var counters: [USICollectionCounter] { checkOwner(); return local.values.sorted { $0.stream.rawValue < $1.stream.rawValue } }
    func takeEffect() -> USICollectionEffect? { checkOwner(); return effects.isEmpty ? nil : effects.removeFirst() }

    func connectHost(capabilities: [USICollectionCapability], nowNs: UInt64) throws {
        checkOwner(); connected = true; disconnectedEffect = false; inFlight = nil; transport.clear()
        if frozen == nil {
            activeTrialID = nil; hostID = nil; hostTimeNs = nil; hostReceivedNs = nil
            hostRevision = 0; hostState = .notConnected; hostVerification = .pending; hostReady = false
        }
        try control(USICollectionPackets.hello(session:sessionID, capabilities:capabilities, profiles:["core","full"]))
        try control(USICollectionPackets.health(session:sessionID,event:"status",message:"",counters:activeCounters()))
        if let trial = activeTrialID, frozen != nil {
            let id = "\(trial):recovery:\(nextToken())"
            try submit(USICollectionPackets.command(action:"status",request:id,trial:trial,revision:hostRevision),trial:trial,now:nowNs)
        }
    }
    func disconnectHost(reason: String) { checkOwner(); connected = false; hostReady = false; transport.clear(); inFlight = nil; failUnknown(reason) }
    func background() { checkOwner(); failUnknown("application backgrounded during unresolved trial") }
    func resetWorld(epochID: String) throws {
        checkOwner(); guard !epochID.isEmpty, epochID != worldEpochID else { throw USICollectionError.invalid("new world epoch required") }
        failUnknown("camera world epoch changed"); worldEpochID = epochID; nextCamera = 0
        encodeWork = encodeWork.filter { $0.key.identity.stream == .ultrawide }
        initializeCameraCounters(); lastFresh[.mainRGB] = nil; lastFresh[.cameraPose] = nil
    }
    func selectCalibration(_ calibration: USIPressureCalibration?) throws {
        checkOwner(); guard frozen == nil else { throw USICollectionError.invalid("trial snapshot frozen") }
        try resetSeal(calibration)
    }
    private func resetSeal(_ calibration: USIPressureCalibration?) throws {
        seal = USISealModel(calibration:calibration,staleNs:configured.pressureStaleNs)
        if let sample = lastPressure { try seal.update(pressuresKPaAbs:sample.0,qualityMask:sample.1,receivedNs:sample.2) }
    }
    func setRates(_ values: USICollectionRates, stream: USICollectionStream) throws {
        checkOwner(); try values.validate(); rates[stream] = values
    }
    func connectBLE(sourceID: String, bootID: UInt32, connectionID: String, nowNs: UInt64) throws {
        checkOwner()
        if bleConnected { failUnknown("BLE connection replaced during trial") }
        let changedEpoch = ble.boot != bootID || ble.source != sourceID
        try ble.connect(source:sourceID,boot:bootID,connection:connectionID,phone:sessionID)
        if changedEpoch {
            phoneBLEOverflow = [:]; local[.pressures] = nil; local[.trigger] = nil
            lossTotals[.pressures] = USICollectionLossTotals(); lossTotals[.trigger] = USICollectionLossTotals()
        }
        invalidateSensors(); latestBLESourceProgress = nil
        bleConnected = true; reassembler = USIBLEReassembler(); fragmentFirstNs = nil
        lastFresh[.pressures] = nil; lastFresh[.trigger] = nil
        try requestClock(.synchronize,now:nowNs)
    }
    func disconnectBLE(reason: String) {
        checkOwner(); bleConnected = false; ble.disconnect(); clockRequest = nil; deferredBoundary = nil
        effects.removeAll { if case .requestBLEClock = $0 { return true }; return false }
        invalidateSensors(); failUnknown(reason)
    }
    private func invalidateSensors() {
        lastFresh[.pressures] = nil; lastFresh[.trigger] = nil; lastPressure = nil; lastTrigger = nil
        seal = USISealModel(calibration:seal.calibration,staleNs:configured.pressureStaleNs)
        trigger = USITriggerModel(staleNs:configured.triggerStaleNs)
    }
    func receiveBLEFragment(_ data: Data, receivedNs: UInt64) throws {
        checkOwner()
        do {
            if data.count > 10, data[8] == 0, data[9] == 0 { fragmentFirstNs = receivedNs }
            let discarded = reassembler.discarded
            let complete = try reassembler.feed(data,receivedNs:receivedNs)
            guard reassembler.discarded == discarded else { throw USIBLEError.invalid }
            if let complete {
                guard let first = fragmentFirstNs else { throw USIBLEError.invalid }
                fragmentFirstNs = nil
                try receiveBLE(USIBLECodec.decode(complete),firstReceivedNs:first,completedNs:receivedNs)
            }
        } catch { fragmentFirstNs = nil; failUnknown("BLE fragment loss or malformed message"); throw error }
    }
    func receiveBLE(_ event: USIBLEEvent, firstReceivedNs: UInt64, completedNs: UInt64) throws {
        checkOwner()
        do {
            guard bleConnected else { throw USIBLEError.invalid }
            if case let .clock(boot,clock) = event {
                guard boot == ble.boot, let request = clockRequest,
                      clock.requestID == request.id, clock.t1PhoneNs == request.sent,
                      completedNs >= request.sent, completedNs-request.sent <= barrierTimeoutNs else { throw USIBLEError.invalid }
                let packets = try ble.barrier(clock,firstReceivedNs:firstReceivedNs,completedNs:completedNs)
                for packet in packets { try sensor(packet) }
                try refreshBLECounters()
                latestBLESourceProgress = USICollectionBLESourceSnapshot(sourceID:ble.source,bootID:boot,
                    connectionID:ble.connection,firstReceivedNs:firstReceivedNs,completedNs:completedNs,clock:clock)
                let (t2,o2) = clock.t2DeviceUs.multipliedReportingOverflow(by:1000)
                let (t3,o3) = clock.t3DeviceUs.multipliedReportingOverflow(by:1000)
                guard !o2, !o3 else { throw USIBLEError.invalid }
                let observation = try USICollectionPackets.clock(link:"ble",exchange:"\(ble.connection):\(clock.requestID)",
                    source:ble.source,epoch:String(boot),times:[clock.t1PhoneNs,t2,t3,firstReceivedNs])
                latestBLEClock = try USICollectionWire.decode(observation.bytes)
                clockRequest = nil
                if phase != .unknown { try control(observation) }
                switch request.boundary {
                case .synchronize:
                    if let deferredBoundary {
                        self.deferredBoundary = nil; try requestClock(deferredBoundary,now:completedNs)
                    } else { try emitHealth("BLE source progress") }
                case .begin: try finishBegin(now:completedNs)
                case .stop: try finishStop(now:completedNs)
                }
            } else {
                for packet in try ble.receive(event,firstReceivedNs:firstReceivedNs,completedNs:completedNs) { try sensor(packet) }
                try refreshBLECounters()
            }
        } catch { ble.disconnect(); invalidateSensors(); failUnknown("BLE progress, epoch, clock, or bounded ingress failure"); throw error }
    }
    private func refreshBLECounters() throws {
        for stream in [USICollectionStream.pressures,.trigger] {
            if ble.synchronized {
                var counter = try ble.counter(stream)
                counter.counts.queueOverflowCount = try addCounts(counter.counts.queueOverflowCount!,phoneBLEOverflow[stream,default:0])
                local[stream] = counter
            }
        }
    }
    private func sensor(_ packet: USICollectionOutbound) throws {
        let decoded = try USICollectionWire.decode(packet.bytes), m = decoded.metadata
        if packet.type == .pressure {
            let samples = m["samples"] as! [[String:Any]]
            for sample in samples {
                let received = (sample["phone_receive_ns"] as! NSNumber).uint64Value
                let values = (sample["pressure_centi_pa"] as! [NSNumber]).map { $0.doubleValue / 100_000 }
                let quality = (sample["quality_mask"] as! NSNumber).uint8Value
                try seal.update(pressuresKPaAbs:values,qualityMask:quality,receivedNs:received)
                lastPressure = (values,quality,received)
                lastFresh[.pressures] = received
            }
        } else {
            let received = (m["phone_receive_ns"] as! NSNumber).uint64Value
            let pressed = m["pressed"] as! Bool
            try trigger.update(pressed:pressed,receivedNs:received); lastFresh[.trigger] = received
            lastTrigger = (pressed,received)
        }
        admit(packet)
    }
    /// Optional periodic progress request. False means a bounded request is already in flight.
    @discardableResult func requestBLEProgress(nowNs: UInt64) throws -> Bool {
        checkOwner(); guard bleConnected, phase != .unknown, clockRequest == nil else { return false }
        try requestClock(.synchronize,now:nowNs); return true
    }
    private func boundaryClock(_ boundary: Boundary, now: UInt64) throws {
        if let pending = clockRequest {
            guard pending.boundary == .synchronize, deferredBoundary == nil else {
                failUnknown("overlapping source boundaries"); throw USICollectionError.invalid("overlapping source boundaries")
            }
            deferredBoundary = boundary
        } else { try requestClock(boundary,now:now) }
    }
    private func requestClock(_ boundary: Boundary, now: UInt64) throws {
        guard bleConnected, clockRequest == nil, clockID < UInt32.max, effects.count < 32 else {
            failUnknown("BLE clock barrier unavailable"); throw USICollectionError.invalid("BLE clock barrier unavailable")
        }
        clockID += 1; clockRequest = ClockRequest(id:clockID,sent:now,boundary:boundary)
        effects.append(.requestBLEClock(requestID:clockID,t1PhoneNs:now))
    }

    /// Assigns acquisition identity before any JPEG work. Pose is immediately validated and queued.
    func admitCamera(pose: USICameraPose) throws -> USICameraAdmission {
        checkOwner(); guard nextCamera < UInt64.max else { failUnknown("camera sequence exhausted"); throw USICollectionError.invalid("camera sequence exhausted") }
        let sequence = nextCamera; nextCamera += 1
        for stream in [USICollectionStream.mainRGB,.cameraPose] { local[stream]!.counts.sourceCount = nextCamera; local[stream]!.counts.receivedCount = nextCamera }
        let packet: USICollectionOutbound
        do { packet = try USICollectionPackets.poses(session:sessionID,epoch:worldEpochID,samples:[(sequence,pose)]) }
        catch {
            loss(.cameraPose,sequence:sequence,rejected:true,kind:.sourceRejection); loss(.mainRGB,sequence:sequence,rejected:true,kind:.sourceRejection)
            try emitHealth("malformed camera pose"); throw error
        }
        lastFresh[.cameraPose] = pose.phoneUptimeNs; admit(packet)
        guard encodingRecommended else { return USICameraAdmission(encodeTicket:nil,posePacket:packet) }
        let identity = try USISampleIdentity(stream:.mainRGB,sourceID:sessionID,epochID:worldEpochID,sequence:sequence)
        guard encodeWork.count < encoderCapacity else {
            loss(.mainRGB,sequence:sequence,rejected:false,kind:.encoderIngressOverflow); try emitHealth("image encoder ingress overflow")
            return USICameraAdmission(encodeTicket:nil,posePacket:packet)
        }
        let ticket = USICameraEncodeTicket(identity:identity,token:nextToken())
        encodeWork[ticket] = EncodeWork(pose:pose,sourceTimestamp:nil,sourceClock:nil,uptime:pose.phoneUptimeNs)
        return USICameraAdmission(encodeTicket:ticket,posePacket:packet)
    }
    func admitUltrawide(epochID: String, sourceTimestampS: Double, sourceClock: String, phoneUptimeNs: UInt64) throws -> USICameraEncodeTicket? {
        checkOwner()
        guard !epochID.isEmpty, !sourceClock.isEmpty, sourceTimestampS.isFinite, sourceTimestampS >= 0 else { throw USICollectionError.invalid("invalid ultrawide source") }
        if ultraEpoch != epochID {
            if ultraEpoch != nil { failUnknown("ultrawide epoch changed") }
            ultraEpoch = epochID; nextUltra = 0
            var c = USICollectionCounter(stream:.ultrawide,sourceID:sessionID,epochID:epochID)
            c.counts = USIStreamCounters(sourceCount:0,receivedCount:0,queueOverflowCount:0,rejectedCount:0,duplicateCount:0); local[.ultrawide] = c; lossTotals[.ultrawide] = USICollectionLossTotals()
        }
        guard nextUltra < UInt64.max else { throw USICollectionError.invalid("ultrawide sequence exhausted") }
        let sequence = nextUltra; nextUltra += 1
        local[.ultrawide]!.counts.sourceCount = nextUltra; local[.ultrawide]!.counts.receivedCount = nextUltra
        guard encodingRecommended else { return nil }
        guard encodeWork.count < encoderCapacity else { loss(.ultrawide,sequence:sequence,rejected:false,kind:.encoderIngressOverflow); try emitHealth("ultrawide encoder ingress overflow"); return nil }
        let ticket = USICameraEncodeTicket(identity:try USISampleIdentity(stream:.ultrawide,sourceID:sessionID,epochID:epochID,sequence:sequence),token:nextToken())
        encodeWork[ticket] = EncodeWork(pose:nil,sourceTimestamp:sourceTimestampS,sourceClock:sourceClock,uptime:phoneUptimeNs)
        return ticket
    }
    /// nil means a real encode failure. Tickets are one-shot; old epoch/duplicate completions throw.
    func completeCamera(ticket: USICameraEncodeTicket, image: USICameraImage?) throws {
        checkOwner(); guard let work = encodeWork.removeValue(forKey:ticket) else { throw USICollectionError.invalid("unknown encode ticket") }
        let id = ticket.identity
        guard local[id.stream]?.epochID == id.epochID else { throw USICollectionError.invalid("retired camera epoch") }
        guard let image else { loss(id.stream,sequence:id.sequence,rejected:true,kind:.encodeFailure); try emitHealth("image encode failed"); return }
        do {
            let c = local[id.stream]!.counts, losses = lossTotals[id.stream,default:USICollectionLossTotals()]
            let packet: USICollectionOutbound
            if let pose = work.pose {
                packet = try USICollectionPackets.mainFrame(session:sessionID,epoch:id.epochID,sequence:id.sequence,
                    pose:pose,image:image,acquired:c.sourceCount!,encodeDrops:losses.encodeDrops,transportDrops:losses.transportOverflows)
            } else {
                packet = try USICollectionPackets.ultrawide(session:sessionID,epoch:id.epochID,sequence:id.sequence,
                    sourceTimestampS:work.sourceTimestamp!,sourceClock:work.sourceClock!,phoneUptimeNs:work.uptime,
                    image:image,acquired:c.sourceCount!,encodeDrops:losses.encodeDrops,transportDrops:losses.transportOverflows)
            }
            lastFresh[id.stream] = work.uptime; admit(packet)
        } catch { loss(id.stream,sequence:id.sequence,rejected:true,kind:.encodeFailure); try emitHealth("malformed encoded camera data"); throw error }
    }
    private func admissible(_ id: USISampleIdentity) -> Bool {
        if let start = beginFences.first(where: { $0.stream == id.stream }) {
            guard start.sourceID == id.sourceID, start.epochID == id.epochID, id.sequence >= start.nextSequence else { return false }
        }
        if let end = endFences.first(where: { $0.stream == id.stream }) {
            guard end.sourceID == id.sourceID, end.epochID == id.epochID, id.sequence < end.nextSequence else { return false }
        }
        return true
    }
    private func admit(_ packet: USICollectionOutbound) {
        guard connected, phase != .unknown, unknownReason == nil, packet.identities.allSatisfy(admissible) else { return }
        if !transport.offer(packet) {
            for id in packet.identities { loss(id.stream,sequence:id.sequence,rejected:false) }
            // Preserve explicit evidence; an unavailable control lane invalidates the transport.
            do { try emitHealth("bounded transport lane overflow") } catch { failUnknown("health control queue overflow") }
        }
    }
    private func loss(_ stream: USICollectionStream, sequence: UInt64, rejected: Bool, kind: USICollectionLossKind = .transportOverflow) {
        if local[stream] != nil {
            let previous = rejected ? local[stream]!.counts.rejectedCount! : local[stream]!.counts.queueOverflowCount!
            guard previous < UInt64.max else { failUnknown("loss counter exhausted"); return }
            if rejected { local[stream]!.counts.rejectedCount = previous + 1 }
            else { local[stream]!.counts.queueOverflowCount = previous + 1 }
        }
        var totals = lossTotals[stream,default:USICollectionLossTotals()]
        switch kind {
        case .encoderIngressOverflow: totals.encoderIngressOverflows += 1
        case .encodeFailure: totals.encodeFailures += 1
        case .sourceRejection: totals.sourceRejections += 1
        case .transportOverflow: totals.transportOverflows += 1
        }
        lossTotals[stream] = totals
        if [.pressures,.trigger].contains(stream), !rejected { phoneBLEOverflow[stream,default:0] += 1 }
        guard let start = beginFences.first(where:{ $0.stream == stream }), sequence >= start.nextSequence,
              endFences.first(where:{ $0.stream == stream }).map({ sequence < $0.nextSequence }) ?? true else { return }
        var c = intervalLoss[stream,default:USIStreamCounters(queueOverflowCount:0,rejectedCount:0)]
        if rejected { c.rejectedCount! += 1 } else { c.queueOverflowCount! += 1 }
        intervalLoss[stream] = c
    }
    private func control(_ packet: USICollectionOutbound) throws {
        guard connected else { throw USICollectionError.invalid("host disconnected") }
        guard transport.offer(packet) else { failUnknown("bounded control lane overflow"); throw USICollectionError.invalid("bounded control lane overflow") }
    }
    private func addCounts(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
        let (sum,overflow) = a.addingReportingOverflow(b)
        guard !overflow else { throw USICollectionError.invalid("source loss counter cannot be represented") }
        return sum
    }
    private func prefixCounters(_ entries: [USICollectionCounter]) -> [USICollectionCounter] {
        entries.map { entry in
            var c = entry
            if encodeWork.keys.contains(where: { $0.identity.stream == entry.stream &&
                $0.identity.epochID == entry.epochID && $0.identity.sequence < (entry.counts.sourceCount ?? 0) }) {
                // Pending encodes can still fail or overflow transport. Their final cumulative
                // source-prefix loss total cannot be known at this acquisition boundary.
                c.counts.rejectedCount = nil; c.counts.queueOverflowCount = nil
            }
            return c
        }
    }
    private func activeCounters() -> [USICollectionCounter] {
        endSnapshot.isEmpty ? prefixCounters(counters) : endSnapshot
    }
    private func emitHealth(_ reason: String) throws {
        guard connected, phase != .unknown else { return }
        // Begin baseline and Stop snapshots are emitted by the boundary transaction itself.
        guard phase != .beginBarrier, phase != .stopBarrier else { return }
        try control(USICollectionPackets.health(session:sessionID,event:"status",message:reason,counters:activeCounters()))
    }
    func takeNext() -> USICollectionSend? {
        checkOwner(); guard connected, inFlight == nil else { return nil }
        let allowed = phase != .beginBarrier && phase != .stopBarrier && phase != .unknown && unknownReason == nil
        guard let packet = transport.takeNext(allowData:allowed) else { return nil }
        let send = USICollectionSend(token:nextToken(),packet:packet); inFlight = send; return send
    }
    func sendCompleted(token: UInt64, succeeded: Bool) {
        checkOwner(); guard inFlight?.token == token else { return }
        inFlight = nil
        if !succeeded { connected = false; transport.clear(); failUnknown("socket send failed") }
    }

    func prepare(snapshot: USICollectionSnapshot, trialID: String, requestID: String, nowNs: UInt64) throws {
        checkOwner()
        let priorRevision: UInt64
        if let previous = requests[requestID] {
            let m = try USICollectionWire.decode(previous.packet.bytes).metadata
            priorRevision = (m["expected_revision"] as! NSNumber).uint64Value
        } else { priorRevision = hostRevision }
        let command = try USICollectionPackets.prepare(request:requestID,trial:trialID,revision:priorRevision,snapshot:snapshot)
        if let previous = requests[requestID] {
            guard previous.packet.bytes == command.bytes, previous.trial == trialID else { throw USICollectionError.invalid("request ID reused with changed contents") }
            _ = try retry(requestID:requestID,nowNs:nowNs); return
        }
        guard frozen == nil, snapshot.sessionID == sessionID, ready(snapshot,now:nowNs).isEmpty else { throw USICollectionError.invalid("collection not ready or snapshot frozen") }
        try validateSnapshotIdentities(snapshot)
        if activeTrialID != trialID { hostID = nil; hostTimeNs = nil }
        frozen = snapshot; configured = snapshot.configuration; activeTrialID = trialID; phase = .preparing
        prepareRequestID = requestID; stopRequestID = nil; unknownReason = nil
        recordingStartNs = nil; recordingEndNs = nil; beginFences = []; endFences = []
        beginBaseline = []; endSnapshot = []; intervalLoss = [:]
        try resetSeal(snapshot.calibration)
        trigger = USITriggerModel(staleNs:configured.triggerStaleNs)
        if let lastTrigger { try trigger.update(pressed:lastTrigger.0,receivedNs:lastTrigger.1) }
        try submit(command,trial:trialID,now:nowNs)
    }
    private func validateSnapshotIdentities(_ snapshot: USICollectionSnapshot) throws {
        for stream in fenceStreams(snapshot) {
            guard let cap = snapshot.capabilities.first(where:{$0.stream == stream}),
                  let actual = local[stream], cap.sourceID == actual.sourceID, cap.epochID == actual.epochID
            else { throw USICollectionError.invalid("capability source epoch differs from live source") }
        }
    }
    private func fenceStreams(_ snapshot: USICollectionSnapshot) -> [USICollectionStream] {
        snapshot.profile == "full" ? [.mainRGB,.cameraPose,.ultrawide,.pressures,.trigger] : [.mainRGB,.cameraPose,.pressures,.trigger]
    }
    private func cameraSnapshot() -> [USICollectionCounter] {
        guard let frozen else { return [] }
        return prefixCounters(fenceStreams(frozen).filter { ![.pressures,.trigger].contains($0) }.compactMap { local[$0] })
    }
    private func makeFences(_ entries: [USICollectionCounter]) throws -> [USICollectionFence] {
        try entries.map {
            guard let count = $0.counts.sourceCount else { throw USICollectionError.invalid("unknown acquisition fence") }
            return try USICollectionFence(stream:$0.stream,sourceID:$0.sourceID,epochID:$0.epochID,nextSequence:count)
        }
    }
    private func startBegin(now: UInt64) throws {
        guard phase == .preparing, let snapshot = frozen else { return }
        try validateSnapshotIdentities(snapshot)
        phase = .beginBarrier; cameraBoundary = cameraSnapshot(); beginFences = try makeFences(cameraBoundary)
        intervalLoss = [:]
        guard ble.synchronized, readySources(snapshot,now:now).isEmpty else { failUnknown("source stale at Begin"); return }
        try boundaryClock(.begin,now:now)
    }
    private func finishBegin(now: UInt64) throws {
        guard phase == .beginBarrier, let trial = activeTrialID, let prepare = prepareRequestID else { return }
        let sensorCounters = try [USICollectionStream.pressures,.trigger].map { try ble.counter($0) }.map { c -> USICollectionCounter in
            var result = c; result.counts.queueOverflowCount = try addCounts(result.counts.queueOverflowCount!,phoneBLEOverflow[c.stream,default:0]); return result
        }
        beginBaseline = cameraBoundary + sensorCounters
        beginFences = try makeFences(beginBaseline)
        transport.retainData(where:admissible)
        try control(USICollectionPackets.health(session:sessionID,event:"status",message:"begin source baseline",counters:beginBaseline))
        try submit(USICollectionPackets.command(action:"begin",request:"\(prepare):begin",trial:trial,revision:hostRevision,fences:beginFences),trial:trial,now:now)
        phase = .awaitRecording
    }
    func stop(requestID: String, nowNs: UInt64) throws {
        checkOwner(); guard frozen != nil else { return }
        if [.stopBarrier,.finalizing,.unknown].contains(phase) { return }
        recordingEndNs = nowNs
        guard phase == .recording else { failUnknown("Stop before acknowledged Recording; outcome unresolved"); return }
        phase = .stopBarrier; stopRequestID = requestID; cameraBoundary = cameraSnapshot()
        endFences = try makeFences(cameraBoundary)
        guard bleConnected, ble.synchronized, let snapshot = frozen, readySources(snapshot,now:nowNs).isEmpty else {
            failUnknown("Stop cannot obtain a fresh BLE end barrier"); return
        }
        try boundaryClock(.stop,now:nowNs)
    }
    private func finishStop(now: UInt64) throws {
        guard phase == .stopBarrier, let trial = activeTrialID, let request = stopRequestID else { return }
        let sensorCounters = try [USICollectionStream.pressures,.trigger].map { stream -> USICollectionCounter in
            var c = try ble.counter(stream); c.counts.queueOverflowCount = try addCounts(c.counts.queueOverflowCount!,phoneBLEOverflow[stream,default:0]); return c
        }
        endSnapshot = cameraBoundary + sensorCounters
        endFences = try makeFences(endSnapshot)
        guard endFences.allSatisfy({ end in beginFences.contains { start in
            start.stream == end.stream && start.sourceID == end.sourceID && start.epochID == end.epochID && end.nextSequence >= start.nextSequence
        } }) else { failUnknown("source epoch or progress changed across trial"); return }
        transport.retainData(where:admissible)
        try submit(USICollectionPackets.command(action:"stop",request:request,trial:trial,revision:hostRevision,
            fences:endFences,counters:activeCounters()),trial:trial,now:now)
        phase = .finalizing
    }
    private func submit(_ packet: USICollectionOutbound, trial: String, now: UInt64) throws {
        guard let id = packet.requestID else { throw USICollectionError.invalid("request ID required") }
        if let previous = requests[id] {
            guard previous.packet.bytes == packet.bytes else { throw USICollectionError.invalid("request ID conflict") }
            _ = try retry(requestID:id,nowNs:now); return
        }
        guard requests.count < 4096 else { failUnknown("request ledger exhausted"); throw USICollectionError.invalid("request ledger exhausted") }
        try control(packet); requests[id] = Request(packet:packet,trial:trial,attempts:1,lastSent:now); latestRequestID = id
    }
    @discardableResult func retry(requestID: String, nowNs: UInt64) throws -> Bool {
        checkOwner(); guard var request = requests[requestID], request.attempts < 3, connected else { return false }
        let action = try USICollectionWire.decode(request.packet.bytes).metadata["action"] as? String
        guard phase != .unknown || action == "status" else { return false }
        try control(request.packet); request.attempts += 1; request.lastSent = nowNs; requests[requestID] = request; return true
    }
    @discardableResult func receiveHost(_ packet: USICollectionPacket, receivedNs: UInt64) throws -> Bool {
        checkOwner(); guard connected else { return false }
        _ = try USICollectionWire.encode(type:packet.type,metadata:packet.metadata,payload:packet.payload)
        if packet.type == .hello { return packet.metadata["role"] as? String == "host" }
        if packet.type == .bleClock {
            guard packet.metadata["link"] as? String == "usb", packet.metadata["source_id"] as? String == sessionID,
                  packet.metadata["epoch_id"] as? String == sessionID else { return false }
            latestUSBClock = packet; return true // Persist/display; never echo a completed USB observation.
        }
        guard packet.type == .trialStatus else { return false }
        let m = packet.metadata, host = m["host_session_id"] as! String
        let trial = m["trial_id"] as? String, request = m["request_id"] as? String
        let revision = (m["revision"] as! NSNumber).uint64Value, time = (m["host_time_ns"] as! NSNumber).uint64Value
        let state = USITrialState(rawValue:m["state"] as! String)!, verification = USIVerification(rawValue:m["verification"] as! String)!
        if let activeTrialID, trial != activeTrialID { return false }
        if let request, requests[request]?.trial != trial { return false }
        if let previous = hostID, previous != host, frozen != nil, state != .incomplete { return false }
        if hostID == host {
            if let last = hostReceivedNs, receivedNs < last { return false }
            if revision < hostRevision { return false }
            if let hostTimeNs, time <= hostTimeNs { return false }
            if revision == hostRevision && (state != hostState || verification != hostVerification || (m["bag_path"] as? String) != hostBagPath) { return false }
        }
        if [.finalizing,.unknown].contains(phase), [.preparing,.recording].contains(state) { return false }
        if [.saved,.incomplete].contains(hostState), frozen == nil, activeTrialID != nil, state != hostState { return false }
        if state == .recording, ![.awaitRecording,.recording].contains(phase) { return false }
        if let snapshot = frozen {
            guard m["profile"] as? String == snapshot.profile,
                  Set(m["required_streams"] as! [String]) == Set(snapshot.requiredStreams),
                  Set(m["missing_modalities"] as! [String]) == Set(snapshot.profile == "core" ? ["ultrawide"] : []) else { return false }
        }
        if state == .saved, knownTrialLoss() {
            failUnknown("host Saved conflicts with known trial source loss"); return false
        }
        hostID = host; hostRevision = revision; hostState = state; hostVerification = verification
        hostBagPath = m["bag_path"] as? String; hostReceivedNs = receivedNs; hostTimeNs = time
        hostReady = m["ready"] as! Bool; hostMissing = m["missing_required_streams"] as! [String]
        excluded = m["missing_modalities"] as! [String]; hostCounters = m["counters"] as! [[String:Any]]
        if let request { requests[request]?.acknowledged = true }
        if state == .preparing { try startBegin(now:receivedNs) }
        if state == .recording {
            phase = .recording
            if recordingStartNs == nil { recordingStartNs = receivedNs }
            if let prepareRequestID { requests["\(prepareRequestID):begin"]?.acknowledged = true }
        }
        if state == .finalizing { if unknownReason == nil { phase = .finalizing }; if let stopRequestID { requests[stopRequestID]?.acknowledged = true } }
        if [.saved,.incomplete].contains(state) {
            if state == .saved { lastSave = USICollectionSave(trialID:trial!,bagPath:hostBagPath!) }
            frozen = nil; phase = .live; unknownReason = nil; clockRequest = nil
            beginFences = []; endFences = []; beginBaseline = []; endSnapshot = []; intervalLoss = [:]
            transport.retainData(where:{ _ in false })
        }
        return true
    }
    private func knownTrialLoss() -> Bool {
        if intervalLoss.values.contains(where: { ($0.queueOverflowCount ?? 0) > 0 || ($0.rejectedCount ?? 0) > 0 }) { return true }
        for end in endSnapshot where [.pressures,.trigger].contains(end.stream) {
            guard let baseline = beginBaseline.first(where:{$0.stream == end.stream}) else { continue }
            for (before,after) in [(baseline.counts.queueOverflowCount,end.counts.queueOverflowCount),
                                   (baseline.counts.rejectedCount,end.counts.rejectedCount)] {
                if let before, let after, after > before { return true }
            }
        }
        return false
    }
    func replyToPing(_ packet: USICollectionPacket, receivedNs: UInt64, sentNs: UInt64) throws {
        checkOwner(); guard packet.type == .ping else { throw USICollectionError.invalid("PING required") }
        _ = try USICollectionWire.encode(type:.ping,metadata:packet.metadata)
        try control(USICollectionPackets.pong(session:sessionID,pingID:(packet.metadata["ping_id"] as! NSNumber).uint64Value,
            hostSendNs:(packet.metadata["host_send_ns"] as! NSNumber).uint64Value,receivedNs:receivedNs,sentNs:sentNs))
    }
    func tick(nowNs: UInt64) {
        checkOwner()
        if let request = clockRequest, nowNs >= request.sent, nowNs-request.sent > barrierTimeoutNs {
            clockRequest = nil; ble.disconnect(); failUnknown("BLE clock barrier timed out; source end fences unknown"); return
        }
        if phase == .recording, let frozen {
            let missing = readySources(frozen,now:nowNs,grace:configured.mandatoryStaleGraceNs)
            if !missing.isEmpty { failUnknown("required source stale beyond grace: \(missing.joined(separator:", "))"); return }
        }
        if let id = latestRequestID, let request = requests[id], !request.acknowledged,
           nowNs >= request.lastSent, nowNs-request.lastSent >= configured.hostHeartbeatNs {
            if request.attempts >= 3 { failUnknown("host acknowledgment retry budget exhausted") }
            else { do { _ = try retry(requestID:id,nowNs:nowNs) } catch { failUnknown("host retry failed") } }
        }
    }
    private func failUnknown(_ reason: String) {
        guard frozen != nil else {
            if !disconnectedEffect, connected { effects.append(.disconnectTransport(reason:reason)); disconnectedEffect = true }
            connected = false; hostReady = false; transport.clear(); inFlight = nil
            clockRequest = nil; deferredBoundary = nil
            effects.removeAll { if case .requestBLEClock = $0 { return true }; return false }
            return
        }
        if unknownReason == nil { unknownReason = reason }
        phase = .unknown; clockRequest = nil; deferredBoundary = nil; transport.clear(); hostReady = false
        effects.removeAll { if case .requestBLEClock = $0 { return true }; return false }
        if !disconnectedEffect { effects.append(.disconnectTransport(reason:reason)); disconnectedEffect = true }
    }
    func readySources(_ snapshot: USICollectionSnapshot, now: UInt64, grace: UInt64 = 0) -> [String] {
        fenceStreams(snapshot).compactMap { stream in
            let stale = stream == .pressures ? snapshot.configuration.pressureStaleNs : stream == .trigger ? snapshot.configuration.triggerStaleNs : snapshot.configuration.visionStaleNs
            guard let time = lastFresh[stream], now >= time else { return stream.rawValue }
            let age = now-time
            return age <= stale || age-stale <= grace ? nil : stream.rawValue
        }
    }
    func ready(_ snapshot: USICollectionSnapshot, now: UInt64) -> [String] {
        var reasons = readySources(snapshot,now:now)
        if !connected || !hostReady || !hostFresh(now) { reasons.append("host unavailable or stale") }
        if !bleConnected || !ble.synchronized { reasons.append("BLE progress unsynchronized") }
        for stream in snapshot.requiredStreams {
            if !snapshot.capabilities.contains(where:{$0.stream.rawValue == stream && $0.available}) { reasons.append(stream) }
        }
        return reasons
    }
    func sealSnapshot(now: UInt64) -> USISealSnapshot { checkOwner(); return seal.snapshot(nowNs:now) }
    func hostFresh(_ now: UInt64) -> Bool {
        guard let time = hostReceivedNs, now >= time else { return false }
        return now-time <= configured.hostStatusStaleNs
    }
}
