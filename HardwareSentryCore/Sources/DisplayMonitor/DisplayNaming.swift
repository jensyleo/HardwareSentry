import Foundation

/// What to call a display in a message.
///
/// macOS names a display only while AppKit can address a window to it, and a display in
/// Mirror mode cannot be — it drops out of `NSScreen` altogether. Without a name to fall
/// back on, the MacBook's own screen, mirroring an external one, was announced as "External
/// Display", which says the opposite of what happened.
public enum DisplayNaming {
    /// The name macOS gives it; failing that, the last name it had while it was addressable;
    /// failing that, a description that is at least true.
    public static func name(screenName: String?, remembered: String?, isBuiltIn: Bool) -> String {
        if let screenName, !screenName.isEmpty { return screenName }
        if let remembered, !remembered.isEmpty { return remembered }
        return isBuiltIn ? "Built-in Display" : "External Display"
    }
}
