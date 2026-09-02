import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// How the application presents itself, and how to keep a copy of every choice made in it.
struct GeneralSettingsView: View {
    @Bindable var model: GeneralSettingsModel
    @Bindable var tuning: MonitorTuningModel
    /// Reads the battery now, rather than waiting for the next scheduled check.
    let checkBatteryHealthNow: () -> Void
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Toggle("Start HardwareSentry at login", isOn: Binding(
                    get: { model.startsAtLogin },
                    set: { model.startsAtLogin = $0 }
                ))

                Picker("Icon", selection: Binding(
                    get: { model.iconVisibility },
                    set: { model.iconVisibility = $0 }
                )) {
                    ForEach(IconVisibility.allCases) { visibility in
                        Text(visibility.label).tag(visibility)
                    }
                }

                if model.iconVisibility == .none {
                    // Choosing this hides every way of reaching the application, so the
                    // way back has to be said before it is taken, not discovered after.
                    Text("With no icon anywhere, open HardwareSentry again from Applications to get back to these settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle("Show Connected Devices at Launch", isOn: Binding(
                    get: { model.showsConnectedDevicesAtLaunch },
                    set: { model.showsConnectedDevicesAtLaunch = $0 }
                ))
                Text("Takes effect the next time the application starts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Power") {
                Toggle("Repeat the power status periodically", isOn: $tuning.repeatsPowerStatus)
                if tuning.repeatsPowerStatus {
                    // Stepper rather than a slider: this is a number somebody has in mind
                    // ("every fifteen minutes"), not one they want to find by feel.
                    Stepper(
                        "Every \(Int(tuning.refireMinutes)) minutes",
                        value: $tuning.refireMinutes,
                        in: 1...1440,
                        step: 5
                    )
                    Toggle("Only while on battery", isOn: $tuning.refireOnlyOnBattery)
                }

                Toggle("Check the battery's health regularly", isOn: $tuning.checksBatteryHealth)
                if tuning.checksBatteryHealth {
                    Stepper(
                        "Every \(Int(tuning.healthCheckDays)) days",
                        value: $tuning.healthCheckDays,
                        in: 1...365,
                        step: 1
                    )
                    Text("Reports only when the reading has moved, so a battery that is holding up stays quiet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Check Now", action: checkBatteryHealthNow)
                    Spacer()
                    if let last = tuning.lastBatteryCheck {
                        Text("Last checked \(last.formatted(.relative(presentation: .named)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Volumes") {
                Stepper(
                    "Warn when free space falls below \(Int(tuning.lowSpacePercent))%",
                    value: $tuning.lowSpacePercent,
                    in: 1...50,
                    step: 1
                )
                Text("Recovery is announced five points higher, so a volume hovering around the line is not reported over and over.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Profile") {
                Text("Back up or restore every custom icon and every on/off setting — which modules run, their notification toggles, and what each message includes — in one file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Export Profile…", action: exportProfile)
                    Button("Import Profile…", action: importProfile)
                    Spacer()
                }

                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func exportProfile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "HardwareSentry Profile.json"
        panel.title = "Export Profile"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try SettingsProfileStore().write(to: url)
            message = "Saved to \(url.lastPathComponent)."
        } catch {
            message = "Could not save: \(error.localizedDescription)"
        }
    }

    private func importProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Import Profile"
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let store = SettingsProfileStore()
            try store.apply(store.read(from: url))
            // Restarting is the honest instruction rather than a silent partial apply:
            // which modules run is decided as they start, and several of these settings
            // are read once at launch.
            message = "Imported. Quit and reopen HardwareSentry for every setting to take effect."
        } catch {
            message = "Could not import: \(error.localizedDescription)"
        }
    }
}
