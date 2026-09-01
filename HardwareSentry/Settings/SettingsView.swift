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

    var body: some View {
        TabView {
            EventSettingsView(model: events)
                .tabItem { Label("Notifications", systemImage: "bell.badge") }

            BannerAppearanceView(store: appearance)
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
        }
        // A fixed height would cut off the appearance tab, which is taller than the
        // notifications one and grows again with every setting added. Fixed in width so
        // the preview is always shown at a believable size, free to grow in height.
        .frame(width: 560)
        .frame(minHeight: 480, idealHeight: 680)
    }
}
