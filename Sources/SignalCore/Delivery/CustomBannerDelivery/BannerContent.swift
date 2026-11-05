import Foundation

/// What a banner should draw, worked out ahead of any drawing.
///
/// Separated from the view so the one part with judgement in it — deciding which words
/// deserve emphasis — can be exercised directly, rather than being locked inside a view
/// that can only be checked by looking at it.
public struct BannerContent: Sendable, Equatable {
    /// One line of the body, split at the point where it reports a change.
    public struct Line: Sendable, Equatable {
        /// Everything up to and including the arrow, or the whole line if it reports no
        /// change.
        public let leading: String
        /// What the value became. Drawn with emphasis, since it is the news.
        public let emphasised: String?

        public init(leading: String, emphasised: String? = nil) {
            self.leading = leading
            self.emphasised = emphasised
        }
    }

    public let title: String
    public let lines: [Line]
    public let icon: NotificationIcon
    /// The state to mark on the icon, or nil to draw it as it is.
    public let badge: IconBadge?

    public init(title: String, lines: [Line], icon: NotificationIcon, badge: IconBadge? = nil) {
        self.title = title
        self.lines = lines
        self.icon = icon
        self.badge = badge
    }

    /// Separates a reported change from the label that introduces it.
    ///
    /// Many notifications say what something was and what it now is. Reading such a line
    /// means finding the new value among the old, so the new value is set apart. Lines
    /// that report no change are left as they are.
    static let changeSeparator = " → "

    public init(event: NotificationEvent) {
        self.title = event.title
        self.icon = event.icon
        self.badge = event.showsIconBadge ? event.iconBadge : nil
        self.lines = event.body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.isEmpty }
            .map(Self.parse)
    }

    static func parse(_ line: String) -> Line {
        guard let range = line.range(of: changeSeparator) else {
            return Line(leading: line)
        }
        let after = String(line[range.upperBound...])
        guard !after.isEmpty else { return Line(leading: line) }

        return Line(
            leading: String(line[..<range.upperBound]),
            emphasised: after
        )
    }
}
