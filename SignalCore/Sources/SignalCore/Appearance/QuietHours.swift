import Foundation

/// Hours in which banners hold their tongue.
///
/// A schedule rather than a switch because the want is regular — overnight, or while
/// working — and a switch is something to forget to turn back on. Notices that need
/// attention can be let through, since quiet is for chatter, not for a disk failing.
public struct QuietHours: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable, CaseIterable {
        /// Banners still appear, without a sound.
        case silent
        /// Nothing is drawn; the history still records it.
        case hidden

        public var label: String { self == .silent ? "Banners appear, without sound" : "Banners are not shown" }
    }

    public var isEnabled: Bool
    /// Minutes after midnight. An end before the start means the span crosses midnight.
    public var startMinute: Int
    public var endMinute: Int
    /// Calendar weekdays, 1 = Sunday … 7 = Saturday, on which the span *starts*.
    public var weekdays: Set<Int>
    public var mode: Mode
    /// Whether a notice that needs attention is let through at full volume.
    public var attentionBreaksThrough: Bool

    public init(
        isEnabled: Bool = false,
        startMinute: Int = 22 * 60,
        endMinute: Int = 7 * 60,
        weekdays: Set<Int> = Set(1...7),
        mode: Mode = .silent,
        attentionBreaksThrough: Bool = true
    ) {
        self.isEnabled = isEnabled
        self.startMinute = min(max(startMinute, 0), 1439)
        self.endMinute = min(max(endMinute, 0), 1439)
        self.weekdays = weekdays
        self.mode = mode
        self.attentionBreaksThrough = attentionBreaksThrough
    }

    /// Whether `date` falls inside the quiet span.
    public func isQuiet(at date: Date, calendar: Calendar = .current) -> Bool {
        guard isEnabled, startMinute != endMinute else { return false }
        let parts = calendar.dateComponents([.hour, .minute, .weekday], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        let weekday = parts.weekday ?? 1

        if startMinute < endMinute {
            return minute >= startMinute && minute < endMinute && weekdays.contains(weekday)
        }
        // Crosses midnight: the evening half belongs to the day it starts on, the morning
        // half to the day before it.
        if minute >= startMinute { return weekdays.contains(weekday) }
        if minute < endMinute { return weekdays.contains(weekday == 1 ? 7 : weekday - 1) }
        return false
    }

    /// What quiet hours do to a notice of this kind at this moment.
    public func effect(for severity: BannerSeverity, at date: Date, calendar: Calendar = .current) -> Effect {
        guard isQuiet(at: date, calendar: calendar) else { return .none }
        if attentionBreaksThrough && severity == .attention { return .none }
        return mode == .hidden ? .hide : .silence
    }

    public enum Effect: Sendable, Equatable { case none, silence, hide }
}
