import UIKit

/// Runs the real UIKit views without ARKit, a camera or a USB connection.
@main
final class LayoutProbe: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var results: [[String: Any]] = []
    private var cases = ["home", "live", "home-large-text", "live-large-text", "diagnostics", "diagnostics-large-text"]

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = UIViewController()
        window?.makeKeyAndVisible()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.nextCase() }
        return true
    }

    private func nextCase() {
        guard !cases.isEmpty else {
            let report: [String: Any] = ["cases": results, "passed": results.allSatisfy { ($0["errors"] as? [String])?.isEmpty == true }]
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("layout-result.json"), options: .atomic)
            return
        }
        let name = cases.removeFirst()
        let controller = name.hasPrefix("diagnostics") ? USIDiagnosticsViewController() : UIViewController()
        controller.overrideUserInterfaceStyle = .dark
        controller.traitOverrides.preferredContentSizeCategory = name.contains("large") ? .accessibilityExtraExtraExtraLarge : .large
        if name.hasPrefix("home") {
            controller.view = USIHomeView(title: "Suction UMI v2")
        } else if !name.hasPrefix("diagnostics") {
            let live = USILiveView(frame: .zero)
            live.setUSBStatus("USB disconnected — waiting for Ubuntu to reconnect")
            live.apply(USIPreviewDetails(tracking: "Insufficient features — point at a textured surface",
                cameraRate: "30.0 FPS", depth: "256 × 192", diagnostics: "Probe fixture", isCapturing: true))
            live.preview.image = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 480)).image { context in
                UIColor.darkGray.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
            }
            controller.view = live
        }
        window?.rootViewController = controller
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.inspect(controller, name: name) }
    }

    private func inspect(_ controller: UIViewController, name: String) {
        let root = controller.view!
        root.layoutIfNeeded()
        var errors: [String] = []
        let safe = root.safeAreaLayoutGuide.layoutFrame
        if root.bounds.width <= root.bounds.height { errors.append("Expected landscape") }
        let buttons = descendants(root).compactMap { $0 as? UIButton }
            .filter { $0.accessibilityIdentifier != nil }
        if buttons.count != (name.hasPrefix("home") ? 3 : 2) { errors.append("Missing navigation controls") }
        for button in buttons {
            if name.hasPrefix("home"), let scroll = ancestors(button).compactMap({ $0 as? UIScrollView }).first {
                scroll.scrollRectToVisible(button.convert(button.bounds, to: scroll), animated: false)
                root.layoutIfNeeded()
            }
            let rect = button.convert(button.bounds, to: root)
            if !safe.insetBy(dx: -1, dy: -1).contains(rect) {
                errors.append("Off-screen control: \(button.accessibilityIdentifier!)")
            }
            if rect.width < 44 || rect.height < 44 { errors.append("Small touch target") }
            if button.accessibilityLabel?.isEmpty != false { errors.append("Missing accessible control label") }
            for label in descendants(button).compactMap({ $0 as? UILabel }) where !label.isHidden && !(label.text ?? "").isEmpty {
                let textRect = label.convert(label.bounds, to: button)
                if !button.bounds.insetBy(dx: -1, dy: -1).contains(textRect) {
                    errors.append("Button text extends outside control: \(button.accessibilityIdentifier!)")
                }
                let text = label.attributedText ?? NSAttributedString(string: label.text ?? "", attributes: [.font: label.font!])
                let required = text.boundingRect(with: CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height
                if label.bounds.height + 2 < required { errors.append("Clipped button text: \(button.accessibilityIdentifier!)") }
            }
        }
        for scroll in descendants(root).compactMap({ $0 as? UIScrollView }) {
            if scroll.contentSize.width > scroll.bounds.width + 1 { errors.append("Unexpected horizontal scrolling") }
        }
        for label in descendants(root).compactMap({ $0 as? UILabel }).filter({ $0.accessibilityIdentifier != nil }) {
            let required = label.sizeThatFits(CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude)).height
            if label.bounds.height + 1 < required { errors.append("Clipped text: \(label.accessibilityIdentifier!)") }
        }
        if let live = root as? USILiveView, !name.contains("large") {
            let rect = live.preview.convert(live.preview.bounds, to: root)
            if !safe.insetBy(dx: -1, dy: -1).contains(rect) { errors.append("Camera image enlarged the viewport") }
        }
        if let home = root as? USIHomeView {
            home.scrollView.setContentOffset(.zero, animated: false)
        }
        root.layoutIfNeeded()
        let renderer = UIGraphicsImageRenderer(bounds: root.bounds)
        let screenshot = renderer.image { _ in root.drawHierarchy(in: root.bounds, afterScreenUpdates: true) }
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try! screenshot.pngData()!.write(to: directory.appendingPathComponent("\(name).png"))
        results.append(["name": name, "width": root.bounds.width, "height": root.bounds.height, "errors": errors])
        nextCase()
    }

    private func descendants(_ view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    private func ancestors(_ view: UIView) -> [UIView] {
        guard let parent = view.superview else { return [] }
        return [parent] + ancestors(parent)
    }
}
