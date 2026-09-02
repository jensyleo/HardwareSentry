import SentryContract
import SignalCore
import SwiftUI

/// Which notifications a person wants, module by module.
///
/// Specific to this application, unlike the appearance screen next to it: the list comes
/// from the monitors this application happens to run, so it could not live in the
/// notification package without that package knowing about hardware.
///
/// A list of modules beside the selected one's settings, rather than every module's events
/// in one long scroll. Thirteen monitors raise more than fifty events between them; in a
/// single column, changing one setting means hunting for it, and the module a row belongs
/// to is only knowable by scrolling back up to the nearest heading.
struct EventSettingsView: View {
    @Bindable var model: EventSettingsModel
    @Bindable var iconOverrides: IconOverrideStore

    @State private var selection: String?

    var body: some View {
        NavigationSplitView {
            List(model.modules, selection: $selection) { module in
                ModuleRow(module: module, isEnabled: model.isEnabled(module.category))
                    .tag(module.id)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            if let module = model.modules.first(where: { $0.id == selection }) {
                ModuleDetail(module: module, model: model, iconOverrides: iconOverrides)
            } else {
                ContentUnavailableView(
                    "Choose a Module",
                    systemImage: "sidebar.left",
                    description: Text("Pick one on the left to choose which of its notifications arrive.")
                )
            }
        }
        .task {
            await model.load()
            // Something is always selected, so the screen never opens on an empty panel
            // that gives no clue what to do next.
            if selection == nil { selection = model.modules.first?.id }
        }
    }
}

/// One module in the list: its artwork, its name, and whether it is running at all.
private struct ModuleRow: View {
    let module: MonitorDescription
    let isEnabled: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: Self.icon(for: module))
            Text(module.category.rawValue)
            Spacer()
            // A dot rather than a switch: the switch lives on the detail panel, and two
            // controls for one setting invites the question of whether they are the same
            // setting. This only reports.
            if !isEnabled {
                Image(systemName: "moon.zzz.fill")
                    .foregroundStyle(.tertiary)
                    .help("This module is switched off")
            }
        }
        .opacity(isEnabled ? 1 : 0.55)
    }

    /// The module's first event's artwork, which is the closest thing to a picture of the
    /// module that exists without inventing a second set of icons to keep in step.
    @MainActor
    private static func icon(for module: MonitorDescription) -> NSImage {
        module.events.first?.icon.image(side: 18)
            ?? NSImage(systemSymbolName: "square.dashed", accessibilityDescription: nil)?.resized(toFit: 18)
            ?? NSImage(size: NSSize(width: 18, height: 18))
    }
}

/// Everything for one module: whether it runs, which of its events arrive, and how much
/// each message says.
private struct ModuleDetail: View {
    let module: MonitorDescription
    @Bindable var model: EventSettingsModel
    @Bindable var iconOverrides: IconOverrideStore

    var body: some View {
        Form {
            Section {
                Toggle("Watch for these", isOn: binding(for: module.category))
                    .toggleStyle(.switch)
            } footer: {
                Text("Switching this off stops the module watching altogether, rather than only silencing it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Notifications") {
                ForEach(module.events, id: \.name) { event in
                    HStack(spacing: 8) {
                        // Leading, not trailing: the icon is how someone recognises the
                        // row they came to change, so it has to be where the eye lands
                        // first rather than at the end of a line of text.
                        EventIconPicker(
                            event: event.name,
                            category: module.category,
                            defaultIcon: event.icon,
                            store: iconOverrides
                        )
                        Toggle(event.title, isOn: binding(for: event, in: module.category))
                    }
                    .disabled(!model.isEnabled(module.category))
                }
            }

            // Not events: extra lines inside a notification that is arriving anyway. In
            // their own section so the difference is visible rather than implied.
            if !module.fields.isEmpty {
                Section("Include in the message") {
                    ForEach(module.fields, id: \.name) { field in
                        Toggle(field.title, isOn: binding(for: field, in: module.category))
                    }
                }
                .disabled(!model.isEnabled(module.category))
            }

            Section {
                Toggle("Announce what is already connected at launch", isOn: Binding(
                    get: { model.announcesWhatIsAlreadyThere },
                    set: { model.announcesWhatIsAlreadyThere = $0 }
                ))
                Text("Takes effect the next time the application starts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    // Separate from "Restore Defaults" on purpose: someone who has spent
                    // time picking icons should not lose them by switching a notification
                    // back on, and someone tidying up their icons should not have their
                    // notification choices reset underneath them.
                    Button("Restore Default Icons") { iconOverrides.resetAll() }
                        .disabled(iconOverrides.overrides.isEmpty)
                    Spacer()
                    Button("Restore Defaults") { model.resetAll() }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(module.category.rawValue)
    }

    private func binding(for category: NotificationCategory) -> Binding<Bool> {
        Binding(
            get: { model.isEnabled(category) },
            set: { model.setEnabled($0, for: category) }
        )
    }

    private func binding(for event: MonitorEventDescription, in category: NotificationCategory) -> Binding<Bool> {
        Binding(
            get: { model.isEnabled(event, in: category) },
            set: { model.setEnabled($0, for: event, in: category) }
        )
    }

    private func binding(for field: MonitorFieldDescription, in category: NotificationCategory) -> Binding<Bool> {
        Binding(
            get: { model.isShown(field, in: category) },
            set: { model.setShown($0, for: field, in: category) }
        )
    }
}
