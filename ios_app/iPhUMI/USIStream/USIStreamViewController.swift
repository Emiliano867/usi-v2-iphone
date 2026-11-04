import ARKit
import UIKit
import simd
import RealityKit

/// A separate public-API ARKit path; stock collection and AVCapture deployment stay intact.
final class USIStreamViewController: UIViewController, ARSessionDelegate {
    private var session = ARSession()
    private let captureQueue = DispatchQueue(label: "usi.arkit.capture")
    private let encodeQueue = DispatchQueue(label: "usi.arkit.encode", qos: .userInitiated)
    private let encoder = USIFrameEncoder()
    private let usb = USIUSBServer()
    private lazy var ble = USIBLECentral(queue: captureQueue)
    private var sensors = USILiveSensorState() // captureQueue only
    private var sensorTimer: DispatchSourceTimer?
    private var sensorLink = "Bluetooth · starting"
    private var sensorUIPending = false
    private var sensorDetails = "Bluetooth telemetry has not started." // main queue
    private var recorder: USIRecorderSession? // captureQueue only
    private var recorderDetails = "Recorder is starting." // main queue
    private var trialFrozen = false // main queue
    private var trialNumber = 1 // main queue
    private var displayedTrialID: String?
    private let content = USICollectionView(frame: .zero)
    private var nativePreview: ARView?
    private weak var diagnostics: USIDiagnosticsViewController?
    private var usbStatus = "Starting USB"
    private var captureDetails = USIPreviewDetails.starting
    private let previewMailbox = USIPreviewMailbox()
    private var visible = false // main queue
    // The following capture/encode state belongs exclusively to captureQueue.
    private var running = false
    private var sessionID = UUID().uuidString
    private var sequence: UInt64 = 0
    private var encodeDrops: UInt64 = 0
    private var encoding = false
    private var pending: USIFrameSnapshot?
    private var recordingPending: [USIFrameSnapshot] = [] // bounded by runtime tickets
    private var lastPreviewTime: TimeInterval = -.infinity
    private var lastStatusTime: TimeInterval = -.infinity
    private var rateStart: TimeInterval = 0
    private var rateFrames = 0
    private var captureFPS = 30 // captureQueue only; actual selected ARKit format

    override func loadView() { view = content }

    override func viewDidLoad() {
        super.viewDidLoad()
        content.onHome = { [weak self] in self?.closePressed() }
        content.onData = { [weak self] in self?.showDiagnostics() }
        content.onSettings = { [weak self] in self?.showSettings() }
        content.onStart = { [weak self] in self?.trialAction(start: true) }
        content.onStop = { [weak self] in self?.trialAction(start: false) }
        let cameraView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        cameraView.session = session
        content.installNativePreview(cameraView)
        nativePreview = cameraView
        updateSessionLabel()
        usb.onStatus = { [weak self] text in
            guard let self else { return }
            self.usbStatus = text
            self.updateDiagnostics()
        }
        session.delegate = self
        session.delegateQueue = captureQueue
        NotificationCenter.default.addObserver(self, selector: #selector(backgrounded),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(foregrounded),
            name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !visible else { return }
        visible = true
        beginEpoch()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Inspecting Data or Settings must not stop the shared capture session.
        guard isBeingDismissed || navigationController?.isBeingDismissed == true else { return }
        visible = false
        stopCapture()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func closePressed() {
        UserDefaults.standard.removeObject(forKey: "appMode")
        dismiss(animated: true)
    }

    private func showDiagnostics() {
        guard presentedViewController == nil else { return }
        let controller = USIDiagnosticsViewController()
        controller.onReset = { [weak self] in self?.beginEpoch() }
        // Keep capture running while inspecting diagnostics. A fullScreen modal
        // would invoke viewWillDisappear and stop the ARSession/USB connection.
        controller.modalPresentationStyle = .overFullScreen
        diagnostics = controller
        updateDiagnostics()
        present(controller, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    private func showSettings() {
        guard presentedViewController == nil else { return }
        guard !trialFrozen else { showTrialError("Finish or resolve the current trial before changing settings."); return }
        let controller = USICollectionSettingsViewController()
        let previousRate = USICaptureRate.load()
        controller.onSave = { [weak self] in
            guard let self else { return }
            self.updateSessionLabel(); self.updateDiagnostics()
            if USICaptureRate.load() != previousRate { self.beginEpoch() }
        }
        controller.onReference = { [weak self] completion in
            guard let self else { return }
            self.captureQueue.async {
                let result = Result { try self.sensors.calibrationReference(nowNs: DispatchTime.now().uptimeNanoseconds) }
                DispatchQueue.main.async { completion(result) }
            }
        }
        controller.onUseCalibration = { [weak self] profile in
            guard let self else { return }
            let calibration = try? profile?.calibration()
            self.captureQueue.async {
                self.sensors.selectCalibration(calibration)
                do { try self.recorder?.selectCalibration(calibration) }
                catch { DispatchQueue.main.async { self.showTrialError("Calibration is locked during this trial.") } }
            }
            self.updateDiagnostics()
        }
        controller.modalPresentationStyle = .overFullScreen
        present(controller, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    private func updateSessionLabel() {
        let defaults = UserDefaults.standard
        let session = defaults.string(forKey: "usi.session") ?? "Untitled session"
        let task = defaults.string(forKey: "usi.task") ?? "No task label"
        content.setSession("\(session)\n\(task)")
    }

    private func trialAction(start: Bool) {
        captureQueue.async { [weak self] in
            guard let self else { return }
            do {
                guard let recorder = self.recorder else { throw USICollectionError.invalid("Recorder is starting") }
                if start { try recorder.beginTrial() }
                else { try recorder.endTrial() }
                self.publishSensorUpdate()
            } catch {
                let message: String
                if case USICollectionError.invalid(let reason) = error { message = reason }
                else { message = error.localizedDescription }
                DispatchQueue.main.async { self.showTrialError(message) }
            }
        }
    }
    private func showTrialError(_ message: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: "Trial status", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    private func updateDiagnostics() {
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
        let buildNumber = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "?"
        let revision = (Bundle.main.object(forInfoDictionaryKey: "USIUIRevision") as? String) ?? "local"
        let defaults = UserDefaults.standard
        diagnostics?.details = "Session: \(defaults.string(forKey: "usi.session") ?? "Untitled")\nTask: \(defaults.string(forKey: "usi.task") ?? "Not set")\nGripper: \(defaults.string(forKey: "usi.gripper") ?? "Not set")\nCalibration label: \(defaults.string(forKey: "usi.calibration") ?? "Not set")\n\n\(usbStatus)\n\n\(captureDetails.diagnostics)\n\nBLUETOOTH TELEMETRY\n\(sensorDetails)\n\nRECORDER\n\(recorderDetails)\n\nDATA STREAMS\nMain RGB: live ARKit, native preview\nDepth / confidence: captured when supplied by ARKit; depth visualization 0–2 m\nCamera pose / tracking / intrinsics: included in USB camera stream\nUltrawide: unavailable in this ARKit capture path\nPressure C1/C2/C3 and trigger: live BLE reception when rig is subscribed\nSuction: trigger-derived command state; no measured pump feedback\nSeal calibration: capture Open and Sealed in Settings; gray until a measured calibration is saved\nCore streams and trial controls use USB port 5559. Recording/Saved state comes from the Ubuntu recorder.\nCamera pose only; tool calibration required.\n\nSuction UMI v2 · collection · version \(version) (\(buildNumber))"
        if let diagnostics { diagnostics.details += "\nSource revision: \(revision)" }
    }

    @objc private func backgrounded() { stopCapture() }

    @objc private func foregrounded() {
        if visible { beginEpoch() }
    }

    private func stopCapture() {
        captureQueue.async { [weak self] in
            guard let self else { return }
            self.running = false
            self.session.pause()
            self.pending = nil
            self.recordingPending.removeAll()
            self.recorder?.stop()
            self.usb.stop()
            self.sensorTimer?.cancel()
            self.sensorTimer = nil
            self.ble.stop()
            self.publishSensorUpdate()
        }
    }

    private func beginEpoch(expectedSession: ARSession? = nil) {
        guard ARWorldTrackingConfiguration.isSupported else {
            captureDetails = .unavailable("ARKit world tracking is unavailable on this device")
            content.apply(captureDetails)
            updateDiagnostics()
            return
        }
        let requestedFPS = USICaptureRate.load().rawValue
        captureQueue.async { [weak self] in
            guard let self else { return }
            if let expectedSession, self.session !== expectedSession { return }
            self.session.pause()
            self.sessionID = UUID().uuidString
            if self.previewMailbox.reset(epoch: self.sessionID) { self.scheduleUIUpdate() }
            self.sequence = 0
            self.encodeDrops = 0
            self.pending = nil
            self.recordingPending.removeAll()
            self.rateStart = 0
            self.rateFrames = 0
            self.lastPreviewTime = -.infinity
            self.lastStatusTime = -.infinity
            let configuration = ARWorldTrackingConfiguration()
            if let format = ARWorldTrackingConfiguration.supportedVideoFormats
                .filter({ $0.framesPerSecond == requestedFPS })
                .min(by: { $0.imageResolution.width * $0.imageResolution.height < $1.imageResolution.width * $1.imageResolution.height }) {
                configuration.videoFormat = format
            }
            self.captureFPS = configuration.videoFormat.framesPerSecond
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                configuration.frameSemantics.insert(.sceneDepth)
            }
            if self.recorder == nil {
                do {
                    let recorder = try USIRecorderSession(queue: self.captureQueue, epochID: self.sessionID)
                    recorder.requestClock = { [weak self] id, time in self?.ble.requestClock(requestID: id, t1PhoneNs: time) ?? false }
                    recorder.onStatus = { [weak self] text in
                        DispatchQueue.main.async { self?.content.setUSBStatus(text) }
                    }
                    self.recorder = recorder
                } catch {
                    DispatchQueue.main.async { self.showTrialError("Recorder initialization failed: \(error)") }
                }
            }
            self.recorder?.start(epochID: self.sessionID, fps: Double(configuration.videoFormat.framesPerSecond))
            self.usb.start(sessionID: self.sessionID)
            self.usb.resetSession(self.sessionID)
            self.running = true
            self.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
            self.startSensors()
        }
    }

    private func startSensors() {
        dispatchPrecondition(condition: .onQueue(captureQueue))
        guard sensorTimer == nil else { return }
        sensors.selectCalibration(try? USISealCalibrationProfile.load()?.calibration())
        ble.onStatus = { [weak self] in self?.sensorLink = $0 }
        ble.onSubscribed = { [weak self] in
            guard let self else { return }
            self.sensors.connect()
            if let source = self.ble.sourceIdentifier { self.recorder?.subscribed(sourceID: source) }
        }
        ble.onDisconnected = { [weak self] in self?.sensors.disconnect(); self?.recorder?.disconnectedBLE() }
        ble.onRejected = { [weak self] in self?.sensors.reject(); self?.recorder?.rejectedBLE() }
        ble.onEvent = { [weak self] event, firstReceivedNs, completedNs in
            guard let self else { return }
            do {
                try self.sensors.receive(event, receivedNs: firstReceivedNs)
                self.recorder?.receiveBLE(event, first: firstReceivedNs, completed: completedNs)
            }
            catch {
                self.sensors.reject()
                self.ble.reconnectAfterFailure("Bluetooth · source changed; reconnecting")
            }
        }
        let timer = DispatchSource.makeTimerSource(queue: captureQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.publishSensorUpdate() }
        sensorTimer = timer
        ble.start()
        timer.resume()
    }

    private func publishSensorUpdate() {
        dispatchPrecondition(condition: .onQueue(captureQueue))
        recorder?.tick()
        // At most one display snapshot waits for main; no UI block is queued per sample.
        guard !sensorUIPending else { return }
        sensorUIPending = true
        let snapshot = sensors.snapshot(nowNs: DispatchTime.now().uptimeNanoseconds)
        let trial = recorder?.rendering()
        let recordingDetails = recorder?.diagnostics() ?? "Recorder unavailable"
        let status = sensorLink
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.visible {
                self.recorderDetails = recordingDetails
                if let trial {
                    self.trialFrozen = trial.configurationFrozen
                    if let id = trial.trialID, id != self.displayedTrialID {
                        if self.displayedTrialID != nil { self.trialNumber += 1 }
                        self.displayedTrialID = id
                    }
                    let elapsed = trial.elapsedNs.map { String(format: "Time %.1f s", Double($0) / 1e9) } ?? "Time —"
                    let state = trial.unknownReason != nil ? "Unknown · see Data" :
                        (trial.recordingAssured ? "Recording" : trial.state.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                    self.content.applyTrial(number: self.trialNumber, state: state,
                        elapsedText: elapsed + (trial.state == .saved ? " · MCAP verified" : ""), recording: trial.stopEnabled)
                }
                let states: [USISealView.State] = snapshot.seal.states.map {
                    $0 == .sealed ? .sealed : $0 == .unsealed ? .unsealed : .unknown
                }
                let suction = snapshot.suction == .on ? "ON" : snapshot.suction == .off ? "OFF" : "—"
                self.content.applySensors(pressures: snapshot.seal.pressuresKPaAbs, states: states,
                    suctionText: "Suction \(suction)\nTrigger-derived · read-only")
                let invalid = snapshot.seal.states.enumerated().compactMap { index, state in
                    state == .invalid ? "C\(index + 1)" : nil
                }
                self.content.setSensorStatus(status + (invalid.isEmpty ? "" : "\nSensor data invalid: " + invalid.joined(separator: ", ")))
                self.sensorDetails = "\(status)\nPressure received this connection: \(snapshot.pressureSamples)\nTrigger received this connection: \(snapshot.triggerSamples)\nObserved sequence gaps: pressure \(snapshot.missingPressureSamples), trigger \(snapshot.missingTriggerSamples)\nDuplicate samples: \(snapshot.duplicates)\nRejected samples/messages: \(snapshot.rejected)\nPressure expires after 250 ms; trigger after 1 s.\nC1/C2/C3: sensor channels 0/5/6; physical chamber map needs calibration.\nSeal calibration: \(snapshot.seal.calibrationID ?? "not set — open Settings")\nFresh numeric pressures display independently of seal colors."
                self.updateDiagnostics()
            }
            self.captureQueue.async { [weak self] in self?.sensorUIPending = false }
        }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard running, session === self.session else { return }
        let currentSequence = sequence
        sequence += 1
        let transform = frame.camera.transform
        let rotation = simd_float3x3(columns: (
            SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
            SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
            SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)))
        let quaternion = simd_normalize(simd_quatf(rotation)).vector
        let tracking = trackingDescription(frame.camera.trackingState)
        let k = frame.camera.intrinsics
        var matrix: [Double] = []
        var intrinsics: [Double] = []
        for row in 0..<4 { for column in 0..<4 { matrix.append(Double(transform[column][row])) } }
        for row in 0..<3 { for column in 0..<3 { intrinsics.append(Double(k[column][row])) } }
        let metadata: [String: Any] = [
            "session_id": sessionID, "frame_seq": currentSequence,
            "arkit_timestamp_s": frame.timestamp, "phone_uptime_ns": USIUSBServer.uptimeNS(),
            "world_frame": "arkit_world", "camera_frame": "arkit_camera", "image_orientation": "sensor_native",
            "camera_transform_row_major": matrix,
            "position_m": [Double(transform.columns.3.x), Double(transform.columns.3.y), Double(transform.columns.3.z)],
            "quaternion_xyzw": [Double(quaternion.x), Double(quaternion.y), Double(quaternion.z), Double(quaternion.w)],
            "tracking_state": tracking.0, "tracking_reason": tracking.1, "pose_valid": tracking.0 != "not_available",
            "intrinsics_row_major": intrinsics,
            "source_image_size": [CVPixelBufferGetWidth(frame.capturedImage), CVPixelBufferGetHeight(frame.capturedImage)],
            "thermal_state": thermalDescription(),
            "counters": ["acquired_frames": sequence, "encode_drops": encodeDrops, "transport_drops": UInt64(0)]
        ]
        let pose = USICameraPose(arkitTimestampS: frame.timestamp,
            phoneUptimeNs: metadata["phone_uptime_ns"] as! UInt64, transform: matrix,
            positionM: [Double(transform.columns.3.x), Double(transform.columns.3.y), Double(transform.columns.3.z)],
            quaternionXYZW: [Double(quaternion.x), Double(quaternion.y), Double(quaternion.z), Double(quaternion.w)],
            trackingState: tracking.0, trackingReason: tracking.1, valid: tracking.0 != "not_available")
        var snapshot = USIFrameSnapshot(sessionID: sessionID, metadata: metadata,
            image: frame.capturedImage, depth: frame.sceneDepth?.depthMap, confidence: frame.sceneDepth?.confidenceMap)
        snapshot.recordingTicket = recorder?.admitCamera(pose)
        if encoding {
            if snapshot.recordingTicket != nil {
                // Recording tickets are bounded by the runtime and never coalesced.
                recordingPending.append(snapshot)
                pending = nil
            } else {
                if pending != nil { encodeDrops += 1 }
                pending = snapshot
            }
        } else { encode(snapshot) }
        rateFrames += 1
        if rateStart == 0 { rateStart = frame.timestamp }
        if frame.timestamp - lastStatusTime >= 1 {
            let duration = frame.timestamp - rateStart
            let fps = duration > 0 ? Double(rateFrames - 1) / duration : 0
            lastStatusTime = frame.timestamp
            let depth = frame.sceneDepth.map { "\(CVPixelBufferGetWidth($0.depthMap)) × \(CVPixelBufferGetHeight($0.depthMap))" } ?? "No depth this frame"
            let trackingText = tracking.0 == "normal" ? "Normal" : (tracking.1.isEmpty ? "Unavailable" : tracking.1.replacingOccurrences(of: "_", with: " ").capitalized)
            let text = String(format: "Camera: %.1f FPS\nFrame: %llu\nTracking: %@\nThermal: %@\nXYZ: %.3f, %.3f, %.3f m\nEncode drops: %llu\nSession: %@",
                fps, currentSequence, tracking.0, thermalDescription(), transform.columns.3.x, transform.columns.3.y,
                transform.columns.3.z, encodeDrops, sessionID)
            let details = USIPreviewDetails(tracking: trackingText, cameraRate: String(format: "%.1f FPS · target %d", fps, captureFPS),
                depth: depth, diagnostics: "\(text)\nDepth: \(depth)\nCapture target: \(captureFPS) FPS; observed acquisition rate shown above.\nRGB USB JPEG size: up to 640 px wide. Depth preview updates with encoded frames (up to 10/s); source depth and native RGB are independent.\nSelected source: \(CVPixelBufferGetWidth(frame.capturedImage)) × \(CVPixelBufferGetHeight(frame.capturedImage))", isCapturing: true,
                positionText: String(format: "Camera XYZ: %.3f / %.3f / %.3f m", transform.columns.3.x, transform.columns.3.y, transform.columns.3.z))
            if previewMailbox.offer(epoch: sessionID, details: details) { scheduleUIUpdate() }
        }
    }

    private func encode(_ snapshot: USIFrameSnapshot) {
        encoding = true
        encodeQueue.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.encoder.encode(snapshot) }
            self.captureQueue.async { [weak self] in
                guard let self else { return }
                self.encoding = false
                if self.running, snapshot.sessionID == self.sessionID {
                    switch result {
                    case .success(var encoded):
                        if let ticket = snapshot.recordingTicket {
                            do {
                                let image = try USICollectionImageAdapter.make(metadata: encoded.metadata, payload: encoded.payload)
                                self.recorder?.completeCamera(ticket, image: image)
                            } catch { self.recorder?.completeCamera(ticket, image: nil) }
                        }
                        var counts = encoded.metadata["counters"] as? [String: Any] ?? [:]
                        counts["encode_drops"] = self.encodeDrops
                        encoded.metadata["counters"] = counts
                        self.usb.offerFrame(metadata: encoded.metadata, payload: encoded.payload)
                        let sourceTime = snapshot.metadata["arkit_timestamp_s"] as? Double ?? 0
                        if sourceTime - self.lastPreviewTime >= 0.1 {
                            self.lastPreviewTime = sourceTime
                            if self.previewMailbox.offer(epoch: snapshot.sessionID, depthPNG: encoded.depthPreviewPNG) {
                                self.scheduleUIUpdate()
                            }
                        }
                    case .failure:
                        self.recorder?.completeCamera(snapshot.recordingTicket, image: nil)
                        self.encodeDrops += 1
                        self.usb.health(event: "encode_error", message: "Frame encoding failed; sequence gap retained")
                    }
                }
                if self.running, !self.recordingPending.isEmpty {
                    self.encode(self.recordingPending.removeFirst())
                } else if self.running, let next = self.pending {
                    self.pending = nil
                    self.encode(next)
                }
            }
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        guard session === self.session else { return }
        running = false
        pending = nil
        recordingPending.removeAll()
        recorder?.stop()
        if previewMailbox.offer(epoch: sessionID, details: .unavailable("Camera interrupted")) { scheduleUIUpdate() }
        usb.health(event: "arkit_interrupted", message: "Capture interrupted; next resume resets world epoch")
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        guard session === self.session else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.visible else { return }
            self.beginEpoch(expectedSession: session)
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        guard session === self.session else { return }
        running = false
        pending = nil
        recordingPending.removeAll()
        recorder?.stop()
        usb.health(event: "arkit_error", message: error.localizedDescription)
        if previewMailbox.offer(epoch: sessionID, details: .unavailable("ARKit: \(error.localizedDescription)")) { scheduleUIUpdate() }
    }

    private func trackingDescription(_ state: ARCamera.TrackingState) -> (String, String) {
        switch state {
        case .normal: return ("normal", "")
        case .notAvailable: return ("not_available", "")
        case .limited(let reason):
            switch reason {
            case .initializing: return ("limited", "initializing")
            case .excessiveMotion: return ("limited", "excessive_motion")
            case .insufficientFeatures: return ("limited", "insufficient_features")
            case .relocalizing: return ("limited", "relocalizing")
            @unknown default: return ("limited", "unknown")
            }
        }
    }

    private func scheduleUIUpdate() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let update = self.previewMailbox.take(), self.visible else { return }
            let image = update.jpeg.flatMap { UIImage(data: $0) }
            let depthImage = update.depthPNG.flatMap { UIImage(data: $0) }
            guard self.previewMailbox.isCurrent(update.epoch) else { return }
            if update.clear { self.content.preview.image = nil }
            if let details = update.details {
                self.captureDetails = details
                self.content.apply(details)
                self.updateDiagnostics()
            }
            if let image, self.captureDetails.isCapturing { self.content.preview.image = image }
            if let depthImage, self.captureDetails.isCapturing { self.content.setDepthPreview(depthImage) }
        }
    }

    private func thermalDescription() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
