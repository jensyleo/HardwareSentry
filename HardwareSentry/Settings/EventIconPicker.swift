import AppKit
import SignalCore
import SwiftUI

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

    @State private var isAskingForSymbol = false
    @State private var typedSymbol = ""

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

            Divider()

            ForEach(Self.suggestions, id: \.self) { symbol in
                Button {
                    store.setOverride(.symbol(symbol), for: event, in: category)
                } label: {
                    Label(Self.title(for: symbol), systemImage: symbol)
                }
            }

            Divider()

            Button("Another Symbol…") {
                typedSymbol = if case .symbol(let name) = current { name } else { "" }
                isAskingForSymbol = true
            }
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
        .help(helpText)
        .popover(isPresented: $isAskingForSymbol, arrowEdge: .bottom) {
            symbolEntry
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
            // The file moved. Said here rather than only when the notification fires, so
            // it can be fixed before anyone misses an icon.
            return NSImage(contentsOfFile: path)?.resized(toFit: Self.side)
                ?? NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)?
                    .resized(toFit: Self.side)
                ?? NSImage(size: NSSize(width: Self.side, height: Self.side))
        case nil:
            return defaultIcon.image(side: Self.side)
                ?? NSApplication.shared.applicationIconImage?.resized(toFit: Self.side)
                ?? NSImage(size: NSSize(width: Self.side, height: Self.side))
        }
    }

    private var helpText: String {
        switch current {
        case .symbol(let name): return "Icon: \(name)"
        case .file(let path):
            return NSImage(contentsOfFile: path) == nil
                ? "This image is missing — the default icon will be used instead"
                : "Icon: \((path as NSString).lastPathComponent)"
        case nil: return "This notification's own icon — click to choose a different one"
        }
    }

    // MARK: - Choosing

    private var symbolEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SF Symbol name").font(.headline)
            HStack {
                TextField("bolt.fill", text: $typedSymbol)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .onSubmit(commitTypedSymbol)
                if !typedSymbol.isEmpty {
                    Image(systemName: NSImage(systemSymbolName: typedSymbol, accessibilityDescription: nil) != nil
                          ? typedSymbol : "questionmark.square.dashed")
                }
            }
            Text("Any symbol name from Apple's SF Symbols application.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { isAskingForSymbol = false }
                Button("Use It", action: commitTypedSymbol)
                    .keyboardShortcut(.defaultAction)
                    // A name that resolves to nothing would be a setting that silently
                    // does nothing, so it cannot be committed in the first place.
                    .disabled(NSImage(systemSymbolName: typedSymbol, accessibilityDescription: nil) == nil)
            }
        }
        .padding()
    }

    private func commitTypedSymbol() {
        guard NSImage(systemSymbolName: typedSymbol, accessibilityDescription: nil) != nil else { return }
        store.setOverride(.symbol(typedSymbol), for: event, in: category)
        isAskingForSymbol = false
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Use as Icon"
        panel.message = "Choose an image for this notification."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.setOverride(.file(url.path), for: event, in: category)
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
/// "System" and "Custom" are the original's words, and they draw the line where it actually
/// falls: a symbol that macOS draws and scales at any size, or a picture from a file that
/// stays whatever it is.
struct EventIconButtons: View {
    let event: String
    let category: NotificationCategory
    @Bindable var store: IconOverrideStore

    @State private var isAskingForSymbol = false
    @State private var typedSymbol = ""

    private var current: IconOverride? { store.override(for: event, in: category) }

    var body: some View {
        HStack(spacing: 6) {
            Button("Custom", action: chooseFile)
                .help("Use a picture from a file")

            Button("System") {
                typedSymbol = if case .symbol(let name) = current { name } else { "" }
                isAskingForSymbol = true
            }
            .help("Use one of the system's own symbols, by name")
            .popover(isPresented: $isAskingForSymbol, arrowEdge: .bottom) {
                symbolEntry
            }

            Button("Reset") { store.setOverride(nil, for: event, in: category) }
                // Nothing to undo when the icon is already the one the module ships with,
                // and a button that does nothing is worse than one that is plainly unavailable.
                .disabled(current == nil)
                .help("Back to this notification's own icon")
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
    }

    private var symbolEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SF Symbol name").font(.headline)
            HStack {
                TextField("bolt.fill", text: $typedSymbol)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .onSubmit(commitTypedSymbol)
                if !typedSymbol.isEmpty {
                    Image(systemName: NSImage(systemSymbolName: typedSymbol, accessibilityDescription: nil) != nil
                          ? typedSymbol : "questionmark.square.dashed")
                }
            }
            Text("Any symbol name from Apple's SF Symbols application.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { isAskingForSymbol = false }
                Button("Use It", action: commitTypedSymbol)
                    .keyboardShortcut(.defaultAction)
                    // A name that resolves to nothing would be a setting that silently
                    // does nothing, so it cannot be committed in the first place.
                    .disabled(NSImage(systemSymbolName: typedSymbol, accessibilityDescription: nil) == nil)
            }
        }
        .padding()
    }

    private func commitTypedSymbol() {
        guard NSImage(systemSymbolName: typedSymbol, accessibilityDescription: nil) != nil else { return }
        store.setOverride(.symbol(typedSymbol), for: event, in: category)
        isAskingForSymbol = false
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Use as Icon"
        panel.message = "Choose an image for this notification."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.setOverride(.file(url.path), for: event, in: category)
    }
}
