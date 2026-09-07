import SignalCore

/// What this monitor can tell you about.
///
/// Presence, the radio's own state, pairing changes, and how strong each connected
/// device's signal is. BLE/GATT accessory detail is not ported; see the porting notes.
public enum BluetoothEvent: String, NotificationEventKey, CaseIterable {
    case connected = "BluetoothConnected"
    case disconnected = "BluetoothDisconnected"
    case radioOn = "BluetoothRadioOn"
    case radioOff = "BluetoothRadioOff"
    case subsystemStateChanged = "BluetoothSubsystemStateChanged"
    case paired = "BluetoothPaired"
    case unpaired = "BluetoothUnpaired"
    // One row per bar, as with Wi-Fi. Per device: two accessories drift independently, and
    // a keyboard on the desk should not be compared with a headset in another room.
    case signalNone = "BluetoothSignalNone"
    case signalWeak = "BluetoothSignalWeak"
    case signalFair = "BluetoothSignalFair"
    case signalGood = "BluetoothSignalGood"
    case signalExcellent = "BluetoothSignalExcellent"
    /// A Bluetooth Low Energy accessory answered about itself, or went away.
    case leConnected = "BluetoothLEConnected"
    case leDisconnected = "BluetoothLEDisconnected"
    // One row per device kind, as the original has it.
    case connectedComputer = "BluetoothConnectedComputer"
    case connectedPhone = "BluetoothConnectedPhone"
    case connectedAccessPoint = "BluetoothConnectedAccessPoint"
    case connectedWearable = "BluetoothConnectedWearable"
    case connectedHealth = "BluetoothConnectedHealth"
    case connectedKeyboard = "BluetoothConnectedKeyboard"
    case connectedMouse = "BluetoothConnectedMouse"
    case connectedCombo = "BluetoothConnectedCombo"
    case connectedHeadset = "BluetoothConnectedHeadset"
    case connectedMicrophone = "BluetoothConnectedMicrophone"
    case connectedSpeaker = "BluetoothConnectedSpeaker"
    case connectedHeadphones = "BluetoothConnectedHeadphones"
    // The peripheral subtypes below the keyboard/pointing bits, which used to have
    // nowhere of their own to be reported.
    case connectedGamepad = "BluetoothConnectedGamepad"
    case connectedRemote = "BluetoothConnectedRemote"
    case connectedTablet = "BluetoothConnectedTablet"
    case connectedCardReader = "BluetoothConnectedCardReader"
    case connectedBarcodeScanner = "BluetoothConnectedBarcodeScanner"
    case connectedSensor = "BluetoothConnectedSensor"
    // Major class Imaging, and the one Toy subtype that is a real input device.
    case connectedPrinter = "BluetoothConnectedPrinter"
    case connectedScanner = "BluetoothConnectedScanner"
    case connectedCamera = "BluetoothConnectedCamera"
    case connectedDisplay = "BluetoothConnectedDisplay"

    public static let category: NotificationCategory = "Bluetooth"
}
