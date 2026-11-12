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
    let editIcons: (String) -> Void

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
                    Button { editIcons(module.id) } label: {
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
            Spacer()
            if event.iconKind != nil {
                // A device has three things that can be said about it.
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
