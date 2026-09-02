import CoreBluetooth
import Foundation
import IOBluetooth

/// Watches classic Bluetooth device connect/disconnect, the radio's own power state, and
/// the CoreBluetooth subsystem state, and polls the paired-device list.
///
/// Deliberately thin and untested, for the same reason `IOKitUSBDeviceSource` is: none of
/// it can run without real Bluetooth hardware/pairing events. Everything worth reasoning
/// about lives in `BluetoothMonitor`, behind `BluetoothSource`.
public struct IOBluetoothSource: BluetoothSource {
    private let pairedPollInterval: Duration
    private let signalPollInterval: Duration

    /// - Parameter signalPollInterval: ten seconds, the original's figure. There is no
    ///   push notification for RSSI moving, so it has to be asked for.
    public init(
        pairedPollInterval: Duration = .seconds(15),
        signalPollInterval: Duration = .seconds(10)
    ) {
        self.pairedPollInterval = pairedPollInterval
        self.signalPollInterval = signalPollInterval
    }

    public func changes() -> AsyncStream<BluetoothSourceEvent> {
        AsyncStream { continuation in
            let watcher = Watcher(
                continuation: continuation,
                pairedPollInterval: pairedPollInterval,
                signalPollInterval: signalPollInterval
            )
            continuation.onTermination = { _ in watcher.stop() }
            watcher.start()
        }
    }
}

private final class Watcher: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    private let continuation: AsyncStream<BluetoothSourceEvent>.Continuation
    private let pairedPollInterval: Duration
    private let signalPollInterval: Duration

    private var connectNotification: IOBluetoothUserNotification?
    private var radioOnToken: NSObjectProtocol?
    private var radioOffToken: NSObjectProtocol?
    private var subsystemManager: CBCentralManager?
    private var pairedPollTask: Task<Void, Never>?

    private var signalPollTask: Task<Void, Never>?
    private var blePollTask: Task<Void, Never>?

    /// Peripherals this has opened its own link to, held because `CBCentralManager` does
    /// not retain them and a peripheral that is released mid-discovery simply stops
    /// answering.
    private var blePeripherals: [UUID: CBPeripheral] = [:]
    /// What each one has answered so far. GATT arrives one characteristic at a time.
    private var bleAnswers: [UUID: BLEAccessoryDetail] = [:]
    /// The pending "it has answered enough" timer per peripheral.
    private var bleCoalescing: [UUID: Task<Void, Never>] = [:]

    /// How long to wait after the last answer before reporting.
    ///
    /// Every characteristic comes back in its own callback, so a device that answers six
    /// of them would be six notifications without this. One and a half seconds is the
    /// original's figure: long enough for a slow accessory to finish, short enough that
    /// the news is still news.
    private static let bleCoalesceDelay = Duration.milliseconds(1500)

    /// Standard Bluetooth SIG service and characteristic numbers — Device Information
    /// (0x180A) and Battery (0x180F). Not vendor-specific, so these sixteen-bit values
    /// are the same on every maker's hardware.
    ///
    /// Built on demand rather than stored: `CBUUID` is a class and not `Sendable`, so a
    /// shared instance would be shared mutable state as far as the compiler is concerned
    /// — and these are cheap to make from a four-character string.
    private static var deviceInfoService: CBUUID { CBUUID(string: "180A") }
    private static var batteryService: CBUUID { CBUUID(string: "180F") }
    private static var batteryLevelCharacteristic: CBUUID { CBUUID(string: "2A19") }

    /// Which Device Information characteristic fills which field.
    private static func field(for uuid: CBUUID) -> WritableKeyPath<BLEFields, String?>? {
        switch uuid.uuidString.uppercased() {
        case "2A29": return \.manufacturer
        case "2A24": return \.model
        case "2A25": return \.serialNumber
        case "2A26": return \.firmwareVersion
        case "2A27": return \.hardwareVersion
        case "2A28": return \.softwareVersion
        default: return nil
        }
    }

    init(
        continuation: AsyncStream<BluetoothSourceEvent>.Continuation,
        pairedPollInterval: Duration,
        signalPollInterval: Duration
    ) {
        self.continuation = continuation
        self.pairedPollInterval = pairedPollInterval
        self.signalPollInterval = signalPollInterval
    }

    func start() {
        connectNotification = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(classicConnected(_:device:)))

        // Baseline the radio's current power state before listening for real transitions —
        // there is no push notification for "what is the state right now", only for changes.
        continuation.yield(.radioPower(isOn: IOBluetoothHostController.default()?.powerState == kBluetoothHCIPowerStateON))
        radioOnToken = NotificationCenter.default.addObserver(forName: NSNotification.Name("IOBluetoothHostControllerPoweredOnNotification"), object: nil, queue: nil) { [weak self] _ in
            self?.continuation.yield(.radioPower(isOn: true))
        }
        radioOffToken = NotificationCenter.default.addObserver(forName: NSNotification.Name("IOBluetoothHostControllerPoweredOffNotification"), object: nil, queue: nil) { [weak self] _ in
            self?.continuation.yield(.radioPower(isOn: false))
        }

        subsystemManager = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: false])

        pairedPollTask = Task { [pairedPollInterval] in
            while !Task.isCancelled {
                self.continuation.yield(.pairedSnapshot(Self.pairedDevices()))
                try? await Task.sleep(for: pairedPollInterval)
            }
        }

        // Slower than the rest: this asks CoreBluetooth for the accessories the system is
        // connected to, and a BLE accessory does not come and go the way a cable does.
        blePollTask = Task { [weak self] in
            while !Task.isCancelled {
                await MainActor.run { self?.refreshBLEAccessories() }
                try? await Task.sleep(for: .seconds(30))
            }
        }

        signalPollTask = Task { [signalPollInterval] in
            while !Task.isCancelled {
                self.continuation.yield(.signalSnapshot(Self.connectedSignals()))
                try? await Task.sleep(for: signalPollInterval)
            }
        }
    }

    /// Reads the live signal of every connected paired device.
    ///
    /// Connected only: `rawRSSI` answers nothing meaningful for a device that is merely
    /// paired, and ranking that answer would put a keyboard in a drawer on the same
    /// footing as one being typed on.
    private static func connectedSignals() -> [String: BluetoothSignalReading] {
        guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return [:] }

        var readings: [String: BluetoothSignalReading] = [:]
        for device in devices where device.isConnected() {
            guard let address = device.addressString else { continue }
            let rssi = Int(device.rawRSSI())
            // 127 is IOBluetooth's "not available". Kept out here as well as in the
            // ranking, so a device that cannot answer never enters the comparison at all.
            guard rssi != BluetoothSignalLevel.unavailableRSSI else { continue }
            readings[address] = BluetoothSignalReading(
                name: device.name ?? address,
                rssi: rssi
            )
        }
        return readings
    }

    func stop() {
        blePollTask?.cancel()
        for task in bleCoalescing.values { task.cancel() }
        for peripheral in blePeripherals.values { subsystemManager?.cancelPeripheralConnection(peripheral) }
        signalPollTask?.cancel()
        connectNotification?.unregister()
        if let radioOnToken { NotificationCenter.default.removeObserver(radioOnToken) }
        if let radioOffToken { NotificationCenter.default.removeObserver(radioOffToken) }
        pairedPollTask?.cancel()
        continuation.finish()
    }

    @objc func classicConnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        device.register(forDisconnectNotification: self, selector: #selector(classicDisconnected(_:device:)))
        continuation.yield(.classicConnected(
            name: device.name ?? "Bluetooth Device",
            kind: BluetoothDeviceKind.from(
                major: UInt32(device.deviceClassMajor),
                minor: UInt32(device.deviceClassMinor)
            ),
            detail: BluetoothDetail(device: device, batteryLevels: BluetoothAccessoryBattery.levelsByAddress())
        ))
    }

    @objc func classicDisconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        continuation.yield(.classicDisconnected(name: device.name ?? "Bluetooth Device"))
        note.unregister()
    }

    // MARK: - Low Energy accessories

    /// Looks for BLE accessories the system is already connected to.
    ///
    /// Not scanning: scanning is a radio-level search for things advertising nearby, which
    /// costs power and finds every stranger's earbuds on the bus. This asks the system
    /// which accessories *it* is already connected to that offer the two standard
    /// services, which is the set somebody would call "mine".
    private func refreshBLEAccessories() {
        guard let manager = subsystemManager, manager.state == .poweredOn else { return }

        let peripherals = manager.retrieveConnectedPeripherals(
            withServices: [Self.deviceInfoService, Self.batteryService]
        )
        for peripheral in peripherals where blePeripherals[peripheral.identifier] == nil {
            blePeripherals[peripheral.identifier] = peripheral
            bleAnswers[peripheral.identifier] = BLEAccessoryDetail()
            peripheral.delegate = self
            manager.connect(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.deviceInfoService, Self.batteryService])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let id = peripheral.identifier
        bleCoalescing.removeValue(forKey: id)?.cancel()
        blePeripherals.removeValue(forKey: id)
        bleAnswers.removeValue(forKey: id)
        continuation.yield(.bleDisconnected(name: peripheral.name ?? "Bluetooth LE accessory"))
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] where characteristic.properties.contains(.read) {
            peripheral.readValue(for: characteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let id = peripheral.identifier
        guard var answers = bleAnswers[id], let data = characteristic.value else { return }

        if characteristic.uuid == Self.batteryLevelCharacteristic {
            // One unsigned byte, as the profile defines it.
            guard let level = data.first else { return }
            answers = BLEAccessoryDetail(
                manufacturer: answers.manufacturer, model: answers.model,
                serialNumber: answers.serialNumber, firmwareVersion: answers.firmwareVersion,
                hardwareVersion: answers.hardwareVersion, softwareVersion: answers.softwareVersion,
                batteryPercent: Int(level)
            )
        } else if let field = Self.field(for: characteristic.uuid) {
            // The Device Information characteristics are all UTF-8 strings, sometimes with
            // trailing whitespace a vendor left in.
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }

            var fields = BLEFields(
                manufacturer: answers.manufacturer, model: answers.model,
                serialNumber: answers.serialNumber, firmwareVersion: answers.firmwareVersion,
                hardwareVersion: answers.hardwareVersion, softwareVersion: answers.softwareVersion
            )
            fields[keyPath: field] = text
            answers = BLEAccessoryDetail(
                manufacturer: fields.manufacturer, model: fields.model,
                serialNumber: fields.serialNumber, firmwareVersion: fields.firmwareVersion,
                hardwareVersion: fields.hardwareVersion, softwareVersion: fields.softwareVersion,
                batteryPercent: answers.batteryPercent
            )
        } else {
            return
        }

        bleAnswers[id] = answers
        scheduleBLEReport(for: peripheral)
    }

    /// Waits for the answers to stop arriving, then reports once.
    ///
    /// Restarted on every answer rather than set once: the delay is "it has gone quiet",
    /// not "one and a half seconds after the first reply", so a slow accessory still gets
    /// all of its characteristics into one notification.
    private func scheduleBLEReport(for peripheral: CBPeripheral) {
        let id = peripheral.identifier
        // The name is taken now rather than inside the task: `CBPeripheral` is a class
        // and not `Sendable`, and carrying one across the wait would be handing another
        // task a reference CoreBluetooth is free to mutate meanwhile.
        let name = peripheral.name
        bleCoalescing[id]?.cancel()
        bleCoalescing[id] = Task { [weak self] in
            try? await Task.sleep(for: Self.bleCoalesceDelay)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.reportBLE(id: id, name: name) }
        }
    }

    private func reportBLE(id: UUID, name: String?) {
        bleCoalescing.removeValue(forKey: id)
        guard let detail = bleAnswers[id], !detail.isEmpty else { return }

        continuation.yield(.bleConnected(
            name: name ?? detail.model ?? "Bluetooth LE accessory",
            detail: detail
        ))
    }

    // CBCentralManagerDelegate's one required method — only Resetting/Unauthorized/Unsupported
    // are forwarded; PoweredOn/Off/Unknown are the classic-API radio event's job.
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state: BluetoothSubsystemState?
        switch central.state {
        case .resetting: state = .resetting
        case .unauthorized: state = .unauthorized
        case .unsupported: state = .unsupported
        default: state = nil
        }
        if let state { continuation.yield(.subsystemState(state)) }
    }

    private static func pairedDevices() -> [String: String] {
        var result: [String: String] = [:]
        for device in IOBluetoothDevice.pairedDevices() ?? [] {
            guard let device = device as? IOBluetoothDevice, let address = device.addressString else { continue }
            result[address] = device.name ?? address
        }
        return result
    }
}

/// The Device Information answers, gathered as they arrive.
///
/// A separate mutable shape from `BLEAccessoryDetail` so the characteristics table above
/// can be a plain map from a Bluetooth SIG number to the field it fills, rather than a
/// switch that has to be kept in step with the table by hand.
struct BLEFields {
    var manufacturer: String?
    var model: String?
    var serialNumber: String?
    var firmwareVersion: String?
    var hardwareVersion: String?
    var softwareVersion: String?
}
