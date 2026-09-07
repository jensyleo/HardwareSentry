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
    // The rest of what the SIG defines under major class Peripheral, below the
    // keyboard/pointing bits. A gamepad or a remote is not a kind of mouse.
    case gamepad, remote, tablet, cardReader, barcodeScanner, sensor

    /// How the row is named in Settings, in the original's words.
    var settingsTitle: String {
        switch self {
        case .computer: return "Computer"
        case .phone: return "Phone"
        case .accessPoint: return "Access Point"
        case .wearable: return "Wearable"
        case .health: return "Health"
        case .keyboard: return "Keyboard"
        case .mouse: return "Mouse"
        case .combo: return "Combo"
        case .headset: return "Headset"
        case .microphone: return "Microphone"
        case .speaker: return "Speaker"
        case .headphones: return "Headphones"
        case .gamepad: return "Gamepad"
        case .remote: return "Remote Control"
        case .tablet: return "Graphics Tablet"
        case .cardReader: return "Card Reader"
        case .barcodeScanner: return "Handheld Scanner"
        case .sensor: return "Sensor"
        }
    }

    /// The event raised when a device of this kind connects.
    var connectedEvent: BluetoothEvent {
        switch self {
        case .computer: return .connectedComputer
        case .phone: return .connectedPhone
        case .accessPoint: return .connectedAccessPoint
        case .wearable: return .connectedWearable
        case .health: return .connectedHealth
        case .keyboard: return .connectedKeyboard
        case .mouse: return .connectedMouse
        case .combo: return .connectedCombo
        case .headset: return .connectedHeadset
        case .microphone: return .connectedMicrophone
        case .speaker: return .connectedSpeaker
        case .headphones: return .connectedHeadphones
        case .gamepad: return .connectedGamepad
        case .remote: return .connectedRemote
        case .tablet: return .connectedTablet
        case .cardReader: return .connectedCardReader
        case .barcodeScanner: return .connectedBarcodeScanner
        case .sensor: return .connectedSensor
        }
    }

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
        case .gamepad: return "BT-TypeGamepad"
        case .remote: return "BT-TypeRemote"
        case .tablet: return "BT-TypeTablet"
        case .cardReader: return "BT-TypeCardReader"
        case .barcodeScanner: return "BT-TypeBarcodeScanner"
        case .sensor: return "BT-TypeSensor"
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
            // The peripheral minor class is two independent fields: two bits saying
            // whether the device is a keyboard, a pointing device or both, and a
            // four-bit device type underneath them. Reading only the two bits — which
            // is all this used to do — meant every Bluetooth gamepad, remote and
            // tablet answered "not a keyboard, not a mouse" and got the generic glyph.
            //
            // The two bits are still read first: they are the device's primary
            // character, and what real keyboards and mice actually set.
            switch minor & 0x30 {
            case 0x10: return .keyboard
            case 0x30: return .combo
            case 0x20:
                // A digitizer tablet is a pointing device with somewhere more specific
                // to go. Anything else pointing stays a mouse.
                return peripheralType(minor) == .tablet ? .tablet : .mouse
            default: return peripheralType(minor)
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

    /// The four-bit device type the SIG defines under major class Peripheral, for the
    /// subtypes that sit below the keyboard/pointing bits.
    ///
    /// Uncategorized (0x0) and handheld gestural input (0x9) deliberately return nil:
    /// there is no artwork that would be honest for either, and a generic glyph beats a
    /// wrong specific one.
    private static func peripheralType(_ minor: UInt32) -> BluetoothDeviceKind? {
        switch minor & 0x0F {
        case 0x01, 0x02: return .gamepad        // Joystick, Gamepad
        case 0x03: return .remote               // Remote control
        case 0x04: return .sensor               // Sensing device
        case 0x05, 0x07: return .tablet         // Digitizer tablet, Digital pen
        case 0x06: return .cardReader           // Card reader, e.g. a SIM reader
        case 0x08: return .barcodeScanner       // Handheld scanner (barcode, RFID)
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
    /// The live signal of every connected device, address → (name, RSSI in dBm).
    ///
    /// A snapshot rather than a delta, and polled: IOBluetooth has no push notification
    /// for RSSI moving, and a reading is only meaningful while the device is connected.
    case signalSnapshot([String: BluetoothSignalReading])
    /// A Bluetooth Low Energy accessory answered about itself.
    ///
    /// Separate from the classic connect: a BLE accessory is not "connected" to the Mac
    /// in the classic sense, it is discovered as already connected to the system and then
    /// asked, over its own GATT link, what it is.
    case bleConnected(name: String, detail: BLEAccessoryDetail)
    case bleDisconnected(name: String)
}

public protocol BluetoothSource: Sendable {
    func changes() -> AsyncStream<BluetoothSourceEvent>
}

/// One device's live signal reading.
public struct BluetoothSignalReading: Sendable, Equatable {
    public let name: String
    /// dBm. 127 is IOBluetooth's "not available", and is refused rather than ranked.
    public let rssi: Int

    public init(name: String, rssi: Int) {
        self.name = name
        self.rssi = rssi
    }
}

/// What a Bluetooth Low Energy accessory said about itself over GATT.
///
/// From the two services the Bluetooth SIG standardised for exactly this — Device
/// Information (0x180A) and Battery (0x180F) — so these are the same numbers on every
/// vendor's hardware rather than something read from one manufacturer's private service.
public struct BLEAccessoryDetail: Sendable, Equatable {
    public let manufacturer: String?
    public let model: String?
    public let serialNumber: String?
    public let firmwareVersion: String?
    public let hardwareVersion: String?
    public let softwareVersion: String?
    public let batteryPercent: Int?

    public init(
        manufacturer: String? = nil,
        model: String? = nil,
        serialNumber: String? = nil,
        firmwareVersion: String? = nil,
        hardwareVersion: String? = nil,
        softwareVersion: String? = nil,
        batteryPercent: Int? = nil
    ) {
        self.manufacturer = manufacturer
        self.model = model
        self.serialNumber = serialNumber
        self.firmwareVersion = firmwareVersion
        self.hardwareVersion = hardwareVersion
        self.softwareVersion = softwareVersion
        self.batteryPercent = batteryPercent
    }

    /// Whether the accessory answered anything at all.
    ///
    /// Some do not: a BLE device is free to advertise the Device Information service and
    /// implement none of its characteristics. Reporting that as a connection with an
    /// empty body would be announcing a shrug.
    public var isEmpty: Bool {
        manufacturer == nil && model == nil && serialNumber == nil
            && firmwareVersion == nil && hardwareVersion == nil
            && softwareVersion == nil && batteryPercent == nil
    }

    var batteryNote: String? { batteryPercent.map { "\($0)%" } }

    /// Maker, model and firmware as one line — the three that together say which thing
    /// this is, where three separate lines would say it three times over.
    var identityNote: String? {
        var parts: [String] = []
        if let manufacturer { parts.append(manufacturer) }
        // Left out when it just repeats the maker, which several accessories do.
        if let model, model != manufacturer { parts.append(model) }
        if let firmwareVersion { parts.append("fw \(firmwareVersion)") }
        if let hardwareVersion { parts.append("hw \(hardwareVersion)") }
        if let softwareVersion { parts.append("sw \(softwareVersion)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
