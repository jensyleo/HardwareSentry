import AppKit
import SignalCore

/// A throwaway host for looking at banners.
///
/// The package's own tests cover the stacking policy and the text handling, but nothing
/// there can answer whether a banner actually draws. This runs a real application so it
/// can be seen.
///
/// Run it with `swift run BannerDemo`. Note that a bare executable is enough to show
/// banners, but a real application would of course be a bundle.
@MainActor
final class DemoDelegate: NSObject, NSApplicationDelegate {
    private var dispatcher: NotificationDispatcher?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let dispatcher = NotificationDispatcher(
            pipeline: [
                DuplicateSuppressionMiddleware(),
                FlapDetectionMiddleware()
            ],
            delivery: BannerDelivery()
        )
        self.dispatcher = dispatcher

        Task {
            await dispatcher.fire(NotificationEvent(
                name: "USBConnected",
                subject: "SanDisk Cruzer",
                category: "USB",
                title: "USB Device Connected",
                body: "SanDisk Cruzer\nCapacity: 64 GB",
                icon: .symbol("externaldrive.connected.to.line.below")
            ))

            await dispatcher.fire(NotificationEvent(
                name: "AudioSampleRateChanged",
                subject: "Studio Display",
                category: "Audio",
                title: "Sample Rate Changed",
                body: "Studio Display\nSample rate:\t44100 Hz → 48000 Hz",
                icon: .symbol("hifispeaker")
            ))

            await dispatcher.fire(NotificationEvent(
                name: "WifiRadioOff",
                category: "Network",
                title: "Wi-Fi Turned Off",
                body: "Status: On → Off",
                icon: .symbol("wifi.slash")
            ))
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = DemoDelegate()
app.delegate = delegate
app.run()
