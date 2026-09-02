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

    public static let category: NotificationCategory = "Bluetooth"
}
