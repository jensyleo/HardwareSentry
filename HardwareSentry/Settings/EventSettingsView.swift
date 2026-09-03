import AppKit
import SentryContract
import SignalCore
import SwiftUI
import ThermalMonitor

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
    @Bindable var tuning: MonitorTuningModel
    /// Fires one thermal transition on demand. See `ThermalSimulator`.
    let simulateThermal: (ThermalState, ThermalState) -> Void

    @State private var selection: String?
    /// Which of the selected module's tabs is showing, by name.
    ///
    /// Held here rather than inside the panel so it survives switching module: somebody
    /// working through the icons of one module after another should not be dropped back
    /// onto the first tab every time they change module. A name that the next module does
    /// not have falls back to its first tab.
    @State private var pane: String = ModulePane.iconsTitle

    var body: some View {
        VStack(spacing: 0) {
            PerformancePicker(model: model)
            splitView
        }
    }

    private var splitView: some View {
        NavigationSplitView {
            List(model.modules, selection: $selection) { module in
                ModuleRow(module: module, model: model, iconOverrides: iconOverrides)
                    .tag(module.id)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            if let module = model.modules.first(where: { $0.id == selection }) {
                ModuleDetail(module: module, model: model, iconOverrides: iconOverrides, tuning: tuning, simulateThermal: simulateThermal, pane: $pane)
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

/// How much of the application runs, as one choice rather than thirteen.
///
/// Above the module list, not inside it, because it is about all of them at once — and
/// because it is the first thing to decide: which modules run at all comes before which of
/// their notifications arrive.
private struct PerformancePicker: View {
    @Bindable var model: EventSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Performance")
                .font(.headline)

            Picker("", selection: Binding(
                get: { model.performanceMode },
                set: { model.setPerformanceMode($0) }
            )) {
                // In the original's order, which puts the two presets between the extremes
                // rather than in the enum's own numbering.
                ForEach([
                    EventSettingsModel.PerformanceMode.minimal,
                    .recommended,
                    .all,
                    .custom
                ]) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            .horizontalRadioGroupLayout()
            .labelsHidden()

            Text(model.performanceMode.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 10)
        Divider()
    }
}

/// One module in the list: its artwork, its name, and whether it is running at all.
private struct ModuleRow: View {
    let module: MonitorDescription
    @Bindable var model: EventSettingsModel
    @Bindable var iconOverrides: IconOverrideStore

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: Self.icon(for: module, overrides: iconOverrides))
            Text(module.category.rawValue)
            Spacer()
            // The module's own switch, here rather than duplicated on the panel: two
            // controls for one setting invites the question of whether they are the same
            // setting, and the answer being "yes" does not stop it being asked.
            Toggle("", isOn: Binding(
                get: { model.isEnabled(module.category) },
                set: { model.setEnabled($0, for: module.category) }
            ))
            .labelsHidden()
            .help("Switching this off stops the module watching altogether, rather than only silencing it.")
        }
        .opacity(model.isEnabled(module.category) ? 1 : 0.55)
    }

    /// Whatever was chosen for this module, or what the module says it looks like — its
    /// first event's artwork unless it named something better, which a module covering
    /// several unrelated things has to.
    @MainActor
    private static func icon(for module: MonitorDescription, overrides: IconOverrideStore) -> NSImage {
        // An override is a symbol name or a path; both become artwork the same way the
        // dispatcher resolves them when a notification fires.
        let chosen: NSImage? = switch overrides.override(for: IconOverrideStore.moduleIconEvent, in: module.category) {
        case .symbol(let name): NotificationIcon.symbol(name).image(side: 18)
        case .file(let path): NSImage(contentsOfFile: path)?.resized(toFit: 18)
        case nil: nil
        }
        return chosen
            ?? module.icon.image(side: 18)
            ?? NSImage(systemSymbolName: "square.dashed", accessibilityDescription: nil)?.resized(toFit: 18)
            ?? NSImage(size: NSSize(width: 18, height: 18))
    }
}

/// The tabs a module's settings are split across.
///
/// One per subject the module declared, plus icons. Two things drove this. A module that
/// covers several subjects — Network raises thirty-one notifications and offers thirty
/// optional lines across Wi-Fi, wired links, VPN, addresses and system configuration — is
/// unreadable as one scroll, and the subject a row belongs to is only knowable by scrolling
/// back to the nearest heading. And icons are chosen once and then left alone, while the
/// switches are changed often, so a picker on every row makes the list of switches twice
/// as tall as it needs to be for the sake of something nobody is looking at.
enum ModulePane {
    static let iconsTitle = "Icons"
    /// What an ungrouped module's one subject tab is called.
    static let plainTitle = "Notifications"

    /// The tab names for one module, in the order the module declared its subjects.
    static func titles(for module: MonitorDescription) -> [String] {
        let subjects = module.eventGroups.map { $0.title ?? plainTitle }
        return subjects + [iconsTitle]
    }
}

/// Everything for one module: which of its notifications arrive, how much each message
/// says, and what each one looks like.
private struct ModuleDetail: View {
    let module: MonitorDescription
    @Bindable var model: EventSettingsModel
    @Bindable var iconOverrides: IconOverrideStore
    @Bindable var tuning: MonitorTuningModel
    let simulateThermal: (ThermalState, ThermalState) -> Void
    @Binding var pane: String

    private var titles: [String] { ModulePane.titles(for: module) }

    /// The tab actually showing. A name carried over from a module that had it and this
    /// one does not falls back to the first, so the panel is never blank.
    private var currentTitle: String {
        titles.contains(pane) ? pane : (titles.first ?? ModulePane.iconsTitle)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Above the form rather than inside it: this chooses which form is showing,
            // so it is not one of the settings.
            Picker("", selection: Binding(get: { currentTitle }, set: { pane = $0 })) {
                ForEach(titles, id: \.self) { title in
                    Text(title).tag(title)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.top, 10)

            if currentTitle == ModulePane.iconsTitle {
                iconsPane
            } else {
                subjectPane(named: currentTitle)
            }
        }
        .navigationTitle(module.category.rawValue)
    }

    // MARK: - One subject

    /// The optional lines that belong to one subject.
    ///
    /// Only the lines: whether a notification arrives at all is a checkbox beside its icon,
    /// which is where somebody picking through notifications is already looking, and it
    /// keeps this list to one question — how much does the message say.
    private func subjectPane(named title: String) -> some View {
        let fields = module.fieldGroups
            .first { ($0.title ?? ModulePane.plainTitle) == title }?
            .rows ?? []

        return Form {
            // A tab that is about something other than a list of lines — how often to
            // look, or a paragraph explaining how the detection works — says so here,
            // above its fields.
            if let note = ModuleNotes.note(for: module.category, group: title) {
                Section {
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if module.category.rawValue == "Volume", title == titles.first {
                IgnoredDrivesEditor(drives: $tuning.ignoredDrives)
            }

            if module.category.rawValue == "Display", title == titles.first {
                Section("Early physical-link detection (experimental)") {
                    Text("A cable can be plugged in seconds before macOS has a display to report. The kernel log mentions the link first, so it is read as an early warning — before \u{201C}Display Connected\u{201D}, not instead of it. Experimental because it depends on log wording that Apple has never documented and can change in any update; when it stops matching, the early notice simply stops arriving and nothing else is affected. Whether it arrives at all is the \u{201C}Video link detected\u{201D} checkbox on the Icons tab.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    slider(
                        "Poll every",
                        value: $tuning.videoLinkSeconds,
                        range: 1...60,
                        caption: "How often the system log is checked for a video link (1–60 s). Only used while \u{201C}Video link detected\u{201D} is switched on."
                    )
                }
            }

            if module.category.rawValue == "Audio", title == titles.first {
                Section {
                    slider(
                        "Volume Critical threshold",
                        value: $tuning.audioVolumeCriticalPercent,
                        range: 50...100,
                        caption: "Warn when the default output goes above this level. It re-arms ten points below, so hovering at the line does not warn twice.",
                        unit: "%"
                    )
                }
            }

            if module.category.rawValue == "Network", title == "Wi-Fi" {
                Section {
                    slider(
                        "Wi-Fi signal check interval",
                        value: $tuning.wifiSignalSeconds,
                        range: 5...60,
                        caption: "How often the Wi-Fi signal strength is checked (5–60 s)."
                    )
                    slider(
                        "Minimum time between signal-change notices",
                        value: $tuning.wifiSignalCooldownSeconds,
                        range: 0...60,
                        caption: "Prevents repeat notices if the signal hovers at a threshold (0–60 s, 0 = off)."
                    )
                }
            }

            // A module whose notifications are levels of one thing lists them here as
            // well as beside their icons: four thermal levels read as a list of levels,
            // where fourteen USB device classes would be a wall.
            if let heading = module.eventListHeading, title == titles.first {
                Section(heading) {
                    ForEach(module.events, id: \.name) { event in
                        Toggle(event.title, isOn: binding(for: event, in: module.category))
                            .toggleStyle(.checkbox)
                            .disabled(!model.isEnabled(module.category))
                    }
                }
            }

            if module.category.rawValue == "Thermal", title == titles.first {
                ThermalSimulator(simulate: simulateThermal)
            }

            if fields.isEmpty {
                Section {
                    Text("No additional fields yet.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Notification fields") {
                    ForEach(fields, id: \.name) { field in
                        Toggle(field.title, isOn: binding(for: field, in: module.category))
                            .toggleStyle(.checkbox)
                    }
                }
                .disabled(!model.isEnabled(module.category))
            }

            // Once, on the first tab: it is one switch for every module at once, and
            // repeating it on each of Network's five tabs would suggest five switches.
            if title == titles.first {
                Section {
                    Toggle("Announce what is already connected at launch", isOn: Binding(
                        get: { model.announcesWhatIsAlreadyThere },
                        set: { model.announcesWhatIsAlreadyThere = $0 }
                    ))
                    Text("Takes effect the next time the application starts. This one is for every module at once.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // On every tab, unlike the switch above: somebody who has just worked through
            // the Wi-Fi tab should not have to go and find the IP tab to undo it.
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

    /// A labelled slider with its own explanation under it, the way the original lays
    /// these out.
    private func slider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        caption: String,
        /// Spelled out by the caller: the helper started life with seconds baked in, and
        /// the first slider that was not a duration read "90 s" for a percentage.
        unit: String = "s"
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            HStack {
                Slider(value: value, in: range, step: 1)
                Text("\(Int(value.wrappedValue))\(unit)")
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Icons

    /// One row per notification: its picture, its name, and whether it arrives.
    ///
    /// The checkbox is here rather than on the subject tabs because these two questions
    /// are asked together — somebody scanning for the notification they want to silence
    /// recognises it by its icon before they read its name.
    private var iconsPane: some View {
        Form {
            Section("Module icon") {
                HStack(spacing: 8) {
                    EventIconPicker(
                        event: IconOverrideStore.moduleIconEvent,
                        category: module.category,
                        defaultIcon: module.icon,
                        store: iconOverrides
                    )
                    Text("Shown beside this module's name in the list")
                        .foregroundStyle(.secondary)
                    Spacer()
                    EventIconButtons(
                        event: IconOverrideStore.moduleIconEvent,
                        category: module.category,
                        store: iconOverrides
                    )
                }
            }

            ForEach(module.eventGroups) { group in
                Section(group.title ?? ModulePane.plainTitle) {
                    ForEach(group.rows, id: \.name) { event in
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
                            Text(event.title)
                            Spacer()
                            EventIconButtons(
                                event: event.name,
                                category: module.category,
                                store: iconOverrides
                            )
                            // A checkbox rather than a switch: this is one item in a long
                            // list of the same question, which is what checkboxes are for,
                            // and it is how the original presents it.
                            Toggle("", isOn: binding(for: event, in: module.category))
                                .labelsHidden()
                                .toggleStyle(.checkbox)
                                .disabled(!model.isEnabled(module.category))
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


/// The paragraphs some tabs carry instead of, or as well as, a list of switches.
///
/// Kept here rather than in the monitors: a monitor declares what it can say and what it
/// can be asked, and how a settings screen explains a detection technique to somebody
/// reading it is not the same kind of fact.
enum ModuleNotes {
    static func note(for category: NotificationCategory, group: String) -> String? {
        switch (category.rawValue, group) {
        case ("Network", "VPN"):
            return """
            Detected through utun/ppp/ipsec virtual interfaces, which is what most VPN             clients use, including macOS's own. It is a heuristic: a few system features             that are not VPNs use a utun interface too. Whether these arrive is a             checkbox beside "VPN connected" and "VPN disconnected" on the Icons tab.
            """
        default:
            return nil
        }
    }
}


/// Fires one thermal transition on demand, so the Serious and Critical notifications can
/// be seen without making the Mac hot.
///
/// Worth its own controls because the interesting states are the ones a Mac rarely
/// reaches: under ordinary load an M-series machine may never go past Fair, so the two
/// notifications that are on by default — and that somebody most wants to have seen once
/// before they matter — would otherwise be unverifiable.
private struct ThermalSimulator: View {
    let simulate: (ThermalState, ThermalState) -> Void

    @State private var from: ThermalState = .nominal
    @State private var to: ThermalState = .serious

    var body: some View {
        Section("Simulate Test Notification") {
            HStack {
                Picker("From:", selection: $from) { levels }
                Picker("To:", selection: $to) { levels }
            }
            HStack {
                Button("Simulate") { simulate(from, to) }
                Spacer()
            }
            Text("Fires the notification for that change without waiting for the Mac to get hot. It does not touch what the application believes the real state is.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var levels: some View {
        ForEach(ThermalState.allCases, id: \.self) { state in
            Text(state.label).tag(state)
        }
    }
}


/// The volumes whose comings and goings are not worth a notification.
///
/// Worth its own editor because the alternative is switching the whole module off. A Time
/// Machine disk that mounts on a schedule, or a virtual-machine image that mounts every
/// time a VM starts, is a notification nobody caused — and losing every other volume's
/// notifications to silence that one is a bad trade.
private struct IgnoredDrivesEditor: View {
    @Binding var drives: [String]
    @State private var selection: String?
    @State private var typed = ""

    var body: some View {
        Section("Ignored Drives") {
            Text("A volume whose name or mount path matches one of these is never announced — neither arriving nor leaving. A trailing * matches anything after it, so \"VM *\" covers every disk image whose name starts that way.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List(selection: $selection) {
                ForEach(drives, id: \.self) { drive in
                    Text(drive).tag(drive)
                }
            }
            .frame(minHeight: 90)

            HStack {
                TextField("Volume name or mount path", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add)
                    // A bare "*" would silence the module while appearing to run, and a
                    // duplicate would sit in the list doing nothing twice.
                    .disabled(!canAdd)
                Button("Remove") {
                    guard let selection else { return }
                    drives.removeAll { $0 == selection }
                    self.selection = nil
                }
                .disabled(selection == nil)
            }

            if typed.trimmingCharacters(in: .whitespaces) == "*" {
                Text("A pattern of just \"*\" would silence every volume, which is what switching the module off is for.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var canAdd: Bool {
        let pattern = typed.trimmingCharacters(in: .whitespaces)
        return !pattern.isEmpty && pattern != "*" && !drives.contains(pattern)
    }

    private func add() {
        guard canAdd else { return }
        drives.append(typed.trimmingCharacters(in: .whitespaces))
        typed = ""
    }
}
