import UIKit

final class USICollectionSettingsViewController: UIViewController {
    var onSave: (() -> Void)?
    var onReference: ((@escaping (Result<[Double], Error>) -> Void) -> Void)?
    var onUseCalibration: ((USISealCalibrationProfile?) -> Void)?
    private var fields: [(String, UITextField)] = []
    private var openReference: [Double]?
    private var sealedReference: [Double]?
    private let calibrationStatus = USICollectionView.label("", style: .footnote)
    private let openStatus = USICollectionView.label("Open: not captured", style: .body)
    private let sealedStatus = USICollectionView.label("Sealed: not captured", style: .body)
    private let useCalibration = UIButton(configuration: .filled())
    private let cameraRate = UISegmentedControl(items: ["30 FPS", "60 FPS"])

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.accessibilityViewIsModal = true
        let heading = USICollectionView.label("Collection Settings", style: .title2)
        let stack = UIStackView(arrangedSubviews: [heading])
        stack.axis = .vertical; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(USICollectionView.label("Camera frame rate", style: .headline))
        cameraRate.selectedSegmentIndex = USICaptureRate.load() == .fps60 ? 1 : 0
        cameraRate.accessibilityLabel = "Camera frame rate"
        cameraRate.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        stack.addArrangedSubview(cameraRate)
        stack.addArrangedSubview(USICollectionView.label("30 FPS reduces camera load. 60 FPS needs a cool phone. Saving a changed rate restarts AR tracking; finish your trial first.", style: .footnote))
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
        stack.addArrangedSubview(USICollectionView.label("Pressure seal calibration", style: .title2))
        stack.addArrangedSubview(USICollectionView.label("1. Leave the cups open with suction OFF. Wait for steady pressure, then capture Open.\n2. Seal all three cups against a flat surface with suction ON. Wait for steady pressure, then capture Sealed.\n3. Use calibration to enable green/red sectors.", style: .body))
        stack.addArrangedSubview(openStatus)
        stack.addArrangedSubview(calibrationButton("Capture Open", action: { [weak self] in self?.captureReference(sealed: false) }))
        stack.addArrangedSubview(sealedStatus)
        stack.addArrangedSubview(calibrationButton("Capture Sealed", action: { [weak self] in self?.captureReference(sealed: true) }))
        useCalibration.setTitle("Use calibration", for: .normal)
        useCalibration.titleLabel?.adjustsFontForContentSizeCategory = true
        useCalibration.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        useCalibration.isEnabled = false
        useCalibration.addAction(UIAction { [weak self] _ in self?.applyCalibration() }, for: .touchUpInside)
        stack.addArrangedSubview(useCalibration)
        stack.addArrangedSubview(calibrationStatus)
        stack.addArrangedSubview(calibrationButton("Clear seal calibration", action: { [weak self] in
            UserDefaults.standard.removeObject(forKey: USISealCalibrationProfile.defaultsKey)
            self?.onUseCalibration?(nil)
            self?.calibrationStatus.text = "No calibration. Fresh pressure numbers still display; sectors are gray."
        }))
        stack.addArrangedSubview(USICollectionView.label("Green = calibrated pressure seal; red = no pressure seal; gray = unavailable or uncalibrated. C1/C2/C3 correspond to sensor channels 0/5/6. Verify each cup's numbered channel before relying on the display. Recalibrate after changing cups or tubing. This two-point preview does not measure holding force; validate it with partial seals and leaks.", style: .footnote))
        showSavedCalibration()
        let done = UIButton(configuration: .filled())
        done.setTitle("Save and Done", for: .normal)
        done.accessibilityLabel = "Save settings and return to live camera"
        done.titleLabel?.adjustsFontForContentSizeCategory = true
        done.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        done.translatesAutoresizingMaskIntoConstraints = false
        done.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            (self.cameraRate.selectedSegmentIndex == 1 ? USICaptureRate.fps60 : .fps30).save()
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

    private func calibrationButton(_ title: String, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(configuration: .bordered())
        button.setTitle(title, for: .normal)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    private func captureReference(sealed: Bool) {
        guard let onReference else { return }
        onReference { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let values):
                let text = zip(["C1", "C2", "C3"], values).map { "\($0) \(String(format: "%.1f", $1))" }.joined(separator: " · ") + " kPa abs"
                if sealed {
                    self.sealedReference = values; self.sealedStatus.text = "Sealed: \(text)"
                } else {
                    // A new open baseline invalidates the old sealed draft.
                    self.openReference = values; self.openStatus.text = "Open: \(text)"
                    self.sealedReference = nil; self.sealedStatus.text = "Sealed: not captured"
                }
                self.calibrationStatus.text = "Captured steady live pressures. Saved calibration changes only when you tap Use calibration."
            case .failure(let error): self.calibrationStatus.text = error.localizedDescription
            }
            self.useCalibration.isEnabled = self.openReference != nil && self.sealedReference != nil
        }
    }

    private func applyCalibration() {
        guard let openReference, let sealedReference else { return }
        do {
            let profile = try USISealCalibrationProfile(openKPaAbs: openReference, sealedKPaAbs: sealedReference)
            try profile.save()
            onUseCalibration?(profile)
            showSavedCalibration()
        } catch { calibrationStatus.text = error.localizedDescription }
    }

    private func showSavedCalibration() {
        guard let profile = USISealCalibrationProfile.load(), let calibration = try? profile.calibration() else {
            calibrationStatus.text = "No saved pressure calibration. Capture Open and Sealed to enable colors."
            return
        }
        calibrationStatus.text = "Saved on this phone. Green below / red above (kPa abs):\n" + calibration.chambers.enumerated().map { index, chamber in
            String(format: "C%d  %.1f / %.1f", index + 1, chamber.sealOnKPaAbs, chamber.sealOffKPaAbs)
        }.joined(separator: "\n") + "\n200 ms persistence prevents color flicker."
    }
}
