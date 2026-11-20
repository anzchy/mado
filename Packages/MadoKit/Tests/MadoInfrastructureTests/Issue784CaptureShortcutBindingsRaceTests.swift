import Foundation
import Testing
import MadoApplication
@testable import MadoInfrastructure

/// Pauses the reader at its `pausedRead`-th read of the suite (counted across every read the reader makes), so a test
/// can land another process's write exactly there. The count follows the reads, so it does not depend on which key
/// the code reads first.
private actor BindingsReadGate {
    let entered: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    private let pausedRead: Int
    private var readCount = 0
    private var waiter: CheckedContinuation<Void, Never>?

    init(pausingAtRead pausedRead: Int = 1) {
        self.pausedRead = pausedRead
        (entered, signal) = AsyncStream.makeStream()
    }

    func pauseFirstRead() async {
        readCount += 1
        guard readCount == pausedRead else { return }
        signal.yield(())
        await withCheckedContinuation { waiter = $0 }
    }

    func releaseFirstRead() {
        waiter?.resume()
        waiter = nil
    }
}

private func plist(_ bindings: CaptureShortcutBindings) throws -> [String: [String: Any]] {
    var plist: [String: [String: Any]] = [:]
    for action in CaptureShortcutAction.allCases {
        let combo = try #require(bindings[action])
        plist[action.rawValue] = ["keyCode": Int(combo.keyCode), "key": combo.key, "modifiers": combo.modifiers.rawValue]
    }
    return plist
}

private let f = CaptureKeyCombo(keyCode: 3, key: "F", modifiers: [.control, .option, .command])

/// `base` with the region capture on ⌃⌥⌘F, as a user sets it in Settings.
private func withRegionOnF(_ base: CaptureShortcutBindings) -> CaptureShortcutBindings {
    var combos: [CaptureShortcutAction: CaptureKeyCombo] = [:]
    for action in CaptureShortcutAction.allCases { combos[action] = base[action] }
    combos[.region] = f
    return CaptureShortcutBindings(combos)
}

/// A suite holding #685's stored ⌃⇧⌘ set without a defaults version, and its name for cleanup.
private func legacySuite() throws -> (UserDefaults, String) {
    let suiteName = "issue784-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.set(try plist(.legacyDefaults), forKey: UserDefaultsCaptureShortcutPreferences.bindingsKey)
    return (defaults, suiteName)
}

/// Runs a migrating `bindings()` paused at `read`, lands `write` there (another process), then lets the read finish.
private func readWithWrite(at read: Int, on defaults: UserDefaults,
                           _ write: () async throws -> Void) async rethrows -> CaptureShortcutBindings {
    let gate = BindingsReadGate(pausingAtRead: read)
    let reader = UserDefaultsCaptureShortcutPreferences(defaults: defaults,
        afterEachRead: { await gate.pauseFirstRead() })
    let pending = Task { await reader.bindings() }
    var entered = gate.entered.makeAsyncIterator()
    _ = await entered.next()
    try await write()
    await gate.releaseFirstRead()
    return await pending.value
}

@Test(.timeLimit(.minutes(2))) func issue784OverlappingBindingReadsBothReturnMigratedDefaults() async throws {
    let suiteName = "issue784-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    var oldPlist: [String: [String: Any]] = [:]
    for action in CaptureShortcutAction.allCases {
        let combo = try #require(CaptureShortcutBindings.legacyDefaults[action])
        oldPlist[action.rawValue] = ["keyCode": Int(combo.keyCode), "key": combo.key,
                                     "modifiers": combo.modifiers.rawValue]
    }
    defaults.set(oldPlist, forKey: UserDefaultsCaptureShortcutPreferences.bindingsKey)
    let gate = BindingsReadGate()
    let preferences = UserDefaultsCaptureShortcutPreferences(defaults: defaults,
        afterEachRead: { await gate.pauseFirstRead() })

    let first = Task { await preferences.bindings() }
    var entered = gate.entered.makeAsyncIterator()
    _ = await entered.next()
    let secondResult = await preferences.bindings()
    await gate.releaseFirstRead()
    let firstResult = await first.value

    #expect(firstResult == .defaults)
    #expect(secondResult == .defaults)
    #expect(defaults.integer(forKey: UserDefaultsCaptureShortcutPreferences.defaultsVersionKey) == 2)
    #expect(await UserDefaultsCaptureShortcutPreferences(defaults: defaults).bindings() == .defaults)
}

/// gpt F1 / opus L1: Settings saves ⌃⌥⌘F through `setBindings()` while the helper's migrating read is paused after
/// its first read (between the two reads) or its second (after the snapshot, before the migration write).
@Test(.timeLimit(.minutes(2)), arguments: [1, 2])
func issue784UserSaveDuringAMigratingReadWins(read: Int) async throws {
    let (defaults, suiteName) = try legacySuite()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let saved = withRegionOnF(.defaults)

    let result = await readWithWrite(at: read, on: defaults) {
        await UserDefaultsCaptureShortcutPreferences(defaults: defaults).setBindings(saved)
    }

    #expect(result == saved, "the read paused at read \(read) returns the user's save")
    #expect(await UserDefaultsCaptureShortcutPreferences(defaults: defaults).bindings() == saved,
            "the user's ⌃⌥⌘F survives the migration paused at read \(read)")
    #expect(defaults.integer(forKey: UserDefaultsCaptureShortcutPreferences.defaultsVersionKey) == 2)
}

/// A changed stored set with no version yet (another process between its bindings and version writes, or a #685
/// helper still running): the changed action keeps the change, the actions still on the snapshot move.
@Test(.timeLimit(.minutes(2))) func issue784MigrationKeepsAnActionChangedSinceItsSnapshot() async throws {
    let (defaults, suiteName) = try legacySuite()
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let result = try await readWithWrite(at: 2, on: defaults) {
        defaults.set(try plist(withRegionOnF(.legacyDefaults)), forKey: UserDefaultsCaptureShortcutPreferences.bindingsKey)
    }

    #expect(result == withRegionOnF(.defaults))
    #expect(await UserDefaultsCaptureShortcutPreferences(defaults: defaults).bindings() == withRegionOnF(.defaults))
    #expect(defaults.integer(forKey: UserDefaultsCaptureShortcutPreferences.defaultsVersionKey) == 2)
}

/// Nothing stored means the defaults: a suite cleared after the snapshot (another process) stays cleared, and the
/// migration does not write the old snapshot back.
@Test(.timeLimit(.minutes(2))) func issue784SuiteClearedDuringAMigratingReadStaysCleared() async throws {
    let (defaults, suiteName) = try legacySuite()
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let result = await readWithWrite(at: 2, on: defaults) {
        defaults.removeObject(forKey: UserDefaultsCaptureShortcutPreferences.bindingsKey)
    }

    #expect(result == .defaults)
    #expect(defaults.dictionary(forKey: UserDefaultsCaptureShortcutPreferences.bindingsKey) == nil)
    #expect(await UserDefaultsCaptureShortcutPreferences(defaults: defaults).bindings() == .defaults)
}
