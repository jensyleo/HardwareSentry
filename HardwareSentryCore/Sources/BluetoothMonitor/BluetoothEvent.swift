import SignalCore

/// What this monitor can tell you about.
///
/// This is the "presence" core only — a classic device connecting/disconnecting, the
/// radio's own power state, subsystem-level trouble, and pairing changes. BLE/GATT
/// accessory detail and per-level signal-strength notifications are not ported at all; see
/// the porting notes for exactly why and what it would take.
public enum BluetoothEvent: String, NotificationEventKey {
    case connected = "BluetoothConnected"
    case disconnected = "BluetoothDisconnected"
    case radioOn = "BluetoothRadioOn"
    case radioOff = "BluetoothRadioOff"
    case subsystemStateChanged = "BluetoothSubsystemStateChanged"
    case paired = "BluetoothPaired"
    case unpaired = "BluetoothUnpaired"

    public static let category: NotificationCategory = "Bluetooth"
}
