import Foundation
import XCTest
@testable import USIWire

final class USICollectionRuntimeTests: XCTestCase {
    let transform: [Double] = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1]
    let k: [Double] = [100,0,2, 0,100,1, 0,0,1]
    func pose(_ time: UInt64 = 1) -> USICameraPose {
        USICameraPose(arkitTimestampS: 12.5, phoneUptimeNs: time, transform: transform,
                      positionM: [0,0,0], quaternionXYZW: [0,0,0,1], trackingState: "normal",
                      trackingReason: "", valid: true)
    }
    func image() -> USICameraImage {
        USICameraImage(intrinsics: k, sourceSize: [4,2], rgbIntrinsics: k, rgbWidth: 4, rgbHeight: 2,
                       jpeg: Data([1,2,3]), depth: nil, confidence: nil, thermalState: "nominal")
    }
    func testOlderImageCompletionCannotRegressCameraFreshness() throws {
        let runtime = try USICollectionRuntime(sessionID: "p", worldEpochID: "w")
        try runtime.connectHost(capabilities: capabilities(), nowNs: 0)
        let older = try XCTUnwrap(try runtime.admitCamera(pose: pose(1)).encodeTicket)
        let newer = try XCTUnwrap(try runtime.admitCamera(pose: pose(2)).encodeTicket)
        try runtime.completeCamera(ticket: newer, image: image())
        try runtime.completeCamera(ticket: older, image: image())
        XCTAssertEqual(runtime.lastFresh[.mainRGB], 2)
    }
    func decoded(_ packet: USICollectionOutbound) throws -> USICollectionPacket {
        try USICollectionWire.decode(packet.bytes)
    }
    func testProductionCameraBuildersRetainNullPlanesAndIndependentPose() throws {
        let p = try USICollectionPackets.poses(session: "phone", epoch: "world", samples: [(7, pose())])
        let f = try USICollectionPackets.mainFrame(session: "phone", epoch: "world", sequence: 7,
            pose: pose(), image: image(), acquired: 8, encodeDrops: 2, transportDrops: 3)
        let m = try decoded(f).metadata
        XCTAssertEqual(try decoded(p).type, .poses)
        XCTAssertEqual(m["frame_seq"] as? Int, 7)
        XCTAssertTrue(m["depth"] is NSNull); XCTAssertTrue(m["confidence"] is NSNull)
        XCTAssertEqual(try decoded(f).payload, Data([1,2,3]))
        let counters = try XCTUnwrap(m["counters"] as? [String:Any])
        XCTAssertEqual(counters["encode_drops"] as? Int, 2)
        var bad = pose(); bad.quaternionXYZW = [0,0,0,2]
        XCTAssertThrowsError(try USICollectionPackets.poses(session: "phone", epoch: "world", samples: [(0,bad)]))
        var badImage = image(); badImage.intrinsics[0] = .nan
        XCTAssertThrowsError(try USICollectionPackets.mainFrame(session: "p", epoch: "w", sequence: 0,
            pose: pose(), image: badImage, acquired: 1, encodeDrops: 0, transportDrops: 0))
    }
    func testProductionBuildersSensorClockHelloPongAndCommands() throws {
        let pressure = USIBLEPressureSample(rawSequence: 4, sourceTimeUs: 123,
            pressuresCentiPa: [5_000_000,-100,8_000_000], qualityErrorMask: 2)
        let p = try USICollectionPackets.pressure(source: "esp", boot: "5", connection: "c", phone: "p",
            samples: [(4_294_967_300, pressure, 321)])
        let m = try XCTUnwrap(try decoded(p).metadata["samples"] as? [[String:Any]])[0]
        XCTAssertEqual(m["sequence"] as? UInt64, 4_294_967_300)
        XCTAssertEqual(m["quality_mask"] as? Int, 5)
        XCTAssertEqual(m["phone_receive_ns"] as? Int, 321)
        XCTAssertEqual(m["pressure_centi_pa"] as? [Int], [5_000_000,-100,8_000_000])
        let t = try USICollectionPackets.trigger(source: "esp", boot: "5", connection: "c", phone: "p",
            sequence: 3, sample: USIBLETrigger(rawSequence: 3, sourceTimeUs: 9, pressed: true, heartbeat: false), receivedNs: 7)
        XCTAssertEqual(try decoded(t).metadata["event"] as? String, "transition")
        XCTAssertEqual(try decoded(t).metadata["pressed"] as? Bool, true)
        let hello = try USICollectionPackets.hello(session: "p", capabilities: [], profiles: ["core"])
        XCTAssertEqual(try decoded(hello).metadata["role"] as? String, "phone")
        let pong = try USICollectionPackets.pong(session: "p", pingID: 9, hostSendNs: 1, receivedNs: 2, sentNs: 3)
        XCTAssertEqual(try decoded(pong).metadata["phone_send_ns"] as? Int, 3)
        let clock = try USICollectionPackets.clock(link: "ble", exchange: "9", source: "esp", epoch: "5", times: [1,2,3,4])
        let mapping = try XCTUnwrap(try decoded(clock).metadata["mapping"] as? [String:Any])
        XCTAssertEqual(mapping["valid"] as? Bool, false); XCTAssertTrue(mapping["scale"] is NSNull)
        for action in ["begin","stop","status"] {
            let fence = try USICollectionFence(stream: .pressures, sourceID: "esp", epochID: "5", nextSequence: 5)
            let c = try USICollectionPackets.command(action: action, request: action, trial: "trial", revision: 2,
                fences: action == "status" ? nil : [fence], counters: action == "stop" ? [] : nil)
            XCTAssertEqual(try decoded(c).metadata["action"] as? String, action)
        }
        XCTAssertThrowsError(try USICollectionPackets.clock(link: "ble", exchange: "x", source: "s", epoch: "e", times: [1,2]))
        XCTAssertThrowsError(try USICollectionPackets.command(action: "stop", request: "s", trial: "t", revision: 1))
    }
    func testProductionSnapshotCapabilityUnitsCalibrationAndHealth() throws {
        let cap = USICollectionCapability(stream: .pressures, available: true, reason: nil, sourceID: "esp", epochID: "5")
        XCTAssertEqual(cap.metadata["units"] as? String, "kPa_abs")
        let snapshot = USICollectionSnapshot(sessionID: "p", taskLabel: "raw", gripperID: "g", profile: "core",
            calibration: nil, ambientKPaAbs: nil, calibrationProvenance: "", capabilities: capabilities())
        let c = try USICollectionPackets.prepare(request: "r", trial: "t", revision: 0, snapshot: snapshot)
        let s = try XCTUnwrap(try decoded(c).metadata["snapshot"] as? [String:Any])
        XCTAssertTrue(s["calibration"] is NSNull)
        XCTAssertEqual(s["missing_modalities"] as? [String], ["ultrawide"])
        let health = try USICollectionPackets.health(session: "p", event: "status", message: "", counters: [
            USICollectionCounter(stream: .pressures, sourceID: "esp", epochID: "5")])
        let row = try XCTUnwrap(try decoded(health).metadata["counters"] as? [[String:Any]])[0]
        XCTAssertTrue(row["source_count"] is NSNull); XCTAssertTrue(row["writer_accepted_count"] is NSNull)
        let ultra = try USICollectionPackets.ultrawide(session: "p", epoch: "u", sequence: 8,
            sourceTimestampS: 8.25, sourceClock: "camera", phoneUptimeNs: 10, image: image(), acquired: 9, encodeDrops: 0, transportDrops: 0)
        XCTAssertNil(try decoded(ultra).metadata["arkit_timestamp_s"])
    }
    func testBoundedLanesKeepPoseAndPressureWhileImageIsBlocked() throws {
        var q = try USICollectionTransport(imageCapacity: 1, poseCapacity: 3, sensorCapacity: 3,
                                            controlCapacity: 2, byteLimitPerLane: 100_000)
        let f = try USICollectionPackets.mainFrame(session: "p", epoch: "w", sequence: 0, pose: pose(),
            image: image(), acquired: 1, encodeDrops: 0, transportDrops: 0)
        XCTAssertTrue(q.offer(f)); XCTAssertFalse(q.offer(f))
        for seq: UInt64 in [0,1,2] {
            XCTAssertTrue(q.offer(try USICollectionPackets.poses(session: "p", epoch: "w", samples: [(seq,pose())])))
            XCTAssertTrue(q.offer(try USICollectionPackets.pressure(source: "esp", boot: "5", connection: "c", phone: "p",
                samples: [(seq, USIBLEPressureSample(rawSequence: UInt32(seq), sourceTimeUs: seq,
                    pressuresCentiPa: [1,2,3], qualityErrorMask: 0), seq)])))
        }
        var found: [USICollectionMessageType] = []
        while let packet = q.takeNext(allowData: true) { found.append(packet.type) }
        XCTAssertEqual(found.filter { $0 == .poses }.count, 3)
        XCTAssertEqual(found.filter { $0 == .pressure }.count, 3)
        XCTAssertEqual(found.filter { $0 == .frame }.count, 1)
        XCTAssertEqual(q.overflowCount[.image], 1)
        let pong = try USICollectionPackets.pong(session: "p", pingID: 1, hostSendNs: 1, receivedNs: 2, sentNs: 3)
        XCTAssertTrue(q.offer(f)); XCTAssertTrue(q.offer(pong))
        XCTAssertEqual(q.takeNext(allowData: false)?.type, .pong)
        XCTAssertNil(q.takeNext(allowData: false))
        XCTAssertEqual(q.takeNext(allowData: true)?.type, .frame)
    }
    func testBLEProgressSeedsRealWrapPreservesFirstReceiptAndReconnectLoss() throws {
        var b = try USICollectionBLEProgress(capacity: 2)
        try b.connect(source: "esp", boot: 5, connection: "c", phone: "p")
        let sample = USIBLEPressureSample(rawSequence: 4, sourceTimeUs: 100,
            pressuresCentiPa: [5_000_000,8_000_000,5_000_000], qualityErrorMask: 0)
        XCTAssertTrue(try b.receive(.pressure(5,[sample]), firstReceivedNs: 20, completedNs: 30).isEmpty)
        let seeded = try b.barrier(clock(pressure: 4_294_967_301), firstReceivedNs: 40, completedNs: 50)
        XCTAssertEqual(seeded.count, 1)
        XCTAssertEqual(seeded[0].identities[0].sequence, 4_294_967_300)
        let samples = try XCTUnwrap(try decoded(seeded[0]).metadata["samples"] as? [[String:Any]])
        XCTAssertEqual(samples[0]["phone_receive_ns"] as? Int, 20)
        XCTAssertEqual(b.lastCompleteNs, 50)
        try b.connect(source: "esp", boot: 5, connection: "d", phone: "p")
        XCTAssertThrowsError(try b.barrier(clock(pressure: 4_294_967_300), firstReceivedNs: 60, completedNs: 60))
        let resumed = try b.barrier(clock(pressure: 4_294_967_305), firstReceivedNs: 70, completedNs: 70)
        XCTAssertTrue(resumed.isEmpty)
        XCTAssertThrowsError(try b.receive(.pressure(4,[sample]), firstReceivedNs: 71, completedNs: 71))
        XCTAssertThrowsError(try b.receive(.pressure(5,[sample]), firstReceivedNs: 72, completedNs: 72))
    }
    func testBLEInitialBufferIsBoundedAndImpossibleBarrierRejected() throws {
        var b = try USICollectionBLEProgress(capacity: 1)
        try b.connect(source: "esp", boot: 5, connection: "c", phone: "p")
        let sample = USIBLEPressureSample(rawSequence: 4, sourceTimeUs: 100,
            pressuresCentiPa: [1,2,3], qualityErrorMask: 0)
        _ = try b.receive(.pressure(5,[sample]), firstReceivedNs: 1, completedNs: 2)
        XCTAssertThrowsError(try b.receive(.pressure(5,[sample]), firstReceivedNs: 3, completedNs: 4))
        XCTAssertThrowsError(try b.barrier(clock(pressure: 0), firstReceivedNs: 5, completedNs: 6))
    }
    func clock(pressure: UInt64 = 1, trigger: UInt64 = 1, request: UInt32 = 1, sent: UInt64 = 1,
               overflow: UInt64 = 0) -> USIBLEClock {
        USIBLEClock(requestID: request, t1PhoneNs: sent, t2DeviceUs: 2, t3DeviceUs: 3, snapshotDeviceUs: 2,
            pressureAcquired: pressure, triggerAcquired: trigger, pressureOverflow: overflow,
            triggerOverflow: 0, pressureDisconnected: 0, triggerDisconnected: 0, schedulerSkips: 0,
            pressureNotifyLost: 0, triggerNotifyLost: 0, notifyCalls: 1, notifyFailures: 0, disconnects: 0)
    }
    func hostStatus(_ state: String, revision: UInt64, trial: String? = "t", request: String? = nil,
                    host: String = "h", time: UInt64 = 1, path: String? = nil) throws -> USICollectionPacket {
        let active = state != "idle"
        return try USICollectionWire.decode(USICollectionWire.encode(type: .trialStatus, metadata: [
            "host_session_id":host, "host_time_ns":time, "request_id":request as Any? ?? NSNull(),
            "trial_id":trial as Any? ?? NSNull(), "revision":revision, "state":state, "ready":true,
            "profile":active ? "core" as Any : NSNull(), "required_streams":active ? USICollectionWire.coreRequiredStreams : [],
            "missing_modalities":active ? ["ultrawide"] : [], "missing_required_streams":[],
            "reason":NSNull(), "bag_path":path as Any? ?? NSNull(),
            "verification":state == "saved" ? "passed" : state == "incomplete" ? "failed" : "pending", "counters":[]]))
    }
    func snapshot() -> USICollectionSnapshot {
        USICollectionSnapshot(sessionID: "p", taskLabel: "raw", gripperID: "g", profile: "core",
            calibration: nil, ambientKPaAbs: nil, calibrationProvenance: "", capabilities: capabilities())
    }
    func drain(_ r: USICollectionRuntime) throws -> [USICollectionPacket] {
        var packets: [USICollectionPacket] = []
        while let send = r.takeNext() {
            packets.append(try decoded(send.packet)); r.sendCompleted(token: send.token, succeeded: true)
        }
        return packets
    }
    func completeBarrier(_ r: USICollectionRuntime, pressure: UInt64 = 1, trigger: UInt64 = 1,
                         now: UInt64 = 10, overflow: UInt64 = 0) throws {
        var request: (UInt32,UInt64)?
        while let effect = r.takeEffect() {
            if case let .requestBLEClock(id,sent) = effect { request = (id,sent) }
        }
        let pending = try XCTUnwrap(request)
        try r.receiveBLE(.clock(5,clock(pressure:pressure, trigger:trigger, request:pending.0, sent:pending.1, overflow:overflow)),
                         firstReceivedNs:now, completedNs:now)
    }
    func warmRuntime(encoderCapacity: Int = 2) throws -> USICollectionRuntime {
        let r = try USICollectionRuntime(sessionID: "p", worldEpochID: "w", encoderCapacity: encoderCapacity)
        try r.connectHost(capabilities: capabilities(), nowNs: 1)
        XCTAssertTrue(try r.receiveHost(hostStatus("idle",revision:0,trial:nil), receivedNs:1))
        try r.connectBLE(sourceID:"esp",bootID:5,connectionID:"c",nowNs:2)
        try r.receiveBLE(.pressure(5,[USIBLEPressureSample(rawSequence:0,sourceTimeUs:1,
            pressuresCentiPa:[5_000_000,8_000_000,5_000_000],qualityErrorMask:0)]),firstReceivedNs:3,completedNs:4)
        try r.receiveBLE(.trigger(5,USIBLETrigger(rawSequence:0,sourceTimeUs:1,pressed:true,heartbeat:true)),firstReceivedNs:5,completedNs:6)
        try completeBarrier(r)
        let admission = try r.admitCamera(pose:pose(11))
        try r.completeCamera(ticket:try XCTUnwrap(admission.encodeTicket),image:image())
        _ = try drain(r)
        return r
    }
    func recordingRuntime() throws -> USICollectionRuntime {
        let r = try warmRuntime()
        try r.prepare(snapshot:snapshot(),trialID:"t",requestID:"prepare",nowNs:12)
        _ = try drain(r)
        XCTAssertTrue(try r.receiveHost(hostStatus("preparing",revision:1,request:"prepare",time:2),receivedNs:13))
        try completeBarrier(r,now:14)
        let beginPackets = try drain(r)
        XCTAssertEqual(beginPackets.filter { $0.type == .trialCommand }.first?.metadata["action"] as? String,"begin")
        XCTAssertTrue(try r.receiveHost(hostStatus("recording",revision:2,request:"prepare:begin",time:3),receivedNs:15))
        return r
    }
    func testAdmissionKeepsPoseWithEncoderSaturationAndCountsFailedEncode() throws {
        let r = try warmRuntime(encoderCapacity:1)
        let a = try r.admitCamera(pose:pose(12))
        let b = try r.admitCamera(pose:pose(13))
        XCTAssertNotNil(a.encodeTicket); XCTAssertNil(b.encodeTicket)
        XCTAssertEqual(b.posePacket.identities[0].sequence,2)
        let packets = try drain(r)
        XCTAssertEqual(packets.filter { $0.type == .poses }.count,2)
        XCTAssertEqual(r.counters.first { $0.stream == .mainRGB }?.counts.queueOverflowCount,1)
        try r.completeCamera(ticket:try XCTUnwrap(a.encodeTicket),image:nil)
        XCTAssertEqual(r.counters.first { $0.stream == .mainRGB }?.counts.rejectedCount,1)
    }
    func testBeginHoldsDataAndSendsBaselineBeforeBeginBeforePostBegin() throws {
        let r = try warmRuntime()
        try r.prepare(snapshot:snapshot(),trialID:"t",requestID:"prepare",nowNs:12)
        _ = try drain(r)
        XCTAssertTrue(try r.receiveHost(hostStatus("preparing",revision:1,request:"prepare",time:2),receivedNs:13))
        let next = try r.admitCamera(pose:pose(14))
        try r.completeCamera(ticket:try XCTUnwrap(next.encodeTicket),image:image())
        XCTAssertTrue(try drain(r).isEmpty)
        try r.receiveBLE(.pressure(5,[USIBLEPressureSample(rawSequence:1,sourceTimeUs:2,
            pressuresCentiPa:[1,2,3],qualityErrorMask:0)]),firstReceivedNs:15,completedNs:15)
        try completeBarrier(r,pressure:2,now:16)
        let out = try drain(r)
        let begin = try XCTUnwrap(out.firstIndex { $0.type == .trialCommand })
        XCTAssertGreaterThan(begin,0); XCTAssertEqual(out[begin-1].type,.health)
        XCTAssertFalse(out.prefix(begin).contains { [.poses,.frame,.pressure].contains($0.type) })
        XCTAssertEqual(out.filter { $0.type == .poses }.count,1)
        XCTAssertEqual(out.filter { $0.type == .pressure }.count,0)
        let fences = try XCTUnwrap(out[begin].metadata["fences"] as? [[String:Any]])
        XCTAssertEqual(fences.first { $0["stream_id"] as? String == "camera_pose" }?["next_sequence"] as? Int,1)
        XCTAssertEqual(fences.first { $0["stream_id"] as? String == "pressures" }?["next_sequence"] as? Int,2)
        XCTAssertFalse(r.render(nowNs:17).recordingAssured)
    }
    func testStopClosesImmediatelyAndDrainsOnlyPreEndWithExactCounters() throws {
        let r = try recordingRuntime()
        let tail = try r.admitCamera(pose:pose(16))
        let inFlight = try XCTUnwrap(r.takeNext())
        XCTAssertNil(r.takeNext())
        try r.stop(requestID:"stop",nowNs:17)
        let after = try r.admitCamera(pose:pose(18))
        XCTAssertNil(after.encodeTicket) // Acquisition/pose continue; no post-end JPEG scheduling.
        XCTAssertNil(r.takeNext())
        r.sendCompleted(token:inFlight.token,succeeded:true)
        XCTAssertTrue(try drain(r).isEmpty)
        try r.receiveBLE(.pressure(5,[USIBLEPressureSample(rawSequence:1,sourceTimeUs:2,
            pressuresCentiPa:[1,2,3],qualityErrorMask:0)]),firstReceivedNs:19,completedNs:19)
        try completeBarrier(r,pressure:2,now:20)
        let out = try drain(r)
        let stop = try XCTUnwrap(out.first { $0.type == .trialCommand })
        XCTAssertEqual(stop.metadata["action"] as? String,"stop")
        let fences = try XCTUnwrap(stop.metadata["fences"] as? [[String:Any]])
        XCTAssertEqual(fences.first { $0["stream_id"] as? String == "main_rgb" }?["next_sequence"] as? Int,2)
        XCTAssertEqual(fences.first { $0["stream_id"] as? String == "pressures" }?["next_sequence"] as? Int,2)
        XCTAssertFalse(out.contains { $0.type == .frame })
        try r.completeCamera(ticket:try XCTUnwrap(tail.encodeTicket),image:image())
        let tails = try drain(r)
        XCTAssertEqual(tails.filter { $0.type == .frame }.count,1)
        try r.receiveBLE(.pressure(5,[USIBLEPressureSample(rawSequence:2,sourceTimeUs:3,
            pressuresCentiPa:[1,2,3],qualityErrorMask:0)]),firstReceivedNs:21,completedNs:21)
        XCTAssertTrue(try drain(r).isEmpty)
        let final = try XCTUnwrap(stop.metadata["counters"] as? [[String:Any]])
        XCTAssertEqual(final.first { $0["stream_id"] as? String == "main_rgb" }?["source_count"] as? Int,2)
        XCTAssertTrue(r.render(nowNs:22).configurationFrozen)
    }
    func testTimeoutHasOneDisconnectNoFabricatedStopAndSameTrialRecovery() throws {
        let r = try recordingRuntime()
        try r.stop(requestID:"stop",nowNs:16)
        r.tick(nowNs:2_000_000_016); r.tick(nowNs:3_000_000_016)
        var disconnects = 0
        while let effect = r.takeEffect() { if case .disconnectTransport = effect { disconnects += 1 } }
        XCTAssertEqual(disconnects,1)
        XCTAssertTrue(try drain(r).isEmpty)
        XCTAssertNotNil(r.render(nowNs:3_000_000_016).unknownReason)
        XCTAssertTrue(r.render(nowNs:3_000_000_016).stopEnabled)
        try r.connectHost(capabilities:capabilities(),nowNs:3_000_000_017)
        let query = try XCTUnwrap(try drain(r).first { $0.type == .trialCommand })
        XCTAssertEqual(query.metadata["action"] as? String,"status")
        XCTAssertEqual(query.metadata["trial_id"] as? String,"t")
        XCTAssertFalse(try r.receiveHost(hostStatus("recording",revision:3,host:"new",time:4),receivedNs:3_000_000_018))
        XCTAssertTrue(try r.receiveHost(hostStatus("incomplete",revision:4,host:"new",time:5),receivedNs:3_000_000_019))
        XCTAssertFalse(r.render(nowNs:3_000_000_019).configurationFrozen)
    }
    func testHostCorrelationAnchorsTimerOnceAndRetainsVerifiedSave() throws {
        let r = try recordingRuntime()
        XCTAssertTrue(r.render(nowNs:25).recordingAssured)
        XCTAssertEqual(r.render(nowNs:25).elapsedNs,10)
        XCTAssertFalse(try r.receiveHost(hostStatus("recording",revision:3,trial:"other",time:4),receivedNs:26))
        XCTAssertFalse(try r.receiveHost(hostStatus("recording",revision:3,request:"other",time:4),receivedNs:26))
        XCTAssertFalse(try r.receiveHost(hostStatus("recording",revision:1,time:4),receivedNs:26))
        XCTAssertTrue(try r.receiveHost(hostStatus("recording",revision:2,time:4),receivedNs:27))
        XCTAssertEqual(r.render(nowNs:30).elapsedNs,15)
        XCTAssertFalse(r.render(nowNs:2_000_000_028).recordingAssured)
        XCTAssertTrue(r.render(nowNs:2_000_000_028).stopEnabled)
        XCTAssertTrue(r.render(nowNs:2_000_000_028).configurationFrozen)
        XCTAssertEqual(r.render(nowNs:30).suction,.off)
        XCTAssertEqual(r.render(nowNs:30).seal.states,[.uncalibrated,.uncalibrated,.uncalibrated])
        try r.stop(requestID:"stop",nowNs:31); try completeBarrier(r,now:32)
        _ = try drain(r)
        XCTAssertTrue(try r.receiveHost(hostStatus("saved",revision:4,request:"stop",time:5,path:"bag/test"),receivedNs:33))
        XCTAssertEqual(r.render(nowNs:33).lastSave?.bagPath,"bag/test")
        XCTAssertFalse(r.render(nowNs:33).configurationFrozen)
        XCTAssertEqual(r.render(nowNs:33).missingModalities,["ultrawide"])
        XCTAssertEqual(r.render(nowNs:33).missingRequiredStreams,[])
    }
    func testStableBoundedRetriesAndStopWhilePreparing() throws {
        let r = try warmRuntime()
        try r.prepare(snapshot:snapshot(),trialID:"t",requestID:"prepare",nowNs:12)
        let first = try XCTUnwrap(try drain(r).first { $0.type == .trialCommand })
        XCTAssertTrue(try r.retry(requestID:"prepare",nowNs:13))
        XCTAssertEqual(try drain(r).first?.metadata["expected_revision"] as? Int,first.metadata["expected_revision"] as? Int)
        XCTAssertTrue(try r.retry(requestID:"prepare",nowNs:14))
        XCTAssertFalse(try r.retry(requestID:"prepare",nowNs:15))
        XCTAssertThrowsError(try r.prepare(snapshot:snapshot(),trialID:"other",requestID:"prepare",nowNs:16))
        try r.stop(requestID:"stop",nowNs:17)
        XCTAssertNotNil(r.render(nowNs:17).unknownReason)
        XCTAssertFalse(try drain(r).contains { $0.metadata["action"] as? String == "begin" || $0.metadata["action"] as? String == "stop" })
    }
    func testFreshTickDoesNotInvalidateAndStaleSourceClosesWithoutStop() throws {
        let r = try recordingRuntime()
        r.tick(nowNs:20)
        XCTAssertNil(r.render(nowNs:20).unknownReason)
        r.tick(nowNs:1_250_000_004)
        XCTAssertNotNil(r.render(nowNs:1_250_000_004).unknownReason)
        XCTAssertFalse(try drain(r).contains { $0.metadata["action"] as? String == "stop" })
    }
    func testDuplicatePrepareAfterRevisionChangeUsesOriginalBytes() throws {
        let r = try recordingRuntime()
        XCTAssertNoThrow(try r.prepare(snapshot:snapshot(),trialID:"t",requestID:"prepare",nowNs:20))
        let retry = try XCTUnwrap(try drain(r).first { $0.metadata["action"] as? String == "prepare" })
        XCTAssertEqual(retry.metadata["expected_revision"] as? Int,0)
        XCTAssertEqual(r.render(nowNs:20).elapsedNs,5)
    }
    func testNewTrialAfterSavedAcceptsPreparingAndRetainsLastSave() throws {
        let r = try recordingRuntime()
        try r.stop(requestID:"stop",nowNs:16); try completeBarrier(r,now:17); _ = try drain(r)
        XCTAssertTrue(try r.receiveHost(hostStatus("saved",revision:4,request:"stop",time:5,path:"bag/one"),receivedNs:18))
        try r.prepare(snapshot:snapshot(),trialID:"two",requestID:"second",nowNs:19)
        _ = try drain(r)
        XCTAssertTrue(try r.receiveHost(hostStatus("preparing",revision:5,trial:"two",request:"second",time:6),receivedNs:20))
        XCTAssertEqual(r.render(nowNs:20).lastSave?.bagPath,"bag/one")
        XCTAssertTrue(r.render(nowNs:20).configurationFrozen)
    }
    func testBLEDisconnectAndNewBootRevokeFreshSealAndSuctionImmediately() throws {
        let r = try warmRuntime()
        let chambers = try (0..<3).map { try USIChamberCalibration(sensorIndex:$0,sectorIndex:(2-$0),
            sealOnKPaAbs:60,sealOffKPaAbs:70,persistenceNs:0) }
        try r.selectCalibration(USIPressureCalibration(id:"measured",chambers:chambers))
        XCTAssertEqual(r.render(nowNs:12).seal.states,[.sealed,.unsealed,.sealed])
        XCTAssertEqual(r.render(nowNs:12).seal.pressuresKPaAbs,[50,80,50])
        XCTAssertEqual(r.render(nowNs:12).suction,.off)
        r.disconnectBLE(reason:"radio disconnected")
        XCTAssertEqual(r.render(nowNs:13).seal.states,[.unknown,.unknown,.unknown])
        XCTAssertEqual(r.render(nowNs:13).suction,.unknown)
        XCTAssertTrue(r.readiness(snapshot:snapshot(),nowNs:13).contains("BLE progress unsynchronized"))
    }
    func testCounterBoundarySnapshotsKeepUnknownPrefixSeparateFromLifetime() throws {
        let r = try warmRuntime(encoderCapacity:4)
        let before = try r.admitCamera(pose:pose(12))
        try r.prepare(snapshot:snapshot(),trialID:"t",requestID:"prepare",nowNs:13); _ = try drain(r)
        _ = try r.receiveHost(hostStatus("preparing",revision:1,request:"prepare",time:2),receivedNs:14)
        try r.completeCamera(ticket:try XCTUnwrap(before.encodeTicket),image:nil)
        try completeBarrier(r,now:15); _ = try drain(r)
        _ = try r.receiveHost(hostStatus("recording",revision:2,request:"prepare:begin",time:3),receivedNs:16)
        try r.stop(requestID:"stop",nowNs:17)
        let after = try r.admitCamera(pose:pose(18))
        XCTAssertNil(after.encodeTicket)
        try completeBarrier(r,now:19)
        let stop = try XCTUnwrap(try drain(r).first { $0.metadata["action"] as? String == "stop" })
        let c = try XCTUnwrap(stop.metadata["counters"] as? [[String:Any]])
        let main = try XCTUnwrap(c.first { $0["stream_id"] as? String == "main_rgb" })
        XCTAssertEqual(main["source_count"] as? Int,2)
        XCTAssertEqual(main["rejected_count"] as? Int,1)
        XCTAssertTrue(r.beginCounterSnapshot.first { $0.stream == .mainRGB }?.metadata["rejected_count"] is NSNull)
        XCTAssertEqual(r.counters.first { $0.stream == .mainRGB }?.counts.rejectedCount,1)
        XCTAssertTrue(r.outstandingEncodeTickets.isEmpty)
        XCTAssertFalse(r.encodingRecommended)
    }
    func testKnownTrialEncodeLossCannotRenderSaved() throws {
        let r = try recordingRuntime()
        let dropped = try r.admitCamera(pose:pose(16))
        try r.completeCamera(ticket:try XCTUnwrap(dropped.encodeTicket),image:nil)
        try r.stop(requestID:"stop",nowNs:17); try completeBarrier(r,now:18); _ = try drain(r)
        XCTAssertFalse(try r.receiveHost(hostStatus("saved",revision:4,request:"stop",time:5,path:"bag/false"),receivedNs:19))
        XCTAssertNil(r.render(nowNs:19).lastSave)
        XCTAssertTrue(r.render(nowNs:19).configurationFrozen)
    }
    func testPingPongAndCompletedUSBClockDoNotEcho() throws {
        let r = try warmRuntime()
        let ping = try USICollectionWire.decode(USICollectionWire.encode(type:.ping,metadata:["ping_id":17,"host_send_ns":100]))
        try r.replyToPing(ping,receivedNs:200,sentNs:230)
        let pong = try XCTUnwrap(try drain(r).first)
        XCTAssertEqual(pong.type,.pong)
        XCTAssertEqual(pong.metadata["host_send_ns"] as? Int,100)
        XCTAssertEqual(pong.metadata["phone_receive_ns"] as? Int,200)
        XCTAssertEqual(pong.metadata["phone_send_ns"] as? Int,230)
        let usb = try decoded(USICollectionPackets.clock(link:"usb",exchange:"usb:h:17",source:"p",epoch:"p",times:[100,200,230,150]))
        XCTAssertTrue(try r.receiveHost(usb,receivedNs:240))
        XCTAssertNotNil(r.latestUSBClock)
        XCTAssertTrue(try drain(r).isEmpty)
    }
    func testValidPlanesPreserveRawDepthBytesAndRejectBadConfidence() throws {
        var raw = image()
        raw.depth = USICameraPlane(width:2,height:1,bytes:Data([0,0,128,127, 0,0,192,127]))
        raw.confidence = USICameraPlane(width:2,height:1,bytes:Data([0,2]))
        let frame = try USICollectionPackets.mainFrame(session:"p",epoch:"w",sequence:0,pose:pose(),image:raw,
            acquired:1,encodeDrops:0,transportDrops:0)
        XCTAssertEqual(try decoded(frame).payload,Data([1,2,3,0,0,128,127,0,0,192,127,0,2]))
        raw.confidence = USICameraPlane(width:1,height:1,bytes:Data([1]))
        XCTAssertThrowsError(try USICollectionPackets.mainFrame(session:"p",epoch:"w",sequence:0,pose:pose(),image:raw,
            acquired:1,encodeDrops:0,transportDrops:0))
    }
    func testSourceLossCountersAreActualBaselineAndEndNotGuessedZero() throws {
        let r = try recordingRuntime()
        try r.stop(requestID:"stop",nowNs:16)
        try completeBarrier(r,now:17,overflow:2)
        let stop = try XCTUnwrap(try drain(r).first { $0.metadata["action"] as? String == "stop" })
        let c = try XCTUnwrap(stop.metadata["counters"] as? [[String:Any]])
        XCTAssertEqual(c.first { $0["stream_id"] as? String == "pressures" }?["queue_overflow_count"] as? Int,2)
        XCTAssertFalse(try r.receiveHost(hostStatus("saved",revision:4,time:4,path:"bag/bad"),receivedNs:18))
    }
    func testBackgroundAndEpochResetFreezeUntilAuthoritativeOutcome() throws {
        let r = try recordingRuntime()
        let old = try r.admitCamera(pose:pose(16))
        try r.resetWorld(epochID:"w2")
        XCTAssertTrue(r.render(nowNs:17).configurationFrozen)
        XCTAssertNotNil(r.render(nowNs:17).unknownReason)
        XCTAssertThrowsError(try r.completeCamera(ticket:try XCTUnwrap(old.encodeTicket),image:image()))
        r.background()
        var disconnects = 0
        while let effect = r.takeEffect() { if case .disconnectTransport = effect { disconnects += 1 } }
        XCTAssertEqual(disconnects,1)
        XCTAssertTrue(try drain(r).isEmpty)
    }
    func testBLERejectsReplayedReconnectSampleAndRegressingSourceTime() throws {
        var b = try USICollectionBLEProgress(capacity:2)
        try b.connect(source:"esp",boot:5,connection:"a",phone:"p")
        _ = try b.barrier(clock(pressure:4),firstReceivedNs:2,completedNs:2)
        let first = USIBLEPressureSample(rawSequence:4,sourceTimeUs:100,pressuresCentiPa:[1,2,3],qualityErrorMask:0)
        _ = try b.receive(.pressure(5,[first]),firstReceivedNs:3,completedNs:3)
        let backwards = USIBLEPressureSample(rawSequence:5,sourceTimeUs:99,pressuresCentiPa:[1,2,3],qualityErrorMask:0)
        XCTAssertThrowsError(try b.receive(.pressure(5,[backwards]),firstReceivedNs:4,completedNs:4))
        try b.connect(source:"esp",boot:5,connection:"b",phone:"p")
        _ = try b.receive(.pressure(5,[first]),firstReceivedNs:5,completedNs:5)
        XCTAssertThrowsError(try b.barrier(clock(pressure:6),firstReceivedNs:6,completedNs:6))
    }
    func testBLERejectsOversizedTypedBatchBeforeUnboundedWork() throws {
        var b = try USICollectionBLEProgress(capacity:100)
        try b.connect(source:"esp",boot:5,connection:"c",phone:"p")
        let samples = (0..<11).map { USIBLEPressureSample(rawSequence:UInt32($0),sourceTimeUs:1,
            pressuresCentiPa:[1,2,3],qualityErrorMask:0) }
        XCTAssertThrowsError(try b.receive(.pressure(5,samples),firstReceivedNs:2,completedNs:2))
    }
    func testControlOverflowClosesTransportAndReportsExactlyOneEffect() throws {
        let q = try USICollectionTransport(controlCapacity:1)
        let r = try USICollectionRuntime(sessionID:"p",worldEpochID:"w",transport:q)
        XCTAssertThrowsError(try r.connectHost(capabilities:capabilities(),nowNs:1))
        XCTAssertNil(r.takeNext())
        var count = 0
        while let effect = r.takeEffect() { if case .disconnectTransport = effect { count += 1 } }
        XCTAssertEqual(count,1)
    }
    func testBoundedPeriodicClockMayFinishBeforeFreshStopBarrier() throws {
        let r = try recordingRuntime()
        XCTAssertTrue(try r.requestBLEProgress(nowNs:16))
        try r.stop(requestID:"stop",nowNs:17)
        try completeBarrier(r,now:18)
        XCTAssertFalse(try drain(r).contains { $0.metadata["action"] as? String == "stop" })
        try completeBarrier(r,now:19)
        XCTAssertEqual(try drain(r).first { $0.metadata["action"] as? String == "stop" }?.type,.trialCommand)
    }
    func testUnrepresentableSourceLossCounterFailsExplicitly() throws {
        let r = try warmRuntime()
        XCTAssertTrue(try r.requestBLEProgress(nowNs:12))
        var request: (UInt32,UInt64)?
        while let effect = r.takeEffect() { if case let .requestBLEClock(id,time) = effect { request = (id,time) } }
        let pending = try XCTUnwrap(request)
        let impossible = USIBLEClock(requestID:pending.0,t1PhoneNs:pending.1,t2DeviceUs:2,t3DeviceUs:3,snapshotDeviceUs:2,
            pressureAcquired:1,triggerAcquired:1,pressureOverflow:UInt64.max,triggerOverflow:0,
            pressureDisconnected:1,triggerDisconnected:0,schedulerSkips:0,pressureNotifyLost:0,triggerNotifyLost:0,
            notifyCalls:1,notifyFailures:0,disconnects:0)
        XCTAssertThrowsError(try r.receiveBLE(.clock(5,impossible),firstReceivedNs:13,completedNs:13))
        XCTAssertTrue(r.readiness(snapshot:snapshot(),nowNs:13).contains("BLE progress unsynchronized"))
    }
    func testFragmentReceiptAndAbandonedMessageLossAreExplicit() throws {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
        let hex = try String(contentsOf:root.appendingPathComponent("fixtures/ble_trigger.hex")).filter { !$0.isWhitespace }
        let chars = Array(hex)
        let logical = Data(try stride(from:0,to:chars.count,by:2).map { try XCTUnwrap(UInt8(String(chars[$0...$0+1]),radix:16)) })
        let r = try USICollectionRuntime(sessionID:"p",worldEpochID:"w")
        try r.connectHost(capabilities:capabilities(),nowNs:1)
        try r.connectBLE(sourceID:"esp",bootID:0x12345678,connectionID:"c",nowNs:2)
        let parts = try USIBLECodec.fragment(logical,messageID:10)
        for (i,part) in parts.enumerated() { try r.receiveBLEFragment(part,receivedNs:10+UInt64(i)) }
        let c = clock(pressure:0,trigger:8,request:1,sent:2)
        try r.receiveBLE(.clock(0x12345678,c),firstReceivedNs:20,completedNs:21)
        let t = try XCTUnwrap(try drain(r).first { $0.type == .trigger })
        XCTAssertEqual(t.metadata["phone_receive_ns"] as? Int,10)
        XCTAssertEqual(r.latestBLEClock?.metadata["t4_ns"] as? Int,20)
        let abandoned = try USIBLECodec.fragment(logical,messageID:11)
        try r.receiveBLEFragment(abandoned[0],receivedNs:30)
        let replacement = try USIBLECodec.fragment(logical,messageID:12)
        XCTAssertThrowsError(try r.receiveBLEFragment(replacement[0],receivedNs:31))
        XCTAssertNil(r.takeNext())
    }
    func testUnknownRecoveryRetriesSameReadOnlyRequestWithinBudget() throws {
        let r = try recordingRuntime()
        r.disconnectHost(reason:"USB removed")
        try r.connectHost(capabilities:capabilities(),nowNs:20)
        let first = try XCTUnwrap(try drain(r).first { $0.type == .trialCommand })
        let requestID = try XCTUnwrap(first.metadata["request_id"] as? String)
        XCTAssertTrue(try r.retry(requestID:requestID,nowNs:21))
        let second = try XCTUnwrap(try drain(r).first)
        XCTAssertEqual(second.metadata["request_id"] as? String,requestID)
        XCTAssertEqual(second.metadata["action"] as? String,"status")
        XCTAssertTrue(try r.retry(requestID:requestID,nowNs:22))
        XCTAssertFalse(try r.retry(requestID:requestID,nowNs:23))
        XCTAssertFalse(try r.retry(requestID:"prepare",nowNs:24))
    }
    func testRecoveredFinalizingDoesNotReopenUnknownForwardingGate() throws {
        let r = try recordingRuntime()
        r.disconnectHost(reason:"USB removed before Stop")
        try r.connectHost(capabilities:capabilities(),nowNs:20); _ = try drain(r)
        XCTAssertTrue(try r.receiveHost(hostStatus("finalizing",revision:3,time:4),receivedNs:21))
        _ = try r.admitCamera(pose:pose(22))
        try r.receiveBLE(.pressure(5,[USIBLEPressureSample(rawSequence:1,sourceTimeUs:2,
            pressuresCentiPa:[1,2,3],qualityErrorMask:0)]),firstReceivedNs:23,completedNs:23)
        XCTAssertTrue(try drain(r).isEmpty)
        XCTAssertNotNil(r.render(nowNs:24).unknownReason)
        XCTAssertTrue(r.render(nowNs:24).configurationFrozen)
    }
    func testFrameSeparatesEncoderIngressAndFailuresFromTransportDrops() throws {
        let r = try warmRuntime(encoderCapacity:1)
        let a = try r.admitCamera(pose:pose(12))
        _ = try r.admitCamera(pose:pose(13)) // Encoder capacity, not socket transport.
        try r.completeCamera(ticket:try XCTUnwrap(a.encodeTicket),image:nil)
        let next = try r.admitCamera(pose:pose(14))
        try r.completeCamera(ticket:try XCTUnwrap(next.encodeTicket),image:image())
        let frame = try XCTUnwrap(try drain(r).first { $0.type == .frame })
        let c = try XCTUnwrap(frame.metadata["counters"] as? [String:Any])
        XCTAssertEqual(c["encode_drops"] as? Int,2)
        XCTAssertEqual(c["transport_drops"] as? Int,0)
    }
    func capabilities() -> [USICollectionCapability] {
        USICollectionWire.coreRequiredStreams.map { name in
            let stream = USICollectionStream(rawValue: name)!
            let sensor = [.pressures,.trigger,.seal].contains(stream)
            return USICollectionCapability(stream: stream, available: true, reason: nil,
                sourceID: sensor ? "esp" : "p", epochID: sensor ? "5" : "w")
        }
    }
}
