import SwiftUI

/// What was shown, most recent first.
struct HistoryView: View {
    @Bindable var store: NotificationHistoryStore

    var body: some View {
        VStack(spacing: 0) {
            if store.entries.isEmpty {
                ContentUnavailableView(
                    "Nothing Yet",
                    systemImage: "clock",
                    description: Text("Notifications appear here once something happens.")
                )
            } else {
                List(store.entries) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(entry.title).font(.headline)
                            Spacer(minLength: 12)
                            Text(entry.at, format: .dateTime.hour().minute().second())
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        if !entry.body.isEmpty {
                            // Tabs are how the monitors lay out "Label:<tab>value"; shown as
                            // spaces here because a list row is not a banner.
                            Text(entry.body.replacingOccurrences(of: "\t", with: "  "))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Text(entry.category)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Text("^[\(store.entries.count) notification](inflect: true)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { store.clear() }
                    .disabled(store.entries.isEmpty)
            }
            .padding(12)
        }
    }
}
