import AppKit
import SwiftUI

/// Lets a person set how banners look, with a live example of the result.
///
/// Part of the package rather than of any one application: every application built on
/// this draws the same banners and therefore wants the same settings, and none of them
/// should have to write this twice. It knows nothing about events or hardware — an
/// application pairs it with its own screen for choosing which notifications it wants.
public struct BannerAppearanceView: View {
    @Bindable private var store: BannerAppearanceStore

    public init(store: BannerAppearanceStore) {
        self.store = store
    }

    public var body: some View {
        Form {
            Section("Preview") {
                preview
            }

            Section("Placement") {
                Picker("Display", selection: $store.appearance.screen) {
                    ForEach(BannerScreen.allCases) { screen in
                        Text(screen.label).tag(screen)
                    }
                }
                // Said rather than hidden: a control whose every option does the same
                // thing looks broken until you know why.
                if NSScreen.screens.count < 2 {
                    Text("With one display connected, every choice is that display.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Picker("Corner", selection: $store.appearance.corner) {
                    ForEach(BannerCorner.allCases, id: \.self) { corner in
                        Text(corner.label).tag(corner)
                    }
                }

                slider(
                    "Distance from edge",
                    value: $store.appearance.margin,
                    range: BannerAppearance.marginRange,
                    format: { "\(Int($0)) pt" }
                )
            }

            Section("Appearance") {
                slider(
                    "Width",
                    value: $store.appearance.width,
                    range: BannerAppearance.widthRange,
                    format: { "\(Int($0)) pt" }
                )

                Picker("Text size", selection: $store.appearance.textScale) {
                    ForEach(BannerTextScale.allCases, id: \.self) { scale in
                        Text(scale.label).tag(scale)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Background", selection: $store.appearance.material) {
                    ForEach(BannerMaterial.allCases, id: \.self) { material in
                        Text(material.label).tag(material)
                    }
                }

                slider(
                    "Opacity",
                    value: $store.appearance.opacity,
                    range: BannerAppearance.opacityRange,
                    format: { "\(Int($0 * 100))%" }
                )
            }

            Section("Behaviour") {
                slider(
                    "Stays on screen for",
                    value: $store.appearance.visibleLifetime,
                    range: BannerAppearance.lifetimeRange,
                    format: { "\(Int($0))s" }
                )

                Stepper(
                    "At most \(store.appearance.maximumVisible) at a time",
                    value: $store.appearance.maximumVisible,
                    in: BannerAppearance.maximumVisibleRange
                )

                slider(
                    "One appears every",
                    value: $store.appearance.revealSpacing,
                    range: BannerAppearance.revealSpacingRange,
                    format: { $0 < 0.05 ? "All at once" : String(format: "%.2fs", $0) }
                )
                Text("Anything over the limit waits its turn. Letting them in one at a time is also what makes them leave one at a time, instead of a whole screenful blinking out together.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Slide in and out", isOn: $store.appearance.isAnimated)

                if store.appearance.isAnimated {
                    slider(
                        "Animation duration",
                        value: $store.appearance.animationDuration,
                        range: BannerAppearance.animationDurationRange,
                        format: { String(format: "%.2fs", $0) }
                    )
                }

                Picker("Sound", selection: $store.appearance.sound) {
                    ForEach(BannerSound.allCases, id: \.self) { sound in
                        Text(sound.label).tag(sound)
                    }
                }
                // Played on choosing, because picking a sound from a list of names without
                // hearing it is guessing.
                .onChange(of: store.appearance.sound) { _, chosen in
                    if let name = chosen.systemName { NSSound(named: name)?.play() }
                }

                Text("Silent while the application is starting up, so everything already plugged in is announced without a burst of chimes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Spacer()
                    Button("Restore Defaults") { store.reset() }
                        .disabled(store.appearance == .standard)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// The real banner view, drawn with the settings as they stand — not an illustration
    /// of one, so what is on screen here is exactly what will arrive later.
    private var preview: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            BannerView(
                content: Self.sample,
                appearance: store.appearance,
                onActivate: {},
                onDismiss: {}
            )
            .opacity(store.appearance.opacity)
            .padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity)
    }

    private static let sample = BannerContent(
        event: NotificationEvent(
            name: "PreviewSample",
            category: "Preview",
            title: "USB Device Connected",
            body: "SanDisk Cruzer\nCapacity: 64 GB",
            icon: .symbol("externaldrive.connected.to.line.below")
        )
    )

    private func slider<V: BinaryFloatingPoint>(
        _ title: String,
        value: Binding<V>,
        range: ClosedRange<V>,
        format: @escaping (V) -> String
    ) -> some View where V.Stride: BinaryFloatingPoint {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range)
                Text(format(value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
        }
    }
}
