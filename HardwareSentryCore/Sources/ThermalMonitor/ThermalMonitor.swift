import Foundation
import SentryContract
import SignalCore

/// Says when the Mac's thermal state changes, and when it overheats during a dark wake.
public actor ThermalMonitor: Monitor {
    public static let category = ThermalEvent.category

    public static let events: [MonitorEventDescription] = [
        .init(name: ThermalEvent.nominal.rawValue, title: "Back to normal (Nominal)", enabledByDefault: false, icon: .asset("Thermal-Nominal", in: .module)),
        .init(name: ThermalEvent.fair.rawValue, title: "Slightly elevated (Fair)", enabledByDefault: false, icon: .asset("Thermal-Fair", in: .module)),
        .init(name: ThermalEvent.serious.rawValue, title: "Throttling active (Serious)", enabledByDefault: true, icon: .asset("Thermal-Serious", in: .module)),
        .init(name: ThermalEvent.critical.rawValue, title: "Severe throttling (Critical)", enabledByDefault: true, icon: .asset("Thermal-Critical", in: .module)),
        .init(name: ThermalEvent.darkWakeEmergency.rawValue, title: "Overheated during a maintenance wake", enabledByDefault: false, icon: .asset("Thermal-DarkWakeEmergency", in: .module))
    ]

    public static let fields: [MonitorFieldDescription] = [
        .init(name: ThermalField.lowPowerMode.rawValue, title: "Note if Low Power Mode is also on", shownByDefault: false)
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

        let lowPowerNote = source.isLowPowerModeEnabled() ? "(Low Power Mode is also currently on)" : nil

        await context.notify(
            ThermalEvent.forState(state).rawValue,
            subject: "State",
            title: "Thermal State Changed",
            body: await context.body([
                .always(Self.describeTransition(from: previous, to: state)),
                // Correlation only, never cause: Low Power Mode can be switched on by
                // hand or by a low battery, with nothing to do with heat. Worth noting
                // together, worth not implying one caused the other.
                .field(ThermalField.lowPowerMode.rawValue, lowPowerNote)
            ]),
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
