import Foundation
import Testing
import MadoCore
@testable import MadoInfrastructure

private final class Canary: Sendable {}

private func attempt(_ body: () async throws -> any FolderWatchSubscription) async -> Result<any FolderWatchSubscription, any Error> {
    do { return .success(try await body()) } catch { return .failure(error) }
}

@Test(.timeLimit(.minutes(2))) func watchHubRefusedStreamHoldsNothingAndLaterStartsOnce() async throws {
    let f = try WatchFixture(folders: ["root/A", "root/B"])
    defer { f.remove() }
    let root = try await f.access.grant(folder: f.url("root"))
    let base = f.scope.counts, log = ChangeLog(clock: f.clock)

    // A refused start throws, releases the lease and leaves no stream.
    f.source.refusals = 1
    await #expect(throws: FolderWatchError.streamStartRefused) {
        try await f.hub.subscribe(rootID: root, folder: f.url("root/A"), recursive: false, onChange: log.sink)
    }
    #expect(f.source.refused == 1 && f.source.starts == 0 && f.source.active == 0)
    #expect(f.scope.counts[0] - f.scope.counts[1] == base[0] - base[1])
    f.source.emit([.mustRescan], on: f.url("root"))
    f.clock.advance(by: 1000)
    #expect(log.count == 0)

    // The next subscribe starts exactly one live stream.
    let live = try await f.hub.subscribe(rootID: root, folder: f.url("root/A"), recursive: false, onChange: log.sink)
    #expect(f.source.starts == 1 && f.source.active == 1)
    f.source.emit([.changed(f.url("root/A/x.png"))], on: f.url("root"))
    f.clock.advance(by: 200)
    #expect(log.count == 1)
    await live.cancel()
    #expect(f.source.active == 0 && f.scope.counts[0] - f.scope.counts[1] == base[0] - base[1])

    // Two concurrent subscribers, one refusal: exactly one throws, the other is really live.
    let logs = (ChangeLog(clock: f.clock), ChangeLog(clock: f.clock))
    f.source.refusals = 1
    async let first = attempt { try await f.hub.subscribe(rootID: root, folder: f.url("root/A"), recursive: false, onChange: logs.0.sink) }
    async let second = attempt { try await f.hub.subscribe(rootID: root, folder: f.url("root/B"), recursive: false, onChange: logs.1.sink) }
    let results = await [first, second]
    let failed = results.filter { if case .failure = $0 { true } else { false } }
    #expect(failed.count == 1)
    #expect(f.source.refused == 2 && f.source.starts == 2 && f.source.active == 1)
    #expect(f.scope.counts[0] - f.scope.counts[1] == base[0] - base[1] + 1)
    f.source.emit([.mustRescan], on: f.url("root"))
    f.clock.advance(by: 200)
    #expect(logs.0.count + logs.1.count == 1)
    for case .success(let subscription) in results { await subscription.cancel() }
    #expect(f.source.active == 0 && f.scope.counts[0] - f.scope.counts[1] == base[0] - base[1])

    // Two concurrent subscribers, two refusals: both throw and nothing is held.
    f.source.refusals = 2
    async let third = attempt { try await f.hub.subscribe(rootID: root, folder: f.url("root/A"), recursive: false, onChange: logs.0.sink) }
    async let fourth = attempt { try await f.hub.subscribe(rootID: root, folder: f.url("root/B"), recursive: true, onChange: logs.1.sink) }
    let both = await [third, fourth]
    #expect(both.allSatisfy { if case .failure(let error) = $0 { (error as? FolderWatchError) == .streamStartRefused } else { false } })
    #expect(f.source.refused == 4 && f.source.active == 0)
    #expect(f.scope.counts[0] - f.scope.counts[1] == base[0] - base[1])
}

@Test func fsEventSourceThrowsWhenTheStreamCannotBeCreatedOrStarted() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fsevents-refuse-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    weak var refusedCanary: Canary?, uncreatedCanary: Canary?
    do {
        let canary = Canary(); refusedCanary = canary
        #expect(throws: FolderWatchError.streamStartRefused) {
            try FSEventSource(start: { _ in false }).start(watching: dir) { _ in _ = canary }
        }
    }
    do {
        let canary = Canary(); uncreatedCanary = canary
        #expect(throws: FolderWatchError.streamCreateFailed) {
            try FSEventSource(create: { _, _, _ in nil }).start(watching: dir) { _ in _ = canary }
        }
    }
    // A refused stream is invalidated and released: nothing keeps its handler alive.
    #expect(refusedCanary == nil)
    #expect(uncreatedCanary == nil)
}
