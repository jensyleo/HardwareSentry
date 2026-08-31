import Foundation
@testable import SignalCore

/// Records every event handed to it, for assertion in tests.
actor RecordingDelivery: NotificationDelivering {
    private(set) var presented: [(event: NotificationEvent, context: DispatchContext)] = []

    func present(_ event: NotificationEvent, context: DispatchContext) async {
        presented.append((event, context))
    }

    var presentedEvents: [NotificationEvent] { presented.map(\.event) }
}

func makeEvent(
    name: String = "TestEvent",
    subject: String? = nil,
    category: NotificationCategory = "TestCategory",
    title: String = "Title",
    body: String = "Body"
) -> NotificationEvent {
    NotificationEvent(name: name, subject: subject, category: category, title: title, body: body)
}

func makeContext(
    phase: DispatchPhase = .steady,
    at seconds: TimeInterval = 0
) -> DispatchContext {
    DispatchContext(phase: phase, firedAt: Date(timeIntervalSince1970: 1000 + seconds))
}

/// A mutable clock for driving the dispatcher's `firedAt` stamping in tests.
final class MutableClock: @unchecked Sendable {
    var date: Date
    init(_ date: Date = Date(timeIntervalSince1970: 1000)) { self.date = date }
    func advance(by seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
}
