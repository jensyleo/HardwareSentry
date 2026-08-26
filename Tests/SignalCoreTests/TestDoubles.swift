import Foundation
@testable import SignalCore

/// Records every event handed to it, for assertion in tests.
actor RecordingDelivery: NotificationDelivering {
    private(set) var presented: [NotificationEvent] = []

    func present(_ event: NotificationEvent) async {
        presented.append(event)
    }
}

func makeEvent(
    id: String = "test-id",
    category: NotificationCategory = "TestCategory",
    title: String = "Title",
    body: String = "Body"
) -> NotificationEvent {
    NotificationEvent(id: id, category: category, title: title, body: body)
}

/// A mutable clock to drive time-dependent middleware in tests without racing
/// Swift 6's sendable-capture checks — the class itself is the sendable unit,
/// not the `var` inside it.
final class MutableClock: @unchecked Sendable {
    var date: Date
    init(_ date: Date) { self.date = date }
    func advance(by seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
}
