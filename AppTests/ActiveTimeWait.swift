import Foundation

/// #600: polls `condition` on the main actor with a budget of time charged to the code under test.
///
/// Time between two looks is charged to the budget, except where an off-main heartbeat thread was silent too. A silence
/// both threads share means the process was suspended (the runner, not the product), so that part is named in
/// `stalls` and not charged. A gap only the main actor shows is the product's time: it is charged, and gaps over
/// `stallThreshold` are listed in `charged`. Only a gap longer than `stallThreshold` can be discounted: a short poll
/// is always charged, even if the heartbeat thread alone was descheduled. `wallCap` and the charged budget are both
/// checked before a success, so a condition that first holds after either has run out still fails; a condition that
/// holds with the charged time at or under the budget passes.
@MainActor struct ActiveTimeWait {
    struct Gap: CustomStringConvertible {
        /// When the gap ended, measured from the start of the wait.
        var at: Duration
        var main: Duration
        var silent: Duration
        var description: String { "+\(Report.ms(at))ms main=\(Report.ms(main))ms heartbeatSilent=\(Report.ms(silent))ms" }
    }
    struct Report: CustomStringConvertible {
        var held: Bool
        var polls: Int
        var active: Duration
        var wall: Duration
        /// The parts of gaps the heartbeat was also silent for: process-wide suspensions, not charged.
        var stalls: [Duration]
        /// Gaps longer than the threshold whose charged part (heartbeat running) was itself over the threshold.
        var charged: [Duration] = []
        /// Every gap longer than the threshold, in order, for the failure diagnostic.
        var timeline: [Gap] = []
        var description: String {
            "held=\(held) polls=\(polls) active=\(Self.ms(active))ms wall=\(Self.ms(wall))ms " +
                "stalls=[\(stalls.map { "\(Self.ms($0))ms" }.joined(separator: ", "))] " +
                "charged=[\(charged.map { "\(Self.ms($0))ms" }.joined(separator: ", "))] " +
                "timeline=[\(timeline.map(\.description).joined(separator: "; "))]"
        }
        static func ms(_ duration: Duration) -> Int64 {
            duration.components.seconds * 1_000 + duration.components.attoseconds / 1_000_000_000_000_000
        }
    }

    var budget: Duration = .seconds(2)
    var stallThreshold: Duration = .milliseconds(250)
    /// 20 s is above the longest main-actor silence recorded on CI (16.4 s, #620 round g) plus the 2 s budget. Callers
    /// running several waits under one test time limit pass a share of that limit instead.
    var wallCap: Duration = .seconds(20)
    var now: @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now }
    var pause: @MainActor () async throws -> Void = { try await Task.sleep(for: .milliseconds(5)) }
    /// How long the off-main heartbeat was silent between two instants. Nil runs a real heartbeat thread for the wait.
    var heartbeatSilence: (@MainActor (ContinuousClock.Instant, ContinuousClock.Instant) -> Duration)?

    func until(between: () -> Void = {}, _ condition: () -> Bool) async throws -> Report {
        let heartbeat = heartbeatSilence == nil ? OffMainHeartbeat.start() : nil
        defer { heartbeat?.stop() }
        let threshold = stallThreshold
        let silence = heartbeatSilence ?? { from, to in
            OffMainHeartbeat.silence(ticks: heartbeat?.ticks() ?? [], from: from, to: to, threshold: threshold)
        }
        let start = now()
        var report = Report(held: false, polls: 0, active: .zero, wall: .zero, stalls: [])
        var last = start
        while true {
            report.wall = start.duration(to: last)
            if report.wall >= wallCap || report.active > budget || Task.isCancelled { return report }
            if condition() { report.held = true; return report }
            if report.active >= budget { return report }
            between()
            try await pause()
            report.polls += 1
            let looked = now()
            let gap = last.duration(to: looked)
            let silent = gap > stallThreshold ? min(gap, silence(last, looked)) : .zero
            last = looked
            report.active += gap - silent
            if silent > .zero { report.stalls.append(silent) }
            if gap - silent > stallThreshold { report.charged.append(gap - silent) }
            if gap > stallThreshold {
                report.timeline.append(Gap(at: start.duration(to: looked), main: gap, silent: silent))
            }
        }
    }
}

/// A thread off the main actor and the cooperative pool that records a tick about every 50 ms. When the whole process
/// is suspended its ticks stop too; when only the main actor is busy they continue.
final class OffMainHeartbeat: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ContinuousClock.Instant] = []
    private var stopped = false

    static func start(interval: TimeInterval = 0.05) -> OffMainHeartbeat {
        let heartbeat = OffMainHeartbeat()
        let thread = Thread { heartbeat.run(interval: interval) }
        thread.name = "issue600-heartbeat"
        thread.qualityOfService = .userInitiated
        thread.start()
        return heartbeat
    }
    private func run(interval: TimeInterval) {
        while lock.withLock({ () -> Bool in
            if stopped { return false }
            recorded.append(.now)
            return true
        }) { Thread.sleep(forTimeInterval: interval) }
    }
    func stop() { lock.withLock { stopped = true } }
    func ticks() -> [ContinuousClock.Instant] { lock.withLock { recorded } }

    /// The part of `from...to` that falls in a gap between ticks longer than `threshold`, counting the time since the
    /// last tick as a gap. Before the first tick there is no evidence, so that time is never silent.
    static func silence(ticks: [ContinuousClock.Instant], from: ContinuousClock.Instant, to: ContinuousClock.Instant,
                        threshold: Duration) -> Duration {
        guard let lastTick = ticks.last else { return .zero }
        var bounds = ticks
        if lastTick < to { bounds.append(to) }
        var total = Duration.zero
        for (low, high) in zip(bounds, bounds.dropFirst()) where low.duration(to: high) > threshold {
            let start = max(low, from), end = min(high, to)
            if start < end { total += start.duration(to: end) }
        }
        return total
    }
}
