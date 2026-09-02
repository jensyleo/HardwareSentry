import Foundation

/// One line of a notification's body.
///
/// Either something the notification would be useless without, or an optional detail the
/// person can switch off. Optional text is produced only if it is wanted, so a field
/// nobody asked for costs nothing to leave declared — which matters for the ones that are
/// a hardware read rather than a string already in hand.
public struct BodyLine: Sendable {
    let field: String?
    let text: @Sendable () -> String?

    /// Always included.
    public static func always(_ text: String) -> BodyLine {
        BodyLine(field: nil, text: { text })
    }

    /// Included only if this field is switched on, and only if it has something to say —
    /// returning nil leaves the line out entirely rather than printing an empty label.
    public static func field(
        _ name: String,
        _ text: @autoclosure @escaping @Sendable () -> String?
    ) -> BodyLine {
        BodyLine(field: name, text: text)
    }

    /// A labelled detail, in the "Label:<tab>value" shape the banners lay out.
    public static func field(
        _ name: String,
        _ label: String,
        _ value: @autoclosure @escaping @Sendable () -> String?
    ) -> BodyLine {
        BodyLine(field: name, text: { value().map { "\(label):\t\($0)" } })
    }

    /// A labelled detail separated by a space rather than a tab.
    ///
    /// A tab lines values up into a column, which is what most of these want. A handful
    /// read as prose instead — a printer's location, a volume's size — and the original
    /// application writes exactly those with a space. Kept as a separate call rather than
    /// a parameter so the ordinary case stays the short one.
    public static func prose(
        _ name: String,
        _ label: String,
        _ value: @autoclosure @escaping @Sendable () -> String?
    ) -> BodyLine {
        BodyLine(field: name, text: { value().map { "\(label): \($0)" } })
    }
}
