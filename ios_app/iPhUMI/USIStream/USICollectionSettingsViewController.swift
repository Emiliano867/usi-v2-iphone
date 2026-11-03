import UIKit

final class USICollectionSettingsViewController: UIViewController {
    var onSave: (() -> Void)?
    private var fields: [(String, UITextField)] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.accessibilityViewIsModal = true
        let heading = USICollectionView.label("Collection Settings", style: .title2)
        let stack = UIStackView(arrangedSubviews: [heading])
        stack.axis = .vertical; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false
        for (key, title) in [("usi.session", "Session"), ("usi.task", "Task label"), ("usi.gripper", "Gripper ID"), ("usi.calibration", "Calibration label (optional)")] {
            let field = UITextField()
            field.borderStyle = .roundedRect
            field.font = .preferredFont(forTextStyle: .body)
            field.adjustsFontForContentSizeCategory = true
            field.autocorrectionType = .no
            field.accessibilityLabel = title
            field.placeholder = title
            field.text = UserDefaults.standard.string(forKey: key)
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            stack.addArrangedSubview(USICollectionView.label(title, style: .caption1))
            stack.addArrangedSubview(field)
            fields.append((key, field))
        }
        stack.addArrangedSubview(USICollectionView.label("Labels are saved on this phone. Pressure thresholds and sensor mapping are not connected yet; the seal indicator stays unknown.", style: .footnote))
        let done = UIButton(configuration: .filled())
        done.setTitle("Save and Done", for: .normal)
        done.accessibilityLabel = "Save settings and return to live camera"
        done.titleLabel?.adjustsFontForContentSizeCategory = true
        done.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        done.translatesAutoresizingMaskIntoConstraints = false
        done.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            for (key, field) in self.fields {
                UserDefaults.standard.set(String((field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(128)), forKey: key)
            }
            self.onSave?()
            self.dismiss(animated: !UIAccessibility.isReduceMotionEnabled)
        }, for: .touchUpInside)
        let scroll = UIScrollView()
        scroll.keyboardDismissMode = .interactive
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll); view.addSubview(done); scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: done.topAnchor, constant: -8),
            done.leadingAnchor.constraint(equalTo: scroll.leadingAnchor), done.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            done.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)
        ])
    }
}
