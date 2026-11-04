import Foundation
import XCTest
@testable import USIWire

final class USISealCalibrationTests: XCTestCase {
    private func feed(_ state: inout USILiveSensorState, values: [Int32], start: UInt32 = 0,
                      base: UInt64 = 1_000_000_000, error: UInt8 = 0, count: Int = 100) throws {
        for i in 0..<count {
            let p = values.enumerated().map { error & (1 << $0.offset) == 0 ? $0.element : -100 }
            try state.receive(.pressure(7, [USIBLEPressureSample(rawSequence: start + UInt32(i),
                sourceTimeUs: UInt64(i) * 7000, pressuresCentiPa: p, qualityErrorMask: error)]),
                receivedNs: base + UInt64(i) * 7_000_000)
        }
    }

    func testMeasuredReferencesDriveColorsAndSurviveReconnectWithoutOldReadings() throws {
        let profile = try USISealCalibrationProfile(openKPaAbs: [100, 101, 102], sealedKPaAbs: [40, 41, 42])
        var state = USILiveSensorState()
        state.connect()
        state.selectCalibration(try profile.calibration())
        try feed(&state, values: [4_000_000, 10_100_000, 4_200_000])
        XCTAssertEqual(state.snapshot(nowNs: 1_700_000_000).seal.states, [.sealed, .unsealed, .sealed])
        state.disconnect()
        state.connect()
        XCTAssertEqual(state.snapshot(nowNs: 2_000_000_000).seal.pressuresKPaAbs, [nil, nil, nil])
        try feed(&state, values: [4_000_000, 4_100_000, 4_200_000], base: 2_000_000_000)
        XCTAssertEqual(state.snapshot(nowNs: 2_700_000_000).seal.aggregate, .full)
        try state.receive(.pressure(7, [USIBLEPressureSample(rawSequence: 100, sourceTimeUs: 700000,
            pressuresCentiPa: [4_000_000, 4_100_000, -100], qualityErrorMask: 4)]), receivedNs: 2_710_000_000)
        XCTAssertEqual(state.snapshot(nowNs: 2_710_000_001).seal.states, [.sealed, .sealed, .invalid])
        XCTAssertEqual(state.snapshot(nowNs: 3_000_000_000).seal.states, [.stale, .stale, .stale])
    }

    func testCaptureRejectsStaleInvalidAndUnstableSensorWindows() throws {
        var state = USILiveSensorState(); state.connect()
        XCTAssertThrowsError(try state.calibrationReference(nowNs: 1))
        try feed(&state, values: [10_000_000, 10_100_000, 10_200_000])
        XCTAssertEqual(try state.calibrationReference(nowNs: 1_700_000_000), [100, 101, 102])
        XCTAssertThrowsError(try state.calibrationReference(nowNs: 2_000_000_000))
        try feed(&state, values: [10_000_000, 10_100_000, 10_200_000], start: 100, base: 2_000_000_000, error: 4)
        XCTAssertThrowsError(try state.calibrationReference(nowNs: 2_700_000_000))
        var changing = USILiveSensorState(); changing.connect()
        try feed(&changing, values: [10_000_000, 10_100_000, 10_200_000])
        try feed(&changing, values: [8_000_000, 8_100_000, 8_200_000], start: 100, base: 1_700_000_000, count: 30)
        XCTAssertThrowsError(try changing.calibrationReference(nowNs: 1_910_000_000))
    }

    func testNoVacuumOrWrongPressureDirectionCannotProduceCalibration() throws {
        for closed in [[99.0, 99, 99], [110, 110, 110], [40, 100, 40], [Double.nan, 40, 40]] {
            XCTAssertThrowsError(try USISealCalibrationProfile(openKPaAbs: [100, 100, 100], sealedKPaAbs: closed))
        }
        XCTAssertThrowsError(try USISealCalibrationProfile(openKPaAbs: [100], sealedKPaAbs: [40]))
    }

    func testSavedProfileRoundTripAndCorruptDataNeverBecomesCalibration() throws {
        let p = try USISealCalibrationProfile(openKPaAbs: [100, 100, 100], sealedKPaAbs: [40, 40, 40])
        let data = try JSONEncoder().encode(p)
        let restored = try JSONDecoder().decode(USISealCalibrationProfile.self, from: data)
        XCTAssertEqual(try restored.calibration(), try p.calibration())
        let suite = "usi-calibration-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try p.save(to: defaults)
        XCTAssertEqual(try USISealCalibrationProfile.load(from: defaults)?.calibration(), try p.calibration())
        let bad = Data("{\"id\":\"bad\",\"openKPaAbs\":[100,100,100],\"sealedKPaAbs\":[200,200,200]}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(USISealCalibrationProfile.self, from: bad).calibration())
        defaults.set(bad, forKey: USISealCalibrationProfile.defaultsKey)
        XCTAssertNil(USISealCalibrationProfile.load(from: defaults))
    }
}
