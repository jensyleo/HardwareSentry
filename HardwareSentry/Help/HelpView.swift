import MonitorRegistry
import SwiftUI

/// The help window: what this application does, and how each setting changes it.
///
/// A sidebar of topics rather than one long page, so a question has a place to be looked
/// up rather than scrolled to. The module reference at the bottom is generated from the
/// monitors themselves — see `HelpLibrary.modules(from:)`.
struct HelpView: View {
    let registry: MonitorRegistry

    @State private var topics: [HelpTopic] = HelpLibrary.prose
    @State private var selection: HelpTopic.ID? = HelpLibrary.prose.first?.id
    @State private var query = ""
    /// Closes this window. Not `dismissWindow(id:)`: that closes a specific window
    /// identity from anywhere, which is right for a menu command reaching in from
    /// outside; this button is inside the window it closes, and `dismiss` is what a
    /// `Window` scene's own content uses to close itself — the same choice ROMForge's
    /// `HelpView` makes, and this one is meant to match it.
    @Environment(\.dismiss) private var dismiss

    private var matches: [HelpTopic] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return topics }
        return topics.filter { topic in
            if topic.title.lowercased().contains(needle) { return true }
            return topic.sections.contains { section in
                (section.heading?.lowercased().contains(needle) ?? false)
                    || section.paragraphs.contains { $0.lowercased().contains(needle) }
                    || section.rows.contains {
                        $0.term.lowercased().contains(needle) || $0.detail.lowercased().contains(needle)
                    }
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                List(selection: $selection) {
                    ForEach(matches) { topic in
                        Label(topic.title, systemImage: topic.symbol).tag(topic.id)
                    }
                }
                .searchable(text: $query, placement: .sidebar, prompt: "Search help")
                .navigationSplitViewColumnWidth(min: 220, ideal: 240)
                .overlay {
                    if matches.isEmpty {
                        ContentUnavailableView.search(text: query)
                    }
                }
            } detail: {
                if let topic = topics.first(where: { $0.id == selection }) {
                    TopicPage(topic: topic)
                } else {
                    ContentUnavailableView("Pick a topic", systemImage: "book")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Not a toolbar item: confirmed live that a toolbar-hosted button's own
            // `.keyboardShortcut` does not reliably reach the responder chain on macOS,
            // and a toolbar can end up hidden by the system's own "Customize Toolbar…"
            // state, taking a button that lives only there down with it. A footer in the
            // ordinary view body has neither problem — same placement as ROMForge's own
            // `HelpView`, and `AppSettingsView`'s "Done"/hidden "Close" pair there.
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
        }
        .frame(minWidth: 760, minHeight: 520)
        .task {
            // Appended once the monitors have been asked what they can do, so the
            // reference is this build's real inventory rather than a copy that drifts.
            let reference = HelpLibrary.modules(from: await registry.describe())
            guard !topics.contains(where: { $0.id == reference.id }) else { return }
            topics.append(reference)
        }
    }
}

private struct TopicPage: View {
    let topic: HelpTopic

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text(topic.title)
                    .font(.largeTitle.weight(.semibold))
                    .textSelection(.enabled)

                ForEach(topic.sections) { section in
                    VStack(alignment: .leading, spacing: 12) {
                        if let heading = section.heading {
                            Text(heading).font(.title3.weight(.semibold))
                        }

                        ForEach(Array(section.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                            Text(paragraph)
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if !section.rows.isEmpty {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                                    if index > 0 { Divider() }
                                    TermRow(row: row)
                                }
                            }
                            .background(.quinary, in: .rect(cornerRadius: 8))
                        }
                    }
                }
            }
            // Kept near 65 characters of running text; a help page read edge to edge on a
            // wide window is a help page nobody finishes.
            .frame(maxWidth: 620, alignment: .leading)
            .textSelection(.enabled)
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct TermRow: View {
    let row: HelpSection.Row

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.term).font(.body.weight(.medium))
                if let note = row.note {
                    Text(note)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: .capsule)
                }
            }
            Text(row.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
