import Foundation
import IOBluetooth

/// Reads a device that has just connected for everything public `IOBluetoothDevice` API
/// will answer about it.
///
/// Untested for the same reason `IOBluetoothSource` is: it needs a real device pairing
/// with a real Mac. What is worth reasoning about — which lines appear, in what order,
/// under which preferences — lives in `BluetoothMonitor` and is tested there against a
/// `BluetoothDetail` built by hand. The one piece of real decoding, turning an SDP service
/// record into a profile name, is split out below so it can be tested on its own.
extension BluetoothDetail {
    init(device: IOBluetoothDevice) {
        self.init(
            kind: BluetoothDeviceKind.from(
                major: UInt32(device.deviceClassMajor),
                minor: UInt32(device.deviceClassMinor)
            ),
            address: device.addressString,
            isPaired: device.isPaired(),
            // Reported as 0 when the controller has no reading rather than as an error,
            // which `rssiNote` treats as "no line" rather than as a perfect signal.
            rssi: Int(device.rawRSSI()),
            linkType: Self.describe(link: device.getLinkType()),
            isIncoming: device.isIncoming(),
            services: Self.describeServices(device),
            isFavorite: device.isFavorite(),
            // `.distantPast` is what a device that has never been used comes back with.
            lastSeen: device.recentAccessDate().flatMap { $0 > Date(timeIntervalSince1970: 0) ? $0 : nil }
        )
    }

    /// Whether the connection is encrypted is deliberately absent: `IOBluetoothDevice`
    /// exposes no public accessor for it, and a security property is the last thing to
    /// report from an undocumented selector that could quietly start returning the wrong
    /// answer. See the pendings document.
    private static func describe(link type: BluetoothLinkType) -> String? {
        switch type {
        case UInt8(kBluetoothACLConnection.rawValue): return "ACL (data)"
        case UInt8(kBluetoothSCOConnection.rawValue): return "SCO (voice)"
        case UInt8(kBluetoothESCOConnection.rawValue): return "eSCO (voice)"
        // Includes `kBluetoothLinkTypeNone` (0xFF), which is what a device with no live
        // link reports — no line rather than a made-up one.
        default: return nil
        }
    }

    private static func describeServices(_ device: IOBluetoothDevice) -> String? {
        let records = (device.services as? [IOBluetoothSDPServiceRecord]) ?? []
        let names = records.compactMap(profileName(of:))
        // Deduplicated because a device commonly publishes several records that resolve to
        // the same profile, and sorted so the same device reads the same way every time.
        let unique = Array(Set(names)).sorted()
        return unique.isEmpty ? nil : unique.joined(separator: ", ")
    }

    /// The profile a service record represents, preferring the SIG-assigned UUID over the
    /// device's own free-text service name — vendors write whatever they like in the name,
    /// and "Wireless iAP" tells you less than "Handsfree".
    static func profileName(of record: IOBluetoothSDPServiceRecord) -> String? {
        if let uuid = serviceClassUUID(of: record), let named = profileNames[uuid] {
            return named
        }
        let fallback = record.getServiceName()?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (fallback?.isEmpty ?? true) ? nil : fallback
    }

    /// The 16-bit SIG service class from a record's ServiceClassIDList (attribute 0x0001).
    private static func serviceClassUUID(of record: IOBluetoothSDPServiceRecord) -> UInt16? {
        guard let list = record.getAttributeDataElement(0x0001),
              let elements = list.getArrayValue() as? [IOBluetoothSDPDataElement]
        else { return nil }

        for element in elements {
            guard let uuid = element.getUUIDValue()?.getWithLength(2) else { continue }
            var value: UInt16 = 0
            withUnsafeMutableBytes(of: &value) { uuid.getBytes($0.baseAddress!, length: 2) }
            return value.bigEndian
        }
        return nil
    }

    /// The profiles worth naming, from the Bluetooth SIG's assigned-numbers list. A record
    /// whose class is not here falls back to the device's own service name rather than
    /// being dropped — an unfamiliar profile is still worth showing.
    static let profileNames: [UInt16: String] = [
        0x1105: "Object Push",
        0x1106: "File Transfer",
        0x110A: "Audio Source",
        0x110B: "Audio Sink",
        0x110C: "Remote Control Target",
        0x110E: "Remote Control",
        0x1112: "Headset Audio Gateway",
        0x1108: "Headset",
        0x111E: "Handsfree",
        0x111F: "Handsfree Audio Gateway",
        0x1124: "Human Interface Device",
        0x112F: "Phonebook Access",
        0x1132: "Message Access",
        0x1200: "Device Identification",
        0x1203: "Generic Audio",
        0x180F: "Battery"
    ]
}
