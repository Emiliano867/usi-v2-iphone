import Foundation
import XCTest
@testable import USIWire

/// Synthetic transport events exercise display freshness, never hardware throughput.
final class USILiveSensorTests: XCTestCase {
    private func pressure(_ sequence: UInt32 = 1, mask: UInt8 = 0) -> USIBLEEvent {
        .pressure(7, [USIBLEPressureSample(rawSequence: sequence, sourceTimeUs: 50,
            pressuresCentiPa: [10_132_500, mask & 2 == 0 ? 9_500_000 : -100, 0], qualityErrorMask: mask)])
    }

    func testFreshUncalibratedPressureHasNumbersButNoGreenSectors() throws {
        var state = USILiveSensorState()
        state.connect()
        try state.receive(pressure(), receivedNs: 100)
        let view = state.snapshot(nowNs: 101)
        XCTAssertEqual(view.seal.pressuresKPaAbs, [101.325, 95, 0])
        XCTAssertEqual(view.seal.states, [.uncalibrated, .uncalibrated, .uncalibrated])
        XCTAssertEqual(view.suction, .unknown)
        XCTAssertEqual(view.pressureSamples, 1)
    }

    func testInvalidAndExpiredMeasurementsDoNotRemainOnScreen() throws {
        var state = USILiveSensorState()
        state.connect()
        try state.receive(pressure(mask: 2), receivedNs: 100)
        XCTAssertEqual(state.snapshot(nowNs: 101).seal.pressuresKPaAbs, [101.325, nil, 0])
        let stale = state.snapshot(nowNs: 250_000_101)
        XCTAssertEqual(stale.seal.pressuresKPaAbs, [nil, nil, nil])
        XCTAssertEqual(stale.seal.states, [.stale, .stale, .stale])
    }

    func testTriggerIsIndependentFromPressureAndExpires() throws {
        var state = USILiveSensorState()
        state.connect()
        try state.receive(.trigger(7, USIBLETrigger(rawSequence: 1, sourceTimeUs: 50,
            pressed: false, heartbeat: true)), receivedNs: 100)
        XCTAssertEqual(state.snapshot(nowNs: 101).suction, .on)
        XCTAssertEqual(state.snapshot(nowNs: 101).seal.pressuresKPaAbs, [nil, nil, nil])
        try state.receive(.trigger(7, USIBLETrigger(rawSequence: 2, sourceTimeUs: 60,
            pressed: true, heartbeat: false)), receivedNs: 200)
        XCTAssertEqual(state.snapshot(nowNs: 201).suction, .off)
        XCTAssertEqual(state.snapshot(nowNs: 1_000_000_201).suction, .unknown)
    }

    func testDuplicateCannotRefreshOldPressureAndGapsAreCounted() throws {
        var state = USILiveSensorState()
        state.connect()
        try state.receive(pressure(), receivedNs: 100)
        try state.receive(pressure(), receivedNs: 250_000_000)
        XCTAssertEqual(state.snapshot(nowNs: 250_000_101).seal.pressuresKPaAbs, [nil, nil, nil])
        try state.receive(pressure(4), receivedNs: 300_000_000)
        let view = state.snapshot(nowNs: 300_000_001)
        XCTAssertEqual(view.pressureSamples, 2)
        XCTAssertEqual(view.missingPressureSamples, 2)
        XCTAssertEqual(view.duplicates, 1)
    }

    func testDisconnectClearsNumbersAndNewConnectionMayRestartSequence() throws {
        var state = USILiveSensorState()
        state.connect()
        try state.receive(pressure(100), receivedNs: 100)
        state.disconnect()
        XCTAssertEqual(state.snapshot(nowNs: 101).seal.pressuresKPaAbs, [nil, nil, nil])
        XCTAssertThrowsError(try state.receive(pressure(), receivedNs: 102))
        state.connect()
        try state.receive(pressure(), receivedNs: 200)
        XCTAssertEqual(state.snapshot(nowNs: 201).pressureSamples, 1)
    }

    func testBootChangeCannotCombineMeasurementsAcrossDevices() throws {
        var state = USILiveSensorState()
        state.connect()
        try state.receive(pressure(), receivedNs: 100)
        XCTAssertThrowsError(try state.receive(.trigger(8, USIBLETrigger(rawSequence: 1,
            sourceTimeUs: 60, pressed: false, heartbeat: true)), receivedNs: 101))
        XCTAssertEqual(state.snapshot(nowNs: 102).suction, .unknown)
    }
}
