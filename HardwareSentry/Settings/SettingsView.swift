import SignalCore
import SwiftUI

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
    let general: GeneralSettingsModel
    let tuning: MonitorTuningModel
    let checkBatteryHealthNow: () -> Void

    var body: some View {
        TabView {
            // First, and in this order, because it is the one tab about the application
            // itself rather than about the notifications it sends.
            GeneralSettingsView(model: general, tuning: tuning, checkBatteryHealthNow: checkBatteryHealthNow)
                .tabItem { Label("General", systemImage: "gearshape") }

            BannerAppearanceView(store: appearance)
                .tabItem { Label("Appearance", systemImage: "paintbrush") }

            EventSettingsView(model: events, iconOverrides: iconOverrides)
                .tabItem { Label("Notifications", systemImage: "bell.badge") }

            HistoryView(store: history)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
        }
        // Every dimension is a minimum and a preference, never a fixed value: a fixed one
        // makes the settings window refuse to resize, and the appearance tab is already
        // taller than fits — it grows again with each setting added. Better to open at a
        // sensible size and let it be dragged than to pin it at one that will be wrong.
        .frame(minWidth: 560, idealWidth: 560, minHeight: 460, idealHeight: 720)
    }
}
