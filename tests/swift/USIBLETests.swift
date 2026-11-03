import Foundation
import XCTest
@testable import USIWire

final class USIBLETests: XCTestCase {
    func golden(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/ble_\(name).hex")
        let text = try String(contentsOf: url).filter { !$0.isWhitespace }
        let chars = Array(text); return Data(try stride(from: 0, to: chars.count, by: 2).map { try XCTUnwrap(UInt8(String(chars[$0...$0+1]), radix: 16)) })
    }
    func testGoldenPressureQualityAndEpochs() throws {
        guard case .pressure(let boot, let samples) = try USIBLECodec.decode(golden("pressure")) else { return XCTFail() }
        XCTAssertEqual(boot, 0x12345678); XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples[0].pressuresCentiPa, [10132500,-100,9000000])
        XCTAssertEqual(samples[0].qualityErrorMask, 2); XCTAssertEqual(samples[0].qualityMask, 5)
        XCTAssertEqual(samples[0].pressuresKPaAbs, [101.325,-0.001,90])
        var history = USISequenceHistory()
        XCTAssertEqual(try history.observe(epoch: "a", rawSequence: UInt64(samples[0].rawSequence)).sequence, 0xffffffff)
        XCTAssertEqual(try history.observe(epoch: "a", rawSequence: UInt64(samples[1].rawSequence)).sequence, 0x100000000)
        XCTAssertEqual(try history.observe(epoch: "b", rawSequence: 0).sequence, 0)
        XCTAssertEqual(try history.observe(epoch: "a", rawSequence: 1).disposition, .oldEpoch)
        var seal = USISealModel(calibration: nil)
        try seal.update(pressuresKPaAbs: samples[0].pressuresKPaAbs, qualityMask: samples[0].qualityMask, receivedNs: 1)
        XCTAssertEqual(seal.snapshot(nowNs: 2).states[1], .invalid)
        XCTAssertEqual(seal.snapshot(nowNs: 250000002).states, [.stale,.stale,.stale])
    }
    func testTriggerClockAndRequest() throws {
        guard case .trigger(_, let t) = try USIBLECodec.decode(golden("trigger")) else { return XCTFail() }
        XCTAssertTrue(t.pressed); XCTAssertFalse(t.suctionOn); XCTAssertFalse(t.heartbeat)
        XCTAssertEqual(t.sourceTimeUs, 1000001); XCTAssertEqual(t.rawSequence, 7)
        guard case .clock(let boot, let c) = try USIBLECodec.decode(golden("clock")) else { return XCTFail() }
        XCTAssertEqual(boot, 0x12345678); XCTAssertEqual(c.requestID, 42)
        XCTAssertEqual(c.t1PhoneNs, 1000000000); XCTAssertEqual(c.t2DeviceUs, 1000100)
        XCTAssertEqual(c.t3DeviceUs, 1000300); XCTAssertEqual(c.snapshotDeviceUs, 1000200)
        XCTAssertEqual(c.pressureAcquired, 0x100000001); XCTAssertEqual(c.pressureNotifyLost, 5)
        XCTAssertEqual(c.notifyFailures, 2)
        XCTAssertEqual(USIBLECodec.clockRequest(requestID: 42, t1PhoneNs: 1000000000), try golden("request"))
    }
    func testFragmentsMTU20AndBounds() throws {
        let raw = try golden("pressure")
        for size in [20,21,64,244] {
            var r = USIBLEReassembler(); let parts = try USIBLECodec.fragment(raw, messageID: 9, payloadSize: size)
            for (i,p) in parts.enumerated() {
                XCTAssertEqual(try r.feed(p, receivedNs: UInt64(i)), i == parts.count-1 ? raw : nil)
            }
            XCTAssertEqual(r.discarded, 0)
            XCTAssertThrowsError(try r.feed(parts[0], receivedNs: 100))
        }
        for size in [19,245] { XCTAssertThrowsError(try USIBLECodec.fragment(raw, messageID: 0, payloadSize: size)) }
        XCTAssertThrowsError(try USIBLECodec.fragment(Data(repeating: 0, count: 257), messageID: 0))
    }
    func testRejectPartialDuplicateOrderOversizedTimeoutAndReset() throws {
        let parts = try USIBLECodec.fragment(golden("pressure"), messageID: 9)
        var malformed = parts[1]; malformed[1] = 2
        var oversized = parts[1]; oversized.append(Data(repeating: 0, count: 245))
        for bad in [parts[0], parts[2], malformed, oversized, Data(parts[1].prefix(10))] {
            var r = USIBLEReassembler(); XCTAssertNil(try r.feed(parts[0], receivedNs: 0))
            XCTAssertThrowsError(try r.feed(bad, receivedNs: 1)); XCTAssertEqual(r.discarded, 1)
            XCTAssertThrowsError(try r.feed(parts[1], receivedNs: 2))
        }
        var r = USIBLEReassembler(); _ = try r.feed(parts[0], receivedNs: 0)
        XCTAssertThrowsError(try r.feed(parts[1], receivedNs: 500000001))
        r.reset()
        for id: UInt32 in [0xffffffff, 0] {
            var result: Data?
            for p in try USIBLECodec.fragment(golden("trigger"), messageID: id) { result = try r.feed(p, receivedNs: 1) }
            XCTAssertEqual(result, try golden("trigger"))
        }
    }
    func testLogicalTruncationUnknownAndQuality() throws {
        for name in ["pressure","trigger","clock"] {
            let raw = try golden(name)
            for n in 0..<raw.count { XCTAssertThrowsError(try USIBLECodec.decode(Data(raw.prefix(n)))) }
            XCTAssertThrowsError(try USIBLECodec.decode(raw + Data([0])))
            var bad=raw; bad[0]=99; XCTAssertThrowsError(try USIBLECodec.decode(bad))
            bad=raw; bad.replaceSubrange(1..<5, with: [0,0,0,0]); XCTAssertThrowsError(try USIBLECodec.decode(bad))
        }
        var p = try golden("pressure"); p[30]=8
        XCTAssertThrowsError(try USIBLECodec.decode(p))
        p = try golden("pressure"); p.replaceSubrange(18..<22, with: [0x9c,0xff,0xff,0xff])
        XCTAssertThrowsError(try USIBLECodec.decode(p))
        var t = try golden("trigger"); t[17]=2
        XCTAssertThrowsError(try USIBLECodec.decode(t))
    }
    func testInFlightIDsAdvanceEvenWhenAbandoned() throws {
        let trigger = try golden("trigger")
        func first(_ id: UInt32) throws -> Data {
            try USIBLECodec.fragment(trigger, messageID: id)[0]
        }
        let rejected: [(UInt32,UInt32)] = [(10,9),(10,10),(10,0x8000000a)]
        for (previous,candidate) in rejected {
            var r = USIBLEReassembler(); XCTAssertNil(try r.feed(first(previous), receivedNs: 0))
            XCTAssertThrowsError(try r.feed(first(candidate), receivedNs: 1))
            XCTAssertEqual(r.discarded,1)
            XCTAssertThrowsError(try r.feed(first(previous), receivedNs: 2))
        }
        var r = USIBLEReassembler()
        for part in try USIBLECodec.fragment(trigger, messageID: 8) {
            _ = try r.feed(part, receivedNs: 0)
        }
        XCTAssertNil(try r.feed(first(10), receivedNs: 1))
        XCTAssertThrowsError(try r.feed(first(9), receivedNs: 2))
        r = USIBLEReassembler()
        XCTAssertNil(try r.feed(first(10), receivedNs: 0))
        XCTAssertNil(try r.feed(first(11), receivedNs: 1)); XCTAssertEqual(r.discarded,1)
        XCTAssertThrowsError(try r.feed(first(10), receivedNs: 2))
        r = USIBLEReassembler()
        XCTAssertNil(try r.feed(first(0xffffffff), receivedNs: 0))
        XCTAssertNil(try r.feed(first(0), receivedNs: 1)); XCTAssertEqual(r.discarded,1)
        var result: Data?
        for part in try USIBLECodec.fragment(trigger, messageID: 0).dropFirst() {
            result = try r.feed(part, receivedNs: 2)
        }
        XCTAssertEqual(result,trigger)
        r = USIBLEReassembler()
        XCTAssertNil(try r.feed(first(10), receivedNs: 0))
        let latePart = try USIBLECodec.fragment(trigger, messageID: 10)[1]
        XCTAssertThrowsError(try r.feed(latePart, receivedNs: 500_000_001))
        XCTAssertThrowsError(try r.feed(first(9), receivedNs: 500_000_002))
        XCTAssertNil(try r.feed(first(11), receivedNs: 500_000_003))
    }
}

extension USIBLETests {
    func testProgressSeedAfterWrap() throws {
        var tracker = try USIBLEProgressTracker(capacity: 3)
        XCTAssertNil(try tracker.receive(raw: UInt32.max))
        XCTAssertNil(try tracker.receive(raw: 5))
        XCTAssertEqual(try tracker.seed(nextSourceCount: (UInt64(1) << 32) + 6), [UInt64(UInt32.max), (UInt64(1) << 32) + 5])
        XCTAssertEqual(try tracker.receive(raw: 6), (UInt64(1) << 32) + 6)
        XCTAssertThrowsError(try tracker.receive(raw: 6))
    }
    func testProgressSeedRejectsAmbiguityAndBounds() throws {
        var tracker = try USIBLEProgressTracker(capacity: 1)
        XCTAssertNil(try tracker.receive(raw: 10))
        XCTAssertThrowsError(try tracker.receive(raw: 11))
        XCTAssertThrowsError(try tracker.seed(nextSourceCount: 10))
        XCTAssertEqual(try tracker.seed(nextSourceCount: 11), [10])
        XCTAssertThrowsError(try tracker.seed(nextSourceCount: 11))
        var empty = try USIBLEProgressTracker(capacity: 2)
        XCTAssertEqual(try empty.seed(nextSourceCount: (UInt64(1) << 32) + 9), [])
        XCTAssertEqual(try empty.receive(raw: 9), (UInt64(1) << 32) + 9)
        XCTAssertThrowsError(try empty.receive(raw: 8))
    }
}
