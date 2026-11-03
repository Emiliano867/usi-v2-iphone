import Foundation

struct USILiveSensorSnapshot {
    let seal: USISealSnapshot
    let suction: USISuctionState
    let pressureSamples: UInt64
    let triggerSamples: UInt64
    let missingPressureSamples: UInt64
    let missingTriggerSamples: UInt64
    let duplicates: UInt64
    let rejected: UInt64
}

/// Serial-owner display state. Original BLE events remain available to the recorder adapter.
/// Uncalibrated numbers can be displayed; seal colors require actual calibration.
struct USILiveSensorState {
    private var connected = false
    private var bootID: UInt32?
    private var seal = USISealModel(calibration: nil)
    private var trigger = USITriggerModel()
    private var pressureHistory = USISequenceHistory()
    private var triggerHistory = USISequenceHistory()
    private var pressureSamples: UInt64 = 0
    private var triggerSamples: UInt64 = 0
    private var missingPressureSamples: UInt64 = 0
    private var missingTriggerSamples: UInt64 = 0
    private var duplicates: UInt64 = 0
    private var rejected: UInt64 = 0

    mutating func connect() { self = Self(); connected = true }
    mutating func disconnect() {
        connected = false
        bootID = nil
        seal = USISealModel(calibration: nil)
        trigger = USITriggerModel()
    }
    mutating func reject() { rejected += 1 }

    mutating func receive(_ event: USIBLEEvent, receivedNs: UInt64) throws {
        guard connected else { throw USICollectionError.invalid("BLE is not subscribed") }
        let boot: UInt32
        switch event {
        case .pressure(let value, _), .trigger(let value, _), .clock(let value, _): boot = value
        }
        guard bootID == nil || bootID == boot else {
            throw USICollectionError.invalid("BLE source rebooted; reconnect required")
        }
        bootID = boot
        switch event {
        case .pressure(_, let samples):
            for sample in samples {
                let observation = try pressureHistory.observe(epoch: String(boot), rawSequence: UInt64(sample.rawSequence))
                guard accept(observation) else { continue }
                try seal.update(pressuresKPaAbs: sample.pressuresKPaAbs,
                    qualityMask: sample.qualityMask, receivedNs: receivedNs)
                pressureSamples += 1
                if let missing = observation.missing { missingPressureSamples += missing.upperBound - missing.lowerBound }
            }
        case .trigger(_, let sample):
            let observation = try triggerHistory.observe(epoch: String(boot), rawSequence: UInt64(sample.rawSequence))
            guard accept(observation) else { return }
            try trigger.update(pressed: sample.pressed, receivedNs: receivedNs)
            triggerSamples += 1
            if let missing = observation.missing { missingTriggerSamples += missing.upperBound - missing.lowerBound }
        case .clock: break
        }
    }

    private mutating func accept(_ observation: USISequenceObservation) -> Bool {
        switch observation.disposition {
        case .newEpoch, .accepted: return true
        case .duplicate: duplicates += 1; return false
        case .outOfOrder, .oldEpoch: rejected += 1; return false
        }
    }

    mutating func snapshot(nowNs: UInt64) -> USILiveSensorSnapshot {
        USILiveSensorSnapshot(seal: seal.snapshot(nowNs: nowNs), suction: trigger.state(nowNs: nowNs),
            pressureSamples: pressureSamples, triggerSamples: triggerSamples,
            missingPressureSamples: missingPressureSamples, missingTriggerSamples: missingTriggerSamples,
            duplicates: duplicates, rejected: rejected)
    }
}
