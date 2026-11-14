import Foundation
import Testing
import MadoApplication

private struct FixedScreen: CaptureScreenPort {
    let png: Data
    func captureCurrentDisplayPNG() async throws -> Data { png }
}

private struct FailedScreen: CaptureScreenPort {
    func captureCurrentDisplayPNG() async throws -> Data { throw CocoaError(.fileReadUnknown) }
}

private actor MemoryFiles: CaptureFilePort {
    var files: [String: Data] = [:]
    let directory = URL(fileURLWithPath: "/Downloads")

    func writeNewPNG(_ data: Data, named: String) throws -> URL {
        guard files[named] == nil else { throw CaptureFileError.alreadyExists }
        files[named] = data
        return directory.appendingPathComponent(named)
    }

    func contents() -> [String: Data] { files }
}

@Test(.timeLimit(.minutes(2))) func captureSessionUsesLocalTimeAndRetriesSameSecondNames() async throws {
    let files = MemoryFiles()
    let png = Data([137, 80, 78, 71])
    let date = try #require(ISO8601DateFormatter().date(from: "2026-11-14T00:00:01Z"))
    let session = CaptureSession(screen: FixedScreen(png: png), files: files,
                                 now: { date }, timeZone: TimeZone(secondsFromGMT: -8 * 3600)!)
    let first = try await session.capture()
    let second = try await session.capture()
    let third = try await session.capture()
    #expect(first.lastPathComponent == "mado-20261113160001.png")
    #expect(second.lastPathComponent == "mado-20261113160001-2.png")
    #expect(third.lastPathComponent == "mado-20261113160001-3.png")
    let stored = await files.contents()
    #expect(stored.count == 3)
    #expect(stored.values.allSatisfy { $0 == png })
}

@Test(.timeLimit(.minutes(2))) func downloadsCaptureFilePortNeverOverwritesExistingFile() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let port = DownloadsCaptureFilePort(directory: directory)
    let name = "mado-20261113160001.png"
    let original = Data("original".utf8)
    let replacement = Data("replacement".utf8)
    let url = try await port.writeNewPNG(original, named: name)
    await #expect(throws: CaptureFileError.alreadyExists) {
        try await port.writeNewPNG(replacement, named: name)
    }
    #expect(try Data(contentsOf: url) == original)
}

@Test(.timeLimit(.minutes(2))) func failedCaptureCreatesNoFileAndNextCaptureCanRetry() async throws {
    let files = MemoryFiles()
    let session = CaptureSession(screen: FailedScreen(), files: files)
    await #expect(throws: CocoaError.self) { try await session.capture() }
    #expect(await files.contents().isEmpty)
}

private actor PausedFiles: CaptureFilePort {
    private let started: AsyncStream<Void>.Continuation
    private var unblock: CheckedContinuation<Void, Never>?

    init(started: AsyncStream<Void>.Continuation) { self.started = started }

    func writeNewPNG(_ data: Data, named: String) async throws -> URL {
        await withCheckedContinuation { unblock = $0; started.yield() }
        return URL(fileURLWithPath: "/Downloads/\(named)")
    }

    func finishWrite() { unblock?.resume(); unblock = nil }
}

@Test(.timeLimit(.minutes(2))) func captureSessionRejectsConcurrentWriteAndRecoversAfterItFinishes() async throws {
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    var iterator = stream.makeAsyncIterator()
    let files = PausedFiles(started: continuation)
    let session = CaptureSession(screen: FixedScreen(png: Data([1])), files: files)
    let first = Task { try await session.capture() }
    _ = await iterator.next()
    await #expect(throws: CaptureSessionError.busy) { try await session.capture() }
    await files.finishWrite()
    _ = try await first.value
    let next = Task { try await session.capture() }
    _ = await iterator.next()
    await files.finishWrite()
    _ = try await next.value
}

private struct FailedFiles: CaptureFilePort {
    func writeNewPNG(_ data: Data, named: String) async throws -> URL {
        throw CocoaError(.fileWriteUnknown)
    }
}

@Test(.timeLimit(.minutes(2))) func captureSessionPropagatesWriteFailureWithoutReportingSavedURL() async {
    let session = CaptureSession(screen: FixedScreen(png: Data([1])), files: FailedFiles())
    await #expect(throws: CocoaError.self) { try await session.capture() }
}

@Test(.timeLimit(.minutes(2))) func downloadsCaptureFilePortReportsMissingDirectory() async {
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let port = DownloadsCaptureFilePort(directory: missing)
    await #expect(throws: CocoaError.self) {
        try await port.writeNewPNG(Data([1]), named: "mado-20261113160001.png")
    }
}
