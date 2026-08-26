# SignalCore

A modular notification core for macOS applications, written in Swift 6 with strict concurrency
enabled.

SignalCore separates *what* to notify from *how* it gets delivered. An emitting module builds a
value-type event and hands it to an actor-isolated dispatcher; an ordered pipeline of middleware
decides whether the event proceeds (deduplication, instability detection, per-event preference
gating), and a pluggable delivery channel presents it — either through the system notification
centre or through a self-contained floating banner.

The package is deliberately application-agnostic: it hardcodes no module names, no preference
keys and no storage backend, so the same core can serve unrelated applications.

## Status

Early development. The dispatcher, the event model and duplicate suppression are implemented and
tested. Flap detection, both delivery channels, the banner stack controller and the preferences
store are designed but not yet written.

## Requirements

- macOS 15 or later
- Swift 6.0 or later

## Building

```
swift build
swift test
```

## Architecture

| Component | Responsibility |
|---|---|
| `NotificationEvent` | Value type describing a single notification request |
| `NotificationCategory` | Identifies the emitting module; declared by the consuming application |
| `NotificationDispatcher` | Actor that runs the middleware pipeline and hands off to delivery |
| `NotificationMiddleware` | One pipeline stage; may pass through, transform, or suppress an event |
| `NotificationDelivering` | A channel capable of presenting an event to the user |

Being actor-isolated rather than lock-guarded means data-race safety is enforced by the compiler
rather than by convention, and every pipeline stage is independently testable without launching
a host application.

## License

GPLv3. See [LICENSE](LICENSE).
