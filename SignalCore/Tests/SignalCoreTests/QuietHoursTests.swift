import Foundation
import Testing
@testable import SignalCore

@Suite("Quiet hours")
struct QuietHoursTests {
    private let calendar: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
    /// 2026-11-11 is a Wednesday.
    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(timeZone: calendar.timeZone, year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    @Test("off means never quiet")
    func off() {
        #expect(!QuietHours(isEnabled: false).isQuiet(at: date(11, 23), calendar: calendar))
    }

    @Test("a span inside one day")
    func sameDay() {
        let q = QuietHours(isEnabled: true, startMinute: 9 * 60, endMinute: 17 * 60)
        #expect(q.isQuiet(at: date(11, 12), calendar: calendar))
        #expect(!q.isQuiet(at: date(11, 8, 59), calendar: calendar))
        #expect(!q.isQuiet(at: date(11, 17), calendar: calendar))
    }

    @Test("a span across midnight covers both sides of it")
    func overnight() {
        let q = QuietHours(isEnabled: true, startMinute: 22 * 60, endMinute: 7 * 60)
        #expect(q.isQuiet(at: date(11, 23), calendar: calendar))
        #expect(q.isQuiet(at: date(12, 3), calendar: calendar))
        #expect(!q.isQuiet(at: date(12, 7), calendar: calendar))
        #expect(!q.isQuiet(at: date(12, 12), calendar: calendar))
    }

    @Test("the morning half belongs to the day the span started on")
    func weekdays() {
        // Only Wednesday nights (weekday 4): Wed 23:00 and Thu 03:00 are quiet, Thu 23:00 is not.
        let q = QuietHours(isEnabled: true, startMinute: 22 * 60, endMinute: 7 * 60, weekdays: [4])
        #expect(q.isQuiet(at: date(11, 23), calendar: calendar))
        #expect(q.isQuiet(at: date(12, 3), calendar: calendar))
        #expect(!q.isQuiet(at: date(12, 23), calendar: calendar))
    }

    @Test("attention can break through, and hidden hides the rest")
    func effects() {
        var q = QuietHours(isEnabled: true, startMinute: 0, endMinute: 1439, mode: .hidden)
        let noon = date(11, 12)
        #expect(q.effect(for: .info, at: noon, calendar: calendar) == .hide)
        #expect(q.effect(for: .attention, at: noon, calendar: calendar) == .none)
        q.attentionBreaksThrough = false
        #expect(q.effect(for: .attention, at: noon, calendar: calendar) == .hide)
        q.mode = .silent
        #expect(q.effect(for: .connected, at: noon, calendar: calendar) == .silence)
    }
}
