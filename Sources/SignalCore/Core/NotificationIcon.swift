import Foundation

/// The icon to display alongside a notification.
public enum NotificationIcon: Sendable, Equatable {
    /// An SF Symbol name, resolved by the delivery layer at presentation time.
    case symbol(String)
    /// Raw image data (e.g. a device-specific icon fetched at event time).
    case imageData(Data)
    /// No icon — the delivery layer falls back to the host app's own icon.
    case none
}
