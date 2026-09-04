import Foundation
import Testing
@testable import SignalCore

/// Stands in for the operating system's notification service, which cannot be reached
/// from a test process.
actor FakeScheduler: SystemNotificationScheduling {
    private(set) var scheduled: [SystemNotificationRequest] = []
    private(set) var authorizationRequests = 0

    private var status: SystemAuthorizationStatus
    private let grantsAuthorization: Bool
    private let failure: Error?

    init(
        status: SystemAuthorizationStatus = .authorized,
        grantsAuthorization: Bool = true,
        failure: Error? = nil
    ) {
        self.status = status
        self.grantsAuthorization = grantsAuthorization
        self.failure = failure
    }

    func authorizationStatus() async -> SystemAuthorizationStatus { status }

    func requestAuthorization() async -> Bool {
        authorizationRequests += 1
        status = grantsAuthorization ? .authorized : .denied
        return grantsAuthorization
    }

    func schedule(_ request: SystemNotificationRequest) async throws {
        if let failure { throw failure }
        scheduled.append(request)
    }
}

private struct SchedulingFailure: Error {}

/// Lets a test observe an interaction handler firing from inside a `@Sendable` closure.
final class InteractionRecorder: @unchecked Sendable {
    private(set) var received: [NotificationInteraction] = []
    func record(_ interaction: NotificationInteraction) { received.append(interaction) }
}

@Suite("SystemDelivery")
struct SystemDeliveryTests {
    @Test("an authorized system accepts the notification")
    func authorizedPresents() async {
        let scheduler = FakeScheduler(status: .authorized)
        let delivery = SystemDelivery(scheduler: scheduler)
        await delivery.prepare()

        let outcome = await delivery.present(makeEvent(), context: makeContext())

        #expect(outcome == .presented)
        #expect(await scheduler.scheduled.count == 1)
    }

    @Test("a denied system reports failure without scheduling anything")
    func deniedFails() async {
        let scheduler = FakeScheduler(status: .denied)
        let delivery = SystemDelivery(scheduler: scheduler)
        await delivery.prepare()

        let outcome = await delivery.present(makeEvent(), context: makeContext())

        #expect(!outcome.didPresent)
        #expect(await scheduler.scheduled.isEmpty)
    }

    @Test("permission is asked for once, then remembered")
    func authorizationResolvedOnce() async {
        let scheduler = FakeScheduler(status: .notDetermined, grantsAuthorization: true)
        let delivery = SystemDelivery(scheduler: scheduler)
        await delivery.prepare()

        for _ in 0..<3 {
            _ = await delivery.present(makeEvent(), context: makeContext())
        }

        #expect(await scheduler.authorizationRequests == 1)
        #expect(await scheduler.scheduled.count == 3)
    }

    @Test("refused permission turns into a failed delivery")
    func refusedPermissionFails() async {
        let scheduler = FakeScheduler(status: .notDetermined, grantsAuthorization: false)
        let delivery = SystemDelivery(scheduler: scheduler)
        await delivery.prepare()

        let outcome = await delivery.present(makeEvent(), context: makeContext())

        #expect(!outcome.didPresent)
    }

    // The permission dialog can sit unanswered for as long as the person ignores it. A
    // startup sweep waiting behind it would arrive far too late, so this channel declines
    // instead and lets whatever is standing in take the notification.
    @Test("an unsettled permission question declines rather than waits")
    func unsettledAuthorizationDeclines() async {
        let scheduler = FakeScheduler(status: .notDetermined, grantsAuthorization: true)
        let delivery = SystemDelivery(scheduler: scheduler)

        let outcome = await delivery.present(makeEvent(), context: makeContext())

        #expect(!outcome.didPresent)
        #expect(await scheduler.scheduled.isEmpty)
    }

    @Test("once the question is settled the system takes over")
    func systemTakesOverOnceSettled() async {
        let scheduler = FakeScheduler(status: .notDetermined, grantsAuthorization: true)
        let delivery = SystemDelivery(scheduler: scheduler)

        _ = await delivery.present(makeEvent(), context: makeContext())
        await delivery.prepare()
        let outcome = await delivery.present(makeEvent(), context: makeContext())

        #expect(outcome == .presented)
    }

    @Test("a system that rejects the request reports failure rather than throwing")
    func schedulingFailureIsReported() async {
        let scheduler = FakeScheduler(failure: SchedulingFailure())
        let delivery = SystemDelivery(scheduler: scheduler)
        await delivery.prepare()

        let outcome = await delivery.present(makeEvent(), context: makeContext())

        #expect(!outcome.didPresent)
    }

    // Repeated news about one subject should supersede itself rather than pile up, while
    // two modules naming their subjects alike must stay independent.
    @Test("the identifier combines category and subject")
    func identifierCombinesCategoryAndSubject() async {
        let scheduler = FakeScheduler()
        let delivery = SystemDelivery(scheduler: scheduler)
        await delivery.prepare()

        await delivery.present(makeEvent(subject: "Cruzer", category: "USB"), context: makeContext())
        await delivery.present(makeEvent(subject: "Cruzer", category: "Bluetooth"), context: makeContext())

        let identifiers = await scheduler.scheduled.map(\.identifier)
        #expect(identifiers == ["USB|Cruzer", "Bluetooth|Cruzer"])
    }

    @Test("low priority is delivered quietly")
    func lowPriorityIsPassive() async {
        let scheduler = FakeScheduler()
        let delivery = SystemDelivery(scheduler: scheduler)
        await delivery.prepare()

        var quiet = makeEvent()
        quiet.priority = .low
        await delivery.present(quiet, context: makeContext())
        await delivery.present(makeEvent(), context: makeContext())

        let levels = await scheduler.scheduled.map(\.interruptionLevel)
        #expect(levels == [.passive, .active])
    }

    @Test("high priority breaks through Focus/Do Not Disturb")
    func highPriorityIsTimeSensitive() async {
        let scheduler = FakeScheduler()
        let delivery = SystemDelivery(scheduler: scheduler)
        await delivery.prepare()

        var urgent = makeEvent()
        urgent.priority = .high
        await delivery.present(urgent, context: makeContext())

        let levels = await scheduler.scheduled.map(\.interruptionLevel)
        #expect(levels == [.timeSensitive])
    }

    @Test("a response reaches the handler the emitting module attached")
    func responseReachesHandler() async {
        let scheduler = FakeScheduler()
        let delivery = SystemDelivery(scheduler: scheduler)
        await delivery.prepare()
        let recorder = InteractionRecorder()

        var event = makeEvent(subject: "Cruzer", category: "USB")
        event.onInteraction = { recorder.record($0) }
        await delivery.present(event, context: makeContext())

        await delivery.handleResponse(identifier: "USB|Cruzer", interaction: .clicked)

        #expect(recorder.received == [.clicked])
    }

    @Test("a handler answers once and is then forgotten")
    func handlersAreOneShot() async {
        let scheduler = FakeScheduler()
        let delivery = SystemDelivery(scheduler: scheduler)
        await delivery.prepare()
        let recorder = InteractionRecorder()

        var event = makeEvent(subject: "Cruzer", category: "USB")
        event.onInteraction = { recorder.record($0) }
        await delivery.present(event, context: makeContext())

        await delivery.handleResponse(identifier: "USB|Cruzer", interaction: .clicked)
        await delivery.handleResponse(identifier: "USB|Cruzer", interaction: .dismissed)

        #expect(recorder.received == [.clicked])
        #expect(await delivery.trackedHandlerCount == 0)
    }

    @Test("a response for something unknown is ignored")
    func unknownResponseIgnored() async {
        let delivery = SystemDelivery(scheduler: FakeScheduler())
        await delivery.prepare()
        await delivery.handleResponse(identifier: "nothing|here", interaction: .clicked)
        #expect(await delivery.trackedHandlerCount == 0)
    }

    @Test("handlers for notifications nobody answers stay bounded")
    func handlerTableStaysBounded() async {
        let delivery = SystemDelivery(scheduler: FakeScheduler(), handlerLimit: 3)
        await delivery.prepare()

        for index in 0..<10 {
            var event = makeEvent(subject: "device-\(index)")
            event.onInteraction = { _ in }
            await delivery.present(event, context: makeContext())
        }

        #expect(await delivery.trackedHandlerCount == 3)
    }

    @Test("events with no handler leave nothing behind")
    func eventsWithoutHandlersTrackNothing() async {
        let delivery = SystemDelivery(scheduler: FakeScheduler())
        await delivery.prepare()

        await delivery.present(makeEvent(), context: makeContext())

        #expect(await delivery.trackedHandlerCount == 0)
    }
}
