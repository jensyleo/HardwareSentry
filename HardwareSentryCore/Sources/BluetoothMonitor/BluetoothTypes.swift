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

/// What a classic Bluetooth device says it is, from its Class of Device record.
///
/// Read at connect and remembered, because the record is cached against the paired device
/// rather than the live connection — which is what lets a disconnect still show the right
/// artwork instead of falling back to the plain glyph.
public enum BluetoothDeviceKind: String, Sendable, Equatable, CaseIterable {
    case computer, phone, accessPoint, wearable, health
    case keyboard, mouse, combo
    case headset, microphone, speaker, headphones

    public var iconBaseName: String {
        switch self {
        case .computer: return "BT-TypeComputer"
        case .phone: return "BT-TypePhone"
        case .accessPoint: return "BT-TypeAccessPoint"
        case .wearable: return "BT-TypeWearable"
        case .health: return "BT-TypeHealth"
        case .keyboard: return "BT-TypeKeyboard"
        case .mouse: return "BT-TypeMouse"
        case .combo: return "BT-TypeCombo"
        case .headset: return "BT-TypeHeadset"
        case .microphone: return "BT-TypeMicrophone"
        case .speaker: return "BT-TypeSpeaker"
        case .headphones: return "BT-TypeHeadphones"
        }
    }

    /// Decodes the Bluetooth SIG major/minor Class of Device pair. Nil for anything with
    /// no artwork of its own — an honest generic icon beats a wrong specific one.
    public static func from(major: UInt32, minor: UInt32) -> BluetoothDeviceKind? {
        switch major {
        case 0x01: return .computer
        case 0x02: return .phone
        case 0x03: return .accessPoint
        case 0x07: return .wearable
        case 0x09: return .health
        case 0x05:
            // The peripheral minor class packs keyboard/pointing/both into two bits.
            switch minor & 0x30 {
            case 0x10: return .keyboard
            case 0x20: return .mouse
            case 0x30: return .combo
            default: return nil
            }
        case 0x04:
            switch minor {
            case 0x01, 0x02: return .headset      // Headset, Hands-free
            case 0x03: return .microphone
            case 0x05: return .speaker
            case 0x06: return .headphones
            default: return nil
            }
        default: return nil
        }
    }
}

/// What the system told this monitor just happened.
public enum BluetoothSourceEvent: Sendable, Equatable {
    /// `detail` is what the device answered about itself at the moment it connected.
    /// Nil from a source that does not read it — the connection is still worth reporting.
    case classicConnected(name: String, kind: BluetoothDeviceKind?, detail: BluetoothDetail? = nil)
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
