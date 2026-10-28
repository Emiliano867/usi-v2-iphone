// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "USIWire",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "USIWire", path: "ios_app/iPhUMI/USIStream",
                exclude: ["USIUSBServer.swift", "USIFrameEncoder.swift", "USIStreamViewController.swift", "USIInterface.swift"],
                sources: ["USIWireProtocol.swift", "USIPreviewMailbox.swift"]),
        .testTarget(name: "USIWireTests", dependencies: ["USIWire"], path: "tests/swift")
    ]
)
