import AppKit
import SignalCore
import SystemIcons

/// Asks for a picture and keeps a private copy of it as one notification's icon.
///
/// One place for both routes to the same choice — the icon's own menu and the "Custom"
/// button beside it — so they cannot drift apart in what they accept or where they keep it.
@MainActor
enum CustomIconChooser {
    static func choose(for event: String, in category: NotificationCategory, store: IconOverrideStore) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Use as Icon"
        panel.message = "Choose an image for this notification. HardwareSentry keeps its own copy, so the original can be moved or deleted afterwards."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            guard let library = CustomIconLibrary.standard() else { throw CustomIconLibrary.ImportError.couldNotSave }
            let stored = try library.importImage(from: url)
            store.setOverride(.file(stored), for: event, in: category)
        } catch {
            let alert = NSAlert()
            alert.messageText = "This picture cannot be used as an icon"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
