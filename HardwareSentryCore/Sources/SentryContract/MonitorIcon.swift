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
        AssetOrigin.note(data, name: name, bundle: bundle)
        return .imageData(data)
    }

    /// The same, for a name only known at run time — an unrecognised one gives no icon
    /// instead of an empty box.
    static func asset(_ name: String?, in bundle: Bundle) -> NotificationIcon {
        guard let name else { return .none }
        return .asset(name, in: bundle)
    }
}

/// Where a picture loaded by `NotificationIcon.asset` came from.
///
/// An icon is only its bytes once loaded, but a settings screen that wants to show *the same
/// device in another state* needs the name it was loaded under — the disconnected version of a
/// hub's picture is the hub's name with a suffix. Remembered here at load time rather than
/// carried on every icon, which would change every place that builds one.
public enum AssetOrigin {
    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var byHash: [Int: (name: String, bundle: Bundle)] = [:]
    }
    private static let registry = Registry()

    static func note(_ data: Data, name: String, bundle: Bundle) {
        registry.lock.lock(); defer { registry.lock.unlock() }
        registry.byHash[data.hashValue] = (name, bundle)
    }

    /// What a picture of this device looks like for `badge`, as this application draws it.
    public enum StateArt: Sendable, Equatable {
        /// There is no state to draw: connected is the picture as it is.
        case plain
        /// The application has a picture of this device in that state.
        case variant(NotificationIcon)
        /// It does not; the state has to be marked on the picture instead.
        case missing
    }

    /// The suffixes this application's artwork uses for a device that is gone, and for one in
    /// serious trouble. Everything else about a name is the device's.
    private static let goneSuffixes = ["-Disconnected", "-Unmounted"]
    private static let criticalSuffixes = ["-Critical", "-Attention"]

    /// Another picture from the bundle a given one came from, by name — for a notification whose
    /// states each have a picture that is not its own name with a suffix.
    public static func sibling(of icon: NotificationIcon, named name: String) -> NotificationIcon? {
        guard case .imageData(let data) = icon else { return nil }
        registry.lock.lock()
        let origin = registry.byHash[data.hashValue]
        registry.lock.unlock()
        guard let origin else { return nil }
        let found = NotificationIcon.asset(name, in: origin.bundle)
        return found == .none ? nil : found
    }

    /// The picture of the same device with no state in it: a hub's own, not its "gone" version.
    /// The same icon back when it already is that, or when its origin is not known.
    public static func neutralIcon(of icon: NotificationIcon) -> NotificationIcon {
        guard case .imageData(let data) = icon else { return icon }
        registry.lock.lock()
        let origin = registry.byHash[data.hashValue]
        registry.lock.unlock()
        guard let origin else { return icon }
        var root = origin.name
        for suffix in goneSuffixes + criticalSuffixes where root.hasSuffix(suffix) {
            root.removeLast(suffix.count)
        }
        guard root != origin.name else { return icon }
        let neutral = NotificationIcon.asset(root, in: origin.bundle)
        return neutral == .none ? icon : neutral
    }

    public static func stateArt(for icon: NotificationIcon, badge: IconBadge) -> StateArt {
        guard badge != .positive else { return .plain }
        guard case .imageData(let data) = icon else { return .missing }
        registry.lock.lock()
        let origin = registry.byHash[data.hashValue]
        registry.lock.unlock()
        guard let origin else { return .missing }

        // The device's own name, with any state suffix taken off.
        var root = origin.name
        for suffix in goneSuffixes + criticalSuffixes where root.hasSuffix(suffix) {
            root.removeLast(suffix.count)
        }
        let suffixes: [String]
        switch badge {
        case .negative: suffixes = goneSuffixes
        case .warning, .critical: suffixes = criticalSuffixes
        default: return .missing
        }
        for suffix in suffixes {
            let candidate = NotificationIcon.asset(root + suffix, in: origin.bundle)
            if candidate != .none { return .variant(candidate) }
        }
        return .missing
    }
}
