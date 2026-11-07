import AppKit
import Foundation
import Testing

#if DEBUG
@MainActor
struct AccessProbeLaunchTests {
    @Test func runsOnlyWithExplicitLaunchArgument() {
        var runCount = 0
        let normal = AccessProbeRunner.runIfRequested(arguments: ["Mado"], runProbe: {
            runCount += 1
        }, terminate: {})
        let similar = AccessProbeRunner.runIfRequested(
            arguments: ["Mado", "-PicseeAccessProbeExtra"],
            runProbe: { runCount += 1 },
            terminate: {}
        )
        let requested = AccessProbeRunner.runIfRequested(
            arguments: ["Mado", "-PicseeAccessProbe"],
            runProbe: { runCount += 1 },
            terminate: {}
        )

        #expect(!normal)
        #expect(!similar)
        #expect(requested)
        #expect(runCount == 1)
    }

    @Test func probeAppLifecycleNeverTouchesProductState() {
        var probeRunCount = 0
        var terminationCount = 0
        var accessServicesConstructionCount = 0
        var events: [AppDelegateProbeHooks.ProductEvent] = []
        let delegate = AppDelegate(probeHooks: AppDelegateProbeHooks(
            arguments: ["Mado", "-PicseeAccessProbe"],
            runProbe: { probeRunCount += 1 },
            terminate: { terminationCount += 1 },
            makeAccessServices: {
                accessServicesConstructionCount += 1
                return Task { throw CancellationError() }
            },
            record: { events.append($0) }
        ))

        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        delegate.application(NSApplication.shared, open: [URL(fileURLWithPath: "/tmp/probe.jpg")])

        #expect(probeRunCount == 1)
        #expect(terminationCount == 1)
        #expect(accessServicesConstructionCount == 0)
        #expect(!events.contains(.windowOpened))
        #expect(!events.contains(.sessionRestored))
        #expect(!events.contains(.recentItemsTouched))
        #expect(!events.contains(.openURL))
    }

    @Test func resultsLogUsesFixedMarkerInsteadOfContainerPath() {
        let output = URL(fileURLWithPath: "/Users/example/Library/Containers/example/results.jsonl")

        #expect(AccessProbeRunner.resultsLogMessage(for: output) == "AccessProbe results ready")
    }

    @Test func collectsSequentialFolderPicksUntilCancel() {
        let first = URL(fileURLWithPath: "/Volumes/A/One", isDirectory: true)
        let second = URL(fileURLWithPath: "/Volumes/B/Two", isDirectory: true)
        var picks: [URL?] = [first, second, nil]
        var pickCount = 0

        let collected = AccessProbeRunner.collectFolders {
            pickCount += 1
            return picks.isEmpty ? nil : picks.removeFirst()
        }

        #expect(collected == [first, second])
        #expect(pickCount == 3)
    }

    @Test func storesBothBookmarkKindsAndWritesJSONLOnEveryRun() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let folder = root.appendingPathComponent("Photos", isDirectory: true)
        let container = root.appendingPathComponent("Probe", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        var selectionCount = 0

        func assertOutput(_ output: URL) throws {
            let lines = try String(contentsOf: output, encoding: .utf8)
                .split(separator: "\n")
            #expect(lines.count == 2)
            let objects = try lines.map { line in
                try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            }
            #expect(Set(objects.compactMap { $0?["bookmarkKind"] as? String }) == Set(["plain", "enriched"]))
            #expect(objects.allSatisfy { $0?["report"] is [String: Any] })
        }

        let firstOutput = try AccessProbeRunner.run(containerURL: container) {
            selectionCount += 1
            return [folder]
        }
        try assertOutput(firstOutput)

        let secondOutput = try AccessProbeRunner.run(containerURL: container) {
            selectionCount += 1
            return []
        }
        try assertOutput(secondOutput)

        #expect(selectionCount == 1)
        #expect(firstOutput == secondOutput)
        #expect(fileManager.fileExists(atPath: container.appendingPathComponent("bookmarks.json").path))
    }
}
#endif
