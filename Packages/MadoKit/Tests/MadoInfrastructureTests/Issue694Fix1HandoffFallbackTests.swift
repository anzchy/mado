import Foundation
import Testing
import MadoApplication
import MadoInfrastructure

// i694-fix1 (audit gpt M3 = opus M4/L2): the container-file adapter behind CaptureAnnotateHandoffPort, the store
// selection, and the explicit no-op when no store exists. In-process only: cross-process visibility is NOT VERIFIED.

private let record694F = CaptureAnnotateHandoffRecord(path: "/Users/u/Downloads/mado-20261122090000.png",
                                                      createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000.5))

private func tempDirectory694F() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("issue694f-\(UUID().uuidString)")
        .appendingPathComponent("container")
}

@Test(.timeLimit(.minutes(2))) func issue694Fix1FileStoreWritesTakesOnceAcrossInstances() throws {
    let directory = tempDirectory694F()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    let helper = FileCaptureAnnotateHandoff(directory: directory)
    helper.write(record694F)
    #expect(FileManager.default.fileExists(atPath: helper.fileURL.path), "the directory is created on write")
    let mado = FileCaptureAnnotateHandoff(directory: directory)
    #expect(mado.take() == record694F)
    #expect(mado.take() == nil, "one record serves one open")
    #expect((try? Data(contentsOf: helper.fileURL))?.isEmpty == true, "emptied in place, never deleted (#684)")
    helper.write(record694F)
    helper.clear()
    #expect(mado.take() == nil)
    let newer = CaptureAnnotateHandoffRecord(path: record694F.path, createdAt: record694F.createdAt.addingTimeInterval(5))
    helper.write(record694F)
    helper.write(newer)
    #expect(mado.take() == newer, "the latest click wins")
}

@Test(.timeLimit(.minutes(2))) func issue694Fix1FileStoreIgnoresMalformedRecord() throws {
    let directory = tempDirectory694F()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = FileCaptureAnnotateHandoff(directory: directory)
    try Data("{\"path\":1}".utf8).write(to: store.fileURL)
    #expect(store.take() == nil)
    #expect((try? Data(contentsOf: store.fileURL))?.isEmpty == true, "emptied in place, never deleted (#684)")
    // An unwritable directory: the write fails quietly and nothing is read back.
    let blocked = FileCaptureAnnotateHandoff(directory: store.fileURL.appendingPathComponent("not-a-directory"))
    try Data().write(to: store.fileURL)
    blocked.write(record694F)
    #expect(blocked.take() == nil)
}

@Test(.timeLimit(.minutes(2))) func issue694Fix1FileStoreDefaultsToTheAppGroupContainer() throws {
    let shared = try #require(FileCaptureAnnotateHandoff.shared())
    #expect(shared.directory.path.contains(CaptureBarIdentity.appGroupID))
    #expect(shared.fileURL.lastPathComponent == "captureAnnotateHandoff.json")
    #expect(CaptureAnnotateHandoffStores.shared().stores.count == 2, "defaults first, then the container file")
    #expect(CaptureAnnotateHandoffStores.shared().stores.first is UserDefaultsCaptureAnnotateHandoff)
}

/// A store whose writes go nowhere another process can see (an unshared suite): the record still arrives by the file.
@Test(.timeLimit(.minutes(2))) func issue694Fix1StoresWriteEveryStoreAndTakeTheNewest() throws {
    let suite = "issue694f-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let directory = tempDirectory694F()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    let suiteStore = UserDefaultsCaptureAnnotateHandoff(defaults: defaults)
    let fileStore = FileCaptureAnnotateHandoff(directory: directory)
    let helper = CaptureAnnotateHandoffStores(defaults: suiteStore, file: fileStore)
    #expect(helper.isAvailable)
    helper.write(record694F)
    // Mado sees only the file (the suite write never reached it).
    let lost = UserDefaultsCaptureAnnotateHandoff(defaults: try #require(UserDefaults(suiteName: "issue694f-\(UUID().uuidString)")))
    let mado = CaptureAnnotateHandoffStores(defaults: lost, file: FileCaptureAnnotateHandoff(directory: directory))
    #expect(mado.take() == record694F)
    #expect(suiteStore.take() == record694F, "the helper's own suite still had it")
    // Both stores hold records: the newest wins and both are cleared.
    let newer = CaptureAnnotateHandoffRecord(path: record694F.path, createdAt: record694F.createdAt.addingTimeInterval(9))
    suiteStore.write(newer)
    fileStore.write(record694F)
    #expect(helper.take() == newer)
    #expect(suiteStore.take() == nil && fileStore.take() == nil)
    helper.write(record694F)
    helper.clear()
    #expect(suiteStore.take() == nil && fileStore.take() == nil)
}

@Test(.timeLimit(.minutes(2))) func issue694Fix1StoresSelection() throws {
    let directory = tempDirectory694F()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    let file = FileCaptureAnnotateHandoff(directory: directory)
    let onlyFile = CaptureAnnotateHandoffStores(defaults: nil, file: file)
    #expect(onlyFile.stores.count == 1 && onlyFile.isAvailable)
    onlyFile.write(record694F)
    #expect(file.take() == record694F, "no App Group suite: the container file carries it")
    // Nothing available: an explicit no-op, never a write to the helper's own defaults.
    let none = CaptureAnnotateHandoffStores(defaults: nil, file: nil)
    #expect(none.stores.isEmpty && !none.isAvailable)
    none.write(record694F)
    #expect(none.take() == nil)
    none.clear()
}
