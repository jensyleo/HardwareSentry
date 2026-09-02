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
    /// Which half of a module's settings is showing. Held here rather than inside the
    /// panel so that switching module keeps you on the same half — somebody working
    /// through the icons of one module after another should not be dropped back onto the
    /// switches every time they change module.
    @State private var pane: ModulePane = .notifications

    var body: some View {
        NavigationSplitView {
            List(model.modules, selection: $selection) { module in
                ModuleRow(module: module, isEnabled: model.isEnabled(module.category))
                    .tag(module.id)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            if let module = model.modules.first(where: { $0.id == selection }) {
                ModuleDetail(module: module, model: model, iconOverrides: iconOverrides, pane: $pane)
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

    /// What the module says it looks like — its first event's artwork unless it named
    /// something better, which a module covering several unrelated things has to.
    @MainActor
    private static func icon(for module: MonitorDescription) -> NSImage {
        module.icon.image(side: 18)
            ?? NSImage(systemSymbolName: "square.dashed", accessibilityDescription: nil)?.resized(toFit: 18)
            ?? NSImage(size: NSSize(width: 18, height: 18))
    }
}

/// Which half of a module's settings is on screen.
///
/// Two lists rather than one with an icon at the start of every row. Network alone raises
/// thirty-one notifications and offers thirty optional lines; with a picker on each row,
/// the list of things to switch on and off is twice as tall as it needs to be, and the
/// icons — which are chosen once and then left alone — are in the way of the switches,
/// which are what somebody comes here to change. The original splits them the same way.
enum ModulePane: String, CaseIterable, Identifiable {
    case notifications = "Notifications"
    case icons = "Icons"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .notifications: return "bell.badge"
        case .icons: return "photo.badge.plus"
        }
    }
}

/// Everything for one module: whether it runs, which of its events arrive, and how much
/// each message says.
private struct ModuleDetail: View {
    let module: MonitorDescription
    @Bindable var model: EventSettingsModel
    @Bindable var iconOverrides: IconOverrideStore
    @Binding var pane: ModulePane

    var body: some View {
        VStack(spacing: 0) {
            // Above the form rather than inside it: this chooses which form is showing,
            // so it is not one of the settings.
            Picker("", selection: $pane) {
                ForEach(ModulePane.allCases) { choice in
                    Label(choice.rawValue, systemImage: choice.symbol).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.top, 10)

            switch pane {
            case .notifications: notificationsPane
            case .icons: iconsPane
            }
        }
        .navigationTitle(module.category.rawValue)
    }

    // MARK: - Icons

    /// One row per notification, with nothing but its picture and its name.
    ///
    /// Deliberately not disabled when the module is switched off: choosing what a
    /// notification will look like before switching it on is a reasonable order to do
    /// things in, and the artwork is not affected by whether the module runs.
    private var iconsPane: some View {
        Form {
            Section {
                Text("Click an icon to choose a different one — a suggested symbol, any SF Symbol by name, or an image of your own.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(module.eventGroups) { group in
                Section(group.title ?? "Notifications") {
                    ForEach(group.rows, id: \.name) { event in
                        HStack(spacing: 8) {
                            EventIconPicker(
                                event: event.name,
                                category: module.category,
                                defaultIcon: event.icon,
                                store: iconOverrides
                            )
                            Text(event.title)
                            Spacer()
                        }
                    }
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("Restore Default Icons") { iconOverrides.resetAll() }
                        .disabled(iconOverrides.overrides.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Notifications

    private var notificationsPane: some View {
        Form {
            Section {
                Toggle("Watch for these", isOn: binding(for: module.category))
                    .toggleStyle(.switch)
            } footer: {
                Text("Switching this off stops the module watching altogether, rather than only silencing it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // One section per heading the module declared, in its own order. A module
            // that declared none comes back as a single unnamed run, so this renders every
            // module the same way rather than asking whether this one bothered.
            ForEach(module.eventGroups) { group in
                Section(group.title ?? "Notifications") {
                    ForEach(group.rows, id: \.name) { event in
                        Toggle(event.title, isOn: binding(for: event, in: module.category))
                            .disabled(!model.isEnabled(module.category))
                    }
                }
            }

            // Not events: extra lines inside a notification that is arriving anyway. In
            // their own section so the difference is visible rather than implied.
            if !module.fields.isEmpty {
                ForEach(module.fieldGroups) { group in
                    Section(group.title.map { "Include in the message — \($0)" } ?? "Include in the message") {
                        ForEach(group.rows, id: \.name) { field in
                            Toggle(field.title, isOn: binding(for: field, in: module.category))
                        }
                    }
                    .disabled(!model.isEnabled(module.category))
                }
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
                    Spacer()
                    // Icons have their own button, on their own tab: someone who has spent
                    // time picking icons should not lose them by switching a notification
                    // back on, and someone tidying up their icons should not have their
                    // notification choices reset underneath them.
                    Button("Restore Defaults") { model.resetAll() }
                }
            }
        }
        .formStyle(.grouped)
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
