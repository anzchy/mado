import Foundation
import Observation
import Testing
import MadoCore
@testable import MadoApplication

@MainActor private func issue344FolderSession(
    store: InMemoryDisplayPreferencesStore, names: [String] = ["img1.png", "img2.png", "img3.png"],
    input: String? = "img1.png", complete: Bool = true
) async throws -> (FolderScanFixture, FolderNavigationHost, ViewerSession, Task<Void, any Error>) {
    let fixture = FolderScanFixture(), host = FolderNavigationHost()
    let session = ViewerSession(preferencesStore: store, host: host)
    session.folderScan = fixture.coordinator
    fixture.coordinator.host = host
    let task = fixture.coordinator.begin(folder: fixture.folder, rootID: fixture.id,
        input: input.map { fixture.folder.appendingPathComponent($0) })
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(names)
    if complete { await fixture.scanner.finish(); try await task.value }
    return (fixture, host, session, task)
}

@MainActor private func issue344Command(_ command: CommandID, session: ViewerSession) {
    _ = CommandRouter().route(command, from: .key, to: session)
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue344SessionLoopStopsWrapsAndStopsAgain() async throws {
    let store = InMemoryDisplayPreferencesStore()
    let (_, host, session, _) = try await issue344FolderSession(store: store)
    #expect(!session.isEnabled(.previous))
    issue344Command(.previous, session: session)
    #expect(host.opens.isEmpty)
    session.setFolderLoopEnabled(true)
    #expect(store.value.loopThroughImages)
    #expect(session.isEnabled(.previous))
    issue344Command(.previous, session: session)
    issue344Command(.next, session: session)
    #expect(host.opens.map(\.0.lastPathComponent) == ["img3.png", "img1.png"])
    session.setFolderLoopEnabled(false)
    #expect(!store.value.loopThroughImages)
    issue344Command(.previous, session: session)
    issue344Command(.next, session: session)
    issue344Command(.next, session: session)
    #expect(!session.isEnabled(.next))
    issue344Command(.next, session: session)
    #expect(host.opens.map(\.0.lastPathComponent) == ["img3.png", "img1.png", "img2.png", "img3.png"])
    #expect(host.navigation.isEmpty)
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue344SessionLoopTwoWindowsShareLiveUpdates() async throws {
    let store = InMemoryDisplayPreferencesStore()
    let (_, firstHost, first, _) = try await issue344FolderSession(store: store)
    let (_, secondHost, second, _) = try await issue344FolderSession(store: store)
    first.setFolderLoopEnabled(true)
    #expect(first.displayPreferences.loopThroughImages && second.displayPreferences.loopThroughImages)
    issue344Command(.previous, session: second)
    issue344Command(.next, session: second)
    #expect(secondHost.opens.map(\.0.lastPathComponent) == ["img3.png", "img1.png"])
    second.setFolderLoopEnabled(false)
    #expect(!first.displayPreferences.loopThroughImages && !second.displayPreferences.loopThroughImages)
    issue344Command(.previous, session: first)
    issue344Command(.next, session: first)
    issue344Command(.next, session: first)
    issue344Command(.next, session: first)
    #expect(firstHost.opens.map(\.0.lastPathComponent) == ["img2.png", "img3.png"])
    #expect(firstHost.navigation.isEmpty && secondHost.navigation.isEmpty)
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue344SessionLoopIncompleteEndpointsWaitForCompletion() async throws {
    var preferences = DisplayPreferences()
    preferences.loopThroughImages = true
    let (fixture, host, session, task) = try await issue344FolderSession(
        store: InMemoryDisplayPreferencesStore(preferences), names: ["img1.png", "img2.png"], complete: false)
    issue344Command(.previous, session: session)
    #expect(host.opens.isEmpty)
    issue344Command(.next, session: session)
    issue344Command(.next, session: session)
    #expect(host.opens.map(\.0.lastPathComponent) == ["img2.png"])
    await fixture.scanner.finish(); try await task.value
    issue344Command(.next, session: session)
    issue344Command(.previous, session: session)
    #expect(host.opens.map(\.0.lastPathComponent) == ["img2.png", "img1.png", "img2.png"])
    #expect(host.navigation.isEmpty)
}

@Test(.timeLimit(.minutes(2)), arguments: [false, true]) @MainActor
func issue344SessionLoopEmptyAndSingletonNeverReopen(singleton: Bool) async throws {
    var preferences = DisplayPreferences()
    preferences.loopThroughImages = true
    let (_, host, session, _) = try await issue344FolderSession(store: InMemoryDisplayPreferencesStore(preferences),
        names: singleton ? ["img1.png"] : [], input: singleton ? "img1.png" : nil)
    let before = host.opens
    issue344Command(.previous, session: session)
    issue344Command(.next, session: session)
    #expect(host.opens.map(\.0) == before.map(\.0))
    #expect(!session.isEnabled(.previous) && !session.isEnabled(.next))
    #expect(host.navigation.isEmpty)
}

@Test(.timeLimit(.minutes(2)), arguments: [2, 3, 5], [false, true]) @MainActor
func issue344SessionLoopCyclesRespectFilteredOrder(count: Int, descending: Bool) async throws {
    var preferences = DisplayPreferences()
    preferences.loopThroughImages = true
    let names = (1...count).map { "img\($0).png" }
    let (fixture, host, session, _) = try await issue344FolderSession(store: InMemoryDisplayPreferencesStore(preferences),
        names: Array(names.reversed()) + ["excluded.jpg"])
    session.setFolderConditions(.init(sort: .name, direction: descending ? .descending : .ascending,
                                     selectedExtensions: ["png"]))
    let ordered = descending ? Array(names.reversed()) : names
    let start = try #require(ordered.firstIndex(of: "img1.png"))
    var expected: [String] = []
    var index = start
    for command in [CommandID.next, .previous] {
        for _ in 0..<count {
            index = (index + (command == .next ? 1 : count - 1)) % count
            expected.append(ordered[index])
            issue344Command(command, session: session)
        }
        #expect(fixture.coordinator.currentURL?.lastPathComponent == "img1.png")
    }
    #expect(host.opens.map(\.0.lastPathComponent) == expected)
    #expect(!host.opens.contains { $0.0.lastPathComponent == "excluded.jpg" })
    #expect(host.navigation.isEmpty)
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue344SessionLoopRestoreKeepsLatestSharedPreference() async throws {
    let store = InMemoryDisplayPreferencesStore()
    let (fixture, host, session, _) = try await issue344FolderSession(store: store)
    let otherWindow = ViewerSession(preferencesStore: store)
    session.setFolderConditions(.init(selectedExtensions: ["png"]))
    let snapshot = fixture.coordinator.snapshot
    let conditions = session.folderConditions
    let first = fixture.folder.appendingPathComponent("img1.png")
    session.beginFolderEntry(shownImage: first, hasCompleteGrid: false)
    session.enterFolderGrid(items: [], sourceVersion: .init(0))
    let reading = fixture.coordinator.begin(folder: fixture.root.appendingPathComponent("B"), rootID: fixture.id)
    await fixture.scanner.waitForStart(1)
    otherWindow.setFolderLoopEnabled(true)
    #expect(session.cancelFolderEntry() == .viewer(first))
    #expect(fixture.coordinator.snapshot == snapshot)
    #expect(session.folderConditions == conditions)
    #expect(session.displayPreferences.loopThroughImages)
    issue344Command(.previous, session: session)
    #expect(host.opens.last?.0.lastPathComponent == "img3.png")
    await fixture.scanner.finish(1); try await reading.value
    #expect(session.displayPreferences.loopThroughImages)
    let replacement = fixture.coordinator.begin(folder: fixture.folder, rootID: fixture.id, input: first)
    await fixture.scanner.waitForStart(2)
    try await fixture.scanner.deliver(["img1.png", "img2.png"], at: 2)
    await fixture.scanner.finish(2); try await replacement.value
    issue344Command(.previous, session: session)
    #expect(host.opens.last?.0.lastPathComponent == "img2.png")
    #expect(store.value.loopThroughImages)
}

// #345 supersedes #344's temporary no-wrap limitation; session coverage is in Issue345LoopSetTests.

@MainActor private final class Issue344ObservationSignal {
    var changed = false
}

@Test(.timeLimit(.minutes(2)), arguments: [CommandID.previous, .next]) @MainActor
func issue344SessionLoopObservationInvalidatesOtherWindowEndpoints(command: CommandID) async throws {
    let store = InMemoryDisplayPreferencesStore()
    let first = ViewerSession(preferencesStore: store)
    let (_, host, second, _) = try await issue344FolderSession(store: store,
        input: command == .previous ? "img1.png" : "img3.png")
    let enabledSignal = Issue344ObservationSignal()
    withObservationTracking {
        #expect(!second.isEnabled(command))
    } onChange: {
        MainActor.assumeIsolated { enabledSignal.changed = true }
    }
    first.setFolderLoopEnabled(true)
    #expect(enabledSignal.changed)
    #expect(second.isEnabled(command))
    let disabledSignal = Issue344ObservationSignal()
    withObservationTracking {
        #expect(second.isEnabled(command))
    } onChange: {
        MainActor.assumeIsolated { disabledSignal.changed = true }
    }
    first.setFolderLoopEnabled(false)
    #expect(disabledSignal.changed)
    #expect(!second.isEnabled(command))
    #expect(host.opens.isEmpty)
}
