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

/// The state a notification's icon stands for, separate from the picture itself.
///
/// Artwork shipped with a host can paint the state into the image — a device drawn with a
/// cross through it — but artwork borrowed from somewhere else, or chosen by the person
/// using the application, is one picture for every state. Carrying the state alongside
/// lets whatever draws the icon add a small mark for it instead of losing it.
public enum IconBadge: String, Sendable, Equatable, CaseIterable {
    /// Arrived, mounted, switched on, back to normal.
    case positive
    /// Left, unmounted, switched off.
    case negative
    /// Needs attention: low, failing, too hot, nearly full.
    case warning
    /// Made the default, or otherwise singled out.
    case favorite
    /// Refusing or stopped: a printer rejecting jobs, a job cancelled.
    case blocked
    /// Running out of a consumable: ink, toner.
    case ink
}
