import AppKit
import SentryContract
import SignalCore
import SwiftUI
import SystemIcons

/// Shows how any notification looks, without waiting for the hardware to do it.
///
/// Every event of every module is listed with its picture as it will really be drawn — the
/// operating system's own where the module is set to System, this application's otherwise —
/// and one button per state it can be in. Pressing one puts a real banner on screen, through
/// the same icon choices the live ones go through, so a change to a setting or to a picture
/// can be judged where it matters: in the notification itself.
///
/// The preview always draws the state mark. This application's own pictures draw their state
/// into the artwork today, so the mark there is extra, but that is the direction the artwork
/// is going and the mark is what the replacement pictures will rely on.
struct NotificationPreviewView: View {
    @Bindable var model: EventSettingsModel
    @Bindable var iconSources: IconSourceModel
    let show: (MonitorEventDescription, NotificationCategory, IconBadge?, IconSource) -> Void

    /// Sends somebody to the Notifications tab, on this module's icons.
    let editIcons: (String, String?) -> Void

    @State private var selection: String?
    /// Chosen here, only for looking: the module's saved choice is left alone. Nil follows it.
    @State private var viewedSource: IconSource?

    private func source(in category: NotificationCategory) -> IconSource {
        viewedSource ?? iconSources.source(for: category)
    }

    private var module: MonitorDescription? {
        model.modules.first { $0.id == selection } ?? model.modules.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Module", selection: Binding(get: { module?.id ?? "" }, set: { selection = $0; viewedSource = nil })) {
                    ForEach(model.modules) { module in Text(module.category.rawValue).tag(module.id) }
                }
                .frame(maxWidth: 260)
                if let module {
                    Picker("Icons", selection: $viewedSource) {
                        Text("Configured").tag(IconSource?.none)
                        Text("App").tag(IconSource?.some(.app))
                        Text("System").tag(IconSource?.some(.system))
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .help("Configured shows what you have set. App and System are for comparing; they change nothing.")
                }
                Spacer()
                if let module {
                    Button { editIcons(module.id, nil) } label: {
                        Label("Edit icons in Notifications", systemImage: "pencil")
                    }
                    .controlSize(.small)
                    .help("Opens this module's icons in the Notifications tab, where they are chosen")
                }
            }
            .padding([.horizontal, .top])

            if let module {
                Form {
                    Section {
                        ForEach(module.events, id: \.name) { event in
                            row(for: event, in: module.category)
                        }
                    } footer: {
                        Text("Each button shows a real banner. It does not change anything on this Mac, is not added to the history, and shows even for a notification that is switched off.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
                .task(id: module.id) {
                    await iconSources.load(kinds: module.events.compactMap { $0.iconKind?.rawValue })
                }
            }
        }
        .task { await iconSources.loadModuleImages() }
    }

    @ViewBuilder
    private func row(for event: MonitorEventDescription, in category: NotificationCategory) -> some View {
        HStack(spacing: 10) {
            // A symbol is drawn in the text colour: scaled into a bitmap it would come out
            // black, which cannot be seen on a dark window.
            if case .symbol(let name) = event.icon,
               !(source(in: category) == .system && iconSources.image(forKind: event.iconKind?.rawValue) != nil) {
                Image(systemName: name)
                    .resizable().aspectRatio(contentMode: .fit)
                    .foregroundStyle(.secondary)
                    .padding(4)
                    .frame(width: 36, height: 36)
            } else {
                Image(nsImage: picture(for: event, in: category))
                    .frame(width: 36, height: 36)
            }
            Text(event.title)
            Button { editIcons(model.modules.first { $0.category == category }?.id ?? "", event.name) } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit this notification's icon")
            Spacer()
            if let offered = offeredStates(for: event, in: category) {
                // This notification says only these things, so only these are offered: a
                // banner the real notification can never produce is not worth previewing.
                ForEach(Array(offered.enumerated()), id: \.offset) { _, state in
                    if let badge = state.badge {
                        stateButton(state.label, systemImage: Self.symbol(for: badge), tint: Self.tint(for: badge), event, category, badge)
                    } else {
                        Button(state.label) { show(event, category, nil, source(in: category)) }.controlSize(.small)
                    }
                }
            } else if event.iconKind != nil {
                // A device row covers a device arriving, leaving, flapping and misbehaving.
                stateButton("Connected", systemImage: "checkmark.circle.fill", tint: .green, event, category, .positive)
                stateButton("Gone", systemImage: "xmark.circle.fill", tint: .red, event, category, .negative)
                Button { showUnstable(event, category) } label: {
                    Label("Unstable", systemImage: "waveform.path.ecg").foregroundStyle(.yellow)
                }
                .controlSize(.small).labelStyle(.titleAndIcon)
                .help("Show the notice for a device that keeps connecting and disconnecting")
                stateButton("Attention", systemImage: "exclamationmark.triangle.fill", tint: .yellow, event, category, .warning)
            } else {
                Button("Show") { show(event, category, nil, source(in: category)) }
                    .controlSize(.small)
            }
        }
    }

    private struct OfferedState { let label: String; let badge: IconBadge? }

    private static func symbol(for badge: IconBadge) -> String {
        switch badge {
        case .positive: "checkmark.circle.fill"
        case .negative: "xmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .favorite: "star.circle.fill"
        case .blocked: "minus.circle.fill"
        case .ink: "drop.circle.fill"
        }
    }

    private static func tint(for badge: IconBadge) -> Color {
        switch badge {
        case .positive: .green
        case .negative: .red
        case .warning: .yellow
        case .favorite: .yellow
        case .blocked, .ink: .red
        }
    }

    /// Notifications that say two particular things, whatever their name suggests.
    private static let twoStates: [String: [OfferedState]] = [
        "DisplaySleepChanged": [.init(label: "Slept", badge: .negative), .init(label: "Woke", badge: .positive)],
        "PrinterError": [.init(label: "Needs attention", badge: .warning), .init(label: "OK again", badge: .positive)],
        "PrinterRejectingJobs": [.init(label: "Rejecting", badge: .blocked), .init(label: "Accepting", badge: .positive)],
        "PrinterSupplyLow": [.init(label: "Running low", badge: .ink)],
        "PrinterDefaultChanged": [.init(label: "Default", badge: .favorite)],
        "PrintJobCanceled": [.init(label: "Cancelled", badge: .blocked)],
        "PrintJobFinished": [.init(label: "Finished", badge: .positive)],
        "WifiHostAPModeChanged": [.init(label: "Started", badge: .positive), .init(label: "Stopped", badge: .negative)],
        "LowPowerMode": [.init(label: "On", badge: .positive), .init(label: "Off", badge: .negative)],
    ]

    /// What this notification can actually be, or nil for a device row that covers arrival,
    /// departure and trouble alike.
    ///
    /// Read from the name, and from whether the module has a separate notification for the
    /// opposite direction: "Joined a Wi-Fi network" and "Left a Wi-Fi network" each say one
    /// thing. A change with no direction — a speed, a resolution, a default — says nothing
    /// about being good or bad, so it is shown plainly.
    private func offeredStates(for event: MonitorEventDescription, in category: NotificationCategory) -> [OfferedState]? {
        if let two = Self.twoStates[event.name] { return two }
        let state = IconBadge.representative(forEventName: event.name)
        if state == .warning { return [.init(label: "Attention", badge: .warning)] }

        let names = Set((model.modules.first { $0.category == category }?.events ?? []).map(\.name))
        let pairs: [(String, String)] = [
            ("Disconnected", "Connected"), ("Unmounted", "Mounted"), ("Lost", "Found"), ("Removed", "Added"),
            ("Detaching", "Attaching"), ("LinkDown", "LinkUp"), ("Unpaired", "Paired"), ("RadioOff", "RadioOn"),
            ("NotResponding", "Responding"), ("Off", "On"),
        ]
        if let state {
            for (negative, positive) in pairs {
                if state == .negative, event.name.contains(negative),
                   names.contains(event.name.replacingOccurrences(of: negative, with: positive)) {
                    return [.init(label: "Gone", badge: .negative)]
                }
                if state == .positive, event.name.contains(positive), !event.name.contains(negative),
                   names.contains(event.name.replacingOccurrences(of: positive, with: negative)) {
                    return [.init(label: "Connected", badge: .positive)]
                }
            }
            return nil
        }
        // No direction in the name: a change is shown as it is, unmarked.
        let neutral = ["Changed", "Renewed", "Detected", "Status", "Started", "Finished", "Canceled", "Sleep", "Wake"]
        if neutral.contains(where: event.name.contains) { return [.init(label: "Show", badge: nil)] }
        return nil
    }

    private func showUnstable(_ event: MonitorEventDescription, _ category: NotificationCategory) {
        show(MonitorEventDescription(name: "FlapDetected", title: "Unstable", icon: event.icon, iconKind: event.iconKind),
             category, .warning, source(in: category))
    }

    private func stateButton(
        _ title: String, systemImage: String, tint: Color,
        _ event: MonitorEventDescription, _ category: NotificationCategory, _ badge: IconBadge
    ) -> some View {
        Button { show(event, category, badge, source(in: category)) } label: {
            Label(title, systemImage: systemImage).foregroundStyle(tint)
        }
        .controlSize(.small)
        .labelStyle(.titleAndIcon)
        .help("Show this notification as \(title.lowercased())")
    }

    /// The picture the live notification would start from: macOS's for a module on System
    /// where it has one, the module's own otherwise.
    private func picture(for event: MonitorEventDescription, in category: NotificationCategory) -> NSImage {
        let side: CGFloat = 36
        return (source(in: category) == .system ? iconSources.image(forKind: event.iconKind?.rawValue) : nil)?.resized(toFit: side)
            ?? event.icon.image(side: side)
            ?? NSImage(size: NSSize(width: side, height: side))
    }
}
