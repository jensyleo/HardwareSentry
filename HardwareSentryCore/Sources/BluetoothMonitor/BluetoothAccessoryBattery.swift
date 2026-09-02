import Foundation
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
/// The cost of that choice is honest and worth stating: AirPods report their left, right
/// and case levels **only** through those private selectors, so this reads nothing for
/// them. Keyboards, mice and trackpads — which is what the original's own setting names —
/// publish a single figure here and are read fine.
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
