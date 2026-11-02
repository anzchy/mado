import Foundation
import Testing
import PicseeCore
@testable import PicseeApplication

private struct T229FailingMetadataReader: FolderMetadataReading {
    func read(_ url: URL) throws -> FolderImageMetadata { throw FolderScanTestError.expected }
}
private final class T229HeldFailingMetadataReader: FolderMetadataReading, @unchecked Sendable {
    private let lock = NSLock()
    private let gate = TestGate()
    private var entered = false
    var started: Bool { lock.withLock { entered } }
    func read(_ url: URL) throws -> FolderImageMetadata {
        lock.withLock { entered = true }
        gate.wait()
        throw FolderScanTestError.expected
    }
    func release() { gate.signal() }
    func open() { gate.open() }
}

@MainActor @Test(.timeLimit(.minutes(3))) func t229MetadataFailureReportsCurrentGenerationAndCallbackEndCannotRepublish() async throws {
    let fixture = FolderScanFixture()
    let scan = FolderScanCoordinator(access: fixture.access, scanner: fixture.scanner,
        metadataReader: T229FailingMetadataReader())
    var failures: [(AccessRootID, URL)] = []
    scan.onReadFailure = { id, url in failures.append((id, url)); scan.end() }
    defer { scan.onReadFailure = nil; scan.end() }
    let pending = scan.begin(folder: fixture.folder, rootID: fixture.id)
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["a.jpg"])
    await fixture.scanner.finish(); try await pending.value
    scan.setConditions(.init(sort: .captureDate))
    while failures.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
    #expect(failures.count == 1)
    #expect(failures.first?.0 == fixture.id)
    #expect(failures.first?.1 == fixture.folder.appendingPathComponent("a.jpg"))
    #expect(scan.snapshot == nil && scan.sourceSnapshot == nil)
    #expect(!scan.isMetadataSortPending)

    let staleFixture = FolderScanFixture(), reader = T229HeldFailingMetadataReader()
    let staleScan = FolderScanCoordinator(access: staleFixture.access, scanner: staleFixture.scanner, metadataReader: reader)
    var staleFailures = 0
    staleScan.onReadFailure = { _, _ in staleFailures += 1 }
    defer { staleScan.end(); reader.open() }
    let old = staleScan.begin(folder: staleFixture.folder, rootID: staleFixture.id)
    await staleFixture.scanner.waitForStart()
    try await staleFixture.scanner.deliver(["old.jpg"])
    await staleFixture.scanner.finish(); try await old.value
    staleScan.setConditions(.init(sort: .captureDate))
    while !reader.started { try await Task.sleep(for: .milliseconds(5)) }
    #expect(reader.started)
    staleScan.end()
    reader.release()
    while true {
        try Task.checkCancellation()
        let balance = await staleFixture.access.balance
        if balance[0] == balance[1] { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(staleFailures == 0)
    #expect(staleScan.snapshot == nil && staleScan.sourceSnapshot == nil)
}
