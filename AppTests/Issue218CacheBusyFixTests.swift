import AppKit
import Testing
import PicseeInfrastructure

// Hold the real disk-cache actor between operations without changing its implementation.
private final class SettingsCacheGate: @unchecked Sendable {
    let entered = NSLock()
    private var started = false
    private let release = DispatchSemaphore(value: 0)
    var isSuspended: Bool { entered.withLock { started } }
    func suspend() {
        entered.withLock { started = true }
        release.wait()
    }
    func resume() { release.signal() }
}

private extension ThumbnailDiskCache {
    func suspendForSettingsTest(_ gate: SettingsCacheGate) { gate.suspend() }
}

@MainActor private func suspendCache(_ cache: ThumbnailDiskCache) async throws -> SettingsCacheGate {
    let gate = SettingsCacheGate()
    Task.detached { await cache.suspendForSettingsTest(gate) }
    try await waitUntil { gate.isSuspended }
    #expect(gate.isSuspended)
    return gate
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue218CacheShowsBusyStateBeforePendingRefreshAndClear() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    // An owned cache payload, measured and removed through the real storage adapter.
    try Data(repeating: 1, count: 42).write(to: directory.appendingPathComponent(String(repeating: "a", count: 64) + ".png"))
    let cache = ThumbnailDiskCache(directory: directory)
    let (panel, _) = fixPanel(cache: cache, confirm: { _, completion in completion(true) })
    defer { panel.window.close() }
    let refreshGate = try await suspendCache(cache)
    defer { refreshGate.resume() }
    panel.select(.cache)
    let root = try #require(panel.window.contentView)
    let size = try #require(fixView("settings.cache.size", in: root) as? NSTextField)
    let clear = try #require(fixView("settings.cache.clear", in: root) as? NSButton)
    #expect(size.stringValue == String(localized: "Measuring…"))
    #expect(!clear.isEnabled)
    try await Task.sleep(for: .milliseconds(30))
    #expect(size.stringValue == String(localized: "Measuring…"))
    #expect(!clear.isEnabled)
    refreshGate.resume()
    let occupied = ByteCountFormatter.string(fromByteCount: 42, countStyle: .file)
    try await waitUntil { size.stringValue == occupied }
    #expect(size.stringValue == occupied)
    #expect(clear.isEnabled)
    let clearGate = try await suspendCache(cache)
    defer { clearGate.resume() }
    clear.performClick(nil)
    #expect(size.stringValue == String(localized: "Measuring…"))
    #expect(!clear.isEnabled)
    try await Task.sleep(for: .milliseconds(30))
    #expect(size.stringValue == String(localized: "Measuring…"))
    #expect(!clear.isEnabled)
    clearGate.resume()
    let empty = ByteCountFormatter.string(fromByteCount: 0, countStyle: .file)
    try await waitUntil { size.stringValue == empty }
    #expect(size.stringValue == empty)
    #expect(clear.isEnabled)
}
