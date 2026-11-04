import CoreBluetooth
import Foundation

/// All CoreBluetooth callbacks and event consumers share the supplied serial owner queue.
/// This adapter receives telemetry only; it has no motor-control command.
final class USIBLECentral: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private static let serviceID = CBUUID(string: "0cda0100-6c5b-4a45-9a80-3e65c2316ab0")
    private static let notifyID = CBUUID(string: "0cda0101-6c5b-4a45-9a80-3e65c2316ab0")
    private static let clockID = CBUUID(string: "0cda0102-6c5b-4a45-9a80-3e65c2316ab0")
    var onStatus: ((String) -> Void)?
    var onSubscribed: (() -> Void)?
    var onDisconnected: (() -> Void)?
    var onRejected: (() -> Void)?
    /// firstReceivedNs is the actual first notification callback time, including CLOCK t4.
    var onEvent: ((USIBLEEvent, UInt64, UInt64) -> Void)?
    /// CoreBluetooth's local opaque identity, not a MAC address or phone identifier.
    var sourceIdentifier: String? { peripheral.map { "ble:" + $0.identifier.uuidString } }
    private let queue: DispatchQueue
    private var manager: CBCentralManager!
    private var active = false
    private var peripheral: CBPeripheral?
    private var notification: CBCharacteristic?
    private var clock: CBCharacteristic?
    private var subscribed = false
    private var reassembler = USIBLEReassembler()
    private var firstReceivedNs: UInt64?
    private var connectionTimeout: DispatchWorkItem?
    private var reconnect: DispatchWorkItem?

    init(queue: DispatchQueue) {
        self.queue = queue
        super.init()
        manager = CBCentralManager(delegate: self, queue: queue)
    }

    func start() {
        dispatchPrecondition(condition: .onQueue(queue))
        active = true
        scanIfReady()
    }
    func stop() {
        dispatchPrecondition(condition: .onQueue(queue))
        active = false
        reconnect?.cancel(); reconnect = nil
        manager.stopScan()
        clearConnection()
        onStatus?("Bluetooth · stopped")
    }
    func requestClock(requestID: UInt32, t1PhoneNs: UInt64) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard subscribed, let peripheral, let clock else { return false }
        peripheral.writeValue(USIBLECodec.clockRequest(requestID: requestID, t1PhoneNs: t1PhoneNs),
            for: clock, type: .withResponse)
        return true
    }

    private func scanIfReady() {
        guard active else { return }
        switch manager.state {
        case .poweredOn:
            guard peripheral == nil else { return }
            onStatus?("Bluetooth · looking for USI-BLE")
            manager.scanForPeripherals(withServices: [Self.serviceID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        case .poweredOff: onStatus?("Bluetooth · turn Bluetooth on in Settings")
        case .unauthorized: onStatus?("Bluetooth · allow access in iPhone Settings")
        case .unsupported: onStatus?("Bluetooth · unavailable on this device")
        case .resetting, .unknown: onStatus?("Bluetooth · starting")
        @unknown default: onStatus?("Bluetooth · unavailable")
        }
    }

    private func clearConnection() {
        connectionTimeout?.cancel(); connectionTimeout = nil
        let old = peripheral
        peripheral = nil; notification = nil; clock = nil; subscribed = false
        reassembler = USIBLEReassembler(); firstReceivedNs = nil
        onDisconnected?()
        if let old { manager.cancelPeripheralConnection(old) }
    }
    func reconnectAfterFailure(_ reason: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        clearConnection()
        onStatus?(reason)
        reconnect?.cancel()
        guard active, manager.state == .poweredOn else { return }
        let retry = DispatchWorkItem { [weak self] in self?.scanIfReady() }
        reconnect = retry
        queue.asyncAfter(deadline: .now() + 2, execute: retry)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn { clearConnection() }
        scanIfReady()
    }
    func centralManager(_ central: CBCentralManager, didDiscover device: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard active, peripheral == nil else { return }
        reconnect?.cancel(); reconnect = nil
        central.stopScan()
        peripheral = device
        device.delegate = self
        onStatus?("Bluetooth · connecting to pressure rig")
        central.connect(device)
        let timeout = DispatchWorkItem { [weak self, weak device] in
            guard let self, let device, self.peripheral === device, !self.subscribed else { return }
            self.reconnectAfterFailure("Bluetooth · connection timed out; retrying")
        }
        connectionTimeout = timeout
        queue.asyncAfter(deadline: .now() + 10, execute: timeout)
    }
    func centralManager(_ central: CBCentralManager, didConnect device: CBPeripheral) {
        guard active, peripheral === device else { central.cancelPeripheralConnection(device); return }
        onStatus?("Bluetooth · discovering pressure service")
        device.discoverServices([Self.serviceID])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect device: CBPeripheral, error: Error?) {
        guard peripheral === device else { return }
        reconnectAfterFailure("Bluetooth · connection failed; retrying")
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral device: CBPeripheral, error: Error?) {
        guard peripheral === device else { return }
        reconnectAfterFailure("Bluetooth · disconnected; retrying")
    }
    func peripheral(_ device: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === device else { return }
        guard error == nil, let service = device.services?.first(where: { $0.uuid == Self.serviceID }) else {
            reconnectAfterFailure("Bluetooth · pressure service missing; retrying"); return
        }
        device.discoverCharacteristics([Self.notifyID, Self.clockID], for: service)
    }
    func peripheral(_ device: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === device, service.uuid == Self.serviceID else { return }
        guard error == nil,
              let notify = service.characteristics?.first(where: { $0.uuid == Self.notifyID }),
              let clock = service.characteristics?.first(where: { $0.uuid == Self.clockID }),
              notify.properties.contains(.notify), clock.properties.contains(.write) else {
            reconnectAfterFailure("Bluetooth · telemetry characteristics missing; retrying"); return
        }
        notification = notify; self.clock = clock
        device.setNotifyValue(true, for: notify)
    }
    func peripheral(_ device: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === device, notification === characteristic else { return }
        guard active, error == nil, characteristic.isNotifying else {
            reconnectAfterFailure("Bluetooth · subscription failed; retrying"); return
        }
        guard !subscribed else { return }
        connectionTimeout?.cancel(); connectionTimeout = nil
        subscribed = true
        reassembler = USIBLEReassembler(); firstReceivedNs = nil
        onSubscribed?()
        onStatus?("Bluetooth · subscribed to pressure rig")
    }
    func peripheral(_ device: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let receivedNs = DispatchTime.now().uptimeNanoseconds
        guard peripheral === device, notification === characteristic, subscribed else { return }
        guard error == nil, let data = characteristic.value else { onRejected?(); return }
        if data.count > 10, data[data.startIndex + 8] == 0, data[data.startIndex + 9] == 0 {
            firstReceivedNs = receivedNs
        }
        let oldDiscarded = reassembler.discarded
        do {
            let message = try reassembler.feed(data, receivedNs: receivedNs)
            if reassembler.discarded > oldDiscarded { onRejected?() }
            guard let message else { return }
            let first = firstReceivedNs ?? receivedNs
            firstReceivedNs = nil
            onEvent?(try USIBLECodec.decode(message), first, receivedNs)
        } catch {
            firstReceivedNs = nil
            onRejected?()
        }
    }
    func peripheral(_ device: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === device, clock === characteristic else { return }
        if error != nil { onRejected?() }
    }
    func peripheral(_ device: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard peripheral === device, invalidatedServices.contains(where: { $0.uuid == Self.serviceID }) else { return }
        reconnectAfterFailure("Bluetooth · service changed; reconnecting")
    }
}
