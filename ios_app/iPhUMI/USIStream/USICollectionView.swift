import UIKit

/// Native collection layout. Unconnected sources stay unknown; no example readings.
final class USISealView: UIView {
    enum State: Equatable { case unknown, sealed, unsealed }
    var states: [State] = [.unknown, .unknown, .unknown] { didSet { setNeedsDisplay(); updateAccessibility() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        isAccessibilityElement = true
        accessibilityLabel = "Three chamber seal indicator"
        updateAccessibility()
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    private func updateAccessibility() {
        accessibilityValue = (0..<3).map { index in
            let state = states.indices.contains(index) ? states[index] : .unknown
            return "C\(index + 1) \(state == .sealed ? "sealed" : state == .unsealed ? "unsealed" : "unknown")"
        }.joined(separator: ", ")
    }
    override func draw(_ rect: CGRect) {
        let radius = max(0, min(bounds.width, bounds.height) / 2 - 3)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        for index in 0..<3 {
            let start = -CGFloat.pi / 2 + CGFloat(index) * 2 * .pi / 3
            let end = start + 2 * .pi / 3
            let path = UIBezierPath()
            path.move(to: center)
            path.addArc(withCenter: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
            path.close()
            let state = states.indices.contains(index) ? states[index] : .unknown
            (state == .sealed ? UIColor.systemGreen : state == .unsealed ? .systemRed : .systemGray).setFill()
            path.fill()
            UIColor.systemBackground.setStroke()
            path.lineWidth = 3
            path.stroke()
            let middle = (start + end) / 2
            let label = "C\(index + 1)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 14), .foregroundColor: UIColor.white]
            let size = label.size(withAttributes: attributes)
            label.draw(at: CGPoint(x: center.x + cos(middle) * radius * 0.6 - size.width / 2,
                                   y: center.y + sin(middle) * radius * 0.6 - size.height / 2), withAttributes: attributes)
        }
    }
}

final class USICollectionView: UIView {
    let preview = UIImageView() // JPEG fallback for the test probe; device uses nativePreview.
    let seal = USISealView(frame: .zero)
    var onHome: (() -> Void)?
    var onData: (() -> Void)?
    var onSettings: (() -> Void)?
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    private let canvas = UIView()
    private var headingLabel: UILabel!
    private var trialBarHeight: NSLayoutConstraint!
    var cameraViewport: CGRect { canvas.convert(canvas.bounds, to: self) }
    var cameraReadoutFrames: [CGRect] { [camera, pose, link].map { $0.convert($0.bounds, to: self) } }
    private let depthImage = UIImageView()
    private let depthThumbnail = UIImageView()
    private var nativePreview: UIView?
    private let unavailable = UILabel()
    private let selector = UISegmentedControl(items: ["RGB", "Depth", "Ultrawide"])
    private let camera = USICollectionView.label("Camera · starting", style: .caption1)
    private let pose = USICollectionView.label("Camera XYZ: — / — / — m", style: .caption1)
    private let link = USICollectionView.label("USB · starting", style: .caption1)
    private let pressure = USICollectionView.label("C1  —\nC2  —\nC3  —", style: .body)
    private let sealStatus = USICollectionView.label("Seal unknown · awaiting sensors", style: .caption1)
    private let suction = USICollectionView.label("Suction —\nAwaiting trigger", style: .subheadline)
    private let sensorStatus = USICollectionView.label("Bluetooth · starting", style: .caption1)
    private let trial = USICollectionView.label("Trial 001 · Not recording", style: .subheadline)
    private let elapsed = USICollectionView.label("Time — · Recorder not connected", style: .caption1)
    private let session = USICollectionView.label("Session / Task", style: .caption1)
    private(set) var startButton: UIButton!
    private(set) var stopButton: UIButton!

    static func label(_ text: String, style: UIFont.TextStyle) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: style)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.textColor = .label
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
    private static func button(_ title: String, id: String, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.tinted()
        configuration.title = title
        configuration.contentInsets = .init(top: 8, leading: 12, bottom: 8, trailing: 12)
        configuration.titleLineBreakMode = .byWordWrapping
        let button = UIButton(configuration: configuration)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.titleLabel?.numberOfLines = 0
        button.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17), maximumPointSize: 24)
            return outgoing
        }
        button.accessibilityIdentifier = id
        button.accessibilityLabel = title
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }
    private static func stack(_ children: [UIView], axis: NSLayoutConstraint.Axis = .vertical, spacing: CGFloat = 8) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: children)
        stack.axis = axis
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        let home = Self.button("Home", id: "collection.home") { [weak self] in self?.onHome?() }
        let data = Self.button("Data", id: "collection.data") { [weak self] in self?.onData?() }
        let settings = Self.button("Settings", id: "collection.settings") { [weak self] in self?.onSettings?() }
        let title = Self.label("Collect Demonstrations", style: .headline)
        headingLabel = title
        title.accessibilityTraits.insert(.header)
        let header = Self.stack([home, title, session, data, settings], axis: .horizontal)
        header.alignment = .center
        // Center-aligned stacks may absorb all spare height without enlarging
        // their children. Reserve that height for the camera instead.
        NSLayoutConstraint.activate([
            header.heightAnchor.constraint(equalToConstant: 48),
            home.widthAnchor.constraint(equalToConstant: 88),
            data.widthAnchor.constraint(equalToConstant: 76),
            settings.widthAnchor.constraint(equalToConstant: 116)
        ])
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        session.setContentCompressionResistancePriority(.fittingSizeLevel, for: .horizontal)
        selector.selectedSegmentIndex = 0
        selector.accessibilityLabel = "Camera view"
        selector.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        selector.addTarget(self, action: #selector(selectPreview), for: .valueChanged)
        canvas.backgroundColor = .black
        canvas.layer.cornerRadius = 8
        canvas.clipsToBounds = true
        for image in [preview, depthImage, depthThumbnail] {
            image.contentMode = .scaleAspectFit
            image.setContentCompressionResistancePriority(.fittingSizeLevel, for: .horizontal)
            image.setContentCompressionResistancePriority(.fittingSizeLevel, for: .vertical)
        }
        preview.accessibilityLabel = "Live RGB camera"
        depthImage.accessibilityLabel = "Live depth visualization, near is light, invalid is black"
        for child in [preview, depthImage, unavailable] { fill(child, in: canvas) }
        unavailable.numberOfLines = 0
        unavailable.textAlignment = .center
        unavailable.textColor = .white
        unavailable.font = .preferredFont(forTextStyle: .body)
        unavailable.adjustsFontForContentSizeCategory = true
        let cameraReadouts = Self.stack([camera, pose, link], spacing: 4)
        for label in [camera, pose, link] {
            label.textColor = .secondaryLabel
            label.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .systemFont(ofSize: 12), maximumPointSize: 18)
        }
        let cameraColumn = Self.stack([selector, canvas], spacing: 4)
        let pressures = Self.stack([Self.label("Pressure · kPa abs", style: .caption1), pressure])
        pressures.accessibilityLabel = "Chamber pressures in kilopascals absolute"
        seal.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([seal.widthAnchor.constraint(equalToConstant: 100), seal.heightAnchor.constraint(equalTo: seal.widthAnchor)])
        let readings = Self.stack([seal, pressures], axis: .horizontal)
        readings.alignment = .center
        suction.backgroundColor = .secondarySystemBackground
        suction.layer.cornerRadius = 8
        suction.clipsToBounds = true
        let depth = Self.button("Depth", id: "collection.depth") { [weak self] in self?.showPreview(1) }
        let wide = Self.button("Ultrawide\nUnavailable", id: "collection.ultrawide") { [weak self] in self?.showPreview(2) }
        depthThumbnail.heightAnchor.constraint(equalToConstant: 28).isActive = true
        depthThumbnail.isAccessibilityElement = false
        let depthTile = Self.stack([depthThumbnail, depth], spacing: 0)
        let thumbs = Self.stack([depthTile, wide], axis: .horizontal)
        thumbs.distribution = .fillEqually
        let status = Self.stack([readings, sealStatus, suction, sensorStatus, cameraReadouts, thumbs])
        let statusScroll = UIScrollView()
        statusScroll.translatesAutoresizingMaskIntoConstraints = false
        statusScroll.addSubview(status)
        NSLayoutConstraint.activate([
            status.leadingAnchor.constraint(equalTo: statusScroll.contentLayoutGuide.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: statusScroll.contentLayoutGuide.trailingAnchor),
            status.topAnchor.constraint(equalTo: statusScroll.contentLayoutGuide.topAnchor),
            status.bottomAnchor.constraint(equalTo: statusScroll.contentLayoutGuide.bottomAnchor),
            status.widthAnchor.constraint(equalTo: statusScroll.frameLayoutGuide.widthAnchor)
        ])
        let body = Self.stack([cameraColumn, statusScroll], axis: .horizontal, spacing: 12)
        statusScroll.widthAnchor.constraint(equalTo: body.widthAnchor, multiplier: 0.35).isActive = true
        startButton = Self.button("Start trial", id: "collection.start") { [weak self] in self?.onStart?() }
        startButton.configuration?.baseBackgroundColor = .systemBlue
        startButton.configuration?.baseForegroundColor = .white
        startButton.configuration?.background.backgroundColor = .systemBlue
        startButton.accessibilityHint = "Requires the Ubuntu recorder connection"
        stopButton = Self.button("Stop", id: "collection.stop") { [weak self] in self?.onStop?() }
        stopButton.isEnabled = false
        let trialText = Self.stack([trial, elapsed], spacing: 2)
        trial.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: 17, weight: .semibold), maximumPointSize: 24)
        elapsed.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .systemFont(ofSize: 12), maximumPointSize: 18)
        let bar = Self.stack([trialText, startButton, stopButton], axis: .horizontal)
        bar.alignment = .center
        trialBarHeight = bar.heightAnchor.constraint(equalToConstant: 52)
        trialBarHeight.isActive = true
        NSLayoutConstraint.activate([
            startButton.widthAnchor.constraint(equalToConstant: 140),
            stopButton.widthAnchor.constraint(equalToConstant: 84)
        ])
        addSubview(header); addSubview(body); addSubview(bar)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -12),
            header.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 4),
            body.leadingAnchor.constraint(equalTo: header.leadingAnchor), body.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            body.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            body.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -8),
            bar.leadingAnchor.constraint(equalTo: header.leadingAnchor), bar.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -4),
            canvas.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
            startButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 100)
        ])
        selectPreview()
        adaptHeader()
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        adaptHeader()
    }
    private func adaptHeader() {
        let large = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        headingLabel?.isHidden = large
        session.isHidden = large
        trialBarHeight?.constant = large ? 76 : 52
    }
    private func fill(_ child: UIView, in parent: UIView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(child)
        NSLayoutConstraint.activate([child.leadingAnchor.constraint(equalTo: parent.leadingAnchor), child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            child.topAnchor.constraint(equalTo: parent.topAnchor), child.bottomAnchor.constraint(equalTo: parent.bottomAnchor)])
    }
    func installNativePreview(_ child: UIView) {
        nativePreview?.removeFromSuperview()
        nativePreview = child
        fill(child, in: canvas)
        canvas.bringSubviewToFront(depthImage)
        canvas.bringSubviewToFront(unavailable)
        selectPreview()
    }
    private func showPreview(_ index: Int) { selector.selectedSegmentIndex = index; selectPreview() }
    @objc private func selectPreview() {
        let index = selector.selectedSegmentIndex
        preview.isHidden = index != 0 || nativePreview != nil
        // Keep the AR view attached and the session running under the depth overlay.
        depthImage.isHidden = index != 1
        unavailable.isHidden = index == 0 || (index == 1 && depthImage.image != nil)
        unavailable.text = index == 2 ? "Ultrawide unavailable\nThis capture path keeps ARKit tracking active." : "Waiting for LiDAR depth"
    }
    func setDepthPreview(_ image: UIImage?) {
        depthImage.image = image
        depthThumbnail.image = image
        selectPreview()
    }
    func setUSBStatus(_ text: String) { link.text = text }
    func setSensorStatus(_ text: String) { sensorStatus.text = text }
    func setSession(_ text: String) { session.text = text }
    func apply(_ details: USIPreviewDetails) {
        camera.text = "RGB + ARKit · \(details.cameraRate)\nTracking: \(details.tracking) · Depth: \(details.depth)"
        pose.text = details.positionText
        if !details.isCapturing || details.depth.hasPrefix("No depth") { preview.image = nil; setDepthPreview(nil) }
    }
    func applySensors(pressures: [Double?], states: [USISealView.State], suctionText: String) {
        seal.states = states
        pressure.text = (0..<3).map { index in
            let value = pressures.indices.contains(index) ? pressures[index] : nil
            let number = value.map { String(format: "%.1f", $0) } ?? "—"
            return "C\(index + 1)  \(number)"
        }.joined(separator: "\n")
        pressure.accessibilityValue = seal.accessibilityValue
        let known = states.filter { $0 != .unknown }.count
        let sealed = states.filter { $0 == .sealed }.count
        sealStatus.text = known < 3 ? "Seal unknown · awaiting valid calibration/data" : "\(sealed == 3 ? "Full seal" : "Partial seal") · \(sealed)/3"
        suction.text = suctionText
    }
    func applyTrial(number: Int, state: String, elapsedText: String, recording: Bool) {
        trial.text = String(format: "Trial %03d · %@", number, state)
        elapsed.text = elapsedText
        stopButton.isEnabled = recording
        startButton.isEnabled = !recording
    }
}
