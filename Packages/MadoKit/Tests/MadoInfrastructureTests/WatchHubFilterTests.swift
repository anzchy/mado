import Foundation
import Testing
import MadoCore
@testable import MadoInfrastructure

@Test func watchHubRelevanceFilterMatchesFolderScope() async throws {
    // (row, subscriber folder spelling or nil for the fixture's own, hint, recursive notified, flat notified)
    typealias Row = (name: String, folder: (WatchFixture) -> URL, hint: (WatchFixture) -> FolderChangeHint, recursive: Bool, flat: Bool)
    let plainF: (WatchFixture) -> URL = { $0.url("root/F") }
    func changed(_ path: String) -> (WatchFixture) -> FolderChangeHint { { .changed($0.url(path)) } }
    let rows: [Row] = [
        ("R1 child", plainF, changed("root/F/x.png"), true, true),
        ("R2 grandchild", plainF, changed("root/F/sub/x.png"), true, false),
        ("R3 child dir", plainF, changed("root/F/sub"), true, true),
        ("R4 folder itself", plainF, changed("root/F"), true, true),
        ("R5 ancestor", plainF, changed("root"), true, true),
        ("R6 sibling", plainF, changed("root/G/x.png"), false, false),
        ("R7 string-prefix sibling", plainF, changed("root/F2/x.png"), false, false),
        ("R8 mustRescan", plainF, { _ in .mustRescan }, true, true),
        ("R9 /var folder, /private hint", { $0.spellings("root/F").plain },
         { .changed($0.spellings("root/F/x.png").privateVar) }, true, true),
        ("R10 /private folder, /var hint", { $0.spellings("root/F").privateVar },
         { .changed($0.spellings("root/F/x.png").plain) }, true, true),
        ("R11 deleted child, /private hint", plainF, { .changed($0.spellings("root/F/gone.png").privateVar) }, true, true),
        ("R11b deleted child, /private folder, /var hint", { $0.spellings("root/F").privateVar },
         { .changed($0.spellings("root/F/gone.png").plain) }, true, true),
        ("R11c deleted grandchild dir, /private hint", plainF,
         { .changed($0.spellings("root/F/gone/deeper.png").privateVar) }, true, false),
        ("R12 deleted sibling, /private hint", plainF, { .changed($0.spellings("root/G/gone.png").privateVar) }, false, false),
    ]
    for row in rows {
        let (f, root) = try await WatchFixture.filterRoot()
        defer { f.remove() }
        try #require(f.spellings("root").plain.path.hasPrefix("/var/"), "temp dir is not under /var: \(f.base.path)")
        let recursiveLog = ChangeLog(clock: f.clock), flatLog = ChangeLog(clock: f.clock)
        let r = try await f.hub.subscribe(rootID: root, folder: row.folder(f), recursive: true, onChange: recursiveLog.sink)
        let s = try await f.hub.subscribe(rootID: root, folder: row.folder(f), recursive: false, onChange: flatLog.sink)
        let hint = row.hint(f)
        f.emit([hint], at: 0)
        f.clock.advance(to: 1000)
        #expect(recursiveLog.count == (row.recursive ? 1 : 0), "row \(row.name) recursive")
        #expect(flatLog.count == (row.flat ? 1 : 0), "row \(row.name) flat")
        await r.cancel(); await s.cancel()
    }

    // A mixed batch with any relevant hint flushes once; a batch of only irrelevant hints flushes nothing.
    let (f, root) = try await WatchFixture.filterRoot()
    defer { f.remove() }
    let flatLog = ChangeLog(clock: f.clock)
    let s = try await f.hub.subscribe(rootID: root, folder: f.url("root/F"), recursive: false, onChange: flatLog.sink)
    let batch: [FolderChangeHint] = [.changed(f.url("root/G/x.png")), .changed(f.url("root/F/x.png")),
        .changed(f.url("root/F/sub/x.png")), .changed(f.url("root/F/sub"))]
    f.emit([batch[0], batch[2]], at: 0)
    f.clock.advance(to: 1000)
    #expect(flatLog.count == 0)
    f.emit(batch, at: 1000)
    f.clock.advance(to: 2000)
    #expect(flatLog.times == [1200])
    await s.cancel()
}

private func flushTimes(_ log: ChangeLog) -> [Int] { log.times }

@Test func watchHubDebounceFlushesExactlyAtWindowDeadline() async throws {
    func fixture() async throws -> (WatchFixture, AccessRootID, ChangeLog, any FolderWatchSubscription) {
        let (f, root) = try await WatchFixture.filterRoot()
        let log = ChangeLog(clock: f.clock)
        let sub = try await f.hub.subscribe(rootID: root, folder: f.url("root/F"), recursive: false, onChange: log.sink)
        return (f, root, log, sub)
    }

    // D1: one event flushes exactly at +200, not before.
    do {
        let (f, _, log, _) = try await fixture(); defer { f.remove() }
        f.emit([.changed(f.url("root/F/x.png"))], at: 0)
        f.clock.advance(to: 199)
        #expect(log.count == 0, "D1 flushed before 200")
        f.clock.advance(to: 200)
        #expect(flushTimes(log) == [200], "D1")
    }
    // D2: a 150 ms burst is cut by the 1000 ms max wait, then trails 200 ms after the last event.
    do {
        let (f, _, log, _) = try await fixture(); defer { f.remove() }
        let hints = (0..<20).map { FolderChangeHint.changed(f.url("root/F/e\($0).png")) }
        for (i, hint) in hints.enumerated() { f.emit([hint], at: i * 150) }
        f.clock.advance(to: 6000)
        #expect(flushTimes(log) == [1000, 2050, 3050], "D2")
    }
    // D3: an event after a flush starts a new window.
    do {
        let (f, _, log, _) = try await fixture(); defer { f.remove() }
        f.emit([.changed(f.url("root/F/a.png"))], at: 0)
        f.emit([.changed(f.url("root/F/b.png"))], at: 500)
        f.clock.advance(to: 2000)
        #expect(flushTimes(log) == [200, 700], "D3")
    }
    // D4: cancelling with a flush pending drops it.
    do {
        let (f, _, log, sub) = try await fixture(); defer { f.remove() }
        f.emit([.changed(f.url("root/F/x.png"))], at: 0)
        f.clock.advance(to: 100)
        await sub.cancel()
        f.clock.advance(to: 5000)
        #expect(log.count == 0, "D4")
    }
    // D5: cancelling one of two pending subscribers keeps the other's flush.
    do {
        let (f, root, logA, a) = try await fixture(); defer { f.remove() }
        let logB = ChangeLog(clock: f.clock)
        let b = try await f.hub.subscribe(rootID: root, folder: f.url("root/F"), recursive: false, onChange: logB.sink)
        f.emit([.changed(f.url("root/F/x.png"))], at: 0)
        f.clock.advance(to: 100)
        await a.cancel()
        f.clock.advance(to: 400)
        #expect(logA.count == 0, "D5 A")
        #expect(flushTimes(logB) == [200], "D5 B")
        await b.cancel()
    }
    // D6: an irrelevant (sibling) event between relevant ones reschedules nothing.
    do {
        let (f, _, log, _) = try await fixture(); defer { f.remove() }
        let first = FolderChangeHint.changed(f.url("root/F/a.png")), second = FolderChangeHint.changed(f.url("root/F/b.png"))
        f.emit([first], at: 0)
        f.emit([.changed(f.url("root/G/x.png"))], at: 150)
        f.emit([second], at: 300)
        f.clock.advance(to: 2000)
        #expect(flushTimes(log) == [200, 500], "D6")
    }
    // D7: each subscriber has its own timer.
    do {
        let (f, root) = try await WatchFixture.filterRoot(); defer { f.remove() }
        let logA = ChangeLog(clock: f.clock), logB = ChangeLog(clock: f.clock)
        let a = try await f.hub.subscribe(rootID: root, folder: f.url("root/F"), recursive: false, onChange: logA.sink)
        let b = try await f.hub.subscribe(rootID: root, folder: f.url("root/G"), recursive: false, onChange: logB.sink)
        f.emit([.changed(f.url("root/F/x.png"))], at: 0)
        f.emit([.changed(f.url("root/G/y.png"))], at: 150)
        f.clock.advance(to: 2000)
        #expect(flushTimes(logA) == [200], "D7 A")
        #expect(flushTimes(logB) == [350], "D7 B")
        await a.cancel(); await b.cancel()
    }

    // Property: for generated timelines the flushes are exactly the law's windows.
    for seed in UInt64(1)...300 {
        var rng = SplitMix64(seed: seed)
        let (f, _, log, _) = try await fixture(); defer { f.remove() }
        var t = 0, timeline: [(at: Int, hint: FolderChangeHint, relevant: Bool)] = []
        for i in 0..<Int.random(in: 1...40, using: &rng) {
            t += Int.random(in: 0..<10, using: &rng) < 7 ? Int.random(in: 1...190, using: &rng) : Int.random(in: 201...1500, using: &rng)
            let relevant = Int.random(in: 0..<10, using: &rng) >= 3
            timeline.append((t, .changed(f.url(relevant ? "root/F/e\(i).png" : "root/G/e\(i).png")), relevant))
        }
        var expected: [Int] = []
        var window: (start: Int, deadline: Int)?
        for event in timeline {
            if let open = window, open.deadline <= event.at { expected.append(open.deadline); window = nil }
            guard event.relevant else { continue }
            if let open = window {
                window = (open.start, min(event.at + 200, open.start + 1000))
            } else { window = (event.at, event.at + 200) }
        }
        if let open = window { expected.append(open.deadline) }

        for event in timeline { f.emit([event.hint], at: event.at) }
        f.clock.advance(to: t + 2000)
        let observed = log.times
        if observed != expected {
            let mismatch = zip(observed, expected).enumerated().first { $1.0 != $1.1 }?.offset ?? min(observed.count, expected.count)
            Issue.record("""
                seed=\(seed) first mismatching window=\(mismatch) observed=\(observed) expected=\(expected) \
                timeline=\(timeline.map { "\($0.at)\($0.relevant ? "" : "~")" })
                """)
            return
        }
    }
}
