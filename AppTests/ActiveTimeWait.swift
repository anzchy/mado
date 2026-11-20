import Foundation

/// #600: polls `condition` on the main actor with a budget of time in which this loop actually ran.
/// A gap between two looks longer than `stallThreshold` means the main actor (or the whole process) did not run: the code
/// under test could not run either, so the gap is recorded in the report and not charged to the budget. `wallCap` bounds
/// the whole wait, so a scan that never completes still fails.
@MainActor struct ActiveTimeWait {
    struct Report: CustomStringConvertible {
        var held: Bool
        var polls: Int
        var active: Duration
        var wall: Duration
        var stalls: [Duration]
        var description: String {
            "held=\(held) polls=\(polls) active=\(Self.ms(active))ms wall=\(Self.ms(wall))ms " +
                "stalls=[\(stalls.map { "\(Self.ms($0))ms" }.joined(separator: ", "))]"
        }
        static func ms(_ duration: Duration) -> Int64 {
            duration.components.seconds * 1_000 + duration.components.attoseconds / 1_000_000_000_000_000
        }
    }

    var budget: Duration = .seconds(2)
    var stallThreshold: Duration = .milliseconds(250)
    var wallCap: Duration = .seconds(20)
    var now: @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now }
    var pause: @MainActor () async throws -> Void = { try await Task.sleep(for: .milliseconds(5)) }

    func until(between: () -> Void = {}, _ condition: () -> Bool) async throws -> Report {
        let start = now()
        var last = start, active = Duration.zero, stalls: [Duration] = [], polls = 0
        while !condition() {
            if active >= budget || start.duration(to: last) >= wallCap || Task.isCancelled {
                return Report(held: false, polls: polls, active: active, wall: start.duration(to: last), stalls: stalls)
            }
            between()
            try await pause()
            polls += 1
            let looked = now()
            let gap = last.duration(to: looked)
            last = looked
            if gap > stallThreshold { stalls.append(gap) } else { active += gap }
        }
        return Report(held: true, polls: polls, active: active, wall: start.duration(to: last), stalls: stalls)
    }
}
