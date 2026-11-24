/// A notification asked for on demand, with the number that gives it meaning.
///
/// For the modules whose notices say little without a figure — how full a battery is, how
/// little space is left, how strong a signal is — so the settings screen can show what one
/// looks like at a chosen value instead of at a fixed one. It never touches what a monitor
/// believes the real state is.
public enum MonitorSimulation: Sendable, Equatable {
    /// The battery at `percentage`, plugged in (`isCharging`) or not.
    case power(percentage: Int, isCharging: Bool)
    /// A volume with `freePercent` of its space left.
    case lowDiskSpace(freePercent: Int)
    /// A Wi-Fi network heard at `rssi` dBm.
    case wifiSignal(rssi: Int)
}
