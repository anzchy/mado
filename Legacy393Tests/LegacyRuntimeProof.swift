import AppKit
import Darwin
import Testing

private final class Legacy393RuntimeBundleAnchor: NSObject {}

/// Independent runtime probe; the isolated comparison behavior selection remains the six original parents.
@Test(.timeLimit(.minutes(3))) @MainActor
func issue393LegacyRuntimeProof() throws {
    let environment = ProcessInfo.processInfo.environment
    #expect(environment["APP_COMPARE_MODE"] == "legacy")
    #expect(ProcessInfo.processInfo.processName == "xctest")
    let executable = try #require(Bundle.main.executableURL)
    #expect(executable.lastPathComponent == "xctest")
    #expect(!(NSApp?.isRunning ?? false))
    let bundle = Bundle(for: Legacy393RuntimeBundleAnchor.self)
    #expect(bundle.bundleURL.lastPathComponent == "MadoLegacy393Tests.xctest")
    let token = try #require(environment["MADO_TEST_RUN_TOKEN"])
    #expect(!token.isEmpty)
    print("[issue393-legacy] pid=\(getpid()) executable=\(executable.path) process=\(ProcessInfo.processInfo.processName) bundle=\(bundle.bundleURL.lastPathComponent) mode=legacy token=\(token)")
}
