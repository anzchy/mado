import Foundation
import Testing
import MadoApplication
import MadoInfrastructure

// #687 slice C, WI-1: a recognise-text Capture reads the screen into memory only. It never writes a file in the
// Capture Folder, never asks the file port for its folder, never touches the clipboard, and shares the one-at-a-time
// admission with every other Capture.

private func key(_ target: CaptureRequest.Target) -> String {
    switch target {
    case let .region(_, id, _, _): "region-\(id)"
    case let .window(id): "window-\(id)"
    case let .fullScreen(id): "screen-\(id)"
    }
}

private func echo(_ request: CaptureRequest) -> Data { Data("png-\(key(request.target))".utf8) }

private func request(_ target: CaptureRequest.Target) -> CaptureRequest {
    CaptureRequest(target: target, barWindowIDs: [], overlayWindowIDs: [])
}

private func region(_ id: UInt32) -> CaptureRequest {
    request(.region(rect: CGRect(x: 10, y: 10, width: 50, height: 40), displayID: id,
                    displayFrame: CGRect(x: 0, y: 0, width: 800, height: 600), scale: 2))
}

/// Returns a PNG derived from the request, and records what it was asked.
private actor EchoScreen: CaptureScreenPort {
    private(set) var requests: [String] = []
    private(set) var currentCalls = 0
    func captureCurrentDisplayPNG() async throws -> Data { currentCalls += 1; return Data("current".utf8) }
    func capturePNG(request: CaptureRequest) async throws -> Data {
        requests.append(key(request.target))
        return echo(request)
    }
}

/// Counts every use of the file port.
private actor RecordingFiles: CaptureFilePort {
    private(set) var writes = 0
    private(set) var folderDisplayCalls = 0
    func writeNewPNG(_ data: Data, named: String) async throws -> URL {
        writes += 1
        return URL(fileURLWithPath: "/Capture/\(named)")
    }
    func folderDisplay() async -> String? { folderDisplayCalls += 1; return "~/Capture" }
}

private actor RecordingClipboard: CaptureClipboardPort {
    private(set) var writes = 0
    func writePNG(_ png: Data) async -> Bool { writes += 1; return true }
}

private struct ConcurrentRead: Error {}
private struct GateTimeout: Error {}

/// Every wait in these tests ends within this bound: a stub that never arrives or never returns fails, it never hangs.
private let gateLimit = Duration.seconds(5)

/// Polls `condition` until it holds or `gateLimit` passes; false on timeout.
private func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + gateLimit
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

/// Holds every read until the test releases it with an outcome, at most `gateLimit`.
private actor ControlledScreen: CaptureScreenPort {
    enum Outcome { case ok, fail }
    private var pending = false
    private var released: Outcome?
    private(set) var reads = 0
    func captureCurrentDisplayPNG() async throws -> Data { Data("current".utf8) }
    func capturePNG(request: CaptureRequest) async throws -> Data {
        // Two reads at once mean admission failed: fail fast instead of waiting behind the first.
        guard !pending else { throw ConcurrentRead() }
        pending = true
        reads += 1
        defer { pending = false; released = nil }
        let deadline = ContinuousClock.now + gateLimit
        while released == nil {
            guard ContinuousClock.now < deadline else { throw GateTimeout() }
            try? await Task.sleep(for: .milliseconds(5))
        }
        if released == .fail { throw CocoaError(.fileReadUnknown) }
        return echo(request)
    }
    /// True once `count` reads have arrived and one is waiting, within `gateLimit`.
    func arrived(_ count: Int) -> Bool { reads >= count && pending }
    func release(_ outcome: Outcome) { if pending { released = outcome } }
}

/// Holds every write until the test finishes it, at most `gateLimit`.
private actor PausedFiles: CaptureFilePort {
    private var pending = false
    private var finished = false
    private(set) var writes = 0
    func writeNewPNG(_ data: Data, named: String) async throws -> URL {
        pending = true
        writes += 1
        defer { pending = false; finished = false }
        let deadline = ContinuousClock.now + gateLimit
        while !finished {
            guard ContinuousClock.now < deadline else { throw GateTimeout() }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return URL(fileURLWithPath: "/Capture/\(named)")
    }
    func arrived(_ count: Int) -> Bool { writes >= count && pending }
    func finishWrite() { if pending { finished = true } }
}

/// Fails until switched on.
private actor SwitchableScreen: CaptureScreenPort {
    private var failing = true
    func succeed() { failing = false }
    func captureCurrentDisplayPNG() async throws -> Data { Data("current".utf8) }
    func capturePNG(request: CaptureRequest) async throws -> Data {
        if failing { throw CocoaError(.fileReadUnknown) }
        return echo(request)
    }
}

/// A fixed linear congruential generator: the same sequence on every run.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

@Test(.timeLimit(.minutes(2))) func captureForRecognitionReturnsScreenPNGAndWritesNoFile() async throws {
    let screen = EchoScreen()
    let files = RecordingFiles()
    let session = CaptureSession(screen: screen, files: files)
    let png = try await session.captureForRecognition(request: region(7))
    #expect(png == Data("png-region-7".utf8))
    #expect(await screen.requests == ["region-7"])
    #expect(await screen.currentCalls == 0)
    #expect(await files.writes == 0)
    #expect(await files.folderDisplayCalls == 0)
}

@Test(.timeLimit(.minutes(2))) func captureForRecognitionPassesEachRequestThrough() async throws {
    let screen = EchoScreen()
    let files = RecordingFiles()
    let session = CaptureSession(screen: screen, files: files)
    var generator = SeededGenerator(state: 687)
    for _ in 0..<50 {
        let id = UInt32.random(in: 1...9_999, using: &generator)
        let made: CaptureRequest = switch Int.random(in: 0...2, using: &generator) {
        case 0: region(id)
        case 1: request(.window(windowID: id))
        default: request(.fullScreen(displayID: id))
        }
        #expect(try await session.captureForRecognition(request: made) == echo(made))
    }
    #expect(await screen.requests.count == 50)
    #expect(await files.writes == 0)
    #expect(await files.folderDisplayCalls == 0)
}

@Test(.timeLimit(.minutes(2))) func captureForRecognitionLeavesRealCaptureFolderEmpty() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = CaptureSession(screen: EchoScreen(), files: DownloadsCaptureFilePort(directory: directory))
    _ = try await session.captureForRecognition(request: region(3))
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    // The same port does write for an ordinary Capture, so the empty folder is not a dead port.
    _ = try await session.capture(request: region(3))
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(names.count == 1)
    #expect(names.allSatisfy { $0.hasPrefix("mado-") && $0.hasSuffix(".png") })
}

@Test(.timeLimit(.minutes(2))) func captureForRecognitionIsBusyWhileACaptureWrites() async throws {
    let screen = EchoScreen()
    let files = PausedFiles()
    let session = CaptureSession(screen: screen, files: files)
    let first = Task { try await session.capture(request: region(1)) }
    #expect(await eventually { await files.arrived(1) })
    await #expect(throws: CaptureSessionError.busy) { try await session.captureForRecognition(request: region(7)) }
    #expect(await screen.requests == ["region-1"])
    await files.finishWrite()
    _ = try await first.value
    #expect(try await session.captureForRecognition(request: region(7)) == Data("png-region-7".utf8))
}

@Test(.timeLimit(.minutes(2))) func captureIsBusyWhileRecognitionReads() async throws {
    let screen = ControlledScreen()
    let files = RecordingFiles()
    let clipboard = RecordingClipboard()
    let session = CaptureSession(screen: screen, files: files)
    let reading = Task { try await session.captureForRecognition(request: region(2)) }
    #expect(await eventually { await screen.arrived(1) })
    await #expect(throws: CaptureSessionError.busy) {
        try await session.capture(request: region(2), policy: .standard, clipboard: clipboard)
    }
    #expect(await clipboard.writes == 0)
    #expect(await files.writes == 0)
    await screen.release(.ok)
    #expect(try await reading.value == Data("png-region-2".utf8))
    let capture = Task { try await session.capture(request: region(2), policy: .standard, clipboard: clipboard) }
    #expect(await eventually { await screen.arrived(2) })
    await screen.release(.ok)
    let state = try await capture.value
    #expect(state.savedURL != nil)
    #expect(await files.writes == 1)
    #expect(await clipboard.writes == 1)
}

@Test(.timeLimit(.minutes(2))) func captureForRecognitionCancelledReleasesAdmissionAndWritesNothing() async throws {
    let screen = ControlledScreen()
    let files = RecordingFiles()
    let session = CaptureSession(screen: screen, files: files)
    let reading = Task { try await session.captureForRecognition(request: region(4)) }
    #expect(await eventually { await screen.arrived(1) })
    reading.cancel()
    await screen.release(.ok)
    await #expect(throws: CancellationError.self) { try await reading.value }
    #expect(await files.writes == 0)
    let again = Task { try await session.captureForRecognition(request: region(5)) }
    #expect(await eventually { await screen.arrived(2) })
    await screen.release(.ok)
    #expect(try await again.value == Data("png-region-5".utf8))
    let capture = Task { try await session.capture(request: region(5)) }
    #expect(await eventually { await screen.arrived(3) })
    await screen.release(.ok)
    _ = try await capture.value
    #expect(await files.writes == 1)
}

@Test(.timeLimit(.minutes(2))) func captureForRecognitionPropagatesScreenFailure() async throws {
    let screen = SwitchableScreen()
    let files = RecordingFiles()
    let session = CaptureSession(screen: screen, files: files)
    do {
        _ = try await session.captureForRecognition(request: region(6))
        Issue.record("expected the screen failure")
    } catch let error as CocoaError {
        #expect(error.code == .fileReadUnknown)
    }
    #expect(await files.writes == 0)
    await screen.succeed()
    #expect(try await session.captureForRecognition(request: region(6)) == Data("png-region-6".utf8))
}

/// Law: at most one Capture of either kind runs; whatever the outcome, the next one is admitted.
@Test(.timeLimit(.minutes(2))) func captureAdmissionIsConservedAcrossRecognitionOutcomes() async throws {
    enum Op: CaseIterable { case recogniseOK, recogniseFail, recogniseCancel, captureOK }
    let screen = ControlledScreen()
    let files = RecordingFiles()
    let clipboard = RecordingClipboard()
    let session = CaptureSession(screen: screen, files: files)
    var generator = SeededGenerator(state: 6870)
    var captures = 0
    var recognitions = 0
    for index in 0..<40 {
        let op = Op.allCases[Int.random(in: 0..<Op.allCases.count, using: &generator)]
        let target = region(UInt32(index + 1))
        let running: Task<Data, any Error> = op == .captureOK
            ? Task { _ = try await session.capture(request: target, policy: .standard, clipboard: clipboard); return Data() }
            : Task { try await session.captureForRecognition(request: target) }
        #expect(await eventually { await screen.arrived(index + 1) })
        // The probe never reaches the screen: it is refused at admission.
        if index.isMultiple(of: 2) {
            await #expect(throws: CaptureSessionError.busy) { try await session.captureForRecognition(request: target) }
        } else {
            await #expect(throws: CaptureSessionError.busy) {
                try await session.capture(request: target, policy: .standard, clipboard: clipboard)
            }
        }
        if op == .recogniseCancel { running.cancel() }
        await screen.release(op == .recogniseFail ? .fail : .ok)
        switch op {
        case .recogniseOK:
            #expect(try await running.value == echo(target))
            recognitions += 1
        case .recogniseFail:
            await #expect(throws: CocoaError.self) { try await running.value }
        case .recogniseCancel:
            await #expect(throws: CancellationError.self) { try await running.value }
        case .captureOK:
            _ = try await running.value
            captures += 1
        }
    }
    #expect(await screen.reads == 40)
    #expect(await files.writes == captures)
    #expect(await clipboard.writes == captures)
    #expect(recognitions + captures <= 40)
}
