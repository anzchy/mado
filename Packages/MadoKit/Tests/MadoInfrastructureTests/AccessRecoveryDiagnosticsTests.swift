import AppKit
import Foundation
import Testing
import MadoCore
@testable import MadoInfrastructure

private final class DiagnosticTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [(String, URL?)] = []
    var messages: [String] { lock.withLock { lines.map(\.0) } }
    var paths: [URL] { lock.withLock { lines.compactMap(\.1) } }
    var diagnostics: AccessDiagnostics { AccessDiagnostics { [self] text, path in lock.withLock { lines.append((text, path)) } } }
}
private final class DiagnosticBoundary: SecurityScope, BookmarkCoding, FileIdentityResourceReading, @unchecked Sendable {
    private let lock = NSLock()
    private var modeValue = "readable"
    var mode: String { get { lock.withLock { modeValue } } set { lock.withLock { modeValue = newValue } } }
    private var countsValue = [0, 0]
    var counts: [Int] { lock.withLock { countsValue } }
    func start(_ url: URL) -> Bool { lock.withLock { countsValue[0] += 1; return modeValue != "scope" } }
    func stop(_ url: URL) { lock.withLock { countsValue[1] += 1 } }
    func isReadable(_ url: URL) -> Bool { true }
    func create(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolve(_ data: Data) throws -> ResolvedBookmark {
        if mode == "bookmark" { throw Self.error }
        return ResolvedBookmark(url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), stale: mode == "stale")
    }
    func identity(for fileURL: URL) throws -> FileResourceIdentity? {
        if mode == "identityRead" { throw Self.error }
        return FileResourceIdentity(volumeUUID: "111", fileIdentifier: mode == "identityMismatch" ? "replacement" : "saved")
    }
    static var error: NSError { NSError(domain: NSCocoaErrorDomain, code: 257, userInfo: [
        NSLocalizedDescriptionKey: "/Volumes/SecretName/photos/private.jpg",
        NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: 13)]) }
}
private actor DiagnosticMounts: DiskMountPort {
    func mountedVolumes() -> [AccessProbeVolume] { [.init(uuid: "111", url: nil, name: nil)] }
    func events() -> AsyncStream<DiskMountEvent> { AsyncStream { $0.finish() } }
}

@Test(.timeLimit(.minutes(2))) func t229DiagnosticsErrorPrivacyAndNestedErrno() {
    let text = AccessDiagnostics.errorKind(DiagnosticBoundary.error)
    #expect(text.contains("NSCocoaErrorDomain:257"))
    #expect(text.contains("NSPOSIXErrorDomain:13"))
    #expect(!text.contains("SecretName") && !text.contains("private.jpg"))
    let unknown = AccessDiagnostics.errorKind(NSError(domain: "/Volumes/SecretName", code: 5))
    #expect(unknown == "other:5")
}

@Test(.timeLimit(.minutes(2)), arguments: ["bookmark", "scope", "volumeMismatch", "volumeRead", "identityMismatch", "identityRead", "rootRead", "folderRead", "stale", "readable"])
func t229DiagnosticsVerificationStages(mode: String) async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let root = base.appendingPathComponent("SecretName"), child = root.appendingPathComponent("child")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    let trace = DiagnosticTrace(), boundary = DiagnosticBoundary()
    let files = try FileAccess(scope: boundary, bookmarks: boundary,
        store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "T229",
        diagnostics: trace.diagnostics, resourceReader: boundary,
        bookmarkVolume: { _ in .init(uuid: "111", url: nil, name: nil) },
        resolvedVolumeUUID: { _ in
            if boundary.mode == "volumeRead" { throw DiagnosticBoundary.error }
            return boundary.mode == "volumeMismatch" ? "222" : "111"
        }, bookmarkIdentity: { _ in .init(volumeUUID: "111", fileIdentifier: "saved") })
    let id = try await files.grant(folder: root)
    boundary.mode = mode
    if mode == "rootRead" { try FileManager.default.removeItem(at: root) }
    if mode == "folderRead" { try FileManager.default.removeItem(at: child) }
    let result = await files.verifySavedRootForRecovery(id, folder: child, mounts: DiagnosticMounts())
    let good = mode == "readable" || mode == "stale"
    #expect((result.classification.cause == .readable) == good)
    let messages = trace.messages
    #expect(messages.contains { $0.contains("AccessRecoveryVerify") && $0.contains("outcome=attempt") })
    #expect(messages.filter { $0.contains("AccessRecoveryVerify") && ($0.contains("outcome=verified") || $0.contains("outcome=refused")) }.count == 1)
    #expect(messages.contains { $0.contains(good ? "outcome=verified" : "outcome=refused") })
    let stage = ["bookmark": "bookmark", "scope": "scope", "volumeMismatch": "volumeMismatch", "volumeRead": "volumeRead", "identityMismatch": "identityMismatch", "identityRead": "identityRead", "rootRead": "rootRead", "folderRead": "folderRead"]
    if let stage = stage[mode] { #expect(messages.contains { $0.contains("stage=\(stage)") }) }
    if mode == "stale" { #expect(messages.contains { $0.contains("bookmark=resolved stale=true") }) }
    if ["bookmark", "volumeRead", "identityRead"].contains(mode) {
        #expect(messages.contains { $0.contains("NSCocoaErrorDomain:257") && $0.contains("NSPOSIXErrorDomain:13") })
    }
    #expect(!messages.joined().contains("SecretName"))
    if mode != "scope" { #expect(boundary.counts[0] == boundary.counts[1]) }
    else { #expect(messages.contains { $0.contains("scopeStarted=false") }) }
    if mode == "bookmark" {
        let savedBytes = try Data(contentsOf: base.appendingPathComponent("roots.json"))
        boundary.mode = "stale"
        let recovered = await files.verifySavedRootForRecovery(id, folder: child, mounts: DiagnosticMounts())
        #expect(recovered.classification.cause == .readable && recovered.folderURL == child)
        #expect(trace.messages.filter { $0.contains("AccessRecoveryVerify") && $0.contains("outcome=verified") }.count == 1)
        #expect(trace.messages.filter { $0.contains("AccessRecoveryVerify") && $0.contains("outcome=refused") }.count == 1)
        #expect(try Data(contentsOf: base.appendingPathComponent("roots.json")) == savedBytes)
        #expect(boundary.counts[0] == boundary.counts[1])
    }
    if good { #expect(result.folderURL == child && trace.paths.contains { $0.standardizedFileURL.path == root.standardizedFileURL.path }) }
}

@MainActor @Test(.timeLimit(.minutes(3))) func t229DiagnosticsMountNotificationReceipts() async throws {
    let center = NotificationCenter(), trace = DiagnosticTrace()
    let url = URL(fileURLWithPath: "/Volumes/SecretName")
    let port = SystemDiskMountPort(center: center, mountedVolumes: { [.init(uuid: "111", url: url, name: nil)] }, diagnostics: trace.diagnostics)
    defer { port.stop() }
    let stream = await port.events()
    var iterator = stream.makeAsyncIterator()
    center.post(name: NSWorkspace.didUnmountNotification, object: nil, userInfo: [NSWorkspace.volumeURLUserInfoKey: url])
    center.post(name: NSWorkspace.didMountNotification, object: nil, userInfo: [NSWorkspace.volumeURLUserInfoKey: url])
    center.post(name: NSWorkspace.didMountNotification, object: nil, userInfo: [NSWorkspace.volumeURLUserInfoKey: URL(fileURLWithPath: "/Volumes/Unknown")])
    center.post(name: NSWorkspace.didMountNotification, object: nil)
    while trace.messages.count < 3 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(trace.messages.contains { $0.contains("event=unmount") && $0.contains("volume=111") })
    #expect(trace.messages.contains { $0.contains("event=mount") && $0.contains("volume=111") })
    #expect(trace.messages.contains { $0.contains("event=mount") && $0.contains("volume=unknown") })
    #expect(await iterator.next() == .unmounted(.init(uuid: "111", url: url, name: nil)))
    #expect(await iterator.next() == .mounted(.init(uuid: "111", url: url, name: nil)))
    while trace.messages.count < 4 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(trace.messages.count == 4)
    #expect(!trace.messages.joined().contains("SecretName"))
}
