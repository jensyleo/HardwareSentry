import SentryContract
import SignalCore
import SwiftUI

/// What was shown, most recent first — and the choices about what gets written down.
///
/// A menu-bar application says things while nobody is looking, which is rather the point
/// of it; anything missed used to be simply gone. The three controls above the table are
/// about the cost of remembering: whether to, for how long, and which modules are worth
/// it.
struct HistoryView: View {
    @Bindable var store: NotificationHistoryStore
    /// The modules to offer, and which of them are running. Taken from the same
    /// description the notifications screen uses, so a module added later appears here
    /// without this being touched.
    let modules: [MonitorDescription]
    let isModuleEnabled: (NotificationCategory) -> Bool

    @State private var isConfirmingClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Keep a history of notifications", isOn: Binding(
                get: { store.isEnabled },
                set: { store.isEnabled = $0 }
            ))
            .toggleStyle(.checkbox)

            HStack {
                Text("Keep for:")
                Slider(value: Binding(
                    get: { store.retentionDays },
                    set: { store.retentionDays = $0 }
                ), in: 1...90, step: 1)
                .frame(width: 220)
                Text("^[\(Int(store.retentionDays)) day](inflect: true)")
                    .monospacedDigit()
                    .frame(width: 60, alignment: .leading)
            }
            .disabled(!store.isEnabled)

            HStack {
                Text("Save history for:")
                Spacer()
                Button("Select All") { store.setRecorded(true, forAll: allCategories) }
                Button("Select None") { store.setRecorded(false, forAll: allCategories) }
                // The useful middle: remember what is actually running, and nothing else.
                // A module that is switched off cannot write anything anyway, so leaving
                // it ticked is a promise about a log that will never have a line in it.
                Button("Select Active Modules") {
                    for module in modules {
                        store.setRecorded(isModuleEnabled(module.category), for: module.category.rawValue)
                    }
                }
            }
            .disabled(!store.isEnabled)

            List {
                ForEach(modules) { module in
                    Toggle(module.category.rawValue, isOn: Binding(
                        get: { store.isRecorded(module.category.rawValue) },
                        set: { store.setRecorded($0, for: module.category.rawValue) }
                    ))
                    .toggleStyle(.checkbox)
                }
            }
            .frame(height: 130)
            .disabled(!store.isEnabled)

            HStack {
                Text("Recent notifications:")
                Spacer()
                Button("Clear History…") { isConfirmingClear = true }
                    .disabled(store.entries.isEmpty)
            }

            if store.entries.isEmpty {
                ContentUnavailableView(
                    "Nothing Yet",
                    systemImage: "clock",
                    description: Text(store.isEnabled
                        ? "Notifications appear here once something happens."
                        : "History is switched off, so nothing is being written down.")
                )
            } else {
                // A table rather than a list of cards: three columns are what makes a log
                // scannable, and "which module said this" is the question somebody
                // reading it back is usually asking.
                Table(store.entries) {
                    TableColumn("Date") { entry in
                        Text(entry.at, format: .dateTime.day().month().year().hour().minute())
                            .monospacedDigit()
                    }
                    .width(min: 130, ideal: 150)

                    TableColumn("Module", value: \.category)
                        .width(min: 80, ideal: 110)

                    TableColumn("Notification") { entry in
                        Text(entry.oneLine)
                    }
                }
            }
        }
        .padding(12)
        .confirmationDialog(
            "Clear the whole history?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) { store.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            // Asked because it cannot be undone, and because the button sits beside a
            // table somebody may have been reading for a reason.
            Text("^[\(store.entries.count) notification](inflect: true) will be forgotten. This cannot be undone.")
        }
    }

    private var allCategories: [String] { modules.map(\.category.rawValue) }
}
