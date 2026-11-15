import AppKit
import Foundation
import Testing
import MadoApplication

// #685 fix round 3 (device N1, smoke685-20261115c): turning 登录时启动 on with the bar running made launchd start a
// second MadoCaptureHelper, with a second bar and a second set of hotkeys. The helper is single-instance, and Mado
// does not open a helper that is already running.

@MainActor private final class FakeInstanceLock: CaptureHelperInstanceLockPort {
    let result: CaptureHelperInstanceClaim
    var claims = 0
    init(_ result: CaptureHelperInstanceClaim) { self.result = result }
    func claim() -> CaptureHelperInstanceClaim { claims += 1; return result }
}

@MainActor @Test(.timeLimit(.minutes(1))) func issue685SecondHelperExitsBeforeTheBarOrHotKeys() {
    var log: [String] = []
    let held = FakeInstanceLock(.heldElsewhere)
    CaptureHelperStartup.launch(lock: held, exit: { log.append("exit") }, start: { log.append("start") })
    #expect(log == ["exit"])
    #expect(held.claims == 1)

    log = []
    let first = FakeInstanceLock(.acquired)
    CaptureHelperStartup.launch(lock: first, exit: { log.append("exit") }, start: { log.append("start") })
    #expect(log == ["start"])

    // No lock file to coordinate through: the helper still runs (Mado's running check still guards its own start).
    log = []
    CaptureHelperStartup.launch(lock: FakeInstanceLock(.unavailable), exit: { log.append("exit") },
                                start: { log.append("start") })
    #expect(log == ["start"])
}

@MainActor @Test(.timeLimit(.minutes(1))) func issue685RealHelperLockIsExclusiveAndReleasable() throws {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("issue685-lock-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent(FlockCaptureHelperInstanceLock.fileName)
    let first = FlockCaptureHelperInstanceLock(url: url)
    let second = FlockCaptureHelperInstanceLock(url: url)
    defer { first.release(); second.release() }

    #expect(first.claim() == .acquired)
    #expect(FileManager.default.fileExists(atPath: url.path))
    #expect(second.claim() == .heldElsewhere)
    // Claiming again from the holder keeps the lock; the other one is still refused.
    #expect(first.claim() == .acquired)
    #expect(second.claim() == .heldElsewhere)
    first.release()
    #expect(second.claim() == .acquired)
    #expect(first.claim() == .heldElsewhere)
    second.release()
    #expect(first.claim() == .acquired)

    // A folder that does not exist gives no lock file: unavailable, not a refusal.
    let missing = FlockCaptureHelperInstanceLock(url: folder.appendingPathComponent("absent/x.lock"))
    #expect(missing.claim() == .unavailable)
}

@MainActor @Test(.timeLimit(.minutes(1))) func issue685MadoDoesNotOpenARunningHelper() async throws {
    let helper = FileManager.default.temporaryDirectory
        .appendingPathComponent("issue685-helper-\(UUID().uuidString).app", isDirectory: true)
    try FileManager.default.createDirectory(at: helper, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: helper) }
    var opened: [URL] = []
    var running = true
    let process = WorkspaceCaptureBarProcess(helperURL: helper, isRunning: { running },
                                             open: { opened.append($0) })
    try await process.startCaptureBar()
    #expect(opened.isEmpty)

    running = false
    try await process.startCaptureBar()
    #expect(opened == [helper])

    let missing = WorkspaceCaptureBarProcess(helperURL: helper.appendingPathComponent("gone.app"),
                                             isRunning: { false }, open: { opened.append($0) })
    await #expect(throws: WorkspaceCaptureBarProcess.Failure.helperMissing) { try await missing.startCaptureBar() }
    #expect(opened == [helper])
}
