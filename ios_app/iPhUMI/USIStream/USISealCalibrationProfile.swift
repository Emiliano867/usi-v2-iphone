import Foundation

enum USISealCalibrationError: LocalizedError {
    case notReady, unstable, insufficientVacuum, invalidProfile
    var errorDescription: String? {
        switch self {
        case .notReady: return "Wait for all three live readings to stay valid for at least one second, then try again."
        case .unstable: return "Pressure is changing. Hold the cups steady for one second and try again."
        case .insufficientVacuum: return "Each sealed cup must measure at least 5 kPa below its open reading. Check the seal and tubing, then capture again."
        case .invalidProfile: return "This calibration is invalid. Capture new open and sealed readings."
        }
    }
}

/// Measured two-point pressure-seal preview, not a holding-force calibration.
struct USISealCalibrationProfile: Codable {
    static let defaultsKey = "usi.pressureSealCalibration.v1"
    let id: String
    let openKPaAbs: [Double]
    let sealedKPaAbs: [Double]

    init(openKPaAbs: [Double], sealedKPaAbs: [Double]) throws {
        id = UUID().uuidString
        self.openKPaAbs = openKPaAbs; self.sealedKPaAbs = sealedKPaAbs
        _ = try calibration()
    }

    func calibration() throws -> USIPressureCalibration {
        guard !id.isEmpty, id.count <= 128, openKPaAbs.count == 3, sealedKPaAbs.count == 3,
              (openKPaAbs + sealedKPaAbs).allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 200 }) else {
            throw USISealCalibrationError.invalidProfile
        }
        let chambers = try (0..<3).map { i -> USIChamberCalibration in
            let drop = openKPaAbs[i] - sealedKPaAbs[i]
            guard drop >= 5 else { throw USISealCalibrationError.insufficientVacuum }
            // Green at 70% of the observed vacuum drop, red below 50%; 200 ms persistence.
            return try USIChamberCalibration(sensorIndex: i, sectorIndex: i,
                sealOnKPaAbs: openKPaAbs[i] - 0.70 * drop,
                sealOffKPaAbs: openKPaAbs[i] - 0.50 * drop, persistenceNs: 200_000_000)
        }
        return try USIPressureCalibration(id: id, chambers: chambers)
    }

    static func load(from defaults: UserDefaults = .standard) -> USISealCalibrationProfile? {
        guard let data = defaults.data(forKey: defaultsKey), data.count <= 4096,
              let profile = try? JSONDecoder().decode(Self.self, from: data),
              (try? profile.calibration()) != nil else { return nil }
        return profile
    }

    func save(to defaults: UserDefaults = .standard) throws {
        _ = try calibration()
        defaults.set(try JSONEncoder().encode(self), forKey: Self.defaultsKey)
    }
}

/// One bounded second of original decoded measurements, owned by the BLE/capture queue.
struct USIPressureReferenceWindow {
    private var samples: [(time: UInt64, pressures: [Double], quality: UInt8)] = []
    mutating func receive(pressures: [Double], quality: UInt8, time: UInt64) {
        samples.append((time, pressures, quality))
        if samples.count > 200 { samples.removeFirst(samples.count - 200) }
    }
    func reference(nowNs: UInt64) throws -> [Double] {
        guard let last = samples.last, nowNs >= last.time, nowNs - last.time <= 200_000_000,
              last.quality == 7 else { throw USISealCalibrationError.notReady }
        let valid = samples.filter { sample in
            sample.time <= nowNs && nowNs - sample.time <= 1_000_000_000 && sample.quality == 7 &&
                sample.pressures.count == 3 && sample.pressures.allSatisfy { $0.isFinite && $0 >= 0 }
        }
        guard valid.count >= 30, let first = valid.first, let end = valid.last,
              end.time - first.time >= 500_000_000,
              zip(valid, valid.dropFirst()).allSatisfy({ $1.time - $0.time <= 100_000_000 }) else {
            throw USISealCalibrationError.notReady
        }
        return try (0..<3).map { channel in
            let values = valid.map { $0.pressures[channel] }.sorted()
            guard values.last! - values.first! <= 2 else { throw USISealCalibrationError.unstable }
            return values[values.count / 2]
        }
    }
}
