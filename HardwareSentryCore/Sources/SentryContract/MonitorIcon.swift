import Foundation
import SignalCore

public extension NotificationIcon {
    /// An image from a monitor's own bundle, by name.
    ///
    /// Each monitor ships the icons it needs rather than reaching into a catalogue shared
    /// by all of them — the same reason each declares its own events and fields. A monitor
    /// gaining an icon is a change to that monitor and to nothing else.
    ///
    /// Falls back to no icon rather than to a wrong one: an icon that failed to load means
    /// the notification shows the application's own, which is honest, where substituting
    /// some other monitor's artwork would not be.
    ///
    ///     .asset("USB-On", in: .module)
    static func asset(_ name: String, in bundle: Bundle) -> NotificationIcon {
        guard let url = bundle.url(forResource: name, withExtension: "png"),
              let data = try? Data(contentsOf: url)
        else { return .none }
        return .imageData(data)
    }

    /// The same, for a name only known at run time — an unrecognised one gives no icon
    /// instead of an empty box.
    static func asset(_ name: String?, in bundle: Bundle) -> NotificationIcon {
        guard let name else { return .none }
        return .asset(name, in: bundle)
    }
}
