import Foundation
import Testing

/// i600-fix2: a fake clock whose `pause` takes the next step. `heartbeatSilent` steps silence the heartbeat for the
/// whole step; `heartbeatAlwaysSilent` models a heartbeat thread starved for the whole wait while main keeps polling.
@MainActor private final class Budget600 {
    let base = ContinuousClock.now
    var offset = Duration.zero
    var steps: [(Duration, heartbeatSilent: Bool)]
    var silent: [(ContinuousClock.Instant, ContinuousClock.Instant)] = []
    var heartbeatAlwaysSilent = false
    var pauses = 0
    init(_ steps: [(Duration, heartbeatSilent: Bool)]) { self.steps = steps }
    func wait() -> ActiveTimeWait {
        var wait = ActiveTimeWait()
        wait.now = { [self] in base.advanced(by: offset) }
        wait.pause = { [self] in
            pauses += 1
            let from = base.advanced(by: offset)
            let step = steps.isEmpty ? (Duration.milliseconds(5), heartbeatSilent: false) : steps.removeFirst()
            offset += step.0
            if step.heartbeatSilent { silent.append((from, base.advanced(by: offset))) }
        }
        wait.heartbeatSilence = { [self] from, to in
            if heartbeatAlwaysSilent { return from.duration(to: to) }
            return silent.reduce(Duration.zero) { sum, gap in
                let low = max(gap.0, from), high = min(gap.1, to)
                return low < high ? sum + low.duration(to: high) : sum
            }
        }
        return wait
    }
}

/// gpt F1 (round 2): a condition that first holds on a look already past the 2 s charged budget fails the wait.
@Test(.timeLimit(.minutes(2))) @MainActor
func issue600ConditionTrueOnlyAfterTheChargedBudgetFails() async throws {
    let clock = Budget600(Array(repeating: (.milliseconds(700), heartbeatSilent: false), count: 3))
    let report = try await clock.wait().until { clock.pauses >= 3 }
    #expect(!report.held, "the condition held only after 2.1 s of charged time: \(report)")
    #expect(report.active == .milliseconds(2_100), "\(report)")
}

/// opus M1 (round 2): heartbeat silence is discounted only inside a long main gap. A heartbeat starved for the whole
/// wait while main keeps polling every 5 ms does not stop `active` from advancing, so the budget still ends the wait.
@Test(.timeLimit(.minutes(2))) @MainActor
func issue600HeartbeatOnlyStarvationDoesNotStopTheBudget() async throws {
    let clock = Budget600([])
    clock.heartbeatAlwaysSilent = true
    let report = try await clock.wait().until { false }
    #expect(!report.held, "\(report)")
    #expect(report.polls == 400 && report.active == .seconds(2) && report.stalls.isEmpty, "\(report)")
}

/// Guard (passes before and after): a condition that holds within the charged budget passes.
@Test(.timeLimit(.minutes(2))) @MainActor
func issue600GuardConditionTrueWithinTheChargedBudgetPasses() async throws {
    let clock = Budget600(Array(repeating: (.milliseconds(600), heartbeatSilent: false), count: 3))
    let report = try await clock.wait().until { clock.pauses >= 3 }
    #expect(report.held && report.active == .milliseconds(1_800), "\(report)")
}

/// Guard (passes before and after): a process-wide stall, heartbeat silent too, is still not charged, so a condition
/// that holds after it passes.
@Test(.timeLimit(.minutes(2))) @MainActor
func issue600GuardProcessWideStallStillNotCharged() async throws {
    let clock = Budget600([(.milliseconds(1_900), heartbeatSilent: false), (.milliseconds(2_500), heartbeatSilent: true)])
    let report = try await clock.wait().until { clock.pauses >= 2 }
    #expect(report.held, "\(report)")
    #expect(report.active == .milliseconds(1_900) && report.stalls == [.milliseconds(2_500)], "\(report)")
}
