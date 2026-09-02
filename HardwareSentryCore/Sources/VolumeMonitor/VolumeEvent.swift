import SignalCore

/// What this monitor can tell you about.
///
/// Disk-not-readable detection, NVMe SMART health, and every body-detail field are not
/// ported at all; see the porting notes for why and what each would take.
public enum VolumeEvent: String, NotificationEventKey, CaseIterable {
    case mounted = "VolumeMounted"
    case unmounted = "VolumeUnmounted"
    case unsafeEject = "VolumeUnsafeEject"
    case notReadable = "VolumeNotReadable"
    case lowSpace = "VolumeLowSpace"
    // Three rows per kind of drive, as the original has it.
    case mountedOptical = "VolumeMountedOptical"
    case unmountedOptical = "VolumeUnmountedOptical"
    case lowSpaceOptical = "VolumeLowSpaceOptical"
    case mountedNAS = "VolumeMountedNAS"
    case unmountedNAS = "VolumeUnmountedNAS"
    case lowSpaceNAS = "VolumeLowSpaceNAS"
    case mountedExternalDisk = "VolumeMountedExternalDisk"
    case unmountedExternalDisk = "VolumeUnmountedExternalDisk"
    case lowSpaceExternalDisk = "VolumeLowSpaceExternalDisk"
    case mountedSDCard = "VolumeMountedSDCard"
    case unmountedSDCard = "VolumeUnmountedSDCard"
    case lowSpaceSDCard = "VolumeLowSpaceSDCard"
    case mountedUSBDrive = "VolumeMountedUSBDrive"
    case unmountedUSBDrive = "VolumeUnmountedUSBDrive"
    case lowSpaceUSBDrive = "VolumeLowSpaceUSBDrive"

    public static let category: NotificationCategory = "Volume"
}
