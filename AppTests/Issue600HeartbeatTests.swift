import Foundation
import Testing

/// A clock the test moves. Each `pause` takes its next step: `main` steps leave the heartbeat running (only the main
/// actor was late), `process` steps silence it for the whole step (the process was suspended). Later pauses take 5 ms.
@MainActor private final class Gaps600 {
    enum Step { case main(Duration), process(Duration) }
    let base = ContinuousClock.now
    var offset = Duration.zero
    var steps: [Step]
    var silent: [(ContinuousClock.Instant, ContinuousClock.Instant)] = []
    var pauses = 0
    init(_ steps: [Step]) { self.steps = steps }
    func wait() -> ActiveTimeWait {
        var wait = ActiveTimeWait()
        wait.now = { [self] in base.advanced(by: offset) }
        wait.pause = { [self] in
            pauses += 1
            let from = base.advanced(by: offset)
            switch steps.isEmpty ? .main(.milliseconds(5)) : steps.removeFirst() {
            case .main(let step): offset += step
            case .process(let step): offset += step; silent.append((from, base.advanced(by: offset)))
            }
        }
        wait.heartbeatSilence = { [self] from, to in
            silent.reduce(Duration.zero) { sum, gap in
                let low = max(gap.0, from), high = min(gap.1, to)
                return low < high ? sum + low.duration(to: high) : sum
            }
        }
        return wait
    }
}

/// i600-fix1 F1: a gap only the main actor shows is the product's time. With every 500 ms gap charged, a wait that
/// never holds ends after 2 s of main-loop time, not at the 20 s wall cap.
@Test(.timeLimit(.minutes(2))) @MainActor
func issue600MainOnlyGapIsChargedAndEndsTheWaitAtTwoSeconds() async throws {
    let gaps = Gaps600(Array(repeating: .main(.milliseconds(500)), count: 10))
    let report = try await gaps.wait().until { false }
    #expect(!report.held, "\(report)")
    #expect(report.polls == 4 && report.active == .seconds(2) && report.wall == .seconds(2), "\(report)")
    #expect(report.stalls.isEmpty, "\(report)")
    #expect(report.charged == Array(repeating: .milliseconds(500), count: 4), "\(report)")
}

/// F1: within one gap, only the part the heartbeat was also silent for is discounted; the rest is charged.
@Test(.timeLimit(.minutes(2))) @MainActor
func issue600PartlySilentGapChargesOnlyTheRunningPart() async throws {
    let gaps = Gaps600([.main(.milliseconds(1_500))])
    var wait = gaps.wait()
    // The heartbeat was silent for the first second of the 1.5 s gap and ran for the rest.
    let start = gaps.base
    wait.heartbeatSilence = { from, to in
        let low = max(from, start), high = min(to, start.advanced(by: .seconds(1)))
        return low < high ? low.duration(to: high) : .zero
    }
    let report = try await wait.until { gaps.pauses >= 3 }
    #expect(report.held, "\(report)")
    #expect(report.stalls == [.seconds(1)], "\(report)")
    #expect(report.active == .milliseconds(510), "\(report)")
    #expect(report.charged == [.milliseconds(500)], "\(report)")
}

/// F1: the wall cap is checked before a success. A product step that only finishes after 20.1 s of process-wide gaps
/// fails the wait even though the condition holds by then.
@Test(.timeLimit(.minutes(2))) @MainActor
func issue600WallCapIsCheckedBeforeASuccess() async throws {
    let gaps = Gaps600(Array(repeating: .process(.milliseconds(300)), count: 80))
    let report = try await gaps.wait().until { gaps.pauses >= 67 }
    #expect(!report.held, "the condition held only after the wall cap: \(report)")
    #expect(report.wall == .milliseconds(20_100) && report.active == .zero, "\(report)")
}

/// F1 with the real heartbeat thread: blocking only the main thread for 600 ms is charged, not named a stall.
@Test(.timeLimit(.minutes(2))) @MainActor
func issue600RealHeartbeatChargesABlockedMainThread() async throws {
    var calls = 0
    let report = try await ActiveTimeWait().until(between: {
        calls += 1
        if calls == 2 { Thread.sleep(forTimeInterval: 0.6) }
    }) { calls >= 4 }
    #expect(report.held, "\(report)")
    #expect(report.timeline.contains { $0.main >= .milliseconds(600) }, "the injected 600 ms block is in the timeline: \(report)")
    #expect(report.active >= .milliseconds(600), "\(report)")
    #expect(report.charged.count == 1 && report.charged[0] >= .milliseconds(600), "\(report)")
}

/// F1: the heartbeat counts as silent only gaps between its ticks longer than the threshold, including the time since
/// its last tick, and only the part inside the asked interval. No ticks at all is no evidence of a suspension.
@Test(.timeLimit(.minutes(2))) @MainActor
func issue600HeartbeatSilenceIsOnlyItsLongGapsInsideTheInterval() {
    let zero = ContinuousClock.now
    func at(_ ms: Int) -> ContinuousClock.Instant { zero.advanced(by: .milliseconds(ms)) }
    let ticks = stride(from: 0, through: 1_000, by: 50).map(at) + [at(3_000), at(3_050)]
    let threshold = Duration.milliseconds(250)
    #expect(OffMainHeartbeat.silence(ticks: ticks, from: at(900), to: at(3_100), threshold: threshold) == .seconds(2))
    #expect(OffMainHeartbeat.silence(ticks: ticks, from: at(2_000), to: at(2_500), threshold: threshold) == .milliseconds(500))
    #expect(OffMainHeartbeat.silence(ticks: ticks, from: at(100), to: at(900), threshold: threshold) == .zero)
    // Since the last tick: 3_050 to 3_550 is silent, 3_050 to 3_200 is under the threshold.
    #expect(OffMainHeartbeat.silence(ticks: ticks, from: at(3_000), to: at(3_550), threshold: threshold) == .milliseconds(500))
    #expect(OffMainHeartbeat.silence(ticks: ticks, from: at(3_000), to: at(3_200), threshold: threshold) == .zero)
    #expect(OffMainHeartbeat.silence(ticks: [], from: at(0), to: at(5_000), threshold: threshold) == .zero)
}

/// F1 guard (passes before and after the change): a gap the heartbeat shares, a process-wide suspension, is still
/// named and not charged.
@Test(.timeLimit(.minutes(2))) @MainActor
func issue600ProcessWideGapIsDiscounted() async throws {
    let gaps = Gaps600([.process(.milliseconds(2_500))])
    let report = try await gaps.wait().until { gaps.pauses >= 3 }
    #expect(report.held, "\(report)")
    #expect(report.stalls == [.milliseconds(2_500)], "\(report)")
    #expect(report.active == .milliseconds(10) && report.charged.isEmpty, "\(report)")
}
