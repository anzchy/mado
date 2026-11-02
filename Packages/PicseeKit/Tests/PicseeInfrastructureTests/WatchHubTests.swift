import Foundation
import Testing
import PicseeCore
@testable import PicseeInfrastructure

@Test(.timeLimit(.minutes(2))) func watchHubSharesOneStreamAndLeasePerRoot() async throws {
    let f = try WatchFixture(folders: ["root/A", "root/B", "other/X", "revoked/X"])
    defer { f.remove() }
    let root = try await f.access.grant(folder: f.url("root"))
    #expect(f.scope.counts == [1, 1])
    let logA = ChangeLog(clock: f.clock), logB = ChangeLog(clock: f.clock)

    let a = try await f.hub.subscribe(rootID: root, folder: f.url("root/A"), recursive: false, onChange: logA.sink)
    #expect(f.source.startURLs == [canonicalPath(f.url("root"))])
    #expect(f.source.scopeAtStart == [[2, 1]])
    let b = try await f.hub.subscribe(rootID: root, folder: f.url("root/B"), recursive: true, onChange: logB.sink)
    #expect(f.source.starts == 1)
    #expect(f.scope.counts == [2, 1])

    f.source.emit([.changed(f.url("root/A/x.png"))], on: f.url("root"))
    f.source.emit([.changed(f.url("root/B/y.png"))], on: f.url("root"))
    f.clock.advance(to: 200)
    #expect(logA.count == 1)
    #expect(logB.count == 1)

    await a.cancel()
    f.source.emit([.changed(f.url("root/B/z.png"))], on: f.url("root"))
    f.clock.advance(by: 200)
    #expect(f.source.stops == 0)
    #expect(logB.count == 2)
    #expect(logA.count == 1)

    await a.cancel()
    f.source.emit([.changed(f.url("root/B/w.png"))], on: f.url("root"))
    f.clock.advance(by: 200)
    #expect(f.source.stops == 0)
    #expect(f.scope.counts == [2, 1])
    #expect(logB.count == 3)

    await b.cancel()
    #expect(f.source.stops == 1)
    #expect(f.source.scopeAtStop == [[2, 1]])
    #expect(f.scope.counts == [2, 2])
    f.source.emit([.changed(f.url("root/B/v.png"))], on: f.url("root"))
    f.clock.advance(by: 200)
    #expect(logB.count == 3)

    await b.cancel()
    #expect(f.source.starts == 1)
    #expect(f.source.stops == 1)
    #expect(f.scope.counts == [2, 2])

    let again = try await f.hub.subscribe(rootID: root, folder: f.url("root/A"), recursive: false, onChange: logA.sink)
    #expect(f.source.starts == 2)
    #expect(f.source.active == 1)
    await again.cancel()
    #expect(f.scope.counts == [3, 3])
    #expect(f.source.active == 0)

    let other = try await f.access.grant(folder: f.url("other"))
    let logC = ChangeLog(clock: f.clock), logD = ChangeLog(clock: f.clock)
    let c = try await f.hub.subscribe(rootID: root, folder: f.url("root/A"), recursive: false, onChange: logC.sink)
    let d = try await f.hub.subscribe(rootID: other, folder: f.url("other/X"), recursive: false, onChange: logD.sink)
    #expect(f.source.starts == 4)
    #expect(Set(f.source.startURLs.suffix(2)) == [canonicalPath(f.url("root")), canonicalPath(f.url("other"))])
    f.source.emit([.changed(f.url("other/X/q.png"))], on: f.url("other"))
    f.clock.advance(by: 200)
    #expect(logD.count == 1)
    #expect(logC.count == 0)
    await c.cancel(); await d.cancel()
    #expect(f.source.active == 0)
    #expect(f.scope.counts.first == f.scope.counts.last)

    let revoked = try await f.access.grant(folder: f.url("revoked"))
    let before = (starts: f.source.starts, scope: f.scope.counts)
    f.bookmarks.fails = true
    await #expect(throws: FileAccessError.needsReconnection(revoked)) {
        try await f.hub.subscribe(rootID: revoked, folder: f.url("revoked/X"), recursive: false, onChange: logC.sink)
    }
    let unknown = AccessRootID()
    await #expect(throws: FileAccessError.needsReconnection(unknown)) {
        try await f.hub.subscribe(rootID: unknown, folder: f.url("revoked/X"), recursive: false, onChange: logC.sink)
    }
    #expect(f.source.starts == before.starts)
    #expect(!f.source.startURLs.contains(canonicalPath(f.url("revoked"))))
    #expect(f.scope.counts == before.scope)
    #expect(f.source.active == 0)
}

private struct Probe: Sendable {
    let id: Int
    let subscription: any FolderWatchSubscription
    let log: ChangeLog
}

private enum WatchOp: Sendable { case subscribe(Int, String, Bool, ChangeLog), cancel(Probe) }

private func runConcurrently(_ ops: [WatchOp], _ f: WatchFixture, _ root: AccessRootID) async throws -> [Probe] {
    try await withThrowingTaskGroup(of: Probe?.self) { group in
        for op in ops {
            group.addTask {
                switch op {
                case .subscribe(let id, let path, let recursive, let log):
                    let subscription = try await f.hub.subscribe(rootID: root, folder: f.url(path), recursive: recursive, onChange: log.sink)
                    return Probe(id: id, subscription: subscription, log: log)
                case .cancel(let probe):
                    await probe.subscription.cancel(); return nil
                }
            }
        }
        var made: [Probe] = []
        for try await probe in group { if let probe { made.append(probe) } }
        return made.sorted { $0.id < $1.id }
    }
}

/// Returns a failure description, or nil when the per-root law holds at this quiescent point.
private func refCountViolation(_ f: WatchFixture, live: [Probe], dead: [Probe]) async -> String? {
    let expected = live.isEmpty ? 0 : 1
    let settled = (try? await poll {
        let counts = f.scope.counts
        return f.source.active == expected && counts[0] - counts[1] == expected && f.source.starts - f.source.stops == f.source.active
    }) ?? false
    guard settled else {
        return "live=\(live.count) active=\(f.source.active) scope=\(f.scope.counts) starts=\(f.source.starts) stops=\(f.source.stops)"
    }
    guard f.source.maxActive <= 1 else { return "maxActive=\(f.source.maxActive)" }
    let before = (live + dead).map(\.log.count)
    f.source.emit([.mustRescan], on: f.url("root"))
    f.clock.advance(by: 1000)
    for (probe, count) in zip(live, before) where probe.log.count != count + 1 {
        return "live subscriber \(probe.id) got \(probe.log.count - count) changes"
    }
    for (probe, count) in zip(dead, before.dropFirst(live.count)) where probe.log.count != count {
        return "cancelled subscriber \(probe.id) got \(probe.log.count - count) changes"
    }
    return nil
}

@Test(.timeLimit(.minutes(2))) func watchHubRefCountInvariantHoldsForAnyInterleaving() async throws {
    let specs = [("root/A", false), ("root/A", true), ("root/B", false)]
    for seed in UInt64(1)...40 {
        for n in 1...8 {
            var rng = SplitMix64(seed: seed &* 1_000 &+ UInt64(n))
            let f = try WatchFixture(folders: ["root/A", "root/B"])
            defer { f.remove() }
            let root = try await f.access.grant(folder: f.url("root"))
            var nextID = 0, ops: [String] = []
            var live: [Probe] = [], dead: [Probe] = []
            func fresh() -> WatchOp {
                let spec = specs[Int.random(in: 0..<specs.count, using: &rng)]
                nextID += 1; ops.append("sub#\(nextID)(\(spec.0),\(spec.1))")
                return .subscribe(nextID, spec.0, spec.1, ChangeLog(clock: f.clock))
            }
            func cancel(_ probe: Probe) -> WatchOp { ops.append("cancel#\(probe.id)"); return .cancel(probe) }
            func failed(_ phase: String, _ why: String) -> Bool {
                Issue.record("seed=\(seed) N=\(n) phase=\(phase) \(why) ops=\(ops.joined(separator: " "))"); return true
            }

            live = try await runConcurrently((0..<n).map { _ in fresh() }, f, root)
            if f.source.starts != 1, failed("1", "starts=\(f.source.starts)") { return }
            if let why = await refCountViolation(f, live: live, dead: dead), failed("1", why) { return }

            var order = live.shuffled(using: &rng)
            while !order.isEmpty {
                let take = min(order.count, Int.random(in: 1...3, using: &rng))
                var chunk = order.prefix(take).map(cancel)
                let cancelled = Set(order.prefix(take).map(\.id))
                order.removeFirst(take)
                var subscribes = false
                if Int.random(in: 0..<5, using: &rng) == 0 {
                    if !dead.isEmpty, Bool.random(using: &rng) { chunk.append(cancel(dead[Int.random(in: 0..<dead.count, using: &rng)])) }
                    else { chunk.append(fresh()); subscribes = true }
                }
                let (stops, wasLive) = (f.source.stops, !live.isEmpty)
                let made = try await runConcurrently(chunk, f, root)
                dead += live.filter { cancelled.contains($0.id) }
                live = live.filter { !cancelled.contains($0.id) } + made
                if wasLive, live.isEmpty, !subscribes, f.source.stops != stops + 1,
                   failed("2", "last cancel made \(f.source.stops - stops) stops") { return }
                if let why = await refCountViolation(f, live: live, dead: dead), failed("2", why) { return }
            }

            if live.isEmpty { live = try await runConcurrently([fresh()], f, root) }
            let last = live.removeLast()
            _ = try await runConcurrently(live.map(cancel), f, root)
            dead += live
            let raced = try await runConcurrently([cancel(last), fresh()], f, root)
            dead.append(last); live = raced
            if let why = await refCountViolation(f, live: live, dead: dead), failed("3", why) { return }

            _ = try await runConcurrently(live.map(cancel), f, root)
            dead += live; live = []
            if let why = await refCountViolation(f, live: live, dead: dead), failed("4", why) { return }
            if f.scope.counts[0] != f.scope.counts[1] || f.source.active != 0,
               failed("4", "scope=\(f.scope.counts) active=\(f.source.active)") { return }
        }
    }
}
