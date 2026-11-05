import Foundation

/// What a notification's icon depicts, when what it depicts is a piece of hardware.
///
/// Written as `module.kind` — `"usb.keyboard"`, `"volume.nas"` — so a kind names the same
/// thing however many modules can see it (a keyboard plugged in over USB and one paired
/// over Bluetooth are drawn alike, but are filed under their own modules, because each
/// module's icons are chosen in that module's settings).
///
/// Carried on a notification next to its icon, so that a later stage can substitute
/// another picture of the same thing — the operating system's own, or one the person
/// chose — without knowing anything about the monitor that raised it. Deliberately absent
/// for icons that depict an idea rather than a device: a Wi-Fi signal level, a VPN, a
/// battery percentage or a temperature has no "other picture of the same thing" to swap in.
public struct DeviceIconKind: Hashable, Sendable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// A kind within a module: `DeviceIconKind("usb", "keyboard")`.
    public init(_ module: String, _ kind: String) {
        self.rawValue = "\(module).\(kind)"
    }

    public var description: String { rawValue }

    /// The module half: `"usb"` for `"usb.keyboard"`.
    public var module: String {
        String(rawValue.prefix { $0 != "." })
    }
}

/// Which model a device is, written the way a notification carries it: `"vvvv:pppp"`,
/// vendor and product ID in lowercase hex.
public enum DeviceIconModel {
    public static func string(vendorID: Int?, productID: Int?) -> String? {
        guard let vendorID, let productID,
              (0...0xFFFF).contains(vendorID), (0...0xFFFF).contains(productID)
        else { return nil }
        return String(format: "%04x:%04x", vendorID, productID)
    }
}
