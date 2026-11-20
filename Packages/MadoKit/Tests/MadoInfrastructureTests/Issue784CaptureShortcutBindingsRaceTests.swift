import Foundation
import Testing
import MadoApplication
@testable import MadoInfrastructure

private actor BindingsReadGate {
    let entered: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    private var readCount = 0
    private var firstWaiter: CheckedContinuation<Void, Never>?

    init() { (entered, signal) = AsyncStream.makeStream() }

    func pauseFirstRead() async {
        readCount += 1
        guard readCount == 1 else { return }
        signal.yield(())
        await withCheckedContinuation { firstWaiter = $0 }
    }

    func releaseFirstRead() {
        firstWaiter?.resume()
        firstWaiter = nil
    }
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
        afterBindingsRead: { await gate.pauseFirstRead() })

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
