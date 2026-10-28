import UIKit

/// Shared text and controls for the two USI screens. Camera data stays outside UI code.
private enum USIInterface {
    static func label(_ text: String, style: UIFont.TextStyle, id: String? = nil) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: style)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.textColor = .label
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.accessibilityIdentifier = id
        return label
    }

    static func button(_ title: String, subtitle: String? = nil, primary: Bool = false,
                       id: String, action: @escaping () -> Void) -> UIButton {
        var configuration = primary ? UIButton.Configuration.filled() : .tinted()
        configuration.title = title
        configuration.subtitle = subtitle
        configuration.titleAlignment = .leading
        configuration.titleLineBreakMode = .byWordWrapping
        configuration.subtitleLineBreakMode = .byWordWrapping
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
        configuration.cornerStyle = .medium
        let button = UIButton(configuration: configuration)
        button.titleLabel?.numberOfLines = 0
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.accessibilityIdentifier = id
        button.accessibilityLabel = title
        button.accessibilityHint = subtitle
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: subtitle == nil ? 48 : 64).isActive = true
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    static func stack(_ views: [UIView], axis: NSLayoutConstraint.Axis = .vertical) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = axis
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    /// Fill the viewport when content fits; grow vertically for larger text.
    static func scrollContent(_ scroll: UIScrollView) -> UIView {
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.showsHorizontalScrollIndicator = false
        let content = UIView()
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(content)
        let viewportHeight = content.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)
        viewportHeight.priority = .defaultLow
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            content.heightAnchor.constraint(greaterThanOrEqualTo: scroll.frameLayoutGuide.heightAnchor),
            viewportHeight
        ])
        return content
    }
}

final class USIHomeView: UIView {
    let scrollView = UIScrollView()
    var onStream: (() -> Void)?
    var onCollect: (() -> Void)?
    var onDeploy: (() -> Void)?

    init(title: String) {
        super.init(frame: .zero)
        backgroundColor = .systemBackground
        let heading = USIInterface.label(title, style: .title1, id: "home.title")
        heading.textAlignment = .center
        heading.accessibilityTraits.insert(.header)
        let stream = USIInterface.button("Live USB Stream", subtitle: "RGB, depth and camera pose to Ubuntu",
            primary: true, id: "home.stream") { [weak self] in self?.onStream?() }
        let collect = USIInterface.button("Collect Demonstrations", subtitle: "Save camera demonstrations on iPhone",
            id: "home.collect") { [weak self] in self?.onCollect?() }
        let deploy = USIInterface.button("Deployment Mode", subtitle: "Original camera streaming options",
            id: "home.deploy") { [weak self] in self?.onDeploy?() }
        let menu = USIInterface.stack([heading, stream, collect, deploy])
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        let content = USIInterface.scrollContent(scrollView)
        content.addSubview(menu)
        let preferredWidth = menu.widthAnchor.constraint(equalToConstant: 640)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),
            menu.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            menu.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            menu.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 16),
            menu.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),
            menu.topAnchor.constraint(greaterThanOrEqualTo: content.topAnchor, constant: 16),
            menu.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16),
            menu.widthAnchor.constraint(lessThanOrEqualToConstant: 640), preferredWidth
        ])
    }

    required init?(coder: NSCoder) { fatalError("Use init(title:)") }
}

final class USILiveView: UIView {
    let preview = UIImageView()
    var onHome: (() -> Void)?
    var onDiagnostics: (() -> Void)?
    private let usb = USIInterface.label("Starting", style: .subheadline, id: "live.usb")
    private let tracking = USIInterface.label("Starting", style: .subheadline, id: "live.tracking")
    private let camera = USIInterface.label("Waiting for frames", style: .subheadline, id: "live.camera")
    private let depth = USIInterface.label("Waiting for frames", style: .subheadline, id: "live.depth")

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        preview.contentMode = .scaleAspectFit
        preview.backgroundColor = .black
        preview.isAccessibilityElement = true
        preview.accessibilityLabel = "Live camera preview"
        preview.setContentHuggingPriority(.defaultLow, for: .vertical)
        // A camera image's intrinsic pixel size must not enlarge the viewport.
        preview.setContentCompressionResistancePriority(.fittingSizeLevel, for: .vertical)
        preview.setContentCompressionResistancePriority(.fittingSizeLevel, for: .horizontal)
        let note = USIInterface.label("Camera pose · tool calibration required", style: .caption1, id: "live.pose-note")
        note.textColor = .secondaryLabel
        let cameraColumn = USIInterface.stack([preview, note])
        cameraColumn.spacing = 8

        let statusScroll = UIScrollView()
        statusScroll.contentInsetAdjustmentBehavior = .never
        statusScroll.backgroundColor = .secondarySystemBackground
        statusScroll.layer.cornerRadius = 8
        let statuses = USIInterface.stack([
            statusRow("USB", value: usb), statusRow("Tracking", value: tracking),
            statusRow("Camera", value: camera), statusRow("Depth", value: depth),
            statusRow("Pressure", value: USIInterface.label("Unavailable in this build", style: .subheadline, id: "live.pressure")),
            statusRow("Host recording", value: USIInterface.label("Not reported", style: .subheadline, id: "live.recording"))
        ])
        statusScroll.addSubview(statuses)
        NSLayoutConstraint.activate([
            statuses.leadingAnchor.constraint(equalTo: statusScroll.contentLayoutGuide.leadingAnchor, constant: 12),
            statuses.trailingAnchor.constraint(equalTo: statusScroll.contentLayoutGuide.trailingAnchor, constant: -12),
            statuses.topAnchor.constraint(equalTo: statusScroll.contentLayoutGuide.topAnchor, constant: 12),
            statuses.bottomAnchor.constraint(equalTo: statusScroll.contentLayoutGuide.bottomAnchor, constant: -12),
            statuses.widthAnchor.constraint(equalTo: statusScroll.frameLayoutGuide.widthAnchor, constant: -24)
        ])
        let body = USIInterface.stack([cameraColumn, statusScroll], axis: .horizontal)
        let preferredStatusWidth = statusScroll.widthAnchor.constraint(equalToConstant: 220)
        preferredStatusWidth.priority = .defaultHigh
        let heading = USIInterface.label("Live USB Stream", style: .headline, id: "live.title")
        heading.accessibilityTraits.insert(.header)
        let contentStack = USIInterface.stack([heading, body])
        contentStack.spacing = 8
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        let content = USIInterface.scrollContent(scroll)
        content.addSubview(contentStack)

        let home = USIInterface.button("Home", id: "live.home") { [weak self] in self?.onHome?() }
        home.accessibilityHint = "Returns to the menu and stops the live stream"
        let diagnostics = USIInterface.button("Diagnostics", id: "live.diagnostics") { [weak self] in self?.onDiagnostics?() }
        diagnostics.accessibilityHint = "Shows capture details and the tracking reset control"
        let actions = USIInterface.stack([home, diagnostics], axis: .horizontal)
        actions.distribution = .fillEqually
        addSubview(actions)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -8),
            actions.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            actions.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            actions.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -8),
            contentStack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: content.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            body.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            preview.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
            statusScroll.widthAnchor.constraint(lessThanOrEqualTo: body.widthAnchor, multiplier: 0.44),
            preferredStatusWidth
        ])
        preview.accessibilityValue = "Waiting for frames"
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    private func statusRow(_ title: String, value: UILabel) -> UIView {
        let label = USIInterface.label(title, style: .caption1)
        label.textColor = .secondaryLabel
        let row = USIInterface.stack([label, value])
        row.spacing = 2
        // Each value remains a separate accessible element so updates are read
        // on demand, without announcing every camera frame.
        label.isAccessibilityElement = false
        value.accessibilityLabel = title
        value.accessibilityValue = value.text
        return row
    }

    func setUSBStatus(_ text: String) {
        usb.text = text
        usb.accessibilityValue = text
    }

    func apply(_ details: USIPreviewDetails) {
        tracking.text = details.tracking
        tracking.accessibilityValue = details.tracking
        camera.text = details.cameraRate
        camera.accessibilityValue = details.cameraRate
        depth.text = details.depth
        depth.accessibilityValue = details.depth
        preview.accessibilityValue = details.isCapturing ? "Updating" : details.tracking
        if !details.isCapturing { preview.image = nil }
    }
}

final class USIDiagnosticsViewController: UIViewController {
    var onReset: (() -> Void)?
    var details = "Starting" { didSet { if isViewLoaded { text.text = details } } }
    private let text = UITextView()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.accessibilityViewIsModal = true
        let title = USIInterface.label("Diagnostics", style: .title2)
        title.accessibilityTraits.insert(.header)
        text.text = details
        text.isEditable = false
        text.font = .preferredFont(forTextStyle: .body)
        text.adjustsFontForContentSizeCategory = true
        text.backgroundColor = .secondarySystemBackground
        text.accessibilityLabel = "Capture diagnostics"
        let reset = USIInterface.button("Reset Tracking…", id: "diagnostics.reset") { [weak self] in self?.confirmReset() }
        let done = USIInterface.button("Done", primary: true, id: "diagnostics.done") { [weak self] in
            self?.dismiss(animated: !UIAccessibility.isReduceMotionEnabled)
        }
        let actions = USIInterface.stack([reset, done], axis: .horizontal)
        actions.distribution = .fillEqually
        let stack = USIInterface.stack([title, text, actions])
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8)
        ])
    }

    private func confirmReset() {
        let alert = UIAlertController(title: "Reset camera tracking?",
            message: "This starts a new tracking session and changes the camera’s coordinate origin.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Reset Tracking", style: .destructive) { [weak self] _ in self?.onReset?() })
        present(alert, animated: !UIAccessibility.isReduceMotionEnabled)
    }
}
