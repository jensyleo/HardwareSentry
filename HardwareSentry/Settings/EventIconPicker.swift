import AppKit
import SignalCore
import SwiftUI
import SystemIcons

/// Lets someone put their own icon on one kind of notification.
///
/// A menu rather than a separate screen: the choice belongs next to the event it applies
/// to, and an icon is small enough to show as the control itself — what you are picking is
/// visible in the thing you pick it with.
struct EventIconPicker: View {
    let event: String
    let category: NotificationCategory
    /// What this event looks like when nobody has chosen otherwise. Shown as the control
    /// itself, so the row answers "which notification is this?" before anyone clicks —
    /// and so the button is the icon it changes rather than an abstract placeholder.
    let defaultIcon: NotificationIcon
    @Bindable var store: IconOverrideStore
    /// The operating system's picture, when this row's module is set to "System" and
    /// macOS has one — shown in place of `defaultIcon`.
    var systemImage: NSImage? = nil
    /// The state this row's notifications carry, marked on the preview whenever the
    /// picture is one that will be marked in the notification too: macOS's, or a chosen one.
    var badge: IconBadge? = nil

    @State private var isAskingForSymbol = false

    /// 32pt, the same size HG4MAC's icon rows use, scaled proportionally so a non-square
    /// image is letterboxed rather than squashed. One constant for every branch below —
    /// the branches differ in where the picture comes from, never in how big it is.
    private static let side: CGFloat = 32

    private var current: IconOverride? { store.override(for: event, in: category) }

    var body: some View {
        Menu {
            Button {
                store.setOverride(nil, for: event, in: category)
            } label: {
                Label("Use the Default", systemImage: current == nil ? "checkmark" : "arrow.uturn.backward")
            }
            // Only worth offering where the default is not already the app's own picture:
            // under a module set to System, this is how one notification keeps it.
            if systemImage != nil || current == .original {
                Button {
                    store.setOverride(.original, for: event, in: category)
                } label: {
                    Label("Use the App's Icon", systemImage: current == .original ? "checkmark" : "app")
                }
            }

            Divider()

            ForEach(Self.suggestions, id: \.self) { symbol in
                Button {
                    store.setOverride(.symbol(symbol), for: event, in: category)
                } label: {
                    Label(Self.title(for: symbol), systemImage: symbol)
                }
            }

            Divider()

            Button("Browse Symbols…") { isAskingForSymbol = true }
            Button("Choose an Image…", action: chooseFile)
        } label: {
            preview
        }
        .menuStyle(.borderlessButton)
        // The frame goes on the menu, not on the image inside it: the borderless menu
        // style measures its label through AppKit, which does not honour a SwiftUI frame
        // buried in the label's body — the icon then grows to whatever the row will give
        // it, which is the whole window. `.fixedSize()` made that worse by proposing an
        // unbounded size in the first place.
        .frame(width: Self.side + 14, height: Self.side)
        .overlay(alignment: .bottomTrailing) {
            if let badge, current != .original, current != nil || systemImage != nil {
                // Over the picture, not the menu's indicator beside it.
                IconBadgeView(badge: badge, iconSide: Self.side)
                    .padding(.trailing, 14)
                    .allowsHitTesting(false)
            }
        }
        .help(helpText)
        .popover(isPresented: $isAskingForSymbol, arrowEdge: .bottom) {
            SFSymbolBrowser(
                currentSymbol: { () -> String? in if case .symbol(let name) = current { return name }; return nil }(),
                onChoose: { symbol in
                    store.setOverride(.symbol(symbol), for: event, in: category)
                    isAskingForSymbol = false
                },
                onCancel: { isAskingForSymbol = false }
            )
        }
    }

    // MARK: - The control itself

    /// Built as a fixed-size `NSImage` rather than a `.resizable()` SwiftUI image: a
    /// resizable image has no intrinsic size, so the `Menu` wrapping it is told the label
    /// wants all the room there is and the icon fills the window. The same thing HG4MAC
    /// does with a 32pt-constrained `NSImageView`.
    private var preview: some View {
        Image(nsImage: resolvedImage)
            .frame(width: Self.side, height: Self.side)
    }

    private var resolvedImage: NSImage {
        let fallback = NSImage(
            systemSymbolName: "questionmark.square.dashed",
            accessibilityDescription: nil
        )?.resized(toFit: Self.side)

        switch current {
        case .symbol(let name):
            // A name that names nothing would otherwise render as a blank control, which
            // reads as a broken picker rather than as a typo.
            return NotificationIcon.symbol(name).image(side: Self.side)
                ?? fallback
                ?? NSImage(size: NSSize(width: Self.side, height: Self.side))
        case .file(let path):
            // The copy is gone — deleted by hand from Application Support. Said here
            // rather than only when the notification fires, so it can be fixed before
            // anyone misses an icon.
            return NSImage(contentsOfFile: path)?.resized(toFit: Self.side)
                ?? NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)?
                    .resized(toFit: Self.side)
                ?? NSImage(size: NSSize(width: Self.side, height: Self.side))
        case .original:
            return defaultIcon.image(side: Self.side)
                ?? NSApplication.shared.applicationIconImage?.resized(toFit: Self.side)
                ?? NSImage(size: NSSize(width: Self.side, height: Self.side))
        case nil:
            if let systemImage { return systemImage.resized(toFit: Self.side) }
            return defaultIcon.image(side: Self.side)
                ?? NSApplication.shared.applicationIconImage?.resized(toFit: Self.side)
                ?? NSImage(size: NSSize(width: Self.side, height: Self.side))
        }
    }

    private var helpText: String {
        switch current {
        case .symbol(let name): return "Icon: \(name)"
        case .original: return "This application's own icon, kept even though the module uses macOS's pictures"
        case .file(let path):
            return NSImage(contentsOfFile: path) == nil
                ? "This image is missing — the default icon will be used instead"
                : "Icon: \((path as NSString).lastPathComponent)"
        case nil:
            return systemImage == nil
                ? "This notification's own icon — click to choose a different one"
                : "macOS's own picture of this device — click to choose a different one"
        }
    }

    // MARK: - Choosing

    private func chooseFile() {
        CustomIconChooser.choose(for: event, in: category, store: store)
    }

    // MARK: - Suggestions

    /// A short list rather than the whole of SF Symbols. A menu of five thousand entries
    /// is not a chooser, it is a haystack; anyone who knows the name they want can type it.
    private static let suggestions = [
        "bell.fill", "bolt.fill", "exclamationmark.triangle.fill", "checkmark.circle.fill",
        "xmark.octagon.fill", "star.fill", "flag.fill", "heart.fill",
        "eye.fill", "lock.fill", "wifi", "cable.connector"
    ]

    /// The symbol's own name, tidied into something readable — no separate table to keep
    /// in step with the list above.
    private static func title(for symbol: String) -> String {
        symbol
            .replacingOccurrences(of: ".fill", with: "")
            .split(separator: ".")
            .map(\.capitalized)
            .joined(separator: " ")
    }
}

/// The same three choices as the picker's menu, as buttons you can see.
///
/// The menu is quicker once you know it is there; three labelled buttons say what is on
/// offer without anyone having to click the icon to find out. Both act on the same stored
/// override, so whichever route somebody takes, the other reflects it immediately.
///
/// "Symbol" and "Custom" draw the line where it actually falls: a symbol that macOS draws
/// and scales at any size, or a picture from a file that stays whatever it is. Not
/// "System", which the module-wide choice above uses for macOS's own device pictures.
struct EventIconButtons: View {
    let event: String
    let category: NotificationCategory
    @Bindable var store: IconOverrideStore
    /// Whether, with nothing chosen, this icon would be macOS's picture — the only case
    /// where asking for the app's own picture changes anything.
    var systemWouldApply: Bool = false

    @State private var isAskingForSymbol = false

    private var current: IconOverride? { store.override(for: event, in: category) }

    var body: some View {
        HStack(spacing: 6) {
            Button("App") { store.setOverride(.original, for: event, in: category) }
                .disabled(current == .original || (current == nil && !systemWouldApply))
                .help("Keep this application's own icon here, even with the module set to System")

            Button("Custom", action: chooseFile)
                .help("Use a picture from a file")

            Button("Symbol") { isAskingForSymbol = true }
                .help("Browse the system's own symbols, or type one by name")
                .popover(isPresented: $isAskingForSymbol, arrowEdge: .bottom) {
                    SFSymbolBrowser(
                        currentSymbol: { () -> String? in if case .symbol(let name) = current { return name }; return nil }(),
                        onChoose: { symbol in
                            store.setOverride(.symbol(symbol), for: event, in: category)
                            isAskingForSymbol = false
                        },
                        onCancel: { isAskingForSymbol = false }
                    )
                }

            Button("Reset") { store.setOverride(nil, for: event, in: category) }
                // Nothing to undo when the icon is already the one the module ships with,
                // and a button that does nothing is worse than one that is plainly unavailable.
                .disabled(current == nil)
                .help("Back to whatever the module's App/System setting gives this notification")
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
    }

    private func chooseFile() {
        CustomIconChooser.choose(for: event, in: category, store: store)
    }
}
