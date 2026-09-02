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

private final class Watcher: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
    private let continuation: AsyncStream<BluetoothSourceEvent>.Continuation
    private let pairedPollInterval: Duration
    private let signalPollInterval: Duration

    private var connectNotification: IOBluetoothUserNotification?
    private var radioOnToken: NSObjectProtocol?
    private var radioOffToken: NSObjectProtocol?
    private var subsystemManager: CBCentralManager?
    private var pairedPollTask: Task<Void, Never>?

    private var signalPollTask: Task<Void, Never>?

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
            detail: BluetoothDetail(device: device)
        ))
    }

    @objc func classicDisconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        continuation.yield(.classicDisconnected(name: device.name ?? "Bluetooth Device"))
        note.unregister()
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
