import Foundation
import SentryContract

/// One page of the help window.
///
/// The prose pages are written out; the module reference is built from what the monitors
/// declare about themselves, so it cannot describe a notification that no longer exists or
/// miss one that was just added. Documentation generated from the thing it documents is the
/// only kind that stays true.
struct HelpTopic: Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String
    let sections: [HelpSection]

    static func == (lhs: HelpTopic, rhs: HelpTopic) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct HelpSection: Identifiable, Hashable {
    let id = UUID()
    var heading: String?
    var paragraphs: [String] = []
    /// Term-and-explanation rows, for settings and events.
    var rows: [Row] = []

    struct Row: Identifiable, Hashable {
        let id = UUID()
        let term: String
        let detail: String
        /// A quiet tag beside the term — "On by default", a unit, a default value.
        var note: String?
    }
}

enum HelpLibrary {
    /// The pages that do not depend on which monitors exist.
    static let prose: [HelpTopic] = [
        HelpTopic(id: "what-it-does", title: "What HardwareSentry does", symbol: "sparkles", sections: [
            HelpSection(paragraphs: ["HardwareSentry watches the hardware attached to this Mac and tells you when something changes. A drive is plugged in, a display wakes, the Wi-Fi network changes, the Mac starts throttling because it is hot — each of those raises a notification you can read at a glance and then forget about.", "It lives in the menu bar and has no main window. Everything it does is either a notification on screen or a setting in this window."]),
            HelpSection(heading: "It draws its own notifications", paragraphs: ["The banners are drawn by HardwareSentry itself rather than handed to macOS. That is deliberate: handing a notification to the system means giving up everything on the Appearance tab, because macOS then decides the corner, the size, how long it stays and what it is drawn on. It would also make the application depend on a permission you have to grant, and stop working if you ever said no.", "One consequence worth knowing: these notifications do not appear in macOS's own Notification Centre, and Do Not Disturb does not silence them. The History tab is where past notifications live."]),
            HelpSection(heading: "What it does not do", paragraphs: ["It does not change anything. No setting here alters how a device behaves, ejects a disk, or reconfigures a network. It reads, and it reports."]),
        ]),
        HelpTopic(id: "startup", title: "What happens at launch", symbol: "power", sections: [
            HelpSection(paragraphs: ["When HardwareSentry starts it takes an inventory: every display, disk, camera, audio device, network link and Bluetooth device already attached gets announced. On a Mac with a few things plugged in that is a burst of notifications over a couple of seconds.", "That burst is treated as a burst rather than as a dozen separate events — no sounds play during it, and the flap detection that would normally flag something connecting repeatedly is held back. Otherwise launching would set off an alarm every time."]),
            HelpSection(heading: "Turning it off", paragraphs: ["General ▸ Show Connected Devices at Launch controls this. Switched off, HardwareSentry reads the same state silently and only speaks when something changes afterwards. The change takes effect the next time it starts."]),
        ]),
        HelpTopic(id: "appearance", title: "How notifications look", symbol: "paintbrush", sections: [
            HelpSection(paragraphs: ["Everything on the Appearance tab changes what is already on screen as you adjust it, so you can see the result rather than guess at it."]),
            HelpSection(heading: "Placement", rows: [.init(term: "Display", detail: "Which screen banners appear on: where the pointer is, the main display, or wherever the active window is. On a Mac with one screen every choice is that screen. The pointer is the default because it is the best guess at where you are looking — a notification on the display you are not looking at is a notification you did not get.", note: "Where the pointer is"), .init(term: "Corner", detail: "Which corner they stack from. Banners walk away from their corner, so the newest is always the one nearest it.", note: "Top right"), .init(term: "Distance from edge", detail: "How far the stack sits from the screen edge.", note: "12 pt")]),
            HelpSection(heading: "Appearance", rows: [.init(term: "Width", detail: "How wide a banner is. Banners already on screen keep the width they were built with — rebuilding one underneath you mid-read would be worse than a few seconds of the old size.", note: "300 pt"), .init(term: "Text size", detail: "Small, medium or large.", note: "Medium"), .init(term: "Background", detail: "Which system material a banner is drawn on. Three materials rather than free colours, so a banner always looks like part of macOS and stays legible in both light and dark.", note: "Popover"), .init(term: "Opacity", detail: "How solid a banner is.", note: "100%")]),
            HelpSection(heading: "Behaviour", rows: [.init(term: "Time on screen", detail: "How long a banner stays before it goes away by itself.", note: "5 seconds"), .init(term: "Animate", detail: "Whether banners slide in from the nearest edge or simply appear."), .init(term: "Sound", detail: "A macOS system sound to play with each notification. Silent to begin with. Sounds never play during the launch inventory, and two banners arriving within a second share one sound — so a handful arriving together do not become a burst of chimes.", note: "None")]),
        ]),
        HelpTopic(id: "choosing", title: "Choosing what arrives", symbol: "bell.badge", sections: [
            HelpSection(paragraphs: ["The Notifications tab has one section per module. There are three levels of control and they do different things."]),
            HelpSection(heading: "The three levels", rows: [.init(term: "The module switch", detail: "The switch in the section header. Off, the module stops watching altogether — not just stops talking. It releases what it was holding and, for the ones that need permission, stops asking for it."), .init(term: "Each notification", detail: "The switches in the list. Off, the module keeps watching but that particular thing is not announced. Useful when you want disconnections but not connections, or a warning but not the all-clear."), .init(term: "Include in the message", detail: "The checkboxes underneath. These are not events — they are extra lines inside a notification that is arriving anyway. Turning one on makes the message longer, never more frequent.")]),
            HelpSection(heading: "Why some are off to begin with", paragraphs: ["A notification is off by default when it would usually be noise: things that repeat, things that only matter if you went looking for them, and things whose answer never changes for a given device. A field is off when it is specification rather than news — a camera's maximum frame rate is the same every time that camera appears.", "Scanner is the one module that is off entirely. Looking for network scanners means browsing the local network, which makes macOS ask for permission, and a prompt nobody invited is worse than a feature nobody switched on."]),
            HelpSection(heading: "Restore Defaults", paragraphs: ["Puts every module, notification and field back to what its module declared — by forgetting your choices rather than by writing today's defaults over them. If a later version changes what a default is, you get the new one.", "Restore Default Icons is a separate button on purpose: time spent picking icons should not be lost by switching a notification back on."]),
        ]),
        HelpTopic(id: "timing", title: "How often it speaks", symbol: "timer", sections: [
            HelpSection(paragraphs: ["Most of what HardwareSentry says is triggered by something happening. Three settings on the General tab are about time rather than events, and they live there because they change when a module speaks rather than whether it does."]),
            HelpSection(heading: "Repeat the power status", rows: [.init(term: "What it does", detail: "Says what the Mac is running on, and at what charge, every so often — even though nothing changed. The message deliberately leaves out the \u{201C}from → to\u{201D} line, because nothing moved."), .init(term: "Only while on battery", detail: "On by default. Plugged in, the same message every fifteen minutes says the same thing every fifteen minutes; running down, it is the point."), .init(term: "Why it is off to begin with", detail: "A notification that arrives when nothing has happened is the definition of noise for anyone who did not ask for it.")]),
            HelpSection(heading: "Check the battery's health", paragraphs: ["Weekly, and on. Battery health is not something you can subscribe to — there is no notification when capacity drops, so the only way to know is to go and look. This looks for you.", "It reports only when the reading has actually moved. A weekly \u{201C}your battery is still fine\u{201D} is a weekly interruption that teaches you to ignore the one that matters. Check Now always answers, because a button that appears to do nothing is worse than a repeated message.", "A named fault or an internal failure is always said, even with every optional line switched off. That is the one thing nobody would choose to miss.", "A desktop Mac has no battery to report on and says nothing rather than inventing a figure. On some Macs the deeper drive-health reading is also unavailable — see Why something did not appear."]),
            HelpSection(heading: "Low free space", paragraphs: ["The percentage at which a volume is called low. Five percent of a 4 TB disk is 200 GB, which is not low, so the line is yours to move.", "Recovery is announced five points higher than the warning. Without that gap, a volume sitting on the line would report low, recovered, low, recovered as files were written and deleted."]),
        ]),
        HelpTopic(id: "icons", title: "Choosing icons", symbol: "photo.badge.plus", sections: [
            HelpSection(paragraphs: ["Every notification in the Notifications tab has its own icon beside it. The button is the icon it changes, so the row shows you what that notification looks like before you click anything.", "Click it to choose something else: one of the suggested symbols, any SF Symbol by name, or an image of your own."]),
            HelpSection(heading: "Using your own image", paragraphs: ["The file is referenced, not copied. Renaming or editing the picture changes the icon, which is usually what pointing at a file means. The cost is that moving it breaks the link — the icon then falls back to the module's own artwork rather than disappearing, and the picker shows a warning triangle so you can fix it before you miss it."]),
            HelpSection(heading: "Typing a symbol name", paragraphs: ["Another Symbol… takes any name from Apple's SF Symbols application. A name that does not resolve cannot be committed, so a setting can never silently do nothing."]),
        ]),
        HelpTopic(id: "profiles", title: "Saving your setup", symbol: "square.and.arrow.up", sections: [
            HelpSection(paragraphs: ["General ▸ Export Profile writes every choice to one file: which modules run, which notifications arrive, what each message includes, how banners look, and any icon you picked. Import Profile reads one back.", "It is worth having because the choices are laborious to remake. Losing them to a reinstall — or being unable to carry them to a second Mac — is the kind of small loss that stops people customising anything at all."]),
            HelpSection(heading: "What importing does", paragraphs: ["Importing adds to what is already there rather than replacing it. A profile written before a setting existed will not silently reset that setting.", "Quit and reopen HardwareSentry afterwards. Which modules run is decided as they start, and several settings are read once at launch."]),
        ]),
        HelpTopic(id: "permissions", title: "Permissions it asks for", symbol: "lock.shield", sections: [
            HelpSection(paragraphs: ["HardwareSentry asks for two permissions, both only because macOS requires them to read something specific. Neither is used for anything else."]),
            HelpSection(rows: [.init(term: "Bluetooth", detail: "Needed to see Bluetooth devices connecting and disconnecting at all. Without it the Bluetooth module cannot report anything."), .init(term: "Location", detail: "Needed only to read the name of the Wi-Fi network you join. macOS treats a network name as a location, because knowing which network you are on does say where you are. HardwareSentry never reads your actual location. Without this permission, joining a network is still detected — the notification just cannot say which network.")]),
            HelpSection(heading: "Local network", paragraphs: ["Switching the Scanner module on makes macOS ask for permission to look at the local network, because finding network scanners means browsing it. That is why the module ships switched off."]),
        ]),
        HelpTopic(id: "where-it-lives", title: "Where it appears", symbol: "menubar.arrow.up.rectangle", sections: [
            HelpSection(heading: "General ▸ Icon", rows: [.init(term: "Show icon in the menubar", detail: "The default. HardwareSentry sits in the menu bar with no dock icon."), .init(term: "Show icon in the dock", detail: "A dock icon and no menu bar item."), .init(term: "Show icon in both", detail: "Both."), .init(term: "No icon visible", detail: "Neither. HardwareSentry keeps running and keeps notifying, but there is no icon to click. It asks you to confirm before doing this, because it hides every way of reaching the settings.")]),
            HelpSection(heading: "Getting back with no icon", paragraphs: ["Open HardwareSentry again from Applications or Launchpad. Opening it while it is already running brings this window up rather than doing nothing."]),
            HelpSection(heading: "Start at login", paragraphs: ["General ▸ Start HardwareSentry at login registers it with macOS. The switch reads the real state from the system rather than remembering what you chose, so if you turn the login item off in System Settings the switch reflects that."]),
        ]),
        HelpTopic(id: "history", title: "History", symbol: "clock.arrow.circlepath", sections: [
            HelpSection(paragraphs: ["The History tab lists what was actually shown, newest first — not everything the modules raised. A notification you switched off, or one suppressed as a duplicate, is not there, because the point of the list is to answer \"what did I miss\".", "It is kept for the current run and cleared when HardwareSentry quits."]),
        ]),
        HelpTopic(id: "quiet", title: "Why something did not appear", symbol: "questionmark.circle", sections: [
            HelpSection(paragraphs: ["If you expected a notification and did not get one, the reasons in order of likelihood:"]),
            HelpSection(rows: [.init(term: "It is switched off", detail: "Check the Notifications tab. Some are off by default, and a module's section-header switch being off silences everything under it."), .init(term: "It repeated too quickly", detail: "The same thing happening twice within a few seconds is announced once. A device connecting and disconnecting repeatedly is reported as unstable rather than as a stream of separate notifications."), .init(term: "It needs a permission", detail: "Bluetooth reports nothing without Bluetooth access; a Wi-Fi network cannot be named without Location access."), .init(term: "The first reading is not a change", detail: "Some things are only reported when they change from a state HardwareSentry already saw. A Mac that was already hot when it launched has not got hotter."), .init(term: "It is not something HardwareSentry watches", detail: "The Modules reference lists everything each module can report.")]),
        ]),
    ]

    /// Builds the module reference from what the monitors declare about themselves.
    static func modules(from descriptions: [MonitorDescription]) -> HelpTopic {
        var sections: [HelpSection] = [
            HelpSection(paragraphs: [
                "Everything each module can report, and every extra line it can add to a message. This list is built from the modules themselves, so it is always what this version actually does.",
                "\"On by default\" means it arrives without you doing anything. Everything else is there when you want it."
            ])
        ]

        for module in descriptions.sorted(by: { $0.category.rawValue < $1.category.rawValue }) {
            sections.append(
                HelpSection(
                    heading: module.category.rawValue,
                    paragraphs: module.enabledByDefault
                        ? []
                        : ["This module is off to begin with — switch it on in the Notifications tab."],
                    rows: module.events.map { event in
                        .init(term: event.title, detail: "Notification name: \(event.name)",
                              note: event.enabledByDefault ? "On by default" : nil)
                    } + module.fields.map { field in
                        .init(term: field.title, detail: "Extra line in the message",
                              note: field.shownByDefault ? "Shown by default" : nil)
                    }
                )
            )
        }
        return HelpTopic(id: "modules", title: "Modules reference", symbol: "list.bullet.rectangle", sections: sections)
    }
}
