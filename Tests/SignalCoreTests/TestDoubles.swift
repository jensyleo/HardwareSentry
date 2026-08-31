import Foundation
@testable import SignalCore

/// Records every event handed to it, for assertion in tests.
actor RecordingDelivery: NotificationDelivering {
    private(set) var presented: [(event: NotificationEvent, context: DispatchContext)] = []

    var outcome: DeliveryOutcome = .presented

    func present(_ event: NotificationEvent, context: DispatchContext) async -> DeliveryOutcome {
        presented.append((event, context))
        return outcome
    }

    func setOutcome(_ outcome: DeliveryOutcome) { self.outcome = outcome }

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

/// Preferences that answer from fixed sets, for exercising the enablement filters.
struct StubPreferences: NotificationPreferences {
    var disabledCategories: Set<String> = []
    var disabledEvents: Set<String> = []

    func isCategoryEnabled(_ category: NotificationCategory) async -> Bool {
        !disabledCategories.contains(category.rawValue)
    }

    func isEventEnabled(_ name: String, in category: NotificationCategory) async -> Bool {
        !disabledEvents.contains(name)
    }
}

/// Conforms to nothing beyond the protocol's own defaults, to prove a host can opt out
/// of gating entirely.
struct SilentPreferences: NotificationPreferences {}

extension MiddlewareDecision {
    var isDeliver: Bool {
        if case .deliver = self { return true }
        return false
    }

    var isSuppress: Bool {
        if case .suppress = self { return true }
        return false
    }

    var deliveredEvent: NotificationEvent? {
        if case .deliver(let event) = self { return event }
        return nil
    }
}
