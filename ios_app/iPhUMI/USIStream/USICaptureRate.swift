import Foundation

enum USICaptureRate: Int, CaseIterable {
    case fps30 = 30, fps60 = 60
    static let defaultsKey = "usi.cameraFPS"

    static func load(defaults: UserDefaults = .standard) -> USICaptureRate {
        USICaptureRate(rawValue: defaults.integer(forKey: defaultsKey)) ?? .fps30
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}
