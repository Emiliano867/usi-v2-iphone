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
    private let preview = UIImageView()
    private let statusLabel = UILabel()
    private let frameLabel = UILabel()
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

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        preview.contentMode = .scaleAspectFit
        preview.backgroundColor = .black
        statusLabel.textColor = .white
        statusLabel.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        statusLabel.text = "USI Stream — starting ARKit"
        statusLabel.numberOfLines = 2
        frameLabel.textColor = .white
        frameLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        frameLabel.numberOfLines = 3
        frameLabel.text = "Camera pose only; suction TCP is not calibrated."
        let close = UIButton(type: .system)
        close.setTitle("Home", for: .normal)
        close.addTarget(self, action: #selector(closePressed), for: .touchUpInside)
        let reset = UIButton(type: .system)
        reset.setTitle("Reset tracking", for: .normal)
        reset.addTarget(self, action: #selector(resetPressed), for: .touchUpInside)
        let header = UIStackView(arrangedSubviews: [close, statusLabel, reset])
        header.axis = .horizontal
        header.spacing = 16
        let stack = UIStackView(arrangedSubviews: [header, preview, frameLabel])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            preview.heightAnchor.constraint(greaterThanOrEqualToConstant: 100)
        ])
        usb.onStatus = { [weak self] text in self?.statusLabel.text = "USI Stream · \(text)" }
        session.delegate = self
        session.delegateQueue = captureQueue
        NotificationCenter.default.addObserver(self, selector: #selector(backgrounded),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(foregrounded),
            name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
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

    @objc private func resetPressed() { beginEpoch() }

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
            statusLabel.text = "ARKit world tracking is unavailable on this device"
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
            let text = String(format: "ARKit %.1f FPS · frame %llu · %@ · thermal %@\nXYZ %.3f %.3f %.3f m · encode drops %llu\nNative camera pose; TCP uncalibrated · session %@",
                fps, currentSequence, tracking.0, thermalDescription(), transform.columns.3.x, transform.columns.3.y,
                transform.columns.3.z, encodeDrops, String(sessionID.prefix(8)))
            if previewMailbox.offer(epoch: sessionID, details: text) { scheduleUIUpdate() }
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
        DispatchQueue.main.async { [weak self] in self?.statusLabel.text = "ARKit: \(error.localizedDescription)" }
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
            if update.clear { self.preview.image = nil }
            if let image { self.preview.image = image }
            if let details = update.details { self.frameLabel.text = details }
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
