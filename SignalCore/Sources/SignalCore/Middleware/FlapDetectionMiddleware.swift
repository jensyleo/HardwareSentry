import Foundation

/// Everything known about a subject that has been found to be flapping, handed to the
/// host so it can phrase the report however it likes.
public struct FlapReport: Sendable {
    /// The subject that is flapping, with any paired-transition suffix already stripped.
    public let subject: String
    public let category: NotificationCategory
    /// How many events were seen inside the window.
    public let occurrences: Int
    public let window: TimeInterval
    /// The event that tipped the subject over the threshold, so its icon and other
    /// details can be reused in the report.
    public let triggeringEvent: NotificationEvent
}

public typealias FlapReportBuilder = @Sendable (FlapReport) -> NotificationEvent

/// Detects a subject changing state over and over in a short span — a loose cable, a
/// failing port, a device on the edge of radio range — and collapses the resulting storm
/// of notifications into a single report that the subject is unstable.
///
/// Once a subject crosses the threshold, the event that tipped it over is **replaced** by
/// the report, and further events for that subject are dropped until it settles or the
/// report cooldown elapses.
///
/// This differs deliberately from the design being replaced, which emitted the report *in
/// addition to* every individual event — so a device flapping four times produced five
/// notifications, the last one pointing out that the previous four were noise. Since the
/// entire purpose of the check is to cut that noise, the report supersedes the storm
/// rather than capping it. Events before the threshold still come through untouched, so
/// ordinary state changes are unaffected.
///
/// Timestamps are held in a per-subject buffer capped at the threshold, so memory is
/// bounded by how many subjects are active rather than by how long the host has run.
public actor FlapDetectionMiddleware: NotificationMiddleware {
    private var recentEvents: [String: [Date]] = [:]
    private var lastReported: [String: Date] = [:]

    private let window: TimeInterval
    private let threshold: Int
    private let reportCooldown: TimeInterval
    private let pairedTransitionSuffixes: [String]
    private let buildReport: FlapReportBuilder
    private let pruneThreshold: Int

    public init(
        window: TimeInterval = 20,
        threshold: Int = 4,
        reportCooldown: TimeInterval = 20,
        pairedTransitionSuffixes: [String] = ["-started", "-stopped"],
        pruneThreshold: Int = 256,
        buildReport: @escaping FlapReportBuilder = FlapDetectionMiddleware.defaultReport
    ) {
        self.window = window
        self.threshold = max(2, threshold)
        self.reportCooldown = reportCooldown
        self.pairedTransitionSuffixes = pairedTransitionSuffixes
        self.pruneThreshold = pruneThreshold
        self.buildReport = buildReport
    }

    public func process(_ event: NotificationEvent, context: DispatchContext) async -> MiddlewareDecision {
        let key = flapKey(for: event)
        let reportedSubject = strippedSubject(event.subject)
        let now = context.firedAt

        if lastReported.count >= pruneThreshold || recentEvents.count >= pruneThreshold {
            prune(before: now)
        }

        var timestamps = (recentEvents[key] ?? []).filter { now.timeIntervalSince($0) < window }
        timestamps.append(now)
        if timestamps.count > threshold {
            timestamps.removeFirst(timestamps.count - threshold)
        }
        recentEvents[key] = timestamps

        guard timestamps.count >= threshold else {
            return .deliver(event)
        }

        if let reported = lastReported[key], now.timeIntervalSince(reported) < reportCooldown {
            return .suppress(reason: "\(reportedSubject) is flapping; already reported")
        }

        lastReported[key] = now
        let report = FlapReport(
            subject: reportedSubject,
            category: event.category,
            occurrences: timestamps.count,
            window: window,
            triggeringEvent: event
        )
        return .deliver(buildReport(report))
    }

    /// The bucket a subject's occurrences are counted in: its category and its name.
    ///
    /// The category is part of the key because two *modules* can speak for one physical
    /// device, and that is not the device flapping — it is one event seen twice. Keyed on
    /// the name alone, a controller paired over Bluetooth counted double, since Bluetooth
    /// Monitor and Gamepad Monitor both name it "Joy-Con (R)": two connect/disconnect
    /// cycles reached a threshold meant for four, and everything about that device was
    /// then dropped for the cooldown. Reported live, 2026-09-07, as Bluetooth notices
    /// that sometimes did not arrive or arrived far too late.
    ///
    /// `DuplicateSuppressionMiddleware` has always keyed on the category for the same
    /// reason; this was the odd one out.
    private func flapKey(for event: NotificationEvent) -> String {
        // A unit separator: no category or subject can contain one, so the two halves
        // cannot run together into a key that means something else.
        "\(event.category.rawValue)\u{1F}\(strippedSubject(event.subject))"
    }

    /// Strips a paired-transition suffix so that "something started" and "something
    /// stopped" count as the same subject flipping back and forth, rather than as two
    /// unrelated subjects each seen half as often.
    private func strippedSubject(_ subject: String) -> String {
        for suffix in pairedTransitionSuffixes where subject.hasSuffix(suffix) {
            return String(subject.dropLast(suffix.count))
        }
        return subject
    }

    private func prune(before instant: Date) {
        recentEvents = recentEvents.compactMapValues { timestamps in
            let live = timestamps.filter { instant.timeIntervalSince($0) < window }
            return live.isEmpty ? nil : live
        }
        lastReported = lastReported.filter { instant.timeIntervalSince($0.value) < reportCooldown }
    }

    /// What to call the subject in a sentence for a person.
    ///
    /// A subject is a key, and some are not words: a display's is its number, which read as
    /// "1 changed state 4 times". Where it is only digits, the first line of the event that
    /// tipped it over — which is where a monitor puts the thing's name — says it better.
    static func spokenName(for report: FlapReport) -> String {
        guard !report.subject.isEmpty, report.subject.allSatisfy(\.isNumber) else { return report.subject }
        let firstLine = report.triggeringEvent.body.split(separator: "\n").first.map(String.init) ?? ""
        let name = firstLine.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return name.isEmpty ? report.subject : name
    }

    public static let defaultReport: FlapReportBuilder = { report in
        NotificationEvent(
            name: "FlapDetected",
            subject: report.subject,
            category: report.category,
            title: "Unstable",
            body: "\(spokenName(for: report)) changed state \(report.occurrences) times "
                + "within \(Int(report.window)) seconds.",
            icon: report.triggeringEvent.icon,
            iconKind: report.triggeringEvent.iconKind,
            iconModel: report.triggeringEvent.iconModel,
            iconBadge: .warning,
            showsIconBadge: true,
            priority: .high
        )
    }

    var trackedSubjectCount: Int { recentEvents.count }
}
