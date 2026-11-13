import Foundation
import Testing

@MainActor private final class FeedController: SparkleController {
    var automaticallyChecksForUpdates = true
    var lastUpdateCheckDate: Date? = Date(timeIntervalSince1970: 123)
    var canCheckForUpdates = true
    var starts = 0
    var checks = 0
    var callback: (@MainActor () -> Void)?
    func checkForUpdates() { checks += 1; canCheckForUpdates = false; callback?() }
    func startUpdater() { starts += 1; canCheckForUpdates = true; callback?() }
    func observe(_ onChange: @escaping @MainActor () -> Void) { callback = onChange }
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue550MissingFeedDisablesUpdatesWithoutConstructingSparkle() {
    for info: [String: Any] in [[:], ["SUFeedURL": ""], ["SUFeedURL": " \n\t"]] {
        let native = FeedController()
        var constructions = 0
        let port = SparkleUpdatePort(infoDictionary: info, makeController: { constructions += 1; return native })
        var notifications = 0
        port.observe { notifications += 1 }
        port.start()
        port.checkForUpdates()
        port.automaticallyChecksForUpdates = true
        #expect(constructions == 0)
        #expect(!port.canCheckForUpdates)
        #expect(!port.automaticallyChecksForUpdates)
        #expect(port.lastUpdateCheckDate == nil)
        #expect(native.starts == 0 && native.checks == 0)
        #expect(notifications == 0)
    }
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue550ConfiguredFeedKeepsUpdateStateAndOperations() {
    let native = FeedController()
    let port = SparkleUpdatePort(infoDictionary: ["SUFeedURL": "https://example.com/feed.xml"], makeController: { native })
    #expect(port.canCheckForUpdates)
    #expect(port.automaticallyChecksForUpdates)
    #expect(port.lastUpdateCheckDate == Date(timeIntervalSince1970: 123))
    port.automaticallyChecksForUpdates = false
    #expect(!native.automaticallyChecksForUpdates)
    var notifications = 0
    port.observe { notifications += 1 }
    port.checkForUpdates()
    #expect(!port.canCheckForUpdates && native.checks == 1)
    port.start()
    #expect(port.canCheckForUpdates && native.starts == 1)
    #expect(notifications == 2)
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue550RealSparkleControllerCanBeConstructedStopped() {
    let port = SparkleUpdatePort(infoDictionary: ["SUFeedURL": "https://example.com/feed.xml"])
    #expect(!port.canCheckForUpdates)
    #expect(port.lastUpdateCheckDate == nil)
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue550RealMissingFeedPortStartAndCheckRemainUnavailable() {
    let port = SparkleUpdatePort(infoDictionary: [:])
    port.start()
    port.checkForUpdates()
    port.automaticallyChecksForUpdates = true
    #expect(!port.canCheckForUpdates)
    #expect(!port.automaticallyChecksForUpdates)
    #expect(port.lastUpdateCheckDate == nil)
}
