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
    init(device: IOBluetoothDevice, batteryLevels: [String: Int] = [:]) {
        let pnp = Self.record(on: device, matching: BluetoothSDPUUID16(kBluetoothSDPUUID16ServiceClassPnPInformation.rawValue))
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
            lastSeen: device.recentAccessDate().flatMap { $0 > Date(timeIntervalSince1970: 0) ? $0 : nil },
            batteryPercent: device.addressString
                .map(BluetoothAccessoryBattery.normalise)
                .flatMap { batteryLevels[$0] },
            encryption: Self.describe(encryption: device.getEncryptionMode()),
            serviceClasses: Self.describeServiceClasses(UInt32(device.classOfDevice)),
            vendorID: Self.number(pnp, attribute: 0x0201),
            productID: Self.number(pnp, attribute: 0x0202),
            productVersion: Self.number(pnp, attribute: 0x0203).map(Self.describeVersion),
            vendorIDSource: Self.number(pnp, attribute: 0x0205).flatMap(Self.describeVendorSource),
            handsFreeFeatures: Self.number(
                Self.record(on: device, matching: BluetoothSDPUUID16(kBluetoothSDPUUID16ServiceClassHandsFree.rawValue)),
                attribute: 0x0311
            ).flatMap(BluetoothDetail.describeHandsFreeFeatures),
            hidDetail: Self.describeHID(device),
            // Read together with the RSSI above, and reported on the same terms: the
            // controller answers with a sentinel rather than an error when it has no
            // figure, and a sentinel shown as a number is worse than a missing line.
            // Read straight off the device: both come back as a sentinel rather than an
            // error when the controller has no figure, and a sentinel printed as a number
            // is worse than a line that is simply absent.
            linkQuality: Int(device.rawRSSI()) == BluetoothSignalLevel.unavailableRSSI
                ? nil
                : Int(device.rawRSSI()) + 128,
            transmitPower: nil
        )
    }

    /// The broad categories a device's Class of Device record claims for itself.
    ///
    /// Public, and worth reading, because it is the device's own claim about what it is
    /// for rather than a guess from its name — a headset that reports Audio and Telephony
    /// is telling you it can carry a call as well as music.
    static func describeServiceClasses(_ classOfDevice: UInt32) -> String? {
        // Bits 16-23 of the 24-bit record, as the Bluetooth SIG assigns them.
        //
        // Bit 13 is deliberately left out. It is "limited discoverable mode", which is
        // about how the device advertises itself rather than anything it can do — and it
        // is set on ordinary keyboards, so including it would put a line nobody can act
        // on into most notifications. The setting this feeds is named for capabilities.
        let named: [(UInt32, String)] = [
            (1 << 16, "Positioning"),
            (1 << 17, "Networking"),
            (1 << 18, "Rendering"),
            (1 << 19, "Capturing"),
            (1 << 20, "Object transfer"),
            (1 << 21, "Audio"),
            (1 << 22, "Telephony"),
            (1 << 23, "Information")
        ]
        let claimed = named.filter { classOfDevice & $0.0 != 0 }.map(\.1)
        return claimed.isEmpty ? nil : claimed.joined(separator: ", ")
    }

    /// What a hands-free device says it can do, from its own feature bitmask.
    static func describeHandsFreeFeatures(_ raw: Int) -> String? {
        let named: [(Int, String)] = [
            (1 << 0, "Three-way calling"),
            (1 << 1, "Echo cancelling"),
            (1 << 2, "Voice recognition"),
            (1 << 3, "In-band ringing"),
            (1 << 4, "Voice tag"),
            (1 << 5, "Call rejection"),
            (1 << 6, "Enhanced call status"),
            (1 << 7, "Enhanced call control"),
            (1 << 8, "Wideband speech")
        ]
        let claimed = named.filter { raw & $0.0 != 0 }.map(\.1)
        return claimed.isEmpty ? nil : claimed.joined(separator: ", ")
    }

    /// A keyboard or mouse's own description of itself.
    ///
    /// Only the two attributes that mean anything to somebody reading a notification: the
    /// country the layout is for, and whether the device can wake the Mac. The rest of a
    /// HID record is descriptor bytes.
    private static func describeHID(_ device: IOBluetoothDevice) -> String? {
        guard let record = record(on: device, matching: BluetoothSDPUUID16(kBluetoothSDPUUID16ServiceClassHumanInterfaceDeviceService.rawValue)) else { return nil }

        var parts: [String] = []
        if let country = number(record, attribute: 0x0206), country != 0 {
            parts.append("Country code \(country)")
        }
        if let remoteWake = number(record, attribute: 0x0209), remoteWake != 0 {
            parts.append("Can wake this Mac")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The device's own SDP record for one profile, or nil when it never advertised it.
    ///
    /// Attribute numbers only mean something relative to the record they came from — the
    /// same number is a vendor ID in a PnP record and something else entirely in a HID
    /// one — so every read has to find its record first.
    private static func record(
        on device: IOBluetoothDevice,
        matching uuid: BluetoothSDPUUID16
    ) -> IOBluetoothSDPServiceRecord? {
        guard let records = device.services as? [IOBluetoothSDPServiceRecord] else { return nil }
        return records.first { $0.matchesUUID16(uuid) }
    }

    private static func number(_ record: IOBluetoothSDPServiceRecord?, attribute: BluetoothSDPServiceAttributeID) -> Int? {
        record?.getAttributeDataElement(attribute)?.getNumberValue()?.intValue
    }

    /// "1.2.3" from the packed 16-bit form the specification uses.
    private static func describeVersion(_ raw: Int) -> String {
        "\((raw >> 8) & 0xFF).\((raw >> 4) & 0x0F).\(raw & 0x0F)"
    }

    /// Which registry the vendor number belongs to.
    ///
    /// Worth saying because the Bluetooth SIG and the USB-IF number vendors separately:
    /// the same figure is two different companies depending on which list it came from,
    /// so a vendor ID without its source is a number nobody can look up.
    private static func describeVendorSource(_ raw: Int) -> String? {
        switch raw {
        case 0x0001: return "Bluetooth SIG"
        case 0x0002: return "USB-IF"
        default: return nil
        }
    }

    private static func describe(encryption mode: BluetoothHCIEncryptionMode) -> String? {
        switch Int(mode) {
        case 0: return "Not encrypted"
        case 1: return "Encrypted (point-to-point)"
        case 2: return "Encrypted (point-to-point and broadcast)"
        default: return nil
        }
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
