import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import MadoCore
import MadoApplication
@testable import MadoInfrastructure

// #690 (P7-11) WI-2: the atomic Annotated Copy writer (ADR-020).

/// Counts leases and records what was requested; every file mutation must happen while one is held.
private actor CountingLeases: AccessLeasing {
    private(set) var acquired = 0, released = 0
    private(set) var requests: [AccessRequest] = []
    var held: Int { acquired - released }
    private var failure: (any Error)?
    func failAcquire(_ error: any Error) { failure = error }
    func acquire(_ request: AccessRequest) throws -> AccessLease {
        requests.append(request)
        if let failure { throw failure }
        acquired += 1
        switch request {
        case .root(let id, let file): return AccessLease(url: file.deletingLastPathComponent(), rootID: id)
        case .fileGrant(let file): return AccessLease(url: file, rootID: nil)
        }
    }
    func release(_ lease: AccessLease) { released += 1 }
}

private final class StepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    var values: [String] { lock.withLock { entries } }
    func append(_ entry: String) { lock.withLock { entries.append(entry) } }
}

private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

private func quadrantImage(width: Int = 16, height: Int = 8) -> CGImage {
    var bytes: [UInt8] = []
    for y in 0..<height {
        for x in 0..<width {
            switch (x < width / 2, y < height / 2) {
            case (true, true): bytes += [255, 0, 0, 255]
            case (false, true): bytes += [0, 255, 0, 255]
            case (true, false): bytes += [0, 0, 255, 255]
            case (false, false): bytes += [128, 128, 128, 255]
            }
        }
    }
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                   space: sRGB, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false,
                   intent: .defaultIntent)!
}

private func copyPixels(_ image: CGImage) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    bytes.withUnsafeMutableBytes { buffer in
        let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: sRGB,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return bytes
}

private struct Decoded {
    let type: String, image: CGImage, properties: [String: Any]
}

private func decode(_ url: URL) throws -> Decoded {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
    return Decoded(type: CGImageSourceGetType(source).map { $0 as String } ?? "", image: image, properties: properties)
}

/// The bytes of a file, or empty when it cannot be read (a thrown read error would read as an environment failure).
private func contents(_ url: URL) -> Data { (try? Data(contentsOf: url)) ?? Data() }

private func sha(_ url: URL) -> String {
    let data = (try? Data(contentsOf: url)) ?? Data()
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// Every entry of `folder`, hidden ones included, with the SHA-256 of its bytes.
private func snapshot(_ folder: URL) -> [String: String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    return Dictionary(uniqueKeysWithValues: names.map { ($0, sha(folder.appendingPathComponent($0))) })
}

private struct Fixture {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("mado-annotated-\(UUID())")
    let rootID = AccessRootID()
    var folder: URL { base.appendingPathComponent("photos") }
    var source: URL { folder.appendingPathComponent("photo.jpg") }
    let copy: CGImage

    init() throws {
        try FileManager.default.createDirectory(at: base.appendingPathComponent("photos"), withIntermediateDirectories: true)
        let original = quadrantImage()
        let destination = try #require(CGImageDestinationCreateWithURL(
            base.appendingPathComponent("photos/photo.jpg") as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 35.0, kCGImagePropertyGPSLatitudeRef: "N"],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCKeywords: ["secret"]],
        ]
        CGImageDestinationAddImage(destination, original, properties as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        copy = try AnnotationFlattener.flatten(original, orientation: 6,
                                               marks: [AnnotationMark(rect: CGRect(x: 1, y: 1, width: 5, height: 10))])
    }

    var request: AccessRequest { .root(rootID, file: source) }
    func named(_ name: String) -> URL { folder.appendingPathComponent(name) }
    func plan(_ sourceName: String = "photo.jpg") -> AnnotatedCopyName {
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return AnnotatedCopyPlan.name(for: sourceName, existing: existing, writableTypes: ImageIOWritableTypes.all)
    }
    func cleanup() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        try? FileManager.default.removeItem(at: base)
    }
}

private let jpegName = AnnotatedCopyName(stem: "photo", pathExtension: "jpg", type: .jpeg)
private let webpType = UTType("org.webmproject.webp")!

private func hasTemp(_ folder: URL) -> Bool {
    ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).contains { $0.contains(".mado-tmp-") }
}

@Test(.timeLimit(.minutes(2))) func writerWritesDecodableCopyWithoutMetadata() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let sourceSHA = sha(fixture.source)
    let leases = CountingLeases()
    let url = try await AnnotatedCopyWriter(leases: leases).write(fixture.copy, folder: fixture.folder,
        target: .create(jpegName), source: fixture.source, request: fixture.request)
    #expect(url.standardizedFileURL == fixture.named("photo-annotated.jpg").standardizedFileURL)
    let decoded = try decode(url)
    #expect(decoded.type == UTType.jpeg.identifier)
    try #require(decoded.image.width == 8 && decoded.image.height == 16)
    let got = copyPixels(decoded.image), want = copyPixels(fixture.copy)
    let meanError = Double(zip(got, want).map { abs(Int($0) - Int($1)) }.reduce(0, +)) / Double(got.count)
    #expect(meanError < 8, "mean error \(meanError)")
    #expect(decoded.properties[kCGImagePropertyGPSDictionary as String] == nil)
    #expect(decoded.properties[kCGImagePropertyIPTCDictionary as String] == nil)
    let orientation = decoded.properties[kCGImagePropertyOrientation as String] as? Int
    #expect(orientation == nil || orientation == 1)
    let after = snapshot(fixture.folder)
    #expect(Set(after.keys) == ["photo.jpg", "photo-annotated.jpg"])
    #expect(after["photo.jpg"] == sourceSHA)
}

@Test(.timeLimit(.minutes(2))) func writerWritesPNGLosslessly() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    try FileManager.default.copyItem(at: fixture.source, to: fixture.named("x.webp"))
    let name = fixture.plan("x.webp")
    #expect(name.name == "x-annotated.png")
    let url = try await AnnotatedCopyWriter(leases: CountingLeases()).write(fixture.copy, folder: fixture.folder,
        target: .create(name), source: fixture.named("x.webp"), request: fixture.request)
    let decoded = try decode(url)
    #expect(decoded.type == UTType.png.identifier)
    #expect(copyPixels(decoded.image) == copyPixels(fixture.copy))
}

@Test(.timeLimit(.minutes(2))) func writerRetriesOnLateClash() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let clash = fixture.named("photo-annotated.jpg")
    let writer = AnnotatedCopyWriter(leases: CountingLeases()) { step, _ in
        if step == .move { try Data("X".utf8).write(to: clash) }
    }
    let url = try await writer.write(fixture.copy, folder: fixture.folder, target: .create(jpegName),
                                     source: fixture.source, request: fixture.request)
    #expect(url.lastPathComponent == "photo-annotated-2.jpg")
    #expect(contents(clash) == Data("X".utf8))
    #expect(try decode(url).image.width == 8)
    #expect(!hasTemp(fixture.folder))
}

@Test(.timeLimit(.minutes(2))) func writerSuccessiveWritesAreDistinct() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let writer = AnnotatedCopyWriter(leases: CountingLeases())
    var names: [String] = []
    for _ in 0..<3 {
        let url = try await writer.write(fixture.copy, folder: fixture.folder, target: .create(fixture.plan()),
                                         source: fixture.source, request: fixture.request)
        names.append(url.lastPathComponent)
        #expect(try decode(url).image.height == 16)
    }
    #expect(names == ["photo-annotated.jpg", "photo-annotated-2.jpg", "photo-annotated-3.jpg"])
    #expect(Set(snapshot(fixture.folder).keys) == Set(["photo.jpg"] + names))
}

@Test(.timeLimit(.minutes(2))) func writerNameExhausted() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    for number in 1...5 { try Data("\(number)".utf8).write(to: fixture.named(jpegName.numbered(number).name)) }
    let before = snapshot(fixture.folder)
    await #expect(throws: AnnotatedCopyError.nameExhausted) {
        try await AnnotatedCopyWriter(leases: CountingLeases(), nameBound: 4).write(fixture.copy,
            folder: fixture.folder, target: .create(jpegName), source: fixture.source, request: fixture.request)
    }
    #expect(snapshot(fixture.folder) == before)
}

@Test(.timeLimit(.minutes(2))) func writerPermissionDeniedOnReadOnlyFolder() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fixture.folder.path)
    let before = snapshot(fixture.folder)
    await #expect(throws: AnnotatedCopyError.permissionDenied) {
        try await AnnotatedCopyWriter(leases: CountingLeases()).write(fixture.copy, folder: fixture.folder,
            target: .create(jpegName), source: fixture.source, request: fixture.request)
    }
    #expect(snapshot(fixture.folder) == before)
}

@Test(.timeLimit(.minutes(2))) func writerFolderMissing() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let elsewhere = fixture.base.appendingPathComponent("photo.jpg")
    try FileManager.default.copyItem(at: fixture.source, to: elsewhere)
    try FileManager.default.removeItem(at: fixture.folder)
    await #expect(throws: AnnotatedCopyError.folderMissing) {
        try await AnnotatedCopyWriter(leases: CountingLeases()).write(fixture.copy, folder: fixture.folder,
            target: .create(jpegName), source: elsewhere, request: fixture.request)
    }
}

@Test(.timeLimit(.minutes(2))) func writerSourceMissingBeforeMove() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let source = fixture.source
    let writer = AnnotatedCopyWriter(leases: CountingLeases()) { step, _ in
        if step == .identityCheck { try FileManager.default.removeItem(at: source) }
    }
    await #expect(throws: AnnotatedCopyError.sourceMissing) {
        try await writer.write(fixture.copy, folder: fixture.folder, target: .create(jpegName), source: source,
                               request: fixture.request)
    }
    #expect(snapshot(fixture.folder) == [:])
}

@Test(.timeLimit(.minutes(2))) func writerRejectsHardLinkAndCaseVariantTarget() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let alias = fixture.named("alias.jpg")
    try FileManager.default.linkItem(at: fixture.source, to: alias)
    let sourceSHA = sha(fixture.source)
    for target in [alias, fixture.named("PHOTO.JPG")] {
        let log = StepLog()
        let writer = AnnotatedCopyWriter(leases: CountingLeases()) { step, _ in log.append("\(step)") }
        await #expect(throws: AnnotatedCopyError.sourceIsTarget, "\(target.lastPathComponent)") {
            try await writer.write(fixture.copy, folder: fixture.folder, target: .replace(target, type: .jpeg),
                                   source: fixture.source, request: fixture.request)
        }
        #expect(!log.values.contains("tempCreate"), "\(target.lastPathComponent): \(log.values)")
    }
    #expect(sha(fixture.source) == sourceSHA && sha(alias) == sourceSHA)
    #expect(Set(snapshot(fixture.folder).keys) == ["photo.jpg", "alias.jpg"])
}

@Test(.timeLimit(.minutes(2))) func writerEncodeFailureCleansUp() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let before = snapshot(fixture.folder)
    let name = AnnotatedCopyName(stem: "photo", pathExtension: "webp", type: webpType)
    await #expect(throws: AnnotatedCopyError.encodeFailed) {
        try await AnnotatedCopyWriter(leases: CountingLeases()).write(fixture.copy, folder: fixture.folder,
            target: .create(name), source: fixture.source, request: fixture.request)
    }
    #expect(snapshot(fixture.folder) == before)
}

@Test(.timeLimit(.minutes(2))) func writerFailureAtAnyStepLeavesFolderUnchanged() async throws {
    for replace in [false, true] {
        for failing in AnnotatedCopyWriteStep.allCases {
            let fixture = try Fixture(); defer { fixture.cleanup() }
            let other = fixture.named("other.jpg")
            try Data("OLD".utf8).write(to: other)
            let before = snapshot(fixture.folder)
            let leases = CountingLeases()
            let writer = AnnotatedCopyWriter(leases: leases) { step, _ in
                if step == failing { throw POSIXError(.EIO) }
            }
            let target: AnnotatedCopyTarget = replace ? .replace(other, type: .jpeg) : .create(jpegName)
            await #expect(throws: AnnotatedCopyError.writeFailed, "\(failing) replace=\(replace)") {
                try await writer.write(fixture.copy, folder: fixture.folder, target: target, source: fixture.source,
                                       request: fixture.request)
            }
            #expect(snapshot(fixture.folder) == before, "\(failing) replace=\(replace)")
            #expect(!hasTemp(fixture.folder), "\(failing) replace=\(replace)")
            let (taken, given) = (await leases.acquired, await leases.released)
            #expect(taken == given, "\(failing) replace=\(replace)")
            #expect(contents(other) == Data("OLD".utf8))
        }
    }
}

@Test(.timeLimit(.minutes(2))) func writerMapsErrno() {
    for code in [EACCES, EPERM, EROFS] { #expect(AnnotatedCopyWriter.map(errno: code) == .permissionDenied, "\(code)") }
    for code in [ENOSPC, EDQUOT] { #expect(AnnotatedCopyWriter.map(errno: code) == .diskFull, "\(code)") }
    #expect(AnnotatedCopyWriter.map(errno: ENOENT) == .folderMissing)
    #expect(AnnotatedCopyWriter.map(errno: ENOTDIR) == .folderMissing)
    #expect(AnnotatedCopyWriter.map(errno: EIO) == .writeFailed, "#690 gap 4")
    #expect(AnnotatedCopyWriter.map(POSIXError(.ENOSPC)) == .diskFull)
    #expect(AnnotatedCopyWriter.map(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))) == .permissionDenied)
    let wrapped = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteUnknown.rawValue,
                          userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS))])
    #expect(AnnotatedCopyWriter.map(wrapped) == .permissionDenied)
    #expect(AnnotatedCopyWriter.map(CocoaError(.fileWriteUnknown)) == .writeFailed)
    #expect(AnnotatedCopyWriter.map(AnnotatedCopyError.sourceMissing) == .sourceMissing, "typed errors pass through")
}

@Test(.timeLimit(.minutes(2))) func writerWritesOnlyInsideLease() async throws {
    for replace in [false, true] {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let other = fixture.named("other.jpg")
        try Data("OLD".utf8).write(to: other)
        let leases = CountingLeases()
        let log = StepLog()
        let writer = AnnotatedCopyWriter(leases: leases) { step, _ in
            if [.tempCreate, .encode, .move].contains(step) { log.append("\(step):\(await leases.held > 0)") }
        }
        let target: AnnotatedCopyTarget = replace ? .replace(other, type: .jpeg) : .create(jpegName)
        let url = try await writer.write(fixture.copy, folder: fixture.folder, target: target, source: fixture.source,
                                         request: fixture.request)
        #expect(log.values == ["tempCreate:true", "encode:true", "move:true"], "replace=\(replace)")
        let (taken, given, held) = (await leases.acquired, await leases.released, await leases.held)
        #expect(taken == 1 && given == 1 && held == 0)
        #expect(FileManager.default.fileExists(atPath: url.path))
        let expected: AccessRequest = replace ? fixture.request
            : .root(fixture.rootID, file: fixture.named("photo-annotated.jpg"))
        #expect(await leases.requests == [expected], "replace=\(replace): the lease names the destination")
    }
}

@Test(.timeLimit(.minutes(2))) func writerAcquireFailureIsAccessLost() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let leases = CountingLeases()
    await leases.failAcquire(FileAccessError.needsReconnection(fixture.rootID))
    let before = snapshot(fixture.folder)
    await #expect(throws: AnnotatedCopyError.accessLost) {
        try await AnnotatedCopyWriter(leases: leases).write(fixture.copy, folder: fixture.folder,
            target: .create(jpegName), source: fixture.source, request: fixture.request)
    }
    #expect(snapshot(fixture.folder) == before)
    #expect(await leases.released == 0)
}

@Test(.timeLimit(.minutes(2))) func writerPanelReplaceIsAtomic() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let other = fixture.named("other.jpg")
    try Data("OLD".utf8).write(to: other)
    await #expect(throws: AnnotatedCopyError.encodeFailed) {
        try await AnnotatedCopyWriter(leases: CountingLeases()).write(fixture.copy, folder: fixture.folder,
            target: .replace(other, type: webpType), source: fixture.source, request: fixture.request)
    }
    #expect(contents(other) == Data("OLD".utf8))
    let url = try await AnnotatedCopyWriter(leases: CountingLeases()).write(fixture.copy, folder: fixture.folder,
        target: .replace(other, type: .jpeg), source: fixture.source, request: fixture.request)
    #expect(url.standardizedFileURL == other.standardizedFileURL)
    let decoded = try decode(other)
    #expect(decoded.image.width == 8 && decoded.image.height == 16)
    #expect(Set(snapshot(fixture.folder).keys) == ["photo.jpg", "other.jpg"])
}

@Test(.timeLimit(.minutes(2))) func writerNewPanelNameIsCreated() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let chosen = fixture.named("chosen.png")
    let url = try await AnnotatedCopyWriter(leases: CountingLeases()).write(fixture.copy, folder: fixture.folder,
        target: .replace(chosen, type: .png), source: fixture.source, request: fixture.request)
    #expect(url.standardizedFileURL == chosen.standardizedFileURL)
    #expect(copyPixels(try decode(chosen).image) == copyPixels(fixture.copy))
    #expect(Set(snapshot(fixture.folder).keys) == ["photo.jpg", "chosen.png"])
}

@Test(.timeLimit(.minutes(2))) func writableTypesFromImageIO() {
    let types = ImageIOWritableTypes.all
    for type in [UTType.jpeg, .png, .tiff, .heic] { #expect(types.contains(type), "\(type)") }
    #expect(!types.contains(webpType))
}

@Test(.timeLimit(.minutes(2))) func annotatedTempFileIsNotScanned() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    try FileManager.default.copyItem(at: fixture.source, to: fixture.named(".photo-annotated.jpg.mado-tmp-\(UUID())"))
    let entries = ScanEntries()
    try await FolderBrowser().scan(in: fixture.folder, root: ItemIdentityRoot(id: fixture.rootID, url: fixture.folder),
                                   options: .init()) { await entries.append($0) }
    #expect(await entries.names == ["photo.jpg"])
}

private actor ScanEntries {
    private(set) var names: [String] = []
    func append(_ batch: [FolderEntry]) { names += batch.map(\.relativePath) }
}
