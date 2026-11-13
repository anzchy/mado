import Foundation

/// Temporary #658 timing probe, enabled only by the #507 App integration test.
public enum I658ScanStartTiming {
    @TaskLocal public static var begin: ContinuousClock.Instant?

    public static func mark(_ stage: String, since start: ContinuousClock.Instant? = begin) {
        guard let start else { return }
        let elapsed = start.duration(to: .now)
        let milliseconds = elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000
        print("[i507] scan start +\(milliseconds)ms \(stage)")
    }
}
