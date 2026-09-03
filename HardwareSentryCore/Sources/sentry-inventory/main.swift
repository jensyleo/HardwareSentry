import Foundation
import MonitorRegistry
import SentryContract

/// Prints what this application can notify about, as JSON, and stops.
///
/// It exists so the parity audit reads the application's own declarations instead of a
/// human reading them: every gap found during this rewrite was a gap between what somebody
/// believed was implemented and what the code actually declared. A grep over Swift source
/// would be another belief; this is the same list the preferences screen renders.
struct Inventory: Encodable {
    struct Event: Encodable {
        let name: String
        let title: String
        let group: String?
        let enabledByDefault: Bool
        let hasIcon: Bool
    }

    struct Field: Encodable {
        let name: String
        let title: String
        let group: String?
        let shownByDefault: Bool
    }

    struct Module: Encodable {
        let category: String
        let enabledByDefault: Bool
        let eventListHeading: String?
        let hasDeclaredIcon: Bool
        let events: [Event]
        let fields: [Field]
    }

    let modules: [Module]
    let eventCount: Int
    let fieldCount: Int
}

let modules = MonitorRegistry.catalogue.map { module in
    Inventory.Module(
        category: module.category.rawValue,
        enabledByDefault: module.enabledByDefault,
        eventListHeading: module.eventListHeading,
        // A module whose icon fell back to `.none` would show blank in a list of modules,
        // which is the regression that recurred in five modules during the rewrite.
        hasDeclaredIcon: module.icon != .none,
        events: module.events.map {
            Inventory.Event(
                name: $0.name,
                title: $0.title,
                group: $0.group,
                enabledByDefault: $0.enabledByDefault,
                hasIcon: $0.icon != .none
            )
        },
        fields: module.fields.map {
            Inventory.Field(
                name: $0.name,
                title: $0.title,
                group: $0.group,
                shownByDefault: $0.shownByDefault
            )
        }
    )
}

let inventory = Inventory(
    modules: modules,
    eventCount: modules.reduce(0) { $0 + $1.events.count },
    fieldCount: modules.reduce(0) { $0 + $1.fields.count }
)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
FileHandle.standardOutput.write(try encoder.encode(inventory))
