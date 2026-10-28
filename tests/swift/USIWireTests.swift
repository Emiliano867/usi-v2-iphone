import Foundation
import XCTest
@testable import USIWire

final class USIWireTests: XCTestCase {
    func testPreviewMailboxCoalescesAndRejectsOldEpoch() {
        let mailbox = USIPreviewMailbox()
        XCTAssertTrue(mailbox.reset(epoch: "first"))
        XCTAssertFalse(mailbox.offer(epoch: "first", jpeg: Data([1])))
        XCTAssertFalse(mailbox.offer(epoch: "first", jpeg: Data([2]), details: .unavailable("Camera interrupted")))
        let interrupted = mailbox.take()
        XCTAssertEqual(interrupted?.jpeg, Data([2]))
        XCTAssertEqual(interrupted?.details?.isCapturing, false)
        XCTAssertTrue(mailbox.reset(epoch: "second"))
        XCTAssertFalse(mailbox.offer(epoch: "first", jpeg: Data([3]), details: .unavailable("Stale error")))
        let update = mailbox.take()
        XCTAssertEqual(update?.epoch, "second")
        XCTAssertTrue(update?.clear == true)
        XCTAssertNil(update?.jpeg)
        XCTAssertEqual(update?.details, .starting)
        XCTAssertFalse(mailbox.isCurrent("first"))
        XCTAssertTrue(mailbox.offer(epoch: "second", jpeg: Data([4])))
        XCTAssertEqual(mailbox.take()?.jpeg, Data([4]))
    }

    func testSharedGoldenHello() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("fixtures/usi_hello_v1.hex")
        let hex = try String(contentsOf: fixture).trimmingCharacters(in: .whitespacesAndNewlines)
        var expected = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let end = hex.index(index, offsetBy: 2)
            expected.append(try XCTUnwrap(UInt8(hex[index..<end], radix: 16)))
            index = end
        }
        let encoded = try USIWire.encode(type: .hello, metadata: ["protocol_version": 1, "role": "host"])
        XCTAssertEqual(encoded, expected)
        let packet = try USIWire.decode(expected)
        XCTAssertEqual(packet.type, .hello)
        XCTAssertEqual(packet.metadata["role"] as? String, "host")
        XCTAssertTrue(packet.payload.isEmpty)
    }

    func testTruncatedPacketsRejected() throws {
        let complete = try USIWire.encode(type: .hello, metadata: ["role": "host"])
        for length in 0..<complete.count {
            XCTAssertThrowsError(try USIWire.decode(Data(complete.prefix(length))))
        }
    }

    func testBadMagicVersionTypeAndOversizeRejected() throws {
        let original = try USIWire.encode(type: .hello, metadata: [:])
        var bad = original; bad[0] = 0
        XCTAssertThrowsError(try USIWire.decode(bad))
        bad = original; bad[5] = 2
        XCTAssertThrowsError(try USIWire.decode(bad))
        bad = original; bad[7] = 99
        XCTAssertThrowsError(try USIWire.decode(bad))
        bad = original; bad[8] = 0xff
        XCTAssertThrowsError(try USIWire.parseHeader(Data(bad.prefix(16))))
        bad = try USIWire.encode(type: .frame, metadata: [:]); bad[12] = 0xff
        XCTAssertThrowsError(try USIWire.parseHeader(Data(bad.prefix(16))))
    }

    func testJSONAndControlPayloadValidation() throws {
        XCTAssertThrowsError(try USIWire.encode(type: .hello, metadata: ["bad": Double.nan]))
        XCTAssertThrowsError(try USIWire.encode(type: .ping, metadata: [:], payload: Data([1])))
        var invalid = try USIWire.encode(type: .hello, metadata: [:])
        invalid[16] = 0xff
        XCTAssertThrowsError(try USIWire.decode(invalid))
    }

    func testFramePayloadAndSourceTimePreserved() throws {
        let raw = Data([0, 255, 1, 2, 3, 0])
        let encoded = try USIWire.encode(type: .frame,
            metadata: ["arkit_timestamp_s": 123.456789, "frame_seq": UInt64(9007199254740993)], payload: raw)
        let decoded = try USIWire.decode(encoded)
        XCTAssertEqual(decoded.payload, raw)
        XCTAssertEqual(decoded.metadata["arkit_timestamp_s"] as? Double, 123.456789)
        XCTAssertEqual((decoded.metadata["frame_seq"] as? NSNumber)?.uint64Value, 9007199254740993)
        XCTAssertThrowsError(try USIWire.decode(encoded + Data([0])))
    }
}
