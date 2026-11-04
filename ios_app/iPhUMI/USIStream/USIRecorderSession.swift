import Foundation
import Network

/// Native port-5559 adapter. Every method/callback shares the ARKit/BLE owner queue.
/// Trial assurance, bounded admission, fences and retries belong to the tested runtime.
final class USIRecorderSession {
    let runtime: USICollectionRuntime
    var requestClock: ((UInt32, UInt64) -> Bool)?
    var onStatus: ((String) -> Void)?
    var targetFPS: Double = 60
    private let queue: DispatchQueue
    private var listener: NWListener?
    private var client: NWConnection?
    private var generation = UUID()
    private var sending = false
    private var helloReceived = false
    private var receiveToken = UUID()
    private var boot: UInt32?
    private var bleSource = ""
    private var bleConnection = UUID().uuidString
    private var sawCamera = false
    private var sawDepth = false
    private var sawConfidence = false
    private var lastProgressNs: UInt64 = 0
    private var statusText = "Recorder USB ready — waiting for Ubuntu"

    init(queue: DispatchQueue, epochID: String) throws {
        self.queue = queue
        runtime = try USICollectionRuntime(sessionID: UUID().uuidString, worldEpochID: epochID, ownerQueue: queue)
    }
    private var now: UInt64 { DispatchTime.now().uptimeNanoseconds }
    private func owner() { dispatchPrecondition(condition: .onQueue(queue)) }
    private func status(_ value: String) { statusText = value; onStatus?(value) }

    func start(epochID: String, fps: Double) {
        owner(); targetFPS = fps
        if runtime.worldEpochID != epochID {
            do { try runtime.resetWorld(epochID: epochID) }
            catch { status("Recorder world reset failed: \(error)") }
            sawCamera = false; sawDepth = false; sawConfidence = false
            pump()
        }
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 5559)
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                if case .ready = state { self.status("Recorder USB ready — waiting for Ubuntu") }
                if case .failed(let error) = state { self.status("Recorder listener failed: \(error.localizedDescription)") }
            }
            listener.newConnectionHandler = { [weak self] in self?.accept($0) }
            listener.start(queue: queue)
        } catch { status("Recorder listener failed: \(error.localizedDescription)") }
    }

    func stop() {
        owner(); runtime.background(); close(reason: "Collection left or app backgrounded")
        listener?.cancel(); listener = nil
    }

    func subscribed(sourceID: String) {
        owner(); boot = nil; bleSource = sourceID; bleConnection = UUID().uuidString
    }
    func disconnectedBLE() {
        owner(); boot = nil; runtime.disconnectBLE(reason: "Pressure rig disconnected"); pump()
    }
    func rejectedBLE() {
        owner(); boot = nil; bleConnection = UUID().uuidString
        runtime.disconnectBLE(reason: "BLE packet loss or malformed telemetry"); pump()
    }
    func receiveBLE(_ event: USIBLEEvent, first: UInt64, completed: UInt64) {
        owner()
        do {
            let eventBoot: UInt32
            switch event { case .pressure(let b,_), .trigger(let b,_), .clock(let b,_): eventBoot = b }
            if boot == nil {
                guard !bleSource.isEmpty else { return }
                boot = eventBoot
                try runtime.connectBLE(sourceID: bleSource, bootID: eventBoot,
                    connectionID: bleConnection, nowNs: first)
            }
            try runtime.receiveBLE(event, firstReceivedNs: first, completedNs: completed)
        } catch {
            status("Recorder sensor synchronization failed: \(error)")
            boot = nil; bleConnection = UUID().uuidString
        }
        pump()
    }

    func admitCamera(_ pose: USICameraPose) -> USICameraEncodeTicket? {
        owner()
        do { let admission = try runtime.admitCamera(pose: pose); pump(); return admission.encodeTicket }
        catch { status("Recorder camera admission failed: \(error)"); pump(); return nil }
    }
    func completeCamera(_ ticket: USICameraEncodeTicket?, image: USICameraImage?) {
        owner(); guard let ticket else { return }
        // A reset retires old work; late encoder callbacks cannot enter the new epoch.
        guard ticket.identity.epochID == runtime.worldEpochID else { return }
        do {
            try runtime.completeCamera(ticket: ticket, image: image)
            if let image { sawCamera = true; sawDepth = sawDepth || image.depth != nil; sawConfidence = sawConfidence || image.confidence != nil }
        } catch { status("Recorder image rejected: \(error)") }
        pump()
    }
    func selectCalibration(_ calibration: USIPressureCalibration?) throws {
        owner(); try runtime.selectCalibration(calibration)
    }

    func beginTrial() throws {
        owner()
        let defaults = UserDefaults.standard
        let profile = USISealCalibrationProfile.load()
        let task = (defaults.string(forKey: "usi.task") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let gripper = (defaults.string(forKey: "usi.gripper") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var snapshot = USICollectionSnapshot(sessionID: runtime.sessionID,
            taskLabel: task.isEmpty ? "Untitled task" : task,
            gripperID: gripper.isEmpty ? "Unspecified gripper" : gripper,
            profile: "core", calibration: try profile?.calibration(),
            ambientKPaAbs: profile.map { $0.openKPaAbs.reduce(0,+)/3 },
            calibrationProvenance: profile.map { "Measured open=\($0.openKPaAbs), sealed=\($0.sealedKPaAbs) kPa abs; threshold drop fractions 0.70/0.50; persistence 200 ms; two-point pressure preview" } ?? "uncalibrated",
            capabilities: capabilities())
        snapshot.configuration.targetFPS = targetFPS
        let missing = runtime.readiness(snapshot: snapshot, nowNs: now)
        guard missing.isEmpty else { throw USICollectionError.invalid("Not ready: " + Array(Set(missing)).sorted().joined(separator: ", ")) }
        let trial = "trial-" + UUID().uuidString
        try runtime.prepare(snapshot: snapshot, trialID: trial, requestID: trial + ":prepare", nowNs: now)
        pump()
    }
    func endTrial() throws {
        owner(); try runtime.stop(requestID: (runtime.activeTrialID ?? "trial") + ":stop", nowNs: now); pump()
    }
    func tick() {
        owner(); runtime.tick(nowNs: now)
        if boot != nil, now - lastProgressNs >= 1_000_000_000 {
            do { if try runtime.requestBLEProgress(nowNs: now) { lastProgressNs = now } }
            catch { status("Recorder source clock request failed: \(error)") }
        }
        pump()
    }
    func rendering() -> USICollectionRendering { owner(); return runtime.render(nowNs: now) }
    func diagnostics() -> String {
        owner(); let r = rendering()
        return "\(statusText)\nTrial: \(r.state.rawValue)\n" +
            "\(r.unknownReason ?? "")\nMissing required: \(r.missingRequiredStreams.joined(separator: ", "))\n" +
            "Saved MCAP: \(r.lastSave?.bagPath ?? "none")\n" +
            "BLE source clock: \(r.bleSourceProgress == nil ? "waiting" : "observed")\n" +
            "Core profile: RGB, raw depth/confidence, camera pose/tracking/calibration, pressures, trigger, seal, metadata, clocks, health.\nUltrawide unavailable."
    }

    private func capabilities() -> [USICollectionCapability] {
        let counters = runtime.counters
        return USICollectionWire.coreRequiredStreams.map { name in
            let stream = USICollectionStream(rawValue: name)!
            let sensor = [.pressures,.trigger,.seal].contains(stream)
            let source = counters.first { $0.stream == (stream == .seal ? .pressures : stream) }
            let available: Bool
            if sensor { available = boot != nil && source != nil }
            else if stream == .rawDepth { available = sawDepth }
            else if stream == .depthConfidence { available = sawConfidence }
            else if [.mainRGB,.cameraCalibration].contains(stream) { available = sawCamera }
            else { available = true }
            return USICollectionCapability(stream: stream, available: available,
                reason: available ? nil : "Waiting for live " + name,
                sourceID: sensor ? source?.sourceID : runtime.sessionID,
                epochID: sensor ? source?.epochID : runtime.worldEpochID)
        } + [USICollectionCapability(stream: .ultrawide, available: false,
            reason: "Unavailable while retaining this ARKit capture session", sourceID: nil, epochID: nil)]
    }

    private func accept(_ candidate: NWConnection) {
        guard client == nil else { candidate.cancel(); return }
        generation = UUID(); let current = generation
        client = candidate; sending = false; helloReceived = false
        candidate.stateUpdateHandler = { [weak self] state in
            guard let self, self.generation == current else { return }
            switch state {
            case .ready:
                do { try self.runtime.connectHost(capabilities: self.capabilities(), nowNs: self.now) }
                catch { self.close(reason: "Recorder handshake failed"); return }
                self.status("Recorder connected — checking live data")
                self.readHeader(candidate, generation: current); self.pump()
            case .failed, .cancelled: self.close(reason: "Recorder USB disconnected")
            default: break
            }
        }
        candidate.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.generation == current, !self.helloReceived else { return }
            self.close(reason: "Recorder handshake timed out")
        }
    }
    private func readHeader(_ connection: NWConnection, generation current: UUID) {
        receiveToken = UUID(); let read = receiveToken
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.generation == current, self.receiveToken == read else { return }
            self.close(reason: "Recorder receive timed out")
        }
        readExact(16, connection: connection, generation: current) { [weak self] headerData in
            guard let self else { return }
            do {
                let header = try USICollectionWire.parseHeader(headerData)
                guard header.payloadLength == 0,
                      [.hello,.ping,.trialStatus,.bleClock].contains(header.type),
                      self.helloReceived || header.type == .hello else { throw USICollectionError.invalid("unexpected host packet") }
                self.readExact(header.metadataLength, connection: connection, generation: current) { [weak self] metadata in
                    guard let self else { return }
                    let receivedNs = self.now
                    do {
                        let packet = try USICollectionWire.decode(headerData + metadata)
                        if packet.type == .hello {
                            guard !self.helloReceived, packet.metadata["role"] as? String == "host" else { throw USICollectionError.invalid("invalid host hello") }
                            self.helloReceived = true
                        }
                        if packet.type == .ping { try self.runtime.replyToPing(packet, receivedNs: receivedNs, sentNs: self.now) }
                        else { _ = try self.runtime.receiveHost(packet, receivedNs: receivedNs) }
                        self.pump()
                        if self.generation == current { self.readHeader(connection, generation: current) }
                    } catch { self.close(reason: "Recorder host protocol error: \(error)") }
                }
            } catch { self.close(reason: "Recorder header rejected") }
        }
    }
    private func readExact(_ count: Int, connection: NWConnection, generation current: UUID,
                           partial: Data = Data(), completion: @escaping (Data) -> Void) {
        guard generation == current else { return }
        if partial.count == count { completion(partial); return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: count - partial.count) { [weak self] bytes,_,ended,error in
            guard let self, self.generation == current else { return }
            guard error == nil, let bytes, !bytes.isEmpty else { self.close(reason: "Recorder USB receive ended"); return }
            let combined = partial + bytes
            if combined.count == count { completion(combined) }
            else if ended { self.close(reason: "Recorder partial packet") }
            else { self.readExact(count, connection: connection, generation: current, partial: combined, completion: completion) }
        }
    }
    private func pump() {
        owner()
        while let effect = runtime.takeEffect() {
            switch effect {
            case .requestBLEClock(let id,let t1):
                if requestClock?(id,t1) != true { runtime.disconnectBLE(reason: "BLE clock request unavailable"); boot = nil }
            case .disconnectTransport(let reason): close(reason: reason)
            }
        }
        guard !sending, let client, let send = runtime.takeNext() else { return }
        sending = true; let current = generation, sendToken = send.token
        client.send(content: send.packet.bytes, completion: .contentProcessed { [weak self] error in
            guard let self, self.generation == current else { return }
            self.sending = false; self.runtime.sendCompleted(token: sendToken, succeeded: error == nil)
            if error != nil { self.close(reason: "Recorder USB send failed") }
            else { self.pump() }
        })
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.generation == current, self.sending else { return }
            // Runtime permits one in-flight token; a later send must not inherit this timeout.
            if self.activeSendToken == sendToken { self.close(reason: "Recorder USB stalled") }
        }
        activeSendToken = sendToken
    }
    private var activeSendToken: UInt64?
    private func close(reason: String) {
        generation = UUID(); let old = client; client = nil; sending = false; activeSendToken = nil
        helloReceived = false; old?.cancel()
        runtime.disconnectHost(reason: reason)
        status(reason + " — waiting for Ubuntu")
    }
}
