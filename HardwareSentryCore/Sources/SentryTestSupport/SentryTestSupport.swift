import Foundation

/// Waits until `isReady` answers true, or a couple of seconds pass.
///
/// Bounded by the clock rather than by a number of turns. How many turns a scripted
/// source needs depends on how the runtime schedules and how busy the machine is, so a
/// fixed count is a guess that holds until the next toolchain: the counts this replaced
/// began failing at random under Swift 6.4. Sleeping rather than spinning on `yield`
/// also lets the monitor's own task run instead of competing with it.
public func waitUntil(_ isReady: () async -> Bool) async {
    let deadline = Date().addingTimeInterval(2)
    while await isReady() == false, Date() < deadline {
        try? await Task.sleep(nanoseconds: 200_000)
    }
}

/// Gives the monitor's own task a moment to say anything it is going to say.
///
/// Used where the test cannot name a number to wait for: a change that gets suppressed
/// produces fewer events than changes, so there is nothing to count up to. A fixed moment
/// of the clock rather than a fixed number of turns — how many turns that takes depends on
/// the runtime's scheduling and the machine's load, which is what began failing at random
/// under Swift 6.4. Proving that nothing arrives can only ever be done by waiting.
public func settle() async {
    try? await Task.sleep(nanoseconds: 50_000_000)
}
