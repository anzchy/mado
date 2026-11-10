import AppKit
import Testing
import MadoCore
import MadoApplication
import MadoInfrastructure
import MadoMacUI
import Darwin

private final class Issue521BundleAnchor: NSObject {}

private struct Issue521Timeout: Error, CustomStringConvertible {
    let stage: String
    var description: String { "Native test helper exceeded the shared deadline during \(stage)" }
}

@MainActor private func issue521Run(_ executable: URL, _ arguments: [String],
    environment: [String: String]? = nil, log: URL,
    deadline: ContinuousClock.Instant, stage: String) async throws -> (Int32, String) {
    try Task.checkCancellation()
    guard ContinuousClock.now < deadline else { throw Issue521Timeout(stage: stage) }
    FileManager.default.createFile(atPath: log.path, contents: nil)
    let output = try FileHandle(forWritingTo: log)
    defer { try? output.close() }
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = environment
    process.standardOutput = output
    process.standardError = output
    try process.run()
    defer {
        if process.isRunning {
            process.terminate()
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
    }
    while process.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    if process.isRunning {
        // The defer terminates and reaps this stage, including swiftc or the native child,
        // before the stage-named error leaves the helper. Cancellation takes the same path.
        throw Issue521Timeout(stage: stage)
    }
    process.waitUntilExit()
    try output.synchronize()
    return (process.terminationStatus, try String(contentsOf: log, encoding: .utf8))
}

/// Keep NSApplication's permanent launch/menu initialization out of the shared unit-test host.
/// The child loads this same test bundle and uses Swift Testing's public generated-runner entry point.
@Test(.enabled(if: ProcessInfo.processInfo.environment["PICSEE_ISSUE521_NATIVE_CHILD"] != "1"),
      .timeLimit(.minutes(3))) @MainActor
func issue521NativePanPassesInIsolatedProcess() async throws {
    try await issue521RunNativeTest(filter: "issue521WindowDragPansFromCanvasAndTabFocusedTools\\b",
        summary: "Test issue521WindowDragPansFromCanvasAndTabFocusedTools(tabCount:) with 3 test cases passed")
}

/// Shared isolated native host; callers retain their own filter and successful nonzero summary.
@MainActor func issue521RunNativeTest(filter: String, summary: String) async throws {
    // All three stages spend this one monotonic budget. Reserve 30 seconds inside the
    // parent's three-minute limit for termination/reaping and failure reporting.
    let deadline = ContinuousClock.now.advanced(by: .seconds(150))
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("issue521-runner-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let source = temporary.appendingPathComponent("NativeRunner.swift")
    let executable = temporary.appendingPathComponent("NativeRunner")
    try #"""
    import Foundation
    import Testing
    @main enum NativeRunner {
        static func main() {
            guard let path = ProcessInfo.processInfo.environment["PICSEE_ISSUE521_TEST_BUNDLE"],
                  let bundle = Bundle(path: path) else { exit(70) }
            do { try bundle.loadAndReturnError() }
            catch { print("Native bundle load failed: \(error)"); exit(70) }
            Task { await Testing.__swiftPMEntryPoint() as Never }
            while true { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01)) }
        }
    }
    """#.write(to: source, atomically: true, encoding: .utf8)
    let (selectionStatus, selection) = try await issue521Run(URL(fileURLWithPath: "/usr/bin/xcode-select"),
        ["-p"], log: temporary.appendingPathComponent("selection.log"),
        deadline: deadline, stage: "Xcode selection")
    try #require(selectionStatus == 0)
    let developer = URL(fileURLWithPath: selection.trimmingCharacters(in: .whitespacesAndNewlines))
        .appendingPathComponent("Platforms/MacOSX.platform/Developer")
    let frameworks = developer.appendingPathComponent("Library/Frameworks").path
    let libraries = developer.appendingPathComponent("usr/lib").path
    let (buildStatus, buildOutput) = try await issue521Run(URL(fileURLWithPath: "/usr/bin/xcrun"),
        ["swiftc", "-parse-as-library", "-F", frameworks,
         "-Xlinker", "-rpath", "-Xlinker", frameworks,
         "-Xlinker", "-rpath", "-Xlinker", libraries, source.path, "-o", executable.path],
        log: temporary.appendingPathComponent("build.log"), deadline: deadline, stage: "swiftc compilation")
    if buildStatus != 0 { print(buildOutput.split(separator: "\n").map { "[issue521-build] \($0)" }.joined(separator: "\n")) }
    try #require(buildStatus == 0, "the native test helper must compile before its assertions count")
    var environment = ProcessInfo.processInfo.environment
    environment["PICSEE_ISSUE521_NATIVE_CHILD"] = "1"
    environment["PICSEE_ISSUE521_TEST_BUNDLE"] = Bundle(for: Issue521BundleAnchor.self).bundleURL.path
    environment["SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH"] = "1"
    let (status, output) = try await issue521Run(executable, ["--filter", filter],
        environment: environment, log: temporary.appendingPathComponent("native.log"),
        deadline: deadline, stage: "native canvas drag matrix")
    // Prefix captured child records so the enclosing App lane sees exactly its own test-run root.
    print(output.split(separator: "\n").map { "[issue521-child] \($0)" }.joined(separator: "\n"))
    // Keep macro failure diagnostics from printing unprefixed embedded test-run records.
    let nativePassed = output.contains(summary)
    let nativeRootCompleted = output.range(of: "Test run with 1 test in [0-9]+ suites? passed after",
        options: .regularExpression) != nil
    #expect(status == 0, "the isolated native canvas drag matrix must pass")
    #expect(nativePassed)
    #expect(nativeRootCompleted,
        "a successful, nonzero completed native root is required")
}

@MainActor func issue521StartNativeDispatch() {
    guard !NSApp.isRunning else { return }
    let timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { _ in
        MainActor.assumeIsolated {
            NSApp.stop(nil)
            if let idle = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                NSApp.postEvent(idle, atStart: true)
            }
        }
    }
    NSApp.run()
    timer.invalidate()
}
