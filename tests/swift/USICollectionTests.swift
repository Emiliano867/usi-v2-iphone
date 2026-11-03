import Foundation
import XCTest
@testable import USIWire

final class USICollectionTests: XCTestCase {
    func testSharedHelloAndMalformedWire() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/collection_hello.hex")
        let hex = try String(contentsOf: url).trimmingCharacters(in: .whitespacesAndNewlines)
        var expected = Data(); var index = hex.startIndex
        while index < hex.endIndex {
            let end = hex.index(index, offsetBy: 2)
            expected.append(try XCTUnwrap(UInt8(hex[index..<end], radix: 16))); index = end
        }
        let wire = try USICollectionWire.encode(type: .hello, metadata: ["role":"host", "protocol_version":2])
        XCTAssertEqual(wire, expected)
        XCTAssertEqual(try USICollectionWire.decode(wire).metadata["role"] as? String, "host")
        for (offset, value): (Int, UInt8) in [(0,0),(5,1),(7,99),(8,255),(12,255)] {
            var bad = wire; bad[offset] = value
            XCTAssertThrowsError(try USICollectionWire.decode(bad))
        }
        for count in 0..<wire.count { XCTAssertThrowsError(try USICollectionWire.decode(Data(wire.prefix(count)))) }
        XCTAssertThrowsError(try USICollectionWire.encode(type: .hello, metadata: ["role":"host","protocol_version":true]))
        XCTAssertThrowsError(try USICollectionWire.encode(type: .hello, metadata: ["role":"host","protocol_version":2,"extra":0]))
        XCTAssertThrowsError(try USICollectionWire.encode(type: .hello, metadata: ["x":Double.nan]))
    }

    func testSealCalibrationFreshnessHysteresisAndTrigger() throws {
        let channels = try (0..<3).map { try USIChamberCalibration(sensorIndex: $0, sectorIndex: $0,
            sealOnKPaAbs: 60, sealOffKPaAbs: 70, persistenceNs: 10) }
        let calibration = try USIPressureCalibration(id: "cal", chambers: channels)
        var model = USISealModel(calibration: calibration, staleNs: 250)
        XCTAssertEqual(model.snapshot(nowNs: 0).states, [.unknown,.unknown,.unknown])
        try model.update(pressuresKPaAbs: [50,80,50], qualityMask: 7, receivedNs: 0)
        XCTAssertEqual(model.snapshot(nowNs: 9).aggregate, .none)
        XCTAssertEqual(model.snapshot(nowNs: 10).aggregate, .partial)
        try model.update(pressuresKPaAbs: [65,50,65], qualityMask: 7, receivedNs: 11)
        XCTAssertEqual(model.snapshot(nowNs: 21).aggregate, .full)
        XCTAssertEqual(model.snapshot(nowNs: 262).states, [.stale,.stale,.stale])
        try model.update(pressuresKPaAbs: [50,50,50], qualityMask: 5, receivedNs: 263)
        XCTAssertEqual(model.snapshot(nowNs: 273).states, [.sealed,.invalid,.sealed])
        XCTAssertEqual(model.snapshot(nowNs: 273).aggregate, .unavailable)
        var raw = USISealModel(calibration: nil)
        try raw.update(pressuresKPaAbs: [50,50,50], qualityMask: 7, receivedNs: 1)
        XCTAssertEqual(raw.snapshot(nowNs: 1).states, [.uncalibrated,.uncalibrated,.uncalibrated])
        var trigger = USITriggerModel(staleNs: 1000)
        XCTAssertEqual(trigger.state(nowNs: 0), .unknown)
        try trigger.update(pressed: false, receivedNs: 1)
        XCTAssertEqual(trigger.state(nowNs: 1), .on)
        try trigger.update(pressed: true, receivedNs: 2)
        XCTAssertEqual(trigger.state(nowNs: 2), .off)
        XCTAssertEqual(trigger.state(nowNs: 1003), .unknown)
        XCTAssertThrowsError(try USIChamberCalibration(sensorIndex: 0, sectorIndex: 0,
            sealOnKPaAbs: 70, sealOffKPaAbs: 60, persistenceNs: 0))
    }

    func testIndependentHistoryWrapAndQueueOverflow() throws {
        var history = USISequenceHistory(modulus: 1 << 32)
        XCTAssertEqual(try history.observe(epoch: "a", rawSequence: (1 << 32)-1).sequence, (1 << 32)-1)
        XCTAssertEqual(try history.observe(epoch: "a", rawSequence: 0).sequence, 1 << 32)
        XCTAssertEqual(try history.observe(epoch: "a", rawSequence: 0).disposition, .duplicate)
        XCTAssertEqual(try history.observe(epoch: "a", rawSequence: 3).missing, (1 << 32)+1..<(1 << 32)+3)
        XCTAssertEqual(try history.observe(epoch: "b", rawSequence: 0).disposition, .newEpoch)
        XCTAssertEqual(try history.observe(epoch: "a", rawSequence: 4).disposition, .oldEpoch)
        var queue = try USIBoundedQueue<String>(capacity: 1)
        XCTAssertTrue(queue.offer("pose1")); XCTAssertFalse(queue.offer("pose2"))
        XCTAssertEqual(queue.overflowCount, 1); XCTAssertEqual(queue.pop(), "pose1"); XCTAssertNil(queue.pop())
    }

    func testHostAcknowledgmentAndStaleness() throws {
        var trial = USITrialModel(hostStaleNs: 2000)
        XCTAssertEqual(trial.displayState(nowNs: 0), .notConnected)
        try trial.beginRequest(requestID: "r", trialID: "t")
        XCTAssertEqual(trial.displayState(nowNs: 0), .preparing)
        XCTAssertTrue(try trial.applyStatus(hostSessionID: "h", trialID: "t", revision: 2,
            state: .recording, verification: .pending, receivedNs: 1))
        XCTAssertEqual(trial.displayState(nowNs: 1), .recording)
        XCTAssertEqual(trial.displayState(nowNs: 2002), .hostStale)
        XCTAssertFalse(try trial.applyStatus(hostSessionID: "h", trialID: "t", revision: 1,
            state: .preparing, verification: .pending, receivedNs: 2003))
        XCTAssertThrowsError(try trial.applyStatus(hostSessionID: "h", trialID: "t", revision: 3,
            state: .saved, verification: .pending, receivedNs: 2003))
    }
    func testTerminalTrialDoesNotRegress() throws {
        XCTAssertNil(USIStreamCounters().writerAcceptedCount)
        var trial=USITrialModel()
        try trial.beginRequest(requestID:"r",trialID:"t")
        XCTAssertTrue(try trial.applyStatus(hostSessionID:"h",trialID:"t",revision:4,state:.saved,verification:.passed,receivedNs:1))
        XCTAssertFalse(try trial.applyStatus(hostSessionID:"h",trialID:"t",revision:5,state:.recording,verification:.pending,receivedNs:2))
        XCTAssertEqual(trial.displayState(nowNs:2),.saved)
    }

    func testBeginCannotOmitFences() {
        XCTAssertThrowsError(try USICollectionWire.encode(type:.trialCommand,
            metadata:["action":"begin","request_id":"r","trial_id":"t","expected_revision":2]))
    }

    private func fixture(_ url: URL) throws -> Data {
        let hex=try String(contentsOf:url).trimmingCharacters(in:.whitespacesAndNewlines)
        var bytes=Data(); var index=hex.startIndex
        while index < hex.endIndex {
            let end=hex.index(index,offsetBy:2)
            bytes.append(try XCTUnwrap(UInt8(hex[index..<end],radix:16))); index=end
        }
        return bytes
    }
    func testEverySharedVectorRequiredFieldsAndFrameSlices() throws {
        let directory=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures")
        let urls=try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)
            .filter { $0.lastPathComponent.hasPrefix("collection_") && !$0.lastPathComponent.hasPrefix("collection_malformed_") && $0.pathExtension == "hex" }
        XCTAssertGreaterThanOrEqual(urls.count,14)
        for url in urls {
            let wire=try fixture(url), packet=try USICollectionWire.decode(wire)
            XCTAssertEqual(try USICollectionWire.encode(type:packet.type,metadata:packet.metadata,payload:packet.payload),wire,url.lastPathComponent)
            for key in packet.metadata.keys {
                var bad=packet.metadata; bad.removeValue(forKey:key)
                XCTAssertThrowsError(try USICollectionWire.encode(type:packet.type,metadata:bad,payload:packet.payload),"\(url.lastPathComponent):\(key)")
            }
            var bad=packet.metadata; bad["unexpected"]=1
            XCTAssertThrowsError(try USICollectionWire.encode(type:packet.type,metadata:bad,payload:packet.payload))
            if packet.type == .frame {
                let parts=try USICollectionWire.sliceFrame(packet)
                XCTAssertEqual(parts.rgb,Data("jpg".utf8))
                if packet.metadata["stream_id"] as? String == "ultrawide" {
                    XCTAssertNil(parts.depth); XCTAssertNil(parts.confidence)
                    XCTAssertEqual(packet.metadata["source_timestamp_s"] as? Double,321.125)
                    XCTAssertNil(packet.metadata["arkit_timestamp_s"])
                } else {
                    XCTAssertEqual(parts.depth,Data("12345678".utf8)); XCTAssertEqual(parts.confidence,Data("12".utf8))
                }
                XCTAssertThrowsError(try USICollectionWire.encode(type:.frame,metadata:packet.metadata,payload:Data()))
            }
        }
    }
    func testBoundedSensorBatchesDuplicateJSONAndStreamingRead() throws {
        let directory=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures")
        var meta=try USICollectionWire.decode(fixture(directory.appendingPathComponent("collection_pressure.hex"))).metadata
        var sample=(meta["samples"] as! [[String:Any]])[0]
        sample["sequence"]=UInt64(1)<<32; sample["raw_sequence"]=0; meta["samples"]=[sample]
        XCTAssertNoThrow(try USICollectionWire.encode(type:.pressure,metadata:meta))
        sample["raw_sequence"]=1;meta["samples"]=[sample]
        XCTAssertThrowsError(try USICollectionWire.encode(type:.pressure,metadata:meta))
        sample["raw_sequence"]=0;sample["sequence"]=true;meta["samples"]=[sample]
        XCTAssertThrowsError(try USICollectionWire.encode(type:.pressure,metadata:meta))
        sample["sequence"]=0;sample["pressure_centi_pa"]=[0,0,Double.nan];meta["samples"]=[sample]
        XCTAssertThrowsError(try USICollectionWire.encode(type:.pressure,metadata:meta))
        sample["pressure_centi_pa"]=[0,0,0];meta["samples"]=Array(repeating:sample,count:65)
        XCTAssertThrowsError(try USICollectionWire.encode(type:.pressure,metadata:meta))
        let body=Data(#"{"role":"host","role":"phone","protocol_version":2}"#.utf8)
        var duplicate=Data([85,83,73,50,0,2,0,1,0,0,0,UInt8(body.count),0,0,0,0]);duplicate.append(body)
        XCTAssertThrowsError(try USICollectionWire.decode(duplicate))
        let wire=try USICollectionWire.encode(type:.hello,metadata:["role":"host","protocol_version":2])
        var incoming=wire+wire
        func read(_ count: Int) -> Data {
            guard !incoming.isEmpty else { return Data() }
            let result=Data(incoming.prefix(1)); incoming.removeFirst(); return result
        }
        XCTAssertNotNil(try USICollectionWire.recvPacket(read:read)); XCTAssertNotNil(try USICollectionWire.recvPacket(read:read))
        XCTAssertNil(try USICollectionWire.recvPacket(read:read))
        incoming=Data(wire.dropLast()); XCTAssertThrowsError(try USICollectionWire.recvPacket(read:read))
        var deep: [String:Any]=[:]
        for _ in 0..<40 { deep=["x":deep] }
        XCTAssertThrowsError(try USICollectionWire.encode(type:.health,metadata:deep))
    }

    func testFinalizingCannotRegressToRecording() throws {
        var trial=USITrialModel()
        try trial.beginRequest(requestID:"r",trialID:"t")
        try trial.applyStatus(hostSessionID:"h",trialID:"t",revision:3,state:.finalizing,verification:.pending,receivedNs:1)
        XCTAssertFalse(try trial.applyStatus(hostSessionID:"h",trialID:"t",revision:4,state:.recording,verification:.pending,receivedNs:2))
        try trial.applyStatus(hostSessionID:"h",trialID:"t",revision:5,state:.saved,verification:.passed,receivedNs:3)
        XCTAssertFalse(try trial.applyStatus(hostSessionID:"new-host",trialID:"t",revision:2,state:.recording,verification:.pending,receivedNs:4))
    }

    func testCanonicalNamesKeepWireIDs() {
        XCTAssertEqual(USICollectionMessageType(rawValue:7)?.schemaName,"PRESSURE")
        XCTAssertEqual(USICollectionMessageType(rawValue:9)?.schemaName,"BLE_CLOCK")
        XCTAssertEqual(USICollectionMessageType(rawValue:10)?.schemaName,"TRIAL_COMMAND")
    }
    func testStatusInventoryRecoveryAndValidation() throws {
        let directory=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures")
        var full=try USICollectionWire.decode(fixture(directory.appendingPathComponent("collection_status.hex"))).metadata
        full["profile"]="full";full["required_streams"]=USICollectionWire.fullRequiredStreams;full["missing_modalities"]=[String]()
        XCTAssertNoThrow(try USICollectionWire.encode(type:.trialStatus,metadata:full))
        var core=full;core["profile"]="core";core["required_streams"]=USICollectionWire.coreRequiredStreams;core["missing_modalities"]=["ultrawide"]
        XCTAssertNoThrow(try USICollectionWire.encode(type:.trialStatus,metadata:core))
        var bad=core;bad["missing_modalities"]=[String]()
        XCTAssertThrowsError(try USICollectionWire.encode(type:.trialStatus,metadata:bad))
        bad=full;bad["required_streams"]=["ultrawide"]
        XCTAssertThrowsError(try USICollectionWire.encode(type:.trialStatus,metadata:bad))
        bad=full;bad["missing_modalities"]=["ultrawide"]
        XCTAssertThrowsError(try USICollectionWire.encode(type:.trialStatus,metadata:bad))
        for field in ["profile","required_streams","missing_modalities"] {
            bad=full;bad.removeValue(forKey:field)
            XCTAssertThrowsError(try USICollectionWire.encode(type:.trialStatus,metadata:bad))
        }
    }

    func testStatusReportsUnavailableRequiredStreamsSeparatelyFromProfileExclusions() throws {
        let directory=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures")
        var preparing=try USICollectionWire.decode(fixture(directory.appendingPathComponent("collection_status.hex"))).metadata
        preparing["state"]="preparing";preparing["profile"]="full"
        preparing["required_streams"]=USICollectionWire.fullRequiredStreams;preparing["missing_modalities"]=[String]()
        preparing["reason"]="required sources unavailable"
        preparing["missing_required_streams"]=["ultrawide","pressures"]
        XCTAssertNoThrow(try USICollectionWire.encode(type:.trialStatus,metadata:preparing))
        XCTAssertEqual(preparing["missing_modalities"] as? [String],[])
        var incomplete=preparing;incomplete["state"]="incomplete";incomplete["verification"]="failed"
        incomplete["reason"]="required sources remained unavailable"
        XCTAssertNoThrow(try USICollectionWire.encode(type:.trialStatus,metadata:incomplete))
        var invalidSubset=preparing;invalidSubset["missing_required_streams"]=["audio"]
        XCTAssertThrowsError(try USICollectionWire.encode(type:.trialStatus,metadata:invalidSubset))
        var recording=preparing;recording["state"]="recording";recording["missing_required_streams"]=["pressures"]
        XCTAssertThrowsError(try USICollectionWire.encode(type:.trialStatus,metadata:recording))
        var saved=recording;saved["state"]="saved";saved["verification"]="passed";saved["bag_path"]="/data/trial-A"
        XCTAssertThrowsError(try USICollectionWire.encode(type:.trialStatus,metadata:saved))
    }
    func testMalformedOversizedNumbersUseProtocolError() throws {
        let directory=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures")
        let poseWire=try fixture(directory.appendingPathComponent("collection_poses.hex"))
        let original=try USICollectionWire.decode(poseWire).metadata
        for value: NSNumber in [NSNumber(value:UInt64.max),NSNumber(value:1e200),NSNumber(value:Double.greatestFiniteMagnitude)] {
            var good=original;var samples=good["samples"] as! [[String:Any]]
            samples[0]["arkit_timestamp_s"]=value;good["samples"]=samples
            XCTAssertNoThrow(try USICollectionWire.decode(USICollectionWire.encode(type:.poses,metadata:good)))
        }
        for name in ["quaternion","timestamp","integer_domain"] {
            let wire=try fixture(directory.appendingPathComponent("collection_malformed_"+name+".hex"))
            XCTAssertThrowsError(try USICollectionWire.decode(wire)) { error in
                XCTAssertTrue(error is USICollectionError,"Expected protocol error, received \(error)")
            }
        }
    }
    func testNewTrialMayBindReplacementHostAfterSaved() throws {
        var trial=USITrialModel();try trial.beginRequest(requestID:"r1",trialID:"t1")
        try trial.applyStatus(hostSessionID:"h1",trialID:"t1",revision:4,state:.saved,verification:.passed,receivedNs:1)
        try trial.beginRequest(requestID:"r2",trialID:"t2")
        XCTAssertTrue(try trial.applyStatus(hostSessionID:"h2",trialID:"t2",revision:1,state:.preparing,verification:.pending,receivedNs:2))
        XCTAssertTrue(try trial.applyStatus(hostSessionID:"h2",trialID:"t2",revision:2,state:.recording,verification:.pending,receivedNs:3))
        XCTAssertFalse(try trial.applyStatus(hostSessionID:"h3",trialID:"t2",revision:1,state:.preparing,verification:.pending,receivedNs:4))
        XCTAssertFalse(try trial.applyStatus(hostSessionID:"h3",trialID:"t2",revision:2,state:.recording,verification:.pending,receivedNs:5))
    }

}

extension USICollectionTests {
    func testSectorPermutationUsesCalibrationMapping() throws {
        let channels = try [
            USIChamberCalibration(sensorIndex: 2, sectorIndex: 1, sealOnKPaAbs: 60, sealOffKPaAbs: 70, persistenceNs: 0),
            USIChamberCalibration(sensorIndex: 0, sectorIndex: 2, sealOnKPaAbs: 60, sealOffKPaAbs: 70, persistenceNs: 0),
            USIChamberCalibration(sensorIndex: 1, sectorIndex: 0, sealOnKPaAbs: 60, sealOffKPaAbs: 70, persistenceNs: 0)
        ]
        var model = USISealModel(calibration: try USIPressureCalibration(id: "permuted", chambers: channels))
        try model.update(pressuresKPaAbs: [50, 80, 50], qualityMask: 7, receivedNs: 1)
        let snapshot = model.snapshot(nowNs: 1)
        XCTAssertEqual(snapshot.states, [.unsealed, .sealed, .sealed])
        XCTAssertEqual(snapshot.pressuresKPaAbs, [80, 50, 50])
    }
}
