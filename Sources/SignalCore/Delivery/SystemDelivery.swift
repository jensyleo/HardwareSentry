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
    private var resolving: Task<SystemAuthorizationStatus, Never>?
    private var handlers: [String: NotificationInteractionHandler] = [:]
    private var handlerOrder: [String] = []
    private let handlerLimit: Int

    public init(scheduler: any SystemNotificationScheduling, handlerLimit: Int = 128) {
        self.scheduler = scheduler
        self.handlerLimit = handlerLimit
    }

    /// Settles whether the system will accept notifications, asking the user if they
    /// have not been asked before.
    ///
    /// Worth calling at startup: until this has finished, every notification goes to
    /// whatever channel is standing in, since presenting cannot wait on it.
    @discardableResult
    public func prepare() async -> Bool {
        await settleAuthorization() != .denied
    }

    @discardableResult
    public func present(_ event: NotificationEvent, context: DispatchContext) async -> DeliveryOutcome {
        // Never wait on the permission question here. It can sit unanswered for as long
        // as the person ignores the dialog, and a startup sweep behind it would arrive
        // minutes late or not at all. Until the answer is in, this channel declines and
        // whatever is standing in gets the notification.
        guard let authorization else {
            beginSettlingAuthorization()
            return .failed(reason: "system authorization has not been settled yet")
        }

        guard authorization != .denied else {
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

    private func settleAuthorization() async -> SystemAuthorizationStatus {
        if let authorization { return authorization }

        let task: Task<SystemAuthorizationStatus, Never>
        if let resolving {
            task = resolving
        } else {
            task = Task { [scheduler] in
                var status = await scheduler.authorizationStatus()
                if status == .notDetermined {
                    status = await scheduler.requestAuthorization() ? .authorized : .denied
                }
                return status
            }
            resolving = task
        }

        // Whoever gets the answer records it, not only whoever started asking: an actor
        // lets others in at every await, so the one that started the work is not
        // necessarily the first one back.
        let status = await task.value
        if authorization == nil {
            authorization = status
            resolving = nil
        }
        return status
    }

    /// Starts settling the question without waiting for the answer, so that one
    /// notification arriving early does not hold up everything behind it.
    private func beginSettlingAuthorization() {
        guard authorization == nil, resolving == nil else { return }
        Task { await settleAuthorization() }
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
