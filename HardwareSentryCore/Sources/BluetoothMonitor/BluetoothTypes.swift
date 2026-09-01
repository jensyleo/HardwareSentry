import Foundation

/// The three subsystem-level states worth reporting on their own, distinct from an
/// individual device connecting/disconnecting or the radio's own power state.
/// PoweredOn/PoweredOff/Unknown are deliberately not included — PoweredOn/Off are already
/// covered by the classic-API radio power event, and reporting both would duplicate it.
public enum BluetoothSubsystemState: Sendable, Equatable {
    case resetting
    case unauthorized
    case unsupported

    var title: String {
        switch self {
        case .resetting: return "Bluetooth is restarting"
        case .unauthorized: return "This app is no longer authorized to use Bluetooth"
        case .unsupported: return "Bluetooth Low Energy is not supported on this Mac"
        }
    }
}

/// What the system told this monitor just happened.
public enum BluetoothSourceEvent: Sendable, Equatable {
    case classicConnected(name: String, typeIdentifier: String)
    case classicDisconnected(name: String)
    /// The radio's own on/off power state. The first value seen is a baseline reading
    /// (taken once at start), not a real transition — the monitor treats it the same way
    /// every other baselined signal in this app is treated.
    case radioPower(isOn: Bool)
    case subsystemState(BluetoothSubsystemState)
    /// The full current set of paired devices (address → name) — not a delta. There is no
    /// push notification for pairing state changes, so this is always the result of a
    /// poll; the monitor is what turns it into paired/unpaired events.
    case pairedSnapshot([String: String])
}

public protocol BluetoothSource: Sendable {
    func changes() -> AsyncStream<BluetoothSourceEvent>
}
