import SignalCore

/// What this monitor can tell you about.
///
/// Disk-not-readable detection, NVMe SMART health, and every body-detail field are not
/// ported at all; see the porting notes for why and what each would take.
public enum VolumeEvent: String, NotificationEventKey {
    case mounted = "VolumeMounted"
    case unmounted = "VolumeUnmounted"
    case unsafeEject = "VolumeUnsafeEject"
    case lowSpace = "VolumeLowSpace"

    public static let category: NotificationCategory = "Volume"
}
