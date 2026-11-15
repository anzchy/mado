import CoreGraphics
import Foundation
import Testing
import MadoApplication
import MadoInfrastructure

// #685 AC-3: the bar's position and collapsed state persist across relaunch.

@Test(.timeLimit(.minutes(2))) func issue685BarLayoutPersistsPerArrangementAcrossInstances() async throws {
    let name = "issue685-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let first = UserDefaultsCaptureBarLayout(defaults: defaults)
    #expect(await first.origin(forArrangement: "a") == nil)
    #expect(await first.isCollapsed() == false)
    await first.setOrigin(CGPoint(x: 120.5, y: -40), forArrangement: "a")
    await first.setOrigin(CGPoint(x: 9, y: 8), forArrangement: "b")
    await first.setCollapsed(true)
    let relaunched = UserDefaultsCaptureBarLayout(defaults: try #require(UserDefaults(suiteName: name)))
    #expect(await relaunched.origin(forArrangement: "a") == CGPoint(x: 120.5, y: -40))
    #expect(await relaunched.origin(forArrangement: "b") == CGPoint(x: 9, y: 8))
    #expect(await relaunched.origin(forArrangement: "c") == nil)
    #expect(await relaunched.isCollapsed())
    await relaunched.setCollapsed(false)
    #expect(await first.isCollapsed() == false)
    defaults.set(["a": "bad", "b": [1.0]], forKey: UserDefaultsCaptureBarLayout.originsKey)
    #expect(await first.origin(forArrangement: "a") == nil)
    #expect(await first.origin(forArrangement: "b") == nil)
    #expect(UserDefaultsCaptureBarLayout.originsKey == "capture.barOrigins.v1")
    #expect(UserDefaultsCaptureBarLayout.collapsedKey == "capture.barCollapsed.v1")
}
