import Foundation

/// How a connection notification names what just arrived.
///
/// Two questions are being answered at once — *how* the thing is attached and *what* it
/// is — and which of them matters depends on the person. Somebody who wants to know that
/// a hub appeared does not care that it came over USB; somebody diagnosing a dock full of
/// devices cares about very little else.
///
/// The choice is one setting for the whole application rather than one per module,
/// because it is one decision about how notifications read, and having it answered
/// differently for USB and for Bluetooth would be worse than either answer.
public enum ConnectionNaming: String, Sendable, CaseIterable, Identifiable {
    /// "USB Hub Connected". The medium first, then what it is.
    case mediumAndType
    /// "Hub Connected". Just the device, with nothing about how it got here.
    case typeOnly

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .mediumAndType: return "How it is attached, then what it is"
        case .typeOnly: return "Just what it is"
        }
    }

    public var example: String {
        switch self {
        case .mediumAndType: return "\"USB Hub Connected\", \"Bluetooth Keyboard Connected\""
        case .typeOnly: return "\"Hub Connected\", \"Keyboard Connected\""
        }
    }

    /// Builds the title.
    ///
    /// - Parameters:
    ///   - medium: "USB", "Bluetooth", "Thunderbolt" — how the thing is attached.
    ///   - type: what it is, when the device said. Nil is the ordinary case rather than a
    ///     failure: most USB devices declare their class per interface rather than on the
    ///     device, so "Device" is what a great many perfectly working things get.
    ///   - action: "Connected", "Disconnected".
    public func title(medium: String, type: String?, action: String) -> String {
        // "Device" rather than nothing: a title of "Connected" on its own reads as a
        // sentence with its subject missing.
        let what = type ?? "Device"
        switch self {
        case .mediumAndType: return "\(medium) \(what) \(action)"
        case .typeOnly: return "\(what) \(action)"
        }
    }
}
