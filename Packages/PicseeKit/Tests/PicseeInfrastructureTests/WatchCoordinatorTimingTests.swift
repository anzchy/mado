import Foundation
import Testing
import PicseeCore
import PicseeApplication
@testable import PicseeInfrastructure

@Test(.timeLimit(.minutes(2))) @MainActor func watchedCoordinatorUpdatesWithinTwoSecondsOfQuiescenceOnOneFakeClock() async throws {
    // Fake event source → real hub debounce → real coordinator → in-memory rescan → snapshot.
    // Scan duration is zero fake time: this bounds pipeline waiting, not large-folder scan performance (未测).
    let w = TimingCoordinatorFixture()
    let c = w.coordinator
    defer { c.end() }
    let initial = c.begin(folder: w.folder, rootID: w.rootID)
    defer { initial.cancel() }
    try await w.trace.waitForEnd(generation: 1, at: 0)
    let step = 10, writes = Array(stride(from: 0, to: 3000, by: 100)), lastWrite = writes[writes.count - 1]
    var updates: [(at: Int, names: [String])] = [], shown = w.names()
    // Only the three flush boundaries suspend the burst driver. Each wait requires an actual scan end,
    // rather than accepting begins == ends before the watch callback has even reached the MainActor.
    func settle(at t: Int) async throws {
        try await w.trace.waitForEnd(generation: UInt64(updates.count + 2), at: t)
        #expect(w.trace.begins == w.trace.ends.map(\.generation), "t=\(t) unmatched refresh begin/end")
        #expect(w.trace.ends.allSatisfy { $0.outcome == .complete })
        if w.names() != shown { shown = w.names(); updates.append((t, shown)) }
    }
    for t in writes {
        w.clock.advance(to: t)
        let name = "n\(t / 100).png"
        w.scanner.add(name)
        w.source.emit([.changed(w.folder.appendingPathComponent(name))], on: w.root)
        if t == 1000 || t == 2000 { try await settle(at: t) }
    }
    w.clock.advance(to: 3000)
    try await settle(at: 3000)
    // Finish the original observation window without polling or creating additional actor turns.
    w.clock.advance(to: lastWrite + 3000)
    let during = updates.filter { $0.at <= lastWrite }
    // A continuous burst still updates at least once per max wait (here at 1000 and 2000, then 3000 after it).
    #expect(during.count >= lastWrite / WatchHub.maxWaitMilliseconds, "updates during the burst: \(updates.map(\.at))")
    #expect((updates.first?.at ?? .max) <= WatchHub.maxWaitMilliseconds + step, "first update \(updates.map(\.at))")
    for (earlier, later) in zip(updates, updates.dropFirst()) {
        #expect(later.at - earlier.at <= WatchHub.maxWaitMilliseconds + step, "gap \(earlier.at)→\(later.at)")
    }
    let final = try #require(updates.last)
    #expect(final.names.contains("n\(lastWrite / 100).png"))
    #expect(final.at <= lastWrite + 2000, "final update at \(final.at), last write \(lastWrite)")
    #expect(final.at <= lastWrite + WatchHub.debounceMilliseconds + step, "final update at \(final.at)")
    #expect(Set(c.sourceSnapshot?.entries.map(\.itemID) ?? []) == Set(w.scanner.entries.map(\.itemID)))
}
