import Foundation

/// Presents notifications through the operating system's own notification service.
///
/// Authorization is resolved once, lazily, and remembered. A host that wants to fall
/// back to another channel when the system refuses can ask `canPresent` before
/// committing, or simply present and act on the returned outcome.
///
/// Icons are not carried through: the system shows the host application's icon, and
/// attaching a per-notification image would mean writing files to disk for every event.
/// The banner channel, which draws its own surface, is where per-event icons apply.
/// Stickiness is likewise a banner concern; the system decides its own dwell time.
public actor SystemDelivery: NotificationDelivering {
    private let scheduler: any SystemNotificationScheduling
    private var authorization: SystemAuthorizationStatus?
    private var handlers: [String: NotificationInteractionHandler] = [:]
    private var handlerOrder: [String] = []
    private let handlerLimit: Int

    public init(scheduler: any SystemNotificationScheduling, handlerLimit: Int = 128) {
        self.scheduler = scheduler
        self.handlerLimit = handlerLimit
    }

    /// Whether the system will currently accept notifications, asking the user once if
    /// they have not been asked before.
    public func canPresent() async -> Bool {
        await resolveAuthorization() != .denied
    }

    @discardableResult
    public func present(_ event: NotificationEvent, context: DispatchContext) async -> DeliveryOutcome {
        guard await resolveAuthorization() != .denied else {
            return .failed(reason: "system notifications are not authorized")
        }

        let identifier = Self.identifier(for: event)
        let request = SystemNotificationRequest(
            identifier: identifier,
            title: event.title,
            body: event.body,
            interruptionLevel: event.priority == .low ? .passive : .active
        )

        do {
            try await scheduler.schedule(request)
        } catch {
            return .failed(reason: String(describing: error))
        }

        rememberHandler(event.onInteraction, for: identifier)
        return .presented
    }

    /// Routes a response from the system back to the handler the emitting module
    /// attached to the event.
    ///
    /// Handlers are one-shot: a notification the user has already answered cannot be
    /// answered again.
    public func handleResponse(identifier: String, interaction: NotificationInteraction) {
        guard let handler = handlers.removeValue(forKey: identifier) else { return }
        handlerOrder.removeAll { $0 == identifier }
        handler(interaction)
    }

    /// Combines category and subject so that repeated news about one thing supersedes
    /// itself in the notification centre — a device connecting and later disconnecting
    /// leaves one entry showing where it stands, not a growing pile — while two modules
    /// that happen to name their subjects alike stay independent.
    static func identifier(for event: NotificationEvent) -> String {
        "\(event.category.rawValue)|\(event.subject)"
    }

    private func resolveAuthorization() async -> SystemAuthorizationStatus {
        if let authorization { return authorization }

        var status = await scheduler.authorizationStatus()
        if status == .notDetermined {
            status = await scheduler.requestAuthorization() ? .authorized : .denied
        }
        authorization = status
        return status
    }

    /// Keeps the handler table bounded: notifications the user never answers would
    /// otherwise accumulate a closure each for the lifetime of the process.
    private func rememberHandler(_ handler: NotificationInteractionHandler?, for identifier: String) {
        handlerOrder.removeAll { $0 == identifier }

        guard let handler else {
            handlers.removeValue(forKey: identifier)
            return
        }

        handlers[identifier] = handler
        handlerOrder.append(identifier)

        while handlerOrder.count > handlerLimit {
            let oldest = handlerOrder.removeFirst()
            handlers.removeValue(forKey: oldest)
        }
    }

    var trackedHandlerCount: Int { handlers.count }
}
