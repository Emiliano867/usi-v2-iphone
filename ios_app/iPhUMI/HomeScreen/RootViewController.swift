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
        configureHome()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Restore on launch once; returning Home must reveal all three modes.
        guard !restoredInitialMode else { return }
        restoredInitialMode = true
        let defaults = UserDefaults.standard
        let appMode = defaults.object(forKey: "appMode") as? String
        
        if appMode == "demonstration" {
            collectDemonstration()
        } else if appMode == "deployment" {
            startDeployment()
        } else if appMode == "usi_stream" {
            startUSIStream()
        }
    }

    private func configureHome() {
        // Removing controls removes their constraints; preserve UIKit's safe area.
        view.subviews.forEach { $0.removeFromSuperview() }
        let home = USIHomeView(title: Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Suction UMI v2")
        home.onStream = { [weak self] in self?.startUSIStream() }
        home.onCollect = { [weak self] in self?.collectDemonstration() }
        home.onDeploy = { [weak self] in self?.startDeployment() }
        home.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(home)
        NSLayoutConstraint.activate([
            home.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            home.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            home.topAnchor.constraint(equalTo: view.topAnchor),
            home.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
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
