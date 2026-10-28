import ARKit
import UIKit
import simd

/// A separate public-API ARKit path; stock collection and AVCapture deployment stay intact.
final class USIStreamViewController: UIViewController, ARSessionDelegate {
    private var session = ARSession()
    private let captureQueue = DispatchQueue(label: "usi.arkit.capture")
    private let encodeQueue = DispatchQueue(label: "usi.arkit.encode", qos: .userInitiated)
    private let encoder = USIFrameEncoder()
    private let usb = USIUSBServer()
    private let content = USILiveView(frame: .zero)
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
    private var lastPreviewTime: TimeInterval = -.infinity
    private var lastStatusTime: TimeInterval = -.infinity
    private var rateStart: TimeInterval = 0
    private var rateFrames = 0

    override func loadView() { view = content }

    override func viewDidLoad() {
        super.viewDidLoad()
        content.onHome = { [weak self] in self?.closePressed() }
        content.onDiagnostics = { [weak self] in self?.showDiagnostics() }
        usb.onStatus = { [weak self] text in
            guard let self else { return }
            self.usbStatus = text
            self.content.setUSBStatus(text)
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

    private func updateDiagnostics() {
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
        let buildNumber = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "?"
        diagnostics?.details = "\(usbStatus)\n\n\(captureDetails.diagnostics)\n\nPressure: unavailable in this build.\nHost recording: not reported.\nCamera pose only; tool calibration required.\n\nSuction UMI v2 · version \(version) (\(buildNumber))"
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
            self.usb.stop()
        }
    }

    private func beginEpoch(expectedSession: ARSession? = nil) {
        guard ARWorldTrackingConfiguration.isSupported else {
            captureDetails = .unavailable("ARKit world tracking is unavailable on this device")
            content.apply(captureDetails)
            updateDiagnostics()
            return
        }
        captureQueue.async { [weak self] in
            guard let self else { return }
            if let expectedSession, self.session !== expectedSession { return }
            self.session.pause()
            self.session.delegate = nil
            let freshSession = ARSession()
            freshSession.delegate = self
            freshSession.delegateQueue = self.captureQueue
            self.session = freshSession
            self.sessionID = UUID().uuidString
            if self.previewMailbox.reset(epoch: self.sessionID) { self.scheduleUIUpdate() }
            self.sequence = 0
            self.encodeDrops = 0
            self.pending = nil
            self.rateStart = 0
            self.rateFrames = 0
            self.lastPreviewTime = -.infinity
            self.lastStatusTime = -.infinity
            let configuration = ARWorldTrackingConfiguration()
            if let format = ARWorldTrackingConfiguration.supportedVideoFormats
                .filter({ $0.framesPerSecond == 30 })
                .min(by: { $0.imageResolution.width * $0.imageResolution.height < $1.imageResolution.width * $1.imageResolution.height }) {
                configuration.videoFormat = format
            }
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                configuration.frameSemantics.insert(.sceneDepth)
            }
            self.usb.start(sessionID: self.sessionID)
            self.usb.resetSession(self.sessionID)
            self.running = true
            self.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
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
        let snapshot = USIFrameSnapshot(sessionID: sessionID, metadata: metadata,
            image: frame.capturedImage, depth: frame.sceneDepth?.depthMap, confidence: frame.sceneDepth?.confidenceMap)
        if encoding {
            if pending != nil { encodeDrops += 1 }
            pending = snapshot
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
            let details = USIPreviewDetails(tracking: trackingText, cameraRate: String(format: "%.1f FPS", fps),
                depth: depth, diagnostics: "\(text)\nDepth: \(depth)", isCapturing: true)
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
                        var counts = encoded.metadata["counters"] as? [String: Any] ?? [:]
                        counts["encode_drops"] = self.encodeDrops
                        encoded.metadata["counters"] = counts
                        self.usb.offerFrame(metadata: encoded.metadata, payload: encoded.payload)
                        let sourceTime = snapshot.metadata["arkit_timestamp_s"] as? Double ?? 0
                        if sourceTime - self.lastPreviewTime >= 0.1 {
                            self.lastPreviewTime = sourceTime
                            if self.previewMailbox.offer(epoch: snapshot.sessionID, jpeg: encoded.previewJPEG) {
                                self.scheduleUIUpdate()
                            }
                        }
                    case .failure:
                        self.encodeDrops += 1
                        self.usb.health(event: "encode_error", message: "Frame encoding failed; sequence gap retained")
                    }
                }
                if self.running, let next = self.pending {
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
            guard self.previewMailbox.isCurrent(update.epoch) else { return }
            if update.clear { self.content.preview.image = nil }
            if let details = update.details {
                self.captureDetails = details
                self.content.apply(details)
                self.updateDiagnostics()
            }
            if let image, self.captureDetails.isCapturing { self.content.preview.image = image }
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
