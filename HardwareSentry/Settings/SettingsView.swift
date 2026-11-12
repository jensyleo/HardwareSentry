import SentryContract
import SignalCore
import SwiftUI
import SystemIcons
import ThermalMonitor

/// The settings window: how notifications look, and which ones arrive.
///
/// The split is the module boundary made visible. "Notifications" is this application's
/// own — it lists the monitors it runs. "Appearance" comes from the notification package
/// itself, so every application built on it offers the same screen without rewriting it.
struct SettingsView: View {
    let appearance: BannerAppearanceStore
    let events: EventSettingsModel
    let history: NotificationHistoryStore
    let iconOverrides: IconOverrideStore
    let iconSources: IconSourceModel
    let general: GeneralSettingsModel
    let tuning: MonitorTuningModel
    let checkBatteryHealthNow: () -> Void
    let checkSerialVendorUpdateNow: () -> Void
    let simulateThermal: (ThermalState, ThermalState) -> Void
    let simulateEvent: (MonitorEventDescription, NotificationCategory) -> Void
    let previewNotification: (MonitorEventDescription, NotificationCategory, IconBadge?, IconSource) -> Void

    @State private var tab = "general"
    /// The module and pane the Notifications tab shows; set by "Edit icon" on the Preview tab.
    @State private var notificationsModule: String?
    @State private var notificationsPane = ModulePane.iconsTitle

    var body: some View {
        TabView(selection: $tab) {
            // First, and in this order, because it is the one tab about the application
            // itself rather than about the notifications it sends.
            GeneralSettingsView(model: general, tuning: tuning)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")

            BannerAppearanceView(store: appearance)
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
                .tag("appearance")

            EventSettingsView(model: events, iconOverrides: iconOverrides, iconSources: iconSources, tuning: tuning, simulateThermal: simulateThermal, simulateEvent: simulateEvent, checkBatteryHealthNow: checkBatteryHealthNow, checkSerialVendorUpdateNow: checkSerialVendorUpdateNow, selection: $notificationsModule, pane: $notificationsPane)
                .tabItem { Label("Notifications", systemImage: "bell.badge") }
                .tag("notifications")

            NotificationPreviewView(model: events, iconSources: iconSources, show: previewNotification, editIcons: { moduleID in
                notificationsModule = moduleID
                notificationsPane = ModulePane.iconsTitle
                tab = "notifications"
            })
                .tabItem { Label("Preview", systemImage: "eye") }
                .tag("preview")

            HistoryView(
                store: history,
                modules: events.modules,
                isModuleEnabled: { events.isEnabled($0) }
            )
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag("history")
        }
        // Every dimension is a minimum and a preference, never a fixed value: a fixed one
        // makes the settings window refuse to resize, and the appearance tab is already
        // taller than fits — it grows again with each setting added. Better to open at a
        // sensible size and let it be dragged than to pin it at one that will be wrong.
        .frame(minWidth: 560, idealWidth: 560, minHeight: 460, idealHeight: 720)
    }
}
