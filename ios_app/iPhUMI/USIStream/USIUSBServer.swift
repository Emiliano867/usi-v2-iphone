import Foundation
import CoreFoundation
import Network

/// Network state belongs to `queue`; the ingress mailbox/drop counter use offerLock.
/// Only two encoded frames are retained: one sending and one pending replacement.
final class USIUSBServer {
    var onStatus: ((String) -> Void)?
    private let queue = DispatchQueue(label: "usi.usb.transport")
    private var listener: NWListener?
    private var connection: NWConnection?
    private var token = UUID()
    private var sessionID = ""
    private var negotiated = false
    private var sending = false
    private var sendToken = UUID()
    private let offerLock = NSLock()
    private var pendingFrame: ([String: Any], Data)? // protected by offerLock
    private var offerPumpScheduled = false // prevents an unbounded queue of retained frame closures
    private var controls: [(USIMessageType, [String: Any])] = []
    private var transportDrops: UInt64 = 0

    func start(sessionID: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.sessionID = sessionID
            guard self.listener == nil else { return }
            do {
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 5558)
                let listener = try NWListener(using: parameters)
                self.listener = listener
                listener.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready: self?.status("USB ready — waiting for Ubuntu")
                    case .failed(let error): self?.status("USB listener: \(error.localizedDescription)")
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] in self?.accept($0) }
                listener.start(queue: self.queue)
            } catch { self.status("USB listener: \(error.localizedDescription)") }
        }
    }

    func resetSession(_ newID: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.sessionID = newID
            self.offerLock.lock()
            self.pendingFrame = nil
            self.transportDrops = 0
            self.offerLock.unlock()
            self.enqueueControl(.health, ["event": "world_reset", "session_id": newID,
                                          "message": "ARKit tracking reset; new world epoch"])
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.closeConnection()
            self.listener?.cancel()
            self.listener = nil
            self.status("USB stopped")
        }
    }

    func offerFrame(metadata: [String: Any], payload: Data) {
        offerLock.lock()
        if pendingFrame != nil { transportDrops += 1 }
        pendingFrame = (metadata, payload)
        let schedule = !offerPumpScheduled
        offerPumpScheduled = true
        offerLock.unlock()
        if schedule {
            queue.async { [weak self] in
                guard let self else { return }
                self.offerLock.lock()
                self.offerPumpScheduled = false
                self.offerLock.unlock()
                self.pump()
            }
        }
    }

    func health(event: String, message: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.enqueueControl(.health, ["event": event, "message": message, "session_id": self.sessionID])
        }
    }

    private func accept(_ candidate: NWConnection) {
        guard connection == nil else { candidate.cancel(); return }
        token = UUID()
        let current = token
        connection = candidate
        negotiated = false
        candidate.stateUpdateHandler = { [weak self] state in
            guard let self, self.token == current else { return }
            switch state {
            case .ready:
                self.status("USB connected — negotiating")
                self.readHeader(candidate, token: current)
            case .failed, .cancelled:
                self.closeConnection()
                self.status("USB disconnected — waiting for Ubuntu")
            default: break
            }
        }
        candidate.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.token == current, !self.negotiated else { return }
            self.closeConnection()
            self.status("USB handshake timed out")
        }
    }

    private func readHeader(_ client: NWConnection, token current: UUID) {
        readExact(16, client: client, token: current) { [weak self] headerData in
            guard let self, self.token == current else { return }
            do {
                let header = try USIWire.parseHeader(headerData)
                // Reject unexpected host messages before reading any large FRAME payload.
                guard header.type == .hello || header.type == .ping else { throw USIWireError.badType }
                self.readExact(header.metadataLength, client: client, token: current) { [weak self] metadata in
                    guard let self, self.token == current else { return }
                    let receiveNS = Self.uptimeNS()
                    do {
                        let packet = try USIWire.decode(headerData + metadata)
                        try self.handle(packet, receiveNS: receiveNS)
                        if self.token == current { self.readHeader(client, token: current) }
                    } catch { self.protocolFailure() }
                }
            } catch { self.protocolFailure() }
        }
    }

    private func readExact(_ count: Int, client: NWConnection, token current: UUID,
                           partial: Data = Data(), completion: @escaping (Data) -> Void) {
        guard token == current else { return }
        if partial.count == count { completion(partial); return }
        client.receive(minimumIncompleteLength: 1, maximumLength: count - partial.count) {
            [weak self] bytes, _, ended, error in
            guard let self, self.token == current else { return }
            guard error == nil, let bytes, !bytes.isEmpty else {
                self.closeConnection()
                self.status("USB disconnected — waiting for Ubuntu")
                return
            }
            let combined = partial + bytes
            if combined.count == count { completion(combined) }
            else if ended { self.protocolFailure() }
            else { self.readExact(count, client: client, token: current, partial: combined, completion: completion) }
        }
    }

    private func handle(_ packet: USIWirePacket, receiveNS: UInt64) throws {
        if packet.type == .hello {
            guard !negotiated, packet.metadata["role"] as? String == "host",
                  Self.unsigned(packet.metadata["protocol_version"]) == 1 else { throw USIWireError.badVersion }
            negotiated = true
            enqueueControl(.hello, ["role": "phone", "protocol_version": 1, "session_id": sessionID,
                "camera_frame": "arkit_camera", "world_frame": "arkit_world",
                "arkit_clock": "ARFrame.timestamp_seconds", "phone_clock": "ProcessInfo.systemUptime_ns"])
            status("USB streaming to Ubuntu")
        } else {
            guard negotiated, let pingID = Self.unsigned(packet.metadata["ping_id"]),
                  let hostSend = Self.unsigned(packet.metadata["host_send_ns"]) else { throw USIWireError.invalidJSON }
            enqueueControl(.pong, ["ping_id": pingID, "host_send_ns": hostSend,
                "phone_receive_ns": receiveNS, "session_id": sessionID])
        }
    }

    private func enqueueControl(_ type: USIMessageType, _ metadata: [String: Any]) {
        guard negotiated else { return }
        guard controls.count < 8 else { protocolFailure(); return }
        controls.append((type, metadata))
        pump()
    }

    private func pump() {
        guard negotiated, !sending, let client = connection else { return }
        var type: USIMessageType
        var metadata: [String: Any]
        var payload = Data()
        if !controls.isEmpty {
            (type, metadata) = controls.removeFirst()
            if type == .pong { metadata["phone_send_ns"] = Self.uptimeNS() }
        } else {
            offerLock.lock()
            let frame = pendingFrame
            pendingFrame = nil
            let drops = transportDrops
            offerLock.unlock()
            guard let frame else { return }
            guard frame.0["session_id"] as? String == sessionID else { pump(); return }
            type = .frame
            metadata = frame.0
            payload = frame.1
            var counts = metadata["counters"] as? [String: Any] ?? [:]
            counts["transport_drops"] = drops
            metadata["counters"] = counts
        }
        do {
            let bytes = try USIWire.encode(type: type, metadata: metadata, payload: payload)
            sending = true
            sendToken = UUID()
            let write = sendToken, current = token
            client.send(content: bytes, completion: .contentProcessed { [weak self] error in
                guard let self, self.token == current, self.sendToken == write else { return }
                self.sending = false
                if let error {
                    self.closeConnection()
                    self.status("USB send: \(error.localizedDescription)")
                } else { self.pump() }
            })
            queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.token == current, self.sendToken == write, self.sending else { return }
                self.closeConnection()
                self.status("USB stalled — disconnected")
            }
        } catch { protocolFailure() }
    }

    private func protocolFailure() {
        closeConnection()
        status("USB protocol error — waiting for a compatible host")
    }

    private func closeConnection() {
        token = UUID()
        connection?.cancel()
        connection = nil
        negotiated = false
        sending = false
        offerLock.lock()
        pendingFrame = nil
        offerLock.unlock()
        controls.removeAll()
    }

    private func status(_ text: String) {
        DispatchQueue.main.async { [weak self] in self?.onStatus?(text) }
    }

    private static func unsigned(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return UInt64(number.stringValue)
    }

    static func uptimeNS() -> UInt64 { UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000) }
}
