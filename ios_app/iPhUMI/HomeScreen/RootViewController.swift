//
//  RootViewController.swift
//  iPhUMI
//
//  Created by Austin Patel on 1/31/25.
//  Copyright © 2025 Apple. All rights reserved.
//

import UIKit

class RootViewController: UIViewController {
    private var restoredInitialMode = false
        
    @IBOutlet weak var versionLabel: UILabel!
    override func viewDidLoad() {
        super.viewDidLoad()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
        configureHome(version: "\(bundleID) · v\(version)")
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Restore on launch once; returning Home must reveal all three modes.
        guard !restoredInitialMode else { return }
        restoredInitialMode = true
        let defaults = UserDefaults.standard
        var appMode = defaults.object(forKey: "appMode") as? String
        
        if appMode == "demonstration" {
            collectDemonstration()
        } else if appMode == "deployment" {
            startDeployment()
        } else if appMode == "usi_stream" {
            startUSIStream()
        }
    }

    private func configureHome(version: String) {
        // Keep the storyboard's stock controller identifiers/actions; lay out three
        // entries so the added mode also fits the landscape iPhone screen.
        // Removing the old controls also removes their constraints. Preserve
        // UIKit's root/safe-area constraints so the new menu stays on screen.
        view.subviews.forEach { $0.removeFromSuperview() }
        let title = UILabel()
        title.text = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "iPhUMI"
        title.font = .systemFont(ofSize: 32, weight: .semibold)
        title.textAlignment = .center
        let versionText = UILabel()
        versionText.text = version
        versionText.font = .systemFont(ofSize: 13)
        versionText.textAlignment = .center
        versionText.textColor = .secondaryLabel
        versionText.adjustsFontSizeToFitWidth = true
        let collect = homeButton("Collect Demonstrations", action: #selector(collectDemonstrationButtonPress(_:)))
        let deployment = homeButton("Deployment Mode", action: #selector(startDeploymentButtonPress(_:)))
        let stream = homeButton("USI Stream", action: #selector(startUSIStream))
        let stack = UIStackView(arrangedSubviews: [title, versionText, collect, deployment, stream])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        let preferredWidth = stack.widthAnchor.constraint(equalToConstant: 400)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 400),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            preferredWidth
        ])
    }

    private func homeButton(_ title: String, action: Selector) -> UIButton {
        let button = UIButton(configuration: .filled())
        button.setTitle(title, for: .normal)
        button.heightAnchor.constraint(equalToConstant: 48).isActive = true
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    @objc private func startUSIStream() {
        UserDefaults.standard.set("usi_stream", forKey: "appMode")
        let controller = USIStreamViewController()
        controller.modalPresentationStyle = .fullScreen
        present(controller, animated: true)
    }
    
    func collectDemonstration() {
        let defaults = UserDefaults.standard
        defaults.set("demonstration", forKey: "appMode")
        
        let storyboard = UIStoryboard(name: "Main", bundle: nil)
        let secondVC = storyboard.instantiateViewController(identifier: "DemonstrationViewController")

        secondVC.modalPresentationStyle = .fullScreen
        secondVC.modalTransitionStyle = .crossDissolve

        present(secondVC, animated: true, completion: nil)
    }
    
    func startDeployment() {
        guard UserDefaults.standard.object(forKey: "arKitUltrawideLensPosition") != nil else {
            UserDefaults.standard.removeObject(forKey: "appMode")
            let alert = UIAlertController(
                title: "Camera Not Initialized",
                message: "Camera parameters have not been initialized yet. Please open the Data Collection interface first so ARKit can run and calibrate the camera, then return here to start deployment.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }

        let defaults = UserDefaults.standard
        defaults.set("deployment", forKey: "appMode")

        let storyboard = UIStoryboard(name: "Main", bundle: nil)
        let secondVC = storyboard.instantiateViewController(identifier: "DeploymentViewController")

        secondVC.modalPresentationStyle = .fullScreen
        secondVC.modalTransitionStyle = .crossDissolve

        present(secondVC, animated: true, completion: nil)
    }
    @IBAction func collectDemonstrationButtonPress(_ sender: Any) {
        collectDemonstration()
    }
    @IBAction func startDeploymentButtonPress(_ sender: Any) {
        startDeployment()
    }
}
