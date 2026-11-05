import SignalCore

public extension IconBadge {
    /// The state a settings screen should show on an event's sample icon, read from the
    /// event's name.
    ///
    /// For the preview only. A real notification is told its state by the monitor that
    /// raised it; a settings row has no notification yet, just a name like
    /// `"VolumeUnmountedNAS"`, and needs a mark that matches the one that row's
    /// notifications will carry. Nil for an event whose name says no direction, which
    /// is drawn unmarked.
    ///
    /// The negatives and warnings are checked first because the positives hide inside
    /// them: "Disconnected" contains "Connected", "Unmounted" contains "Mounted".
    static func representative(forEventName name: String) -> IconBadge? {
        let warnings = ["LowSpace", "Critical", "NotReadable", "UnsafeEject", "StoppedResponding", "SupplyLow", "Error"]
        let negatives = ["Disconnected", "Unmounted", "Lost", "Removed", "Detaching", "LinkDown", "Unpaired", "RadioOff", "Off"]
        let positives = ["Connected", "Mounted", "Found", "Added", "Attaching", "LinkUp", "Paired", "RadioOn", "On"]
        if warnings.contains(where: name.contains) { return .warning }
        if negatives.contains(where: { name.contains($0) && !(($0 == "Off") && !name.hasSuffix("Off")) }) { return .negative }
        if positives.contains(where: { name.contains($0) && !(($0 == "On") && !name.hasSuffix("On")) }) { return .positive }
        return nil
    }
}
