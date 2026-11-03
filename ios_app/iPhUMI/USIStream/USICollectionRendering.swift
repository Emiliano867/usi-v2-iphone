import Foundation

enum USICollectionLossKind { case encoderIngressOverflow, encodeFailure, sourceRejection, transportOverflow }
struct USICollectionLossTotals {
    var encoderIngressOverflows: UInt64 = 0
    var encodeFailures: UInt64 = 0
    var sourceRejections: UInt64 = 0
    var transportOverflows: UInt64 = 0
    var encodeDrops: UInt64 { encoderIngressOverflows + encodeFailures + sourceRejections }
}
struct USICollectionSave { let trialID: String; let bagPath: String }
struct USICollectionRates {
    var selectedSourceFPS: Double? = nil
    var acquisitionFPS: Double? = nil
    var previewFPS: Double? = nil
    var encodeFPS: Double? = nil
    var hostReceiveFPS: Double? = nil
    var hostWriteFPS: Double? = nil
    func validate() throws {
        guard [selectedSourceFPS,acquisitionFPS,previewFPS,encodeFPS,hostReceiveFPS,hostWriteFPS]
            .compactMap({$0}).allSatisfy({$0.isFinite && $0 >= 0}) else { throw USICollectionError.invalid("invalid measured rate") }
    }
}
struct USICollectionStreamRendering {
    let stream: USICollectionStream
    let phone: USICollectionCounter?
    /// Preserve unavailable host fields as JSON null; never infer them from phone totals.
    let host: [String:Any]?
    let rates: USICollectionRates
    let losses: USICollectionLossTotals?
    let trialLosses: USIStreamCounters?
}
struct USICollectionRendering {
    let state: USITrialState
    let recordingAssured: Bool
    let elapsedNs: UInt64?
    let configurationFrozen: Bool
    let stopEnabled: Bool
    let unknownReason: String?
    let trialID: String?
    let lastSave: USICollectionSave?
    let seal: USISealSnapshot
    let suction: USISuctionState
    let missingRequiredStreams: [String]
    let missingModalities: [String]
    let bleSourceProgress: USICollectionBLESourceSnapshot?
    let streams: [USICollectionStreamRendering]
}
extension USICollectionRuntime {
    func render(nowNs: UInt64) -> USICollectionRendering {
        // Access through counters also checks the serial owner for this read.
        let values = counters
        let fresh = connected && hostFresh(nowNs)
        let assured = phase == .recording && hostState == .recording && fresh && unknownReason == nil
        let display: USITrialState = unknownReason != nil ? .notConnected :
            phase == .stopBarrier || phase == .finalizing ? .finalizing :
            !fresh && frozen != nil ? .hostStale : phase == .preparing || phase == .beginBarrier || phase == .awaitRecording ? .preparing : hostState
        let elapsed: UInt64?
        if let start = recordingStartNs { let end = recordingEndNs ?? nowNs; elapsed = end >= start ? end-start : 0 }
        else { elapsed = nil }
        return USICollectionRendering(state:display,recordingAssured:assured,elapsedNs:elapsed,
            configurationFrozen:frozen != nil,stopEnabled:frozen != nil,unknownReason:unknownReason,
            trialID:activeTrialID,lastSave:lastSave,seal:sealSnapshot(now:nowNs),suction:trigger.state(nowNs:nowNs),
            missingRequiredStreams:hostMissing,missingModalities:excluded,
            bleSourceProgress:latestBLESourceProgress,
            streams:USICollectionStream.allCases.map { stream in
                USICollectionStreamRendering(stream:stream,phone:values.first(where:{$0.stream == stream}),
                    host:hostCounters.first(where:{$0["stream_id"] as? String == stream.rawValue}),rates:rates[stream] ?? USICollectionRates(),
                    losses:lossTotals[stream],trialLosses:trialLossCounters[stream])
            })
    }
    func readiness(snapshot: USICollectionSnapshot, nowNs: UInt64) -> [String] {
        _ = counters
        return ready(snapshot,now:nowNs)
    }
}
