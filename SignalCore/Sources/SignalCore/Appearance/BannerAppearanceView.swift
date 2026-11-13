import AppKit
import SwiftUI

/// Lets a person set how banners look, with a live example of the result.
///
/// Part of the package rather than of any one application: every application built on
/// this draws the same banners and therefore wants the same settings, and none of them
/// should have to write this twice. It knows nothing about events or hardware — an
/// application pairs it with its own screen for choosing which notifications it wants.
public struct BannerAppearanceView: View {
    @Bindable private var store: BannerAppearanceStore
    @Bindable private var themes: BannerThemeStore
    private let showTest: (() -> Void)?
    @State private var newThemeName = ""
    @State private var message: String?

    /// `showTest`, when given, puts a real banner on screen with the settings as they stand —
    /// the application supplies it because only it knows how to deliver one.
    private let moduleNames: [String]

    public init(store: BannerAppearanceStore, themes: BannerThemeStore = BannerThemeStore(), moduleNames: [String] = [], showTest: (() -> Void)? = nil) {
        self.moduleNames = moduleNames
        self.store = store
        self.themes = themes
        self.showTest = showTest
    }

    public var body: some View {
        Form {
            Section("Preview") {
                preview
                if let showTest {
                    HStack {
                        Spacer()
                        Button("Show a real notification", action: showTest)
                            .help("Puts a banner on screen, in the corner and display chosen below")
                    }
                }
            }

            themeSection

            Section("Placement") {
                Picker("Display", selection: $store.appearance.screen) {
                    ForEach(BannerScreen.allCases) { screen in
                        Text(screen.label).tag(screen)
                    }
                }
                // Said rather than hidden: a control whose every option does the same
                // thing looks broken until you know why.
                if NSScreen.screens.count < 2 {
                    Text("With one display connected, every choice is that display.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Picker("Corner", selection: $store.appearance.corner) {
                    ForEach(BannerCorner.allCases, id: \.self) { corner in
                        Text(corner.label).tag(corner)
                    }
                }

                slider(
                    "Distance from edge",
                    value: $store.appearance.margin,
                    range: BannerAppearance.marginRange,
                    format: { "\(Int($0)) pt" }
                )
            }

            Section("Appearance") {
                slider(
                    "Width",
                    value: $store.appearance.width,
                    range: BannerAppearance.widthRange,
                    format: { "\(Int($0)) pt" }
                )

                Picker("Text size", selection: $store.appearance.textScale) {
                    ForEach(BannerTextScale.allCases, id: \.self) { scale in
                        Text(scale.label).tag(scale)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Background", selection: $store.appearance.material) {
                    ForEach(BannerMaterial.allCases, id: \.self) { material in
                        Text(material.label).tag(material)
                    }
                }

                Toggle("Custom tint", isOn: customTintBinding)

                if store.appearance.tint.isCustom {
                    ColorPicker("Tint colour", selection: customColorBinding, supportsOpacity: false)
                    Text("Overlaid on the material above, not instead of it — a flat colour with nothing behind it would not adapt to light and dark.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                slider(
                    "Opacity",
                    value: $store.appearance.opacity,
                    range: BannerAppearance.opacityRange,
                    format: { "\(Int($0 * 100))%" }
                )
            }

            Section("Shape") {
                slider("Corner radius", value: $store.appearance.cornerRadius, range: BannerAppearance.cornerRadiusRange, format: { "\(Int($0)) pt" })
                slider("Outline", value: $store.appearance.borderWidth, range: BannerAppearance.borderWidthRange, format: { $0 < 0.1 ? "None" : String(format: "%.1f pt", $0) })
                slider("Inner spacing", value: $store.appearance.padding, range: BannerAppearance.paddingRange, format: { "\(Int($0)) pt" })
                Toggle("Show the picture", isOn: $store.appearance.showsIcon)
                if store.appearance.showsIcon {
                    slider("Picture size", value: $store.appearance.iconScale, range: BannerAppearance.iconScaleRange, format: { "\(Int($0 * 100))%" })
                }
                Stepper(
                    store.appearance.maximumBodyLines == 0 ? "Body lines: all" : "Body lines: at most \(store.appearance.maximumBodyLines)",
                    value: $store.appearance.maximumBodyLines,
                    in: BannerAppearance.bodyLinesRange
                )
            }

            Section("By kind of notice") {
                ForEach(BannerSeverity.allCases) { severity in
                    severityRow(severity)
                }
                Text("Each kind can have an outline colour and a sound of its own, and can stay until it is closed — a warning that matters should not be able to slip away while you look elsewhere.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if !moduleNames.isEmpty {
                Section("By module") {
                    ForEach(moduleNames, id: \.self) { name in
                        Picker(name, selection: Binding(
                            get: { store.appearance.moduleSounds[name] },
                            set: { chosen in
                                store.appearance.moduleSounds[name] = chosen
                                if let sound = chosen?.systemName { NSSound(named: sound)?.play() }
                            }
                        )) {
                            Text("Same as the others").tag(BannerSound?.none)
                            ForEach(BannerSound.allCases, id: \.self) { Text($0.label).tag(BannerSound?.some($0)) }
                        }
                    }
                    Text("A kind of notice with a sound of its own wins over its module's.").font(.caption).foregroundStyle(.secondary)
                    ForEach(moduleNames, id: \.self) { name in
                        Picker("\(name) stays", selection: Binding(
                            get: { store.appearance.moduleLifetimes[name] },
                            set: { store.appearance.moduleLifetimes[name] = $0 }
                        )) {
                            Text("As long as the others").tag(TimeInterval?.none)
                            ForEach([3.0, 5, 8, 12, 20, 30], id: \.self) { Text("\(Int($0)) seconds").tag(TimeInterval?.some($0)) }
                        }
                    }
                }
            }

            quietHoursSection

            Section("Behaviour") {
                slider(
                    "Stays on screen for",
                    value: $store.appearance.visibleLifetime,
                    range: BannerAppearance.lifetimeRange,
                    format: { "\(Int($0))s" }
                )

                Stepper(
                    "At most \(store.appearance.maximumVisible) at a time",
                    value: $store.appearance.maximumVisible,
                    in: BannerAppearance.maximumVisibleRange
                )

                slider(
                    "One appears every",
                    value: $store.appearance.revealSpacing,
                    range: BannerAppearance.revealSpacingRange,
                    format: { $0 < 0.05 ? "All at once" : String(format: "%.2fs", $0) }
                )
                Text("Anything over the limit waits its turn. Letting them in one at a time is also what makes them leave one at a time, instead of a whole screenful blinking out together.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Slide in and out", isOn: $store.appearance.isAnimated)

                if store.appearance.isAnimated {
                    slider(
                        "Animation duration",
                        value: $store.appearance.animationDuration,
                        range: BannerAppearance.animationDurationRange,
                        format: { String(format: "%.2fs", $0) }
                    )
                }

                Picker("Sound", selection: $store.appearance.sound) {
                    ForEach(BannerSound.allCases, id: \.self) { sound in
                        Text(sound.label).tag(sound)
                    }
                }
                // Played on choosing, because picking a sound from a list of names without
                // hearing it is guessing.
                .onChange(of: store.appearance.sound) { _, chosen in
                    if let name = chosen.systemName { NSSound(named: name)?.play() }
                }

                Text("Silent while the application is starting up, so everything already plugged in is announced without a burst of chimes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Spacer()
                    Button("Restore Defaults") { store.reset() }
                        .disabled(store.appearance == .standard)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// The real banner view, drawn with the settings as they stand — not an illustration
    /// of one, so what is on screen here is exactly what will arrive later.
    private var preview: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(Self.samples.enumerated()), id: \.offset) { _, sample in
                    BannerView(
                        content: sample,
                        appearance: store.appearance,
                        onActivate: {},
                        onDismiss: {}
                    )
                    .opacity(store.appearance.opacity)
                }
            }
            .padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity)
    }

    private var themeSection: some View {
        Section("Themes") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(themes.all) { theme in
                    let isCurrent = theme.matches(store.appearance)
                    Button {
                        store.appearance = theme.applied(to: store.appearance)
                    } label: {
                        Text(theme.name).lineLimit(1).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(isCurrent ? .accentColor : nil)
                    .contextMenu {
                        if !themes.isBuiltIn(theme) { Button("Delete “\(theme.name)”", role: .destructive) { themes.delete(theme) } }
                    }
                }
            }
            HStack {
                TextField("Name for this look", text: $newThemeName)
                Button("Save as theme") {
                    if themes.save(name: newThemeName, from: store.appearance) { newThemeName = ""; message = "Saved." }
                    else { message = "Give it a name that is not one of the built-in themes." }
                }
                .disabled(newThemeName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Picker("In light mode use", selection: $themes.lightThemeName) {
                Text("Leave as it is").tag(String?.none)
                ForEach(themes.all) { Text($0.name).tag(String?.some($0.name)) }
            }
            Picker("In dark mode use", selection: $themes.darkThemeName) {
                Text("Leave as it is").tag(String?.none)
                ForEach(themes.all) { Text($0.name).tag(String?.some($0.name)) }
            }
            HStack {
                Button("Export my themes…") { exportThemes() }.disabled(themes.custom.isEmpty)
                Button("Import…") { importThemes() }
                Spacer()
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            Text("A theme is only a look — it never moves a banner to another corner, changes how long it stays or turns a sound on. Right-click one of your own themes to delete it.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var quietHoursSection: some View {
        Section("Quiet hours") {
            Toggle("Keep quiet on a schedule", isOn: $store.appearance.quietHours.isEnabled)
            if store.appearance.quietHours.isEnabled {
                DatePicker("From", selection: minuteBinding(\.startMinute), displayedComponents: .hourAndMinute)
                DatePicker("Until", selection: minuteBinding(\.endMinute), displayedComponents: .hourAndMinute)
                HStack {
                    ForEach(Array(Calendar.current.shortWeekdaySymbols.enumerated()), id: \.offset) { index, symbol in
                        let day = index + 1
                        Toggle(symbol, isOn: Binding(
                            get: { store.appearance.quietHours.weekdays.contains(day) },
                            set: { on in
                                if on { store.appearance.quietHours.weekdays.insert(day) } else { store.appearance.quietHours.weekdays.remove(day) }
                            }
                        ))
                        .toggleStyle(.button)
                    }
                }
                Picker("During quiet hours", selection: $store.appearance.quietHours.mode) {
                    ForEach(QuietHours.Mode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("Notices that need attention still come through", isOn: $store.appearance.quietHours.attentionBreaksThrough)
                Text("The history still records everything. A span that ends before it starts runs overnight, and belongs to the day it starts on.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// A time of day held as minutes after midnight, as the date picker wants it.
    private func minuteBinding(_ keyPath: WritableKeyPath<QuietHours, Int>) -> Binding<Date> {
        Binding(
            get: {
                let minutes = store.appearance.quietHours[keyPath: keyPath]
                return Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                store.appearance.quietHours[keyPath: keyPath] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }

    private func severityRow(_ severity: BannerSeverity) -> some View {
        let style = store.appearance.style(for: severity)
        return DisclosureGroup {
            Toggle("Outline colour", isOn: Binding(
                get: { style.accent != nil },
                set: { on in update(severity) { $0.accent = on ? Self.suggestedAccent(for: severity) : nil } }
            ))
            if let accent = style.accent, accent.count == 3 {
                ColorPicker("Colour", selection: Binding(
                    get: { Color(red: accent[0], green: accent[1], blue: accent[2]) },
                    set: { color in
                        let c = color.resolve(in: EnvironmentValues())
                        update(severity) { $0.accent = [Double(c.red), Double(c.green), Double(c.blue)] }
                    }
                ), supportsOpacity: false)
            }
            Picker("Sound", selection: Binding(
                get: { style.sound },
                set: { chosen in
                    update(severity) { $0.sound = chosen }
                    if let name = chosen?.systemName { NSSound(named: name)?.play() }
                }
            )) {
                Text("Same as the others").tag(BannerSound?.none)
                ForEach(BannerSound.allCases, id: \.self) { Text($0.label).tag(BannerSound?.some($0)) }
            }
            Toggle("Stays until I close it", isOn: Binding(
                get: { style.staysUntilDismissed },
                set: { on in update(severity) { $0.staysUntilDismissed = on } }
            ))
        } label: {
            HStack {
                Text(severity.label)
                Spacer()
                if !style.isDefault { Text("customised").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private func update(_ severity: BannerSeverity, _ change: (inout BannerSeverityStyle) -> Void) {
        var style = store.appearance.style(for: severity)
        change(&style)
        if style.isDefault { store.appearance.severityStyles[severity] = nil } else { store.appearance.severityStyles[severity] = style }
    }

    private static func suggestedAccent(for severity: BannerSeverity) -> [Double] {
        switch severity {
        case .info: return [0.35, 0.55, 0.95]
        case .connected: return [0.2, 0.75, 0.4]
        case .gone: return [0.9, 0.3, 0.3]
        case .attention: return [0.95, 0.75, 0.15]
        }
    }

    private func exportThemes() {
        guard let data = themes.exportData() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "banner-themes.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        message = (try? data.write(to: url)) == nil ? "Could not write the file." : "Exported."
    }

    private func importThemes() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        if let added = themes.importData(data) { message = "Imported \(added) theme\(added == 1 ? "" : "s")." } else { message = "That file is not a set of themes." }
    }

    /// One of each kind of notice, so a look is judged on all three at once.
    private static let samples: [BannerContent] = [
        BannerContent(event: NotificationEvent(
            name: "PreviewSample", category: "Preview", title: "USB Device Connected",
            body: "SanDisk Cruzer\nCapacity: 64 GB\nSpeed: USB 3.0",
            icon: .symbol("externaldrive.connected.to.line.below"), iconBadge: .positive, showsIconBadge: true)),
        BannerContent(event: NotificationEvent(
            name: "PreviewSample", category: "Preview", title: "Battery Low",
            body: "12 % remaining\nAbout 20 minutes left",
            icon: .symbol("battery.25percent"), iconBadge: .warning, showsIconBadge: true)),
        BannerContent(event: NotificationEvent(
            name: "PreviewSample", category: "Preview", title: "Disk Not Readable",
            body: "Backup Drive\nIt may need repair",
            icon: .symbol("exclamationmark.triangle"), iconBadge: .negative, showsIconBadge: true)),
    ]

    /// Whether a custom tint is chosen, as a plain `Bool` a `Toggle` can bind to —
    /// switching it on picks a starting colour rather than leaving `.custom` uninitialised
    /// with nothing behind it; switching it off drops back to the system material exactly.
    private var customTintBinding: Binding<Bool> {
        Binding(
            get: { store.appearance.tint.isCustom },
            set: { isOn in
                store.appearance.tint = isOn ? .custom(red: 0.2, green: 0.4, blue: 0.9) : .systemMaterial
            }
        )
    }

    /// The custom tint's colour, as a `Color` a `ColorPicker` can bind to. Reads the
    /// standing colour while custom is chosen; if somehow read while it is not (the
    /// picker is hidden in that case, so this is only ever a fallback), it hands back
    /// exactly what `customTintBinding`'s own default would set.
    private var customColorBinding: Binding<Color> {
        Binding(
            get: {
                if case .custom(let red, let green, let blue) = store.appearance.tint {
                    return Color(red: red, green: green, blue: blue)
                }
                return Color(red: 0.2, green: 0.4, blue: 0.9)
            },
            set: { color in
                let resolved = color.resolve(in: EnvironmentValues())
                store.appearance.tint = .custom(
                    red: Double(resolved.red),
                    green: Double(resolved.green),
                    blue: Double(resolved.blue)
                )
            }
        )
    }

    private func slider<V: BinaryFloatingPoint>(
        _ title: String,
        value: Binding<V>,
        range: ClosedRange<V>,
        format: @escaping (V) -> String
    ) -> some View where V.Stride: BinaryFloatingPoint {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range)
                Text(format(value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
        }
    }
}
