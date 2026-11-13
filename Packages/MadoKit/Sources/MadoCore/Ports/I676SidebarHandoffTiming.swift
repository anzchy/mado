import Foundation

/// Temporary #676 probe inherited only by the three sidebar handoff App tests.
public enum I676SidebarHandoffTiming {
    @TaskLocal public static var begin: ContinuousClock.Instant?

    public static func mark(_ stage: String, since start: ContinuousClock.Instant? = begin) {
        guard let start else { return }
        let elapsed = start.duration(to: .now)
        let milliseconds = elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000
        print("[i676] sidebar handoff +\(milliseconds)ms \(stage)")
    }
}
