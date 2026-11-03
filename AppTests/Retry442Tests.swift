import AppKit
import Testing
import PicseeCore
import PicseeApplication
import PicseeInfrastructure
import PicseeMacUI
import Darwin

private final class Retry442BundleAnchor: NSObject {}

private struct Retry442Timeout: Error, CustomStringConvertible {
    let stage: String
    var description: String { "Native test helper exceeded the shared deadline during \(stage)" }
}

@MainActor private func retry442Run(_ executable: URL, _ arguments: [String],
    environment: [String: String]? = nil, log: URL,
    deadline: ContinuousClock.Instant, stage: String) async throws -> (Int32, String) {
    try Task.checkCancellation()
    guard ContinuousClock.now < deadline else { throw Retry442Timeout(stage: stage) }
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
        throw Retry442Timeout(stage: stage)
    }
    process.waitUntilExit()
    try output.synchronize()
    return (process.terminationStatus, try String(contentsOf: log, encoding: .utf8))
}

/// Keep NSApplication's permanent launch/menu initialization out of the shared unit-test host.
/// The child loads this same test bundle and uses Swift Testing's public generated-runner entry point.
@Test(.enabled(if: ProcessInfo.processInfo.environment["PICSEE_RETRY442_NATIVE_CHILD"] != "1"),
      .timeLimit(.minutes(3))) @MainActor
func retry442NativeKeyboardMatrixPassesInIsolatedProcess() async throws {
    // All three stages spend this one monotonic budget. Reserve 30 seconds inside the
    // parent's three-minute limit for termination/reaping and failure reporting.
    let deadline = ContinuousClock.now.advanced(by: .seconds(150))
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("retry442-runner-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let source = temporary.appendingPathComponent("NativeRunner.swift")
    let executable = temporary.appendingPathComponent("NativeRunner")
    try #"""
    import Foundation
    import Testing
    @main enum NativeRunner {
        static func main() {
            guard let path = ProcessInfo.processInfo.environment["PICSEE_RETRY442_TEST_BUNDLE"],
                  let bundle = Bundle(path: path) else { exit(70) }
            do { try bundle.loadAndReturnError() }
            catch { print("Native bundle load failed: \(error)"); exit(70) }
            Task { await Testing.__swiftPMEntryPoint() as Never }
            while true { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01)) }
        }
    }
    """#.write(to: source, atomically: true, encoding: .utf8)
    let (selectionStatus, selection) = try await retry442Run(URL(fileURLWithPath: "/usr/bin/xcode-select"),
        ["-p"], log: temporary.appendingPathComponent("selection.log"),
        deadline: deadline, stage: "Xcode selection")
    try #require(selectionStatus == 0)
    let developer = URL(fileURLWithPath: selection.trimmingCharacters(in: .whitespacesAndNewlines))
        .appendingPathComponent("Platforms/MacOSX.platform/Developer")
    let frameworks = developer.appendingPathComponent("Library/Frameworks").path
    let libraries = developer.appendingPathComponent("usr/lib").path
    let (buildStatus, buildOutput) = try await retry442Run(URL(fileURLWithPath: "/usr/bin/xcrun"),
        ["swiftc", "-parse-as-library", "-F", frameworks,
         "-Xlinker", "-rpath", "-Xlinker", frameworks,
         "-Xlinker", "-rpath", "-Xlinker", libraries, source.path, "-o", executable.path],
        log: temporary.appendingPathComponent("build.log"), deadline: deadline, stage: "swiftc compilation")
    if buildStatus != 0 { print(buildOutput.split(separator: "\n").map { "[retry442-build] \($0)" }.joined(separator: "\n")) }
    try #require(buildStatus == 0, "the native test helper must compile before its assertions count")
    var environment = ProcessInfo.processInfo.environment
    environment["PICSEE_RETRY442_NATIVE_CHILD"] = "1"
    environment["PICSEE_RETRY442_TEST_BUNDLE"] = Bundle(for: Retry442BundleAnchor.self).bundleURL.path
    environment["SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH"] = "1"
    let (status, output) = try await retry442Run(executable, ["--filter", "retry442NativeKeyboardMatrix\\b"],
        environment: environment, log: temporary.appendingPathComponent("native.log"),
        deadline: deadline, stage: "native keyboard matrix")
    // Prefix captured child records so the enclosing App lane sees exactly its own test-run root.
    print(output.split(separator: "\n").map { "[retry442-child] \($0)" }.joined(separator: "\n"))
    // Keep macro failure diagnostics from printing unprefixed embedded test-run records.
    let nativePassed = output.contains("Test retry442NativeKeyboardMatrix() passed")
    let nativeRootCompleted = output.range(of: "Test run with 1 test in [0-9]+ suites? passed after",
        options: .regularExpression) != nil
    #expect(status == 0, "the isolated native keyboard matrix must pass")
    #expect(nativePassed)
    #expect(nativeRootCompleted,
        "a successful, nonzero completed native root is required")
}

@MainActor private final class Retry442MotionSource: ReduceMotionSource {
    var reduceMotion = false
    var onChange: (@MainActor () -> Void)?
}

@MainActor private func retry442Find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
    guard let view else { return nil }
    if let result = view as? T { return result }
    return view.subviews.lazy.compactMap { retry442Find(type, in: $0) }.first
}

@MainActor private final class Retry442Scene {
    let base: URL
    let folder: URL
    let child: URL
    let controller: CanvasWindowController
    let window: CommandWindow
    let menu: CommandMenu
    let previousMenu: NSMenu?
    let previousActivationPolicy: NSApplication.ActivationPolicy

    init() throws {
        _ = NSApplication.shared
        previousActivationPolicy = NSApp.activationPolicy()
        // Match PicseeApp startup; a bare xctest host otherwise has prohibited activation.
        _ = NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let fm = FileManager.default
        base = fm.temporaryDirectory.appendingPathComponent("retry442-\(UUID().uuidString)")
        folder = base.appendingPathComponent("photos")
        child = folder.appendingPathComponent("unreadable")
        try fm.createDirectory(at: child, withIntermediateDirectories: true)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestAssets/synthetic/landscape-3x2.png")
        let data = try Data(contentsOf: fixture)
        try data.write(to: folder.appendingPathComponent("image.png"))
        try data.write(to: child.appendingPathComponent("nested.png"))
        let scope = SystemSecurityScope()
        let access = try FileAccess(scope: scope, bookmarks: scope,
            store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "retry442")
        let services = AccessServices(files: access,
            recent: RecentFolderStore(url: base.appendingPathComponent("recent.json")),
            browser: FolderBrowser(),
            watch: WatchHub(access: access, source: FSEventSource(), scheduler: DispatchWatchScheduler()))
        let preferences = InMemoryDisplayPreferencesStore()
        controller = CanvasWindowController(pipeline: ImageIOPipeline(), preferencesStore: preferences,
            accessServices: Task { services }, motionPolicy: MotionPolicy(source: Retry442MotionSource()))
        window = try #require(controller.window as? CommandWindow)
        previousMenu = NSApp.mainMenu
        let target = controller
        menu = CommandMenu(preferencesStore: preferences, openWithoutWindow: {}, openSettings: {},
            openDiagnostics: {}, windowController: { target })
        window.setContentSize(NSSize(width: 1280, height: 772))
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        retry442StartNativeDispatch()
    }

    func close() {
        retry442ClearCurrentEvent()
        NSApp.mainMenu = previousMenu
        window.close()
        _ = NSApp.setActivationPolicy(previousActivationPolicy)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: child.path)
        try? FileManager.default.removeItem(at: base)
        withExtendedLifetime(menu) {}
    }

    var page: ReadFailedStateView? {
        guard let page = retry442Find(ReadFailedStateView.self, in: window.contentView),
              !page.isHiddenOrHasHiddenAncestor else { return nil }
        return page
    }
    var grid: GridBrowserView? { retry442Find(GridBrowserView.self, in: window.contentView) }
    var canvas: CanvasView? { retry442Find(CanvasView.self, in: window.contentView) }

    func wait(_ condition: () -> Bool) async throws {
        try await PicseeAppTests.waitUntil(between: { window.update() }, condition)
    }

    func openGrid() async throws {
        controller.openGrantedFolder(folder)
        try await wait { controller.gridSearchAvailable }
        #expect(grid?.displayedItemIDs.count == 1)
    }

    func denyRecursiveChild() async throws {
        if controller.gridSearchAvailable {
            _ = controller.session.setFolderRecursiveEnabled(false)
            try await wait { controller.gridSearchAvailable && grid?.displayedItemIDs.count == 1 }
        } else { try await openGrid() }
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: child.path)
        try #require(!FileManager.default.isReadableFile(atPath: child.path), "fixture must really deny child access")
        _ = controller.session.setFolderRecursiveEnabled(true)
        try await wait { page != nil && controller.session.folderScan?.isScanning == false }
        let failed = try #require(page)
        #expect(controller.session.folderScan?.failureReason == "Folder access denied")
        #expect(window.firstResponder === failed.retryButton)
        #expect(controller.session.mode == .browsing)
        #expect(canvas?.isHiddenOrHasHiddenAncestor == true)
    }

    /// Use the actual application dispatch and installed production menu, with a real current key event.
    /// The test never calls route(), performClick(), or a menu action in place of event delivery.
    func press(_ keypad: Bool) throws {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // A bare xctest host can be inactive; makeKeyAndOrderFront then only orders the window.
        // Explicit key ownership is required before testing NSApplication's real equivalent routing.
        window.makeKey()
        let deadline = Date(timeIntervalSinceNow: 2)
        while NSApp.keyWindow !== window && Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
            window.makeKeyAndOrderFront(nil)
            window.makeKey()
        }
        try #require(NSApp.keyWindow === window)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: keypad ? [.numericPad] : [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: keypad ? "\u{3}" : "\r", charactersIgnoringModifiers: keypad ? "\u{3}" : "\r",
            isARepeat: false, keyCode: keypad ? 76 : 36))
        NSApp.postEvent(event, atStart: true)
        let current = try #require(NSApp.nextEvent(matching: .keyDown,
            until: Date(timeIntervalSinceNow: 1), inMode: .default, dequeue: true))
        #expect(NSApp.currentEvent?.keyCode == event.keyCode)
        NSApp.sendEvent(current)
    }
}

/// Unlike the production executable, a bare xctest host never enters NSApplication.run().
/// Let AppKit finish activation and key-window delivery before exercising its event route.
@MainActor private func retry442StartNativeDispatch() {
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

@MainActor private func retry442ClearCurrentEvent() {
    guard let idle = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
        timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) else { return }
    NSApp.postEvent(idle, atStart: true)
    _ = NSApp.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 1), inMode: .default, dequeue: true)
}

/// Runs only in the isolated native child: NSApplication.run() permanently initializes AppKit's menu
/// augmentation, so the unit-test host must not own this lifecycle.
@Test(.enabled(if: ProcessInfo.processInfo.environment["PICSEE_RETRY442_NATIVE_CHILD"] == "1"),
      .timeLimit(.minutes(3))) @MainActor
func retry442NativeKeyboardMatrix() async throws {
    let scene = try Retry442Scene()
    defer { scene.close() }
    var requests = 0
    scene.controller.onOpenRequest = { requests += 1 }
    for keypad in [false, true] {
        try await scene.denyRecursiveChild()
        let failed = try #require(scene.page)
        #expect(failed.retryButton.nextValidKeyView === failed.chooseOtherButton)
        // Reproduce the rehearsal's Tab then Shift-Tab before Return.
        scene.window.selectNextKeyView(nil)
        #expect(scene.window.firstResponder === failed.chooseOtherButton)
        scene.window.selectPreviousKeyView(nil)
        #expect(scene.window.firstResponder === failed.retryButton)
        try scene.press(keypad)
        #expect(scene.controller.session.mode == .browsing, "Return must not open the retained image")
        try #require(scene.controller.session.folderScan?.isScanning == true,
            "Return must start a new retry instead of opening the retained image")
        try await scene.wait { scene.page != nil && scene.controller.session.folderScan?.isScanning == false }
        let retried = try #require(scene.page)
        #expect(scene.controller.session.mode == .browsing)
        #expect(scene.canvas?.isHiddenOrHasHiddenAncestor == true)
        #expect(scene.grid?.isHiddenOrHasHiddenAncestor == true)
        #expect(scene.window.firstResponder === retried.retryButton)
        #expect(scene.controller.session.folderScan?.failureReason == "Folder access denied")

        // The other focused control owns its own action for both Return and keypad Enter.
        let priorRequests = requests
        scene.window.selectNextKeyView(nil)
        #expect(scene.window.firstResponder === retried.chooseOtherButton)
        try scene.press(keypad)
        #expect(requests == priorRequests + 1)
        #expect(scene.page === retried)
        #expect(scene.controller.session.folderScan?.isScanning == false)
        #expect(scene.controller.session.mode == .browsing)
        #expect(scene.canvas?.isHiddenOrHasHiddenAncestor == true)
        #expect(scene.window.firstResponder === retried.chooseOtherButton)
        scene.window.selectPreviousKeyView(nil)
        #expect(scene.window.firstResponder === retried.retryButton)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scene.child.path)
        try scene.press(keypad)
        try #require(scene.controller.session.folderScan?.isScanning == true)
        try await scene.wait { scene.controller.gridSearchAvailable }
        #expect(scene.page == nil)
        #expect(scene.controller.session.mode == .browsing)
        #expect(scene.canvas?.isHiddenOrHasHiddenAncestor == true)
        let grid = try #require(scene.grid)
        #expect(!grid.isHiddenOrHasHiddenAncestor)
        #expect(grid.displayedItemIDs.count == 2)
        let files = Set(grid.displayedItemIDs.compactMap { grid.entry(for: $0)?.url.lastPathComponent })
        #expect(files == ["image.png", "nested.png"])
    }
    #expect(requests == 2)
    // Once a complete grid is shown, Return must retain its normal Open Current Image route.
    let grid = try #require(scene.grid)
    let current = try #require(grid.currentItemID)
    try scene.press(false)
    try #require(scene.controller.session.mode == .viewing)
    try await scene.wait { scene.controller.hasImage }
    #expect(scene.controller.session.imageLoader.fileURL == grid.entry(for: current)?.url)
    #expect(scene.controller.session.previewSet?.currentItemID == current)
    #expect(scene.grid?.isHiddenOrHasHiddenAncestor == true)
    #expect(scene.canvas?.isHiddenOrHasHiddenAncestor == false)
    #expect(scene.page == nil)
}
