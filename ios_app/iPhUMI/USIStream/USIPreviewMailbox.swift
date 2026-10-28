import Foundation

struct USIPreviewUpdate {
    let epoch: String
    var jpeg: Data? = nil
    var details: String? = nil
    var clear = false
}

/// Coalesces capture updates while the main queue is busy. The scheduled closure
/// carries no JPEG; at most one pending image is retained, tagged with its epoch.
final class USIPreviewMailbox {
    private let lock = NSLock()
    private var epoch = ""
    private var pending: USIPreviewUpdate?
    private var scheduled = false

    func reset(epoch: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        self.epoch = epoch
        pending = USIPreviewUpdate(epoch: epoch, jpeg: nil, details: "Starting new tracking epoch", clear: true)
        let needsSchedule = !scheduled
        scheduled = true
        return needsSchedule
    }

    func offer(epoch: String, jpeg: Data? = nil, details: String? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard epoch == self.epoch else { return false }
        var update = pending ?? USIPreviewUpdate(epoch: epoch)
        if let jpeg { update.jpeg = jpeg }
        if let details { update.details = details }
        pending = update
        let needsSchedule = !scheduled
        scheduled = true
        return needsSchedule
    }

    func take() -> USIPreviewUpdate? {
        lock.lock(); defer { lock.unlock() }
        let result = pending
        pending = nil
        scheduled = false
        return result
    }

    func isCurrent(_ candidate: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return candidate == epoch
    }
}
