import Foundation
import XCTest
@testable import USIWire

final class USICaptureRateTests: XCTestCase {
    func testPresentationDefaultAndSavedRateSelection() {
        let name = "usi-rate-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(USICaptureRate.load(defaults: defaults).rawValue, 30)
        USICaptureRate.fps60.save(defaults: defaults)
        XCTAssertEqual(USICaptureRate.load(defaults: defaults).rawValue, 60)
        USICaptureRate.fps30.save(defaults: defaults)
        XCTAssertEqual(USICaptureRate.load(defaults: defaults).rawValue, 30)
        defaults.set(120, forKey: USICaptureRate.defaultsKey)
        XCTAssertEqual(USICaptureRate.load(defaults: defaults).rawValue, 30)
    }
}
