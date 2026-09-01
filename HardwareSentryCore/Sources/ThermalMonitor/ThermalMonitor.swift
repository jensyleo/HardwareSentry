import Foundation
import SentryContract
import SignalCore

/// Says when the Mac's thermal state changes, and when it overheats during a dark wake.
public actor ThermalMonitor: Monitor {
    public static let category = ThermalEvent.category

    public static let events: [MonitorEventDescription] = [
        .init(name: ThermalEvent.nominal.rawValue, title: "Back to normal (Nominal)", enabledByDefault: false),
        .init(name: ThermalEvent.fair.rawValue, title: "Slightly elevated (Fair)", enabledByDefault: false),
        .init(name: ThermalEvent.serious.rawValue, title: "Throttling active (Serious)", enabledByDefault: true),
        .init(name: ThermalEvent.critical.rawValue, title: "Severe throttling (Critical)", enabledByDefault: true),
        .init(name: ThermalEvent.darkWakeEmergency.rawValue, title: "Overheated during a maintenance wake", enabledByDefault: true)
    ]

    private let source: any ThermalStateSource
    private let context: MonitorContext
    private var lastState: ThermalState?
    private var watching: [Task<Void, Never>] = []

    public init(source: any ThermalStateSource, context: MonitorContext) {
        self.source = source
        self.context = context
    }

    public func start() async {
        guard watching.isEmpty else { return }
        lastState = source.currentState()

        watching = [
            Task { [source, context] in
                for await state in source.stateChanges() {
                    guard !Task.isCancelled else { return }
                    await self.reportStateChange(to: state, through: context)
                }
            },
            Task { [source, context] in
                for await _ in source.darkWakeEmergencies() {
                    guard !Task.isCancelled else { return }
                    await Self.reportDarkWakeEmergency(through: context)
                }
            }
        ]
    }

    public func stop() async {
        watching.forEach { $0.cancel() }
        watching = []
    }

    private func reportStateChange(to state: ThermalState, through context: MonitorContext) async {
        guard state != lastState else { return }
        let previous = lastState
        lastState = state
        guard let previous else { return } // first sighting — baseline only, no notification

        await context.notify(
            ThermalEvent.forState(state).rawValue,
            subject: "State",
            title: "Thermal State Changed",
            body: Self.describeTransition(from: previous, to: state),
            // The icon says the severity at a glance, before the text is read.
            icon: .asset("Thermal-\(state.label)", in: .module)
        )
    }

    private static func reportDarkWakeEmergency(through context: MonitorContext) async {
        await context.notify(
            ThermalEvent.darkWakeEmergency.rawValue,
            subject: "DarkWakeEmergency",
            title: "Dark Wake Thermal Emergency",
            body: "The Mac overheated during a brief maintenance wake and may sleep again immediately to cool down.",
            icon: .asset("Thermal-DarkWakeEmergency", in: .module)
        )
    }

    /// "old → new — what the new level means", plus whether this is improving or worsening.
    static func describeTransition(from: ThermalState, to: ThermalState) -> String {
        let line = "State:\t\(from.label) → \(to.label) — \(to.meaning)"
        if to < from { return line + "\n" + "↓ Cooling down (improving)" }
        if to > from { return line + "\n" + "↑ Warming up (worsening)" }
        return line
    }
}
