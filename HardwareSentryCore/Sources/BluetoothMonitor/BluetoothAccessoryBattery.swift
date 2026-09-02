import Foundation
import IOBluetooth
import IOKit

/// Reads how much battery an Apple Bluetooth accessory has left.
///
/// Through the IO registry, which is public API, rather than through
/// `IOBluetoothDevice`'s undocumented battery selectors. The original tries those first
/// and falls back to this; this application uses only the public route, deliberately.
/// Undocumented selectors are a promise nobody made: they can disappear in a point
/// release, and a notifier that stops naming a battery level after a system update is
/// worse than one that never named it.
///
/// AirPods are the reason the private route exists at all: they report their left, right and
/// case levels **only** through those selectors, and nothing public publishes them. So both
/// routes are here, in that order — the registry first, because it is supported and will
/// keep working, and the selectors only for what the registry cannot answer.
///
/// Every selector call is guarded by asking the object whether it responds, so a macOS
/// release that removes them costs a missing line rather than a crash. That is the whole
/// safety net available: there is no version to check and no deprecation to watch.
public enum BluetoothAccessoryBattery {
    /// Battery level by device address, for every accessory that publishes one.
    ///
    /// Read in one sweep rather than once per device: the registry is walked either way,
    /// and a Mac with a keyboard, a mouse and a trackpad would otherwise walk it three
    /// times for one notification.
    public static func levelsByAddress() -> [String: Int] {
        var levels: [String: Int] = [:]

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("AppleDeviceManagementHIDEventService"),
            &iterator
        ) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iterator) }

        while true {
            let service = IOIteratorNext(iterator)
            guard service != IO_OBJECT_NULL else { break }
            defer { IOObjectRelease(service) }

            guard let percent = property(service, "BatteryPercent") as? Int,
                  let address = address(of: service)
            else { continue }
            levels[address] = percent
        }
        return levels
    }

    /// The device's Bluetooth address, from whichever key this node happens to carry it in.
    ///
    /// Two keys, because neither is always populated and the two spell the address
    /// differently — one with colons, one with hyphens. Normalised so a lookup by address
    /// cannot miss on punctuation alone.
    private static func address(of service: io_object_t) -> String? {
        for key in ["DeviceAddress", "SerialNumber"] {
            guard let raw = property(service, key) as? String else { continue }
            let normalised = normalise(raw)
            if !normalised.isEmpty { return normalised }
        }
        return nil
    }

    private static func property(_ service: io_object_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }

    /// Addresses are written `d0-c0-50-c3-25-7a` in one place and `d0:c0:50:c3:25:7a` in
    /// another, and case varies too.
    public static func normalise(_ address: String) -> String {
        address
            .lowercased()
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}


// MARK: - AirPods, which nothing public reports

public extension BluetoothAccessoryBattery {
    /// The left, right and case levels of an accessory that carries three batteries.
    ///
    /// Read through `IOBluetoothDevice`'s undocumented battery selectors, because for
    /// AirPods there is no other route: the registry node that keyboards and mice publish
    /// their level on does not exist for them.
    ///
    /// Each call is guarded by `responds(to:)` and goes through `perform(_:)`, so a
    /// release that drops a selector loses a line and nothing else. Anything outside
    /// 0...100 is refused — these return a negative number for "no reading", and a
    /// battery of minus one percent is worse than no battery line at all.
    struct MultipartLevel: Sendable, Equatable {
        public let left: Int?
        public let right: Int?
        public let enclosure: Int?

        public init(left: Int? = nil, right: Int? = nil, enclosure: Int? = nil) {
            self.left = left
            self.right = right
            self.enclosure = enclosure
        }

        public var isEmpty: Bool { left == nil && right == nil && enclosure == nil }

        /// "L 80% / R 75% / Case 100%", the original's shape, leaving out whichever part
        /// did not answer rather than printing a gap.
        public var note: String? {
            var parts: [String] = []
            if let left { parts.append("L \(left)%") }
            if let right { parts.append("R \(right)%") }
            if let enclosure { parts.append("Case \(enclosure)%") }
            return parts.isEmpty ? nil : parts.joined(separator: " / ")
        }
    }

    /// A single figure, for an accessory that has one battery and no registry node.
    static func singleLevel(of device: IOBluetoothDevice) -> Int? {
        percent(device, "batteryPercentSingle")
    }

    static func multipartLevel(of device: IOBluetoothDevice) -> MultipartLevel {
        MultipartLevel(
            left: percent(device, "batteryPercentLeft"),
            right: percent(device, "batteryPercentRight"),
            enclosure: percent(device, "batteryPercentCase")
        )
    }

    /// Asks for one undocumented value, or gives nothing.
    private static func percent(_ device: IOBluetoothDevice, _ name: String) -> Int? {
        let selector = NSSelectorFromString(name)
        guard device.responds(to: selector) else { return nil }
        guard let value = device.perform(selector)?.takeUnretainedValue() as? NSNumber else { return nil }
        let percent = value.intValue
        // These answer with a negative number when there is no reading, and an accessory
        // is never above full.
        return (0...100).contains(percent) ? percent : nil
    }
}
