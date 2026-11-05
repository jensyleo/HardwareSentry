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

Implemented and tested, and in daily use as the notification core of HardwareSentry, which
is where it currently lives. The API may still change between that application's releases;
it is expected to move to a repository of its own once it settles.

What is in it:

- An actor-isolated dispatcher with an ordered middleware pipeline and a launch phase that
  treats the opening burst of notifications as a burst.
- Middleware for duplicate suppression, flap (instability) detection, per-category and
  per-event enablement, icon overrides and a history hook.
- Two delivery channels: the system notification centre, and self-drawn floating banners
  with stacking, pacing, sound, and a configurable appearance (corner, display, size,
  material and tint, lifetime, animation speed) with its own editor view.
- Per-event icon choices (an SF Symbol, a picture file, or the event's own icon kept on
  purpose), and a state badge drawn on icons that do not show their state themselves.
- A preferences store for categories, events and optional body fields.

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
| `BannerDelivery` | Draws its own floating banners, outside Notification Centre |
| `IconOverrideStore` | Remembers an icon chosen for an event, readable with `defaults read` |
| `NotificationPreferencesStore` | Remembers which categories, events and body fields are wanted |

Being actor-isolated rather than lock-guarded means data-race safety is enforced by the compiler
rather than by convention, and every pipeline stage is independently testable without launching
a host application.

## License

GPLv3. See [LICENSE](LICENSE).
