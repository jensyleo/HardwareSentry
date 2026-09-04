import AppKit
import SwiftUI

/// A visual browser for choosing an SF Symbol by sight, not by memorising its name.
///
/// The name field still works exactly as it always did — typing an exact symbol name and
/// pressing Return commits it, for anyone who already knows the one they want — but that
/// was, until now, the *only* way in: a blank text field with no picture until you had
/// already guessed correctly. This adds a scrollable grid of real symbols underneath it,
/// so the common case is finding one by eye and clicking it, with the name field acting
/// as a search filter over the same grid rather than a shot in the dark.
struct SFSymbolBrowser: View {
    /// The symbol currently in effect, if any — highlighted in the grid so someone can
    /// see at a glance which one they are changing away from.
    let currentSymbol: String?
    let onChoose: (String) -> Void
    let onCancel: () -> Void

    @State private var query = ""

    private var filtered: [String] {
        guard !query.isEmpty else { return Self.catalog }
        let needle = query.lowercased()
        return Self.catalog.filter { $0.contains(needle) }
    }

    private let columns = [GridItem(.adaptive(minimum: 36, maximum: 36), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Choose a Symbol")
                .font(.headline)

            TextField("Search, or type an exact symbol name", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commitTypedIfExact)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(filtered, id: \.self) { name in
                        Button {
                            onChoose(name)
                        } label: {
                            Image(systemName: name)
                                .font(.system(size: 16))
                                .frame(width: 32, height: 32)
                                .background(
                                    name == currentSymbol
                                        ? Color.accentColor.opacity(0.3)
                                        : Color.clear
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .help(name)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(width: 300, height: 240)

            if filtered.isEmpty {
                Text(
                    NSImage(systemSymbolName: query, accessibilityDescription: nil) != nil
                        ? "No suggestion matches, but \u{201C}\(query)\u{201D} is a real symbol \u{2014} press Return to use it."
                        : "No symbol found."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                if !query.isEmpty {
                    Button("Use It", action: commitTypedIfExact)
                        .keyboardShortcut(.defaultAction)
                        .disabled(NSImage(systemSymbolName: query, accessibilityDescription: nil) == nil)
                }
            }
        }
        .padding()
    }

    private func commitTypedIfExact() {
        guard !query.isEmpty, NSImage(systemSymbolName: query, accessibilityDescription: nil) != nil else { return }
        onChoose(query)
    }

    /// A broad, curated set grouped loosely by what a hardware notifier's own icons tend
    /// to need. SF Symbols ships several thousand names with no public API to enumerate
    /// them, so this is the closest thing to "all of them" a picker like this can offer —
    /// every name here was checked against this system's own symbol catalogue before
    /// being included, the same way a wrong one was once caught in this app's own icons.
    static let catalog: [String] = [
        // Status / alerts
        "checkmark.circle.fill", "checkmark.seal.fill", "xmark.circle.fill",
        "xmark.octagon.fill", "exclamationmark.triangle.fill", "exclamationmark.circle.fill",
        "questionmark.circle.fill", "info.circle.fill", "bell.fill", "bell.slash.fill",
        "flag.fill", "star.fill", "star.circle.fill", "bolt.fill", "bolt.slash.fill",
        "bolt.badge.a.fill", "sparkles", "flame.fill", "drop.fill", "snowflake",

        // Devices
        "desktopcomputer", "laptopcomputer", "iphone", "ipad", "applewatch",
        "airpods", "airpodspro", "headphones", "gamecontroller.fill", "keyboard.fill",
        "computermouse.fill", "printer.fill", "scanner.fill", "externaldrive.fill",
        "externaldrive.fill.badge.plus", "internaldrive.fill", "opticaldiscdrive.fill",
        "tv.fill", "display", "cpu.fill", "memorychip.fill", "cable.connector",
        "cable.connector.horizontal", "poweroutlet.type.b.fill", "powerplug.fill",
        "battery.100", "battery.25", "battery.0", "camera.fill", "web.camera",
        "video.fill", "video.slash.fill", "mic.fill", "mic.slash.fill",

        // Connectivity
        "wifi", "wifi.slash", "antenna.radiowaves.left.and.right", "personalhotspot",
        "network", "point.3.filled.connected.trianglepath.dotted",
        "point.3.connected.trianglepath.dotted", "dot.radiowaves.left.and.right",
        "iphone.radiowaves.left.and.right", "airplane", "location.fill",
        "sensor.fill", "waveform", "waveform.path", "waveform.path.ecg",

        // Media
        "play.fill", "pause.fill", "stop.fill", "speaker.fill", "speaker.slash.fill",
        "speaker.wave.1.fill", "speaker.wave.2.fill", "speaker.wave.3.fill",
        "music.note", "music.note.list", "photo.fill", "film.fill", "tv.and.mediabox.fill",

        // Storage / files
        "folder.fill", "doc.fill", "doc.text.fill", "archivebox.fill", "tray.fill",
        "tray.full.fill", "square.and.arrow.down.fill", "square.and.arrow.up.fill",
        "arrow.down.circle.fill", "arrow.up.circle.fill", "trash.fill",

        // Security
        "lock.fill", "lock.open.fill", "lock.shield.fill", "key.fill",
        "faceid", "touchid", "eye.fill", "eye.slash.fill", "shield.fill",
        "shield.lefthalf.filled",

        // People / accounts
        "person.fill", "person.2.fill", "person.crop.circle.fill",
        "person.badge.plus.fill", "person.wave.2.fill",

        // Nature / weather
        "sun.max.fill", "moon.fill", "moon.stars.fill", "cloud.fill",
        "cloud.rain.fill", "wind", "thermometer", "thermometer.sun.fill",
        "thermometer.snowflake", "leaf.fill",

        // Arrows / navigation
        "arrow.clockwise", "arrow.counterclockwise", "arrow.left.arrow.right",
        "arrow.up.arrow.down", "arrow.triangle.2.circlepath", "chevron.up.circle.fill",
        "chevron.down.circle.fill", "arrow.uturn.backward",

        // Objects / misc
        "gear", "gearshape.fill", "wrench.and.screwdriver.fill", "hammer.fill",
        "paintbrush.fill", "puzzlepiece.fill", "cube.fill", "shippingbox.fill",
        "cart.fill", "creditcard.fill", "banknote.fill", "gift.fill",
        "table.furniture", "chair.fill", "bed.double.fill", "house.fill",
        "building.2.fill", "car.fill", "bicycle", "figure.walk",

        // Health
        "heart.fill", "heart.text.square.fill", "cross.case.fill", "pills.fill",
        "bandage.fill", "stethoscope",

        // Time
        "clock.fill", "timer", "hourglass", "calendar", "alarm.fill",

        // Shapes
        "circle.fill", "square.fill", "triangle.fill", "diamond.fill",
        "hexagon.fill", "seal.fill"
    ]
}
