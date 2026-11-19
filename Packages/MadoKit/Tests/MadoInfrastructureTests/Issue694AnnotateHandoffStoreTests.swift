import Foundation
import Testing
import MadoApplication
import MadoInfrastructure

// #694 P7-11 CAP-02: the one-shot Annotate hand-off record in the App Group defaults the helper and Mado share.

private let record694 = CaptureAnnotateHandoffRecord(path: "/Users/u/Downloads/mado-20261113140532.png",
                                                     createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000.25))

@Test(.timeLimit(.minutes(2))) func issue694HandoffStoreWritesTakesOnceAcrossInstances() throws {
    let suite = "issue694-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let helper = UserDefaultsCaptureAnnotateHandoff(defaults: defaults)
    helper.write(record694)
    // Mado opens its own instance of the suite.
    let mado = UserDefaultsCaptureAnnotateHandoff(defaults: try #require(UserDefaults(suiteName: suite)))
    #expect(mado.take() == record694)
    #expect(mado.take() == nil, "one record serves one open")
    #expect(helper.take() == nil)
    #expect(defaults.object(forKey: UserDefaultsCaptureAnnotateHandoff.key) == nil)
}

@Test(.timeLimit(.minutes(2))) func issue694HandoffStoreClearAndOverwrite() throws {
    let suite = "issue694-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = UserDefaultsCaptureAnnotateHandoff(defaults: defaults)
    store.write(record694)
    store.clear()
    #expect(store.take() == nil)
    let newer = CaptureAnnotateHandoffRecord(path: "/Users/u/Downloads/mado-20261113140600.png",
                                             createdAt: record694.createdAt.addingTimeInterval(28))
    store.write(record694)
    store.write(newer)
    #expect(store.take() == newer, "the latest click wins")
}

/// Anything that is not a record (an older format, another writer) is dropped and never annotates.
@Test(.timeLimit(.minutes(2))) func issue694HandoffStoreIgnoresMalformedRecord() throws {
    let suite = "issue694-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = UserDefaultsCaptureAnnotateHandoff(defaults: defaults)
    for junk: Any in ["/Users/u/Downloads/a.png", Data("{\"path\":1}".utf8), 42] {
        defaults.set(junk, forKey: UserDefaultsCaptureAnnotateHandoff.key)
        #expect(store.take() == nil)
        #expect(defaults.object(forKey: UserDefaultsCaptureAnnotateHandoff.key) == nil)
    }
}

@Test(.timeLimit(.minutes(2))) func issue694HandoffStoreUsesTheSharedSuite() {
    #expect(UserDefaultsCaptureAnnotateHandoff.shared() != nil)
    #expect(UserDefaultsCaptureAnnotateHandoff.key == "captureAnnotateHandoff")
}
