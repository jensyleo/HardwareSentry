import SentryContract
import SignalCore
import SwiftUI

/// Which notifications a person wants, module by module.
///
/// Specific to this application, unlike the appearance screen next to it: the list comes
/// from the monitors this application happens to run, so it could not live in the
/// notification package without that package knowing about hardware.
struct EventSettingsView: View {
    @Bindable var model: EventSettingsModel

    var body: some View {
        Form {
            ForEach(model.modules) { module in
                Section {
                    ForEach(module.events, id: \.name) { event in
                        Toggle(event.title, isOn: binding(for: event, in: module.category))
                            .disabled(!model.isEnabled(module.category))
                    }

                    // Not events: extra lines inside a notification that is arriving
                    // anyway. Kept in the same section as the events they belong to, but
                    // marked so the difference is visible rather than implied.
                    if !module.fields.isEmpty {
                        LabeledContent("Include in the message") {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(module.fields, id: \.name) { field in
                                    Toggle(field.title, isOn: binding(for: field, in: module.category))
                                }
                            }
                        }
                        .disabled(!model.isEnabled(module.category))
                    }
                } header: {
                    Toggle(module.category.rawValue, isOn: binding(for: module.category))
                        .font(.headline)
                        .toggleStyle(.switch)
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("Restore Defaults") { model.resetAll() }
                }
            }
        }
        .formStyle(.grouped)
        .task { await model.load() }
        .overlay {
            if model.modules.isEmpty {
                ContentUnavailableView("No Modules", systemImage: "square.stack.3d.up.slash")
            }
        }
    }

    private func binding(for category: NotificationCategory) -> Binding<Bool> {
        Binding(
            get: { model.isEnabled(category) },
            set: { model.setEnabled($0, for: category) }
        )
    }

    private func binding(for event: MonitorEventDescription, in category: NotificationCategory) -> Binding<Bool> {
        Binding(
            get: { model.isEnabled(event, in: category) },
            set: { model.setEnabled($0, for: event, in: category) }
        )
    }

    private func binding(for field: MonitorFieldDescription, in category: NotificationCategory) -> Binding<Bool> {
        Binding(
            get: { model.isShown(field, in: category) },
            set: { model.setShown($0, for: field, in: category) }
        )
    }
}
