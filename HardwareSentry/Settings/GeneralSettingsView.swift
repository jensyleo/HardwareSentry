import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// How the application presents itself, and how to keep a copy of every choice made in it.
struct GeneralSettingsView: View {
    @Bindable var model: GeneralSettingsModel
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
