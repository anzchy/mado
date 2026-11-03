import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import os
import PicseeCore
import SQLite3
import UniformTypeIdentifiers

/// Re-creatable small renders only. Actor isolation serializes SQLite and payload operations;
/// the actor never inherits MainActor from its caller.
public actor ThumbnailDiskCache: ThumbnailCaching, CacheMaintenance {
    public struct WriteDiagnostics: Sendable, Equatable {
        public let failureCount: Int
        public let skippedWriteCount: Int
        public let lastFailure: String?
    }
    enum IntegrityDecision: Equatable { case healthy, confirmedCorrupt, unconfirmedFailure }
    static func integrityDecision(prepareCode: Int32, firstStepCode: Int32?, diagnostic: String?) -> IntegrityDecision {
        if isCorruptSQLite(prepareCode) { return .confirmedCorrupt }
        guard prepareCode == SQLITE_OK, let firstStepCode else { return .unconfirmedFailure }
        if isCorruptSQLite(firstStepCode) { return .confirmedCorrupt }
        guard firstStepCode == SQLITE_ROW, let diagnostic else { return .unconfirmedFailure }
        return diagnostic == "ok" ? .healthy : .confirmedCorrupt
    }
    static func isMissingRemovalError(_ error: NSError) -> Bool {
        (error.domain == NSCocoaErrorDomain && error.code == CocoaError.fileNoSuchFile.rawValue)
            || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
    }
    static func publicErrorCode(_ error: Error) -> String {
        if case let ThumbnailStoreError.database(code) = error { return "sqlite:\(code)" }
        if error is CachePathError { return "unsafe-cache-path" }
        let value = error as NSError
        if value.domain == NSCocoaErrorDomain { return "cocoa:\(value.code)" }
        if value.domain == NSPOSIXErrorDomain { return "posix:\(value.code)" }
        return "other:\(value.code)"
    }
    public static let maximumSourceBytes = 32 * 1024 * 1024
    public static let maximumPayloadBytes = 8 * 1024 * 1024
    public static let maximumPixelEdge = 1024
    static let defaultHighWaterBytes = 2 * 1024 * 1024 * 1024
    static let defaultLowWaterBytes = defaultHighWaterBytes * 3 / 4
    private static let cacheVersion = 2
    private static let encoderVersion = 2
    private static let tempSweepCutoff: Date = {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return .distantFuture }
        let started = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: TimeInterval(started.tv_sec) + TimeInterval(started.tv_usec) / 1_000_000)
    }()
    private let directory: URL
    private let highWaterBytes: Int
    private let lowWaterBytes: Int
    private let afterPayloadWrite: (@Sendable () throws -> Void)?
    private let afterReadLeaseAcquired: (@Sendable () async -> Void)?
    private let afterOrphanSnapshot: (@Sendable () async -> Void)?
    private var didSweepOrphans = false
    private var writeFailureCount = 0
    private var skippedWriteCount = 0
    private var writeRetrySkipsRemaining = 0
    private var lastWriteFailure: String?
    private var loadHits = 0
    private var loadMisses = 0
    private let statsClock: @Sendable () -> TimeInterval
    private static let uptime: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Full index aggregates run so far; diagnostics test seam.
    private(set) var indexScans = 0
    /// The last aggregate, reused for `indexScanInterval` so a visible panel doesn't scan the index every second.
    private var lastIndexScan: (at: TimeInterval, entries: Int, bytes: Int64)?
    static let indexScanInterval: TimeInterval = 10
    private let logger = Logger(subsystem: "io.github.anzchy.picsee", category: "thumbnail-cache")

    public init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Picsee/Thumbnails", isDirectory: true)) {
        self.directory = directory
        self.highWaterBytes = Self.defaultHighWaterBytes
        self.lowWaterBytes = Self.defaultLowWaterBytes
        self.afterPayloadWrite = nil
        self.afterReadLeaseAcquired = nil
        self.afterOrphanSnapshot = nil
        self.statsClock = Self.uptime
    }

    init(directory: URL, statsClock: @escaping @Sendable () -> TimeInterval) {
        self.directory = directory
        self.highWaterBytes = Self.defaultHighWaterBytes
        self.lowWaterBytes = Self.defaultLowWaterBytes
        self.afterPayloadWrite = nil
        self.afterReadLeaseAcquired = nil
        self.afterOrphanSnapshot = nil
        self.statsClock = statsClock
    }

    init(directory: URL, afterPayloadWrite: @escaping @Sendable () throws -> Void) {
        self.directory = directory
        self.highWaterBytes = Self.defaultHighWaterBytes
        self.lowWaterBytes = Self.defaultLowWaterBytes
        self.afterPayloadWrite = afterPayloadWrite
        self.afterReadLeaseAcquired = nil
        self.afterOrphanSnapshot = nil
        self.statsClock = Self.uptime
    }

    init(directory: URL, highWaterBytes: Int, lowWaterBytes: Int) {
        self.directory = directory
        self.highWaterBytes = highWaterBytes
        self.lowWaterBytes = lowWaterBytes
        self.afterPayloadWrite = nil
        self.afterReadLeaseAcquired = nil
        self.afterOrphanSnapshot = nil
        self.statsClock = Self.uptime
    }

    init(directory: URL, afterReadLeaseAcquired: @escaping @Sendable () async -> Void) {
        self.directory = directory
        self.highWaterBytes = Self.defaultHighWaterBytes
        self.lowWaterBytes = Self.defaultLowWaterBytes
        self.afterPayloadWrite = nil
        self.afterReadLeaseAcquired = afterReadLeaseAcquired
        self.afterOrphanSnapshot = nil
        self.statsClock = Self.uptime
    }

    init(directory: URL, afterOrphanSnapshot: @escaping @Sendable () async -> Void) {
        self.directory = directory
        self.highWaterBytes = Self.defaultHighWaterBytes
        self.lowWaterBytes = Self.defaultLowWaterBytes
        self.afterPayloadWrite = nil
        self.afterReadLeaseAcquired = nil
        self.afterOrphanSnapshot = afterOrphanSnapshot
        self.statsClock = Self.uptime
    }

    /// Logical bytes of cache-owned regular files. A failed measurement is an error, not zero.
    public func sizeBytes() throws -> Int64 {
        try withIndexLock {
            try requireSafeDirectory()
            guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            var total: Int64 = 0
            for name in names where Self.isOwnedName(name) {
                let url = directory.appendingPathComponent(name)
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular else { continue }
                let bytes = (attributes[.size] as! NSNumber).int64Value
                let (sum, overflow) = total.addingReportingOverflow(bytes)
                total = overflow ? Int64.max : sum
            }
            return total
        }
    }
    public func writeDiagnostics() -> WriteDiagnostics {
        WriteDiagnostics(failureCount: writeFailureCount, skippedWriteCount: skippedWriteCount,
                         lastFailure: lastWriteFailure)
    }
    public func hasWriteFailure() -> Bool { lastWriteFailure != nil }
    /// Load outcomes since launch, with the entry count and payload bytes the index records for current-version
    /// rows (older rows always miss). The index can still list a payload deleted outside the App until a load
    /// repairs it. One aggregate query, reused for up to `indexScanInterval` seconds; this cache's `clear()`
    /// drops it. A missing index is an empty cache; one that can't be read leaves both figures unknown.
    public func diagnostics() -> DiagnosticsSnapshot.DiskCache {
        let now = statsClock()
        if let last = lastIndexScan, now - last.at < Self.indexScanInterval {
            return DiagnosticsSnapshot.DiskCache(entries: last.entries, storedBytes: last.bytes, hits: loadHits, misses: loadMisses)
        }
        let indexed = withIndexLock { () -> (entries: Int, bytes: Int64)? in
            guard (try? requireSafeDirectory()) != nil else { return nil }
            guard FileManager.default.fileExists(atPath: databaseURL.path) else { return (0, 0) }
            guard let db = openDatabase(create: false) else { return nil }
            defer { sqlite3_close(db) }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*), COALESCE(SUM(byte_count),0) FROM thumbnails WHERE cache_version=2",
                                     -1, &statement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(statement) }
            indexScans += 1
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            let scanned = (entries: Int(sqlite3_column_int64(statement, 0)), bytes: sqlite3_column_int64(statement, 1))
            lastIndexScan = (now, scanned.entries, scanned.bytes)
            return scanned
        }
        return DiagnosticsSnapshot.DiskCache(entries: indexed?.entries, storedBytes: indexed?.bytes,
                                             hits: loadHits, misses: loadMisses)
    }

    /// Advances the generation before removing any files, so old work can never publish later.
    public func clear() throws {
        lastIndexScan = nil
        try withIndexLock {
            try requireSafeDirectory()
            CacheIndexLocks.shared.advanceGeneration(for: directory)
            guard FileManager.default.fileExists(atPath: directory.path) else { return }
            for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) where Self.isOwnedName(name) {
                let url = directory.appendingPathComponent(name)
                guard url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
                      (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeRegular,
                      (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil else { continue }
                try PayloadLeaseRegistry.shared.removeWhenUnleased(url.path)
            }
            didSweepOrphans = false
        }
        writeFailureCount = 0
        skippedWriteCount = 0
        writeRetrySkipsRemaining = 0
        lastWriteFailure = nil
    }

    /// Used by Settings after Clear so its next measurement includes deferred lease cleanup.
    public func deferredClearFailure() -> String? {
        PayloadLeaseRegistry.shared.deferredClearFailure(in: directory)
    }

    public func waitForPendingDeletions(onRegistered: (@Sendable () -> Void)? = nil) async {
        await PayloadLeaseRegistry.shared.waitForPendingDeletions(in: directory, onRegistered: onRegistered)
    }

    private static func isOwnedName(_ name: String) -> Bool {
        if ["index.sqlite3", "index.sqlite3-wal", "index.sqlite3-shm", "index.sqlite3-journal"].contains(name) { return true }
        if name.hasPrefix(".tmp-") { return UUID(uuidString: String(name.dropFirst(5))) != nil }
        guard name.hasSuffix(".png"), name.utf8.count == 68 else { return false }
        return name.dropLast(4).utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private func requireSafeDirectory() throws {
        var prefix = "/"
        for component in directory.standardizedFileURL.pathComponents.dropFirst() {
            prefix = (prefix as NSString).appendingPathComponent(component)
            // macOS exposes its system-owned /var and /tmp aliases in temporary paths.
            if prefix == "/var" || prefix == "/tmp" { continue }
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: prefix)) != nil {
                throw CachePathError.symbolicLinkDirectory
            }
        }
    }

    public func prepare(_ request: ImageDecodeRequest) async throws -> ThumbnailCacheTicket? {
        try request.accessPermit?.check()
        try Task.checkCancellation()
        let generation = CacheIndexLocks.shared.generation(for: directory)
        guard let render = request.renderKey,
              render.itemID.stableEncoding.hasPrefix("id1:root:"),
              render.policy == .orientedSDR, render.frameIndex == 0,
              render.maximumPixelSize == request.maximumPixelSize,
              render.isPreview == request.isPreview,
              request.maximumPixelSize > 0,
              request.maximumPixelSize <= Self.maximumPixelEdge,
              request.fileURL.isFileURL else { return nil }
        let digest: String?
        do { digest = try fingerprint(request.fileURL, expected: render.revision) }
        catch where AccessReadFailure.isPermissionDenied(error) { throw error }
        catch { digest = nil }
        try Task.checkCancellation()
        guard let digest, let key = DurableThumbnailKey(renderKey: render, sourceSHA256: digest,
                                                       encoderVersion: Self.encoderVersion) else { return nil }
        try request.accessPermit?.check()
        return ThumbnailCacheTicket(request: request, key: key, sourceSHA256: digest,
                                    generation: generation)
    }

    /// A returned image is a hit and nil a miss; a throw (cancellation) is neither. Counted per load attempt:
    /// a caller that discards a returned image afterwards (for example on its size checks) leaves the hit.
    public func load(_ ticket: ThumbnailCacheTicket) async throws -> DecodedImage? {
        try ticket.request.accessPermit?.check()
        let image = try await loadPayload(ticket)
        return try AccessWorkPermit.admitting(ticket.request.accessPermit) {
            if image == nil { loadMisses += 1 } else { loadHits += 1 }
            return image
        }
    }

    public nonisolated var supportsMemoryReuse: Bool { true }

    public func revalidateMemory(_ image: DecodedImage, for ticket: ThumbnailCacheTicket) async throws -> DecodedImage? {
        try ticket.request.accessPermit?.check()
        let validated = try await loadPayload(ticket, reusing: image)
        return try AccessWorkPermit.admitting(ticket.request.accessPermit) { validated }
    }

    private func loadPayload(_ ticket: ThumbnailCacheTicket, reusing resident: DecodedImage? = nil) async throws -> DecodedImage? {
        try Task.checkCancellation()
        guard ticket.generation == CacheIndexLocks.shared.generation(for: directory) else { return nil }
        guard let render = ticket.request.renderKey,
              let expectedKey = DurableThumbnailKey(renderKey: render, sourceSHA256: ticket.sourceSHA256,
                                                    encoderVersion: Self.encoderVersion),
              expectedKey == ticket.key,
              try fingerprint(ticket.request.fileURL, expected: render.revision) == ticket.sourceSHA256 else { return nil }
        await sweepOrphansIfNeeded()
        guard let row = readRow(ticket), row.byteCount > 0, row.byteCount <= Self.maximumPayloadBytes,
              row.payloadPath == ticket.key.filename + ".png" else {
            removeDamagedEntry(ticket)
            return nil
        }
        let payload = directory.appendingPathComponent(row.payloadPath)
        guard PayloadLeaseRegistry.shared.acquire(payload.path) else { return nil }
        var leaseHeld = true
        defer { if leaseHeld { PayloadLeaseRegistry.shared.release(payload.path) } }
        func damagedPayload() -> DecodedImage? {
            PayloadLeaseRegistry.shared.release(payload.path)
            leaseHeld = false
            removeDamagedEntry(ticket)
            return nil
        }
        await afterReadLeaseAcquired?()
        try ticket.request.accessPermit?.check()
        try Task.checkCancellation()
        let decodeOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: ticket.request.maximumPixelSize,
        ]
        guard let data = try boundedPayload(at: payload, expectedByteCount: row.byteCount),
              digest(data) == row.payloadSHA256,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              (CGImageSourceGetType(source) as String?) == UTType.png.identifier,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { return damagedPayload() }
        let image: CGImage
        if let resident {
            guard resident.itemID == render.itemID, resident.revision == render.revision,
                  resident.sourcePixelSize == CGSize(width: row.sourceWidth, height: row.sourceHeight),
                  resident.image.width > 0, resident.image.height > 0,
                  resident.image.width <= ticket.request.maximumPixelSize,
                  resident.image.height <= ticket.request.maximumPixelSize else { return nil }
            image = resident.image
        } else {
            guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, decodeOptions as CFDictionary),
                  decoded.width > 0, decoded.height > 0,
                  decoded.width <= ticket.request.maximumPixelSize,
                  decoded.height <= ticket.request.maximumPixelSize else { return damagedPayload() }
            image = decoded
        }
        try Task.checkCancellation()
        guard try fingerprint(ticket.request.fileURL, expected: render.revision) == ticket.sourceSHA256,
              resident == nil || ticket.generation == CacheIndexLocks.shared.generation(for: directory) else { return nil }
        try Task.checkCancellation()
        touch(ticket.key.filename)
        return DecodedImage(image: image,
            sourcePixelSize: CGSize(width: row.sourceWidth, height: row.sourceHeight),
            revision: render.revision, itemID: render.itemID, accessPermit: ticket.request.accessPermit)
    }

    public func store(_ image: DecodedImage, for ticket: ThumbnailCacheTicket) async throws {
        _ = try await storeForMemory(image, for: ticket)
    }

    public func storeForMemory(_ image: DecodedImage, for ticket: ThumbnailCacheTicket) async throws -> Bool {
        try ticket.request.accessPermit?.check()
        try Task.checkCancellation()
        guard let render = ticket.request.renderKey,
              let expectedKey = DurableThumbnailKey(renderKey: render, sourceSHA256: ticket.sourceSHA256,
                                                    encoderVersion: Self.encoderVersion),
              expectedKey == ticket.key,
              image.image.width > 0, image.image.height > 0,
              image.image.bitsPerComponent == 8,
              image.image.width <= ticket.request.maximumPixelSize,
              image.image.height <= ticket.request.maximumPixelSize,
              image.sourcePixelSize.width > 0, image.sourcePixelSize.height > 0,
              image.sourcePixelSize.width.isFinite, image.sourcePixelSize.height.isFinite,
              image.sourcePixelSize.width <= Double(Int32.max),
              image.sourcePixelSize.height <= Double(Int32.max) else { return false }
        guard image.itemID == render.itemID, image.revision == render.revision else {
            throw ImageLoadError(.sourceChanged, itemID: render.itemID, revision: image.revision)
        }
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image.image, nil) // No original EXIF/GPS metadata.
        guard CGImageDestinationFinalize(destination) else { return false }
        guard let payload = Self.removingPNGMetadata(from: bytes as Data),
              payload.count > 0, payload.count <= Self.maximumPayloadBytes else { return false }
        // Re-read after decode and encoding. Metadata alone cannot prove same-inode writes.
        guard try sourceMatches(ticket, render: render) else {
            throw ImageLoadError(.sourceChanged, itemID: render.itemID, revision: render.revision)
        }
        try Task.checkCancellation()
        guard ticket.generation == CacheIndexLocks.shared.generation(for: directory) else { return false }
        guard writeRetrySkipsRemaining == 0 else {
            skippedWriteCount += 1
            writeRetrySkipsRemaining -= 1
            return false
        }
        var didWrite = false
        do {
        try withIndexLock {
        guard ticket.generation == CacheIndexLocks.shared.generation(for: directory) else { return }
        try requireSafeDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = ticket.key.filename + ".png"
        guard let url = payloadURL(forKey: ticket.key.filename) else { return }
        guard PayloadLeaseRegistry.shared.acquireWrite(url.path) else { return }
        defer { PayloadLeaseRegistry.shared.releaseWrite(url.path) }
        // An interrupted rewrite must not destroy a previously indexed render.
        let previousPayload: Data?
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue,
           size > 0, size <= Self.maximumPayloadBytes {
            previousPayload = try? Data(contentsOf: url)
        } else { previousPayload = nil }
        defer {
            if !didWrite, ticket.request.accessPermit?.isCurrent == false {
                if let previousPayload { try? previousPayload.write(to: url, options: .atomic) }
                else { try? FileManager.default.removeItem(at: url) }
            }
        }
        let temporary = directory.appendingPathComponent(".tmp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try payload.write(to: temporary)
        try AccessWorkPermit.admitting(ticket.request.accessPermit) {
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
        }
        try afterPayloadWrite?()
        do { try ticket.request.accessPermit?.check() }
        catch {
            if previousPayload == nil { try? FileManager.default.removeItem(at: url) }
            throw error
        }
        // Catch a source mutation during payload publication before indexing the bytes.
        let unchanged: Bool
        do { unchanged = try sourceMatches(ticket, render: render) }
        catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        guard unchanged else {
            try? FileManager.default.removeItem(at: url)
            throw ImageLoadError(.sourceChanged, itemID: render.itemID, revision: render.revision)
        }
        try Task.checkCancellation()
        try AccessWorkPermit.admitting(ticket.request.accessPermit) {
            try withIndexLock {
                try repairCorruptIndexIfNeeded()
                try writeRow(ticket, payloadPath: path, payloadBytes: payload.count,
                             payloadSHA256: digest(payload), sourceWidth: Int(image.sourcePixelSize.width),
                             sourceHeight: Int(image.sourcePixelSize.height))
                didWrite = true
            }
        }
        }
        if didWrite { lastWriteFailure = nil }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ImageLoadError where error.kind == .sourceChanged {
            throw error
        } catch where AccessReadFailure.isPermissionDenied(error) {
            throw error
        } catch let error as ThumbnailStoreError where !error.isPersistentWriteFailure {
            logger.error("Thumbnail cache store failed; retry remains available: \(Self.publicErrorCode(error), privacy: .public)")
            throw error
        } catch {
            writeFailureCount += 1
            writeRetrySkipsRemaining = 1
            lastWriteFailure = String(describing: error)
            logger.error("Thumbnail cache write failed; retry after one skipped attempt: \(Self.publicErrorCode(error), privacy: .public)")
        }
        return didWrite && ticket.generation == CacheIndexLocks.shared.generation(for: directory)
    }

    private func sourceMatches(_ ticket: ThumbnailCacheTicket, render: RenderKey) throws -> Bool {
        do {
            return try fingerprint(ticket.request.fileURL, expected: render.revision) == ticket.sourceSHA256
        } catch is CancellationError {
            throw CancellationError()
        } catch where AccessReadFailure.isPermissionDenied(error) {
            throw error
        } catch {
            throw ImageLoadError(.sourceChanged, itemID: render.itemID, revision: render.revision)
        }
    }

    private func boundedPayload(at url: URL, expectedByteCount: Int) throws -> Data? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = (attributes[.size] as? NSNumber)?.intValue,
                  size == expectedByteCount, size > 0, size <= Self.maximumPayloadBytes else { return nil }
            let data = try Data(contentsOf: url)
            return data.count == expectedByteCount ? data : nil
        } catch where AccessReadFailure.isPermissionDenied(error) { throw error }
        catch { return nil }
    }

    private func fingerprint(_ url: URL, expected: FileRevision) throws -> String? {
        try Task.checkCancellation()
        let before = try FileRevisionReader.read(url)
        guard before == expected, before.byteCount >= 0,
              before.byteCount <= Self.maximumSourceBytes else { return nil }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var sha = SHA256()
        var count = 0
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            try Task.checkCancellation()
            count += chunk.count
            guard count <= Self.maximumSourceBytes else { return nil }
            sha.update(data: chunk)
        }
        try Task.checkCancellation()
        let after = try FileRevisionReader.read(url)
        guard count == before.byteCount, after == before else { return nil }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func removingPNGMetadata(from data: Data) -> Data? {
        let signature = Data([137, 80, 78, 71, 13, 10, 26, 10])
        guard data.starts(with: signature) else { return nil }
        let metadataChunks: Set<String> = ["eXIf", "tEXt", "zTXt", "iTXt"]
        var result = signature, offset = 8
        while offset + 12 <= data.count {
            let length = data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let end = offset + 12 + Int(length)
            guard end <= data.count else { return nil }
            let type = String(decoding: data[(offset + 4)..<(offset + 8)], as: UTF8.self)
            if !metadataChunks.contains(type) { result.append(data[offset..<end]) }
            offset = end
        }
        return offset == data.count ? result : nil
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func rowChecksum(key: String, item: String, source: String, path: String,
                             byteCount: Int, payloadSHA256: String, width: Int, height: Int) -> String {
        let fields = ["row1", key, item, source, path, String(byteCount), payloadSHA256,
                      String(Self.cacheVersion), String(width), String(height)]
        return digest(Data(fields.joined(separator: "|").utf8))
    }

    private struct Row {
        let payloadPath: String
        let byteCount: Int
        let payloadSHA256: String
        let sourceWidth: Int
        let sourceHeight: Int
    }
    private var databaseURL: URL { directory.appendingPathComponent("index.sqlite3") }
    private func withIndexLock<T>(_ body: () throws -> T) rethrows -> T {
        try CacheIndexLocks.shared.withLock(for: directory, body)
    }
    private func payloadURL(forKey key: String) -> URL? {
        let bytes = key.utf8
        guard bytes.count == 64,
              bytes.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        let root = directory.standardizedFileURL
        let payload = root.appendingPathComponent(key + ".png").standardizedFileURL
        guard payload.deletingLastPathComponent() == root else { return nil }
        return payload
    }

    private func deleteIndexRow(_ key: String, using db: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM thumbnails WHERE key=?", -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        bind(key, to: statement, at: 1)
        return sqlite3_step(statement) == SQLITE_DONE
    }
    private func repairCorruptIndexIfNeeded() throws {
        let index = databaseURL.path
        guard FileManager.default.fileExists(atPath: index),
              (try? FileManager.default.attributesOfItem(atPath: index)[.type] as? FileAttributeType) == .typeRegular else { return }
        let decision = try { () throws -> IntegrityDecision in
            var db: OpaquePointer?
            let opened = sqlite3_open_v2(index, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
            defer { if let db { sqlite3_close(db) } }
            guard opened == SQLITE_OK else { throw ThumbnailStoreError.database(opened) }
            var statement: OpaquePointer?
            let prepared = sqlite3_prepare_v2(db, "PRAGMA quick_check", -1, &statement, nil)
            defer { sqlite3_finalize(statement) }
            let result = prepared == SQLITE_OK ? sqlite3_step(statement) : nil
            var diagnostic: String?
            if result == SQLITE_ROW, let status = sqlite3_column_text(statement, 0) {
                diagnostic = String(cString: status)
            }
            let decision = Self.integrityDecision(prepareCode: prepared, firstStepCode: result, diagnostic: diagnostic)
            guard decision != .unconfirmedFailure else {
                throw ThumbnailStoreError.database(prepared == SQLITE_OK ? result! : prepared)
            }
            return decision
        }()
        guard decision == .confirmedCorrupt else { return }
        try FileManager.default.removeItem(atPath: index)
        didSweepOrphans = false
    }
    private static func isCorruptSQLite(_ code: Int32) -> Bool {
        let primary = code & 0xff
        return primary == SQLITE_CORRUPT || primary == SQLITE_NOTADB
    }
    private func removeDamagedEntry(_ ticket: ThumbnailCacheTicket) {
        withIndexLock { removeDamagedEntryLocked(ticket) }
    }
    private func removeDamagedEntryLocked(_ ticket: ThumbnailCacheTicket) {
        // The path comes from the key, never from a possibly damaged SQLite row.
        guard let path = payloadURL(forKey: ticket.key.filename)?.path else { return }
        guard PayloadLeaseRegistry.shared.beginDeletion(path) else { return }
        defer { PayloadLeaseRegistry.shared.endDeletion(path) }
        var writable: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &writable,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db = writable else {
            if let writable { sqlite3_close(writable) }
            return
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM thumbnails WHERE key=?", -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bind(ticket.key.filename, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_DONE else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    private func referencedPayloads() -> Set<String>? {
        guard let db = openDatabase(create: false) else { return nil }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM thumbnails", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        var referenced = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let path = sqlite3_column_text(statement, 0) { referenced.insert(String(cString: path)) }
        }
        return referenced
    }
    private func sweepOrphansIfNeeded() async {
        guard !didSweepOrphans, let referenced = withIndexLock({ referencedPayloads() }) else { return }
        await afterOrphanSnapshot?()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        var deferred = false
        for name in names where name.hasPrefix(".tmp-") {
            let temporary = directory.appendingPathComponent(name)
            guard let modified = (try? FileManager.default.attributesOfItem(atPath: temporary.path)[.modificationDate] as? Date),
                  modified < Self.tempSweepCutoff else { continue }
            if !withIndexLock({ removeStaleTemp(temporary) }) { deferred = true }
        }
        for name in names where name.hasSuffix(".png") && name.count == 68 && !referenced.contains(name) {
            guard let payload = payloadURL(forKey: String(name.dropLast(4))) else { continue }
            if !withIndexLock({ removeOrphanIfUnindexed(payload) }) { deferred = true }
        }
        didSweepOrphans = !deferred
    }
    private func removeStaleTemp(_ temporary: URL) -> Bool {
        guard PayloadLeaseRegistry.shared.beginDeletion(temporary.path) else { return false }
        defer { PayloadLeaseRegistry.shared.endDeletion(temporary.path) }
        try? FileManager.default.removeItem(at: temporary)
        return !FileManager.default.fileExists(atPath: temporary.path)
    }
    private func removeOrphanIfUnindexed(_ payload: URL) -> Bool {
        guard PayloadLeaseRegistry.shared.beginDeletion(payload.path) else { return false }
        defer { PayloadLeaseRegistry.shared.endDeletion(payload.path) }
        guard let db = openDatabase(create: false) else { return false }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM thumbnails WHERE payload=? LIMIT 1", -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        bind(payload.lastPathComponent, to: statement, at: 1)
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW { return true }
        guard result == SQLITE_DONE else { return false }
        do { try FileManager.default.removeItem(at: payload) }
        catch { return false }
        return true
    }

    private func touch(_ key: String) {
        withIndexLock { touchLocked(key) }
    }
    private func touchLocked(_ key: String) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            return
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        let sql = "UPDATE thumbnails SET last_access=(SELECT MAX(last_access)+1 FROM thumbnails) WHERE key=?"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bind(key, to: statement, at: 1)
        _ = sqlite3_step(statement)
    }

    private func evictIfNeeded(using db: OpaquePointer) {
        guard highWaterBytes > 0, lowWaterBytes >= 0, lowWaterBytes <= highWaterBytes else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db,
            "SELECT key,payload,byte_count FROM thumbnails ORDER BY last_access ASC,key ASC",
            -1, &statement, nil) == SQLITE_OK else { return }
        var rows: [(key: String, path: String, bytes: Int64)] = []
        var total: Int64 = 0
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let key = sqlite3_column_text(statement, 0),
                  let path = sqlite3_column_text(statement, 1) else { continue }
            let bytes = max(0, sqlite3_column_int64(statement, 2))
            let (sum, overflow) = total.addingReportingOverflow(bytes)
            total = overflow ? Int64.max : sum
            rows.append((String(cString: key), String(cString: path), bytes))
        }
        sqlite3_finalize(statement)
        guard total > highWaterBytes else { return }
        for row in rows where total > lowWaterBytes {
            guard let payload = payloadURL(forKey: row.key), row.path == payload.lastPathComponent else {
                // An index row cannot authorize deletion of a filesystem path.
                if deleteIndexRow(row.key, using: db) { total -= row.bytes }
                continue
            }
            guard PayloadLeaseRegistry.shared.beginDeletion(payload.path) else { continue }
            defer { PayloadLeaseRegistry.shared.endDeletion(payload.path) }
            do { try FileManager.default.removeItem(at: payload) }
            catch {
                guard Self.isMissingRemovalError(error as NSError) else { continue }
            }
            total -= row.bytes
            _ = deleteIndexRow(row.key, using: db)
        }
    }
    private func openDatabase(create: Bool) -> OpaquePointer? {
        if !create && !FileManager.default.fileExists(atPath: databaseURL.path) { return nil }
        var db: OpaquePointer?
        let flags = (create ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE : SQLITE_OPEN_READONLY) | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &db, flags, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            return nil
        }
        return db
    }
    private func bind(_ value: String, to statement: OpaquePointer?, at index: Int32) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        value.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
    }
    private func readRow(_ ticket: ThumbnailCacheTicket) -> Row? {
        withIndexLock { readRowLocked(ticket) }
    }
    private func readRowLocked(_ ticket: ThumbnailCacheTicket) -> Row? {
        guard let db = openDatabase(create: false) else { return nil }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        let sql = "SELECT payload, byte_count, payload_sha256, source_width, source_height, item_id, source_sha256, row_sha256 FROM thumbnails WHERE key=? AND cache_version=2"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(ticket.key.filename, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let path = sqlite3_column_text(statement, 0),
              let sha = sqlite3_column_text(statement, 2),
              let item = sqlite3_column_text(statement, 5),
              let source = sqlite3_column_text(statement, 6),
              let rowSHA = sqlite3_column_text(statement, 7),
              String(cString: item) == ticket.request.renderKey?.itemID.stableEncoding,
              String(cString: source) == ticket.sourceSHA256 else { return nil }
        let width = Int(sqlite3_column_int(statement, 3)), height = Int(sqlite3_column_int(statement, 4))
        let byteCount = Int(sqlite3_column_int(statement, 1))
        guard width > 0, height > 0,
              String(cString: rowSHA) == rowChecksum(key: ticket.key.filename, item: String(cString: item),
                source: String(cString: source), path: String(cString: path), byteCount: byteCount,
                payloadSHA256: String(cString: sha), width: width, height: height) else { return nil }
        return Row(payloadPath: String(cString: path), byteCount: byteCount,
                   payloadSHA256: String(cString: sha), sourceWidth: width, sourceHeight: height)
    }
    private func writeRow(_ ticket: ThumbnailCacheTicket, payloadPath: String, payloadBytes: Int,
                          payloadSHA256: String, sourceWidth: Int, sourceHeight: Int) throws {
        guard let db = openDatabase(create: true) else { throw ThumbnailStoreError.database(SQLITE_CANTOPEN) }
        defer { sqlite3_close(db) }
        let schema = "CREATE TABLE IF NOT EXISTS thumbnails (key TEXT PRIMARY KEY, item_id TEXT NOT NULL, source_sha256 TEXT NOT NULL, payload TEXT NOT NULL, byte_count INTEGER NOT NULL, payload_sha256 TEXT NOT NULL, last_access REAL NOT NULL, cache_version INTEGER NOT NULL, source_width INTEGER NOT NULL, source_height INTEGER NOT NULL, row_sha256 TEXT)"
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else { throw ThumbnailStoreError.database(sqlite3_errcode(db)) }
        // Older re-creatable indexes lack this column. Their version-1 rows remain misses.
        _ = sqlite3_exec(db, "ALTER TABLE thumbnails ADD COLUMN row_sha256 TEXT", nil, nil, nil)
        var statement: OpaquePointer?
        let sql = "INSERT OR REPLACE INTO thumbnails (key,item_id,source_sha256,payload,byte_count,payload_sha256,last_access,cache_version,source_width,source_height,row_sha256) VALUES (?,?,?,?,?, ?, (SELECT COALESCE(MAX(last_access),0)+1 FROM thumbnails), ?,?,?,?)"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw ThumbnailStoreError.database(sqlite3_errcode(db)) }
        defer { sqlite3_finalize(statement) }
        guard let renderKey = ticket.request.renderKey else { throw ThumbnailStoreError.database(SQLITE_MISUSE) }
        bind(ticket.key.filename, to: statement, at: 1)
        bind(renderKey.itemID.stableEncoding, to: statement, at: 2)
        bind(ticket.sourceSHA256, to: statement, at: 3)
        bind(payloadPath, to: statement, at: 4)
        sqlite3_bind_int(statement, 5, Int32(payloadBytes))
        bind(payloadSHA256, to: statement, at: 6)
        sqlite3_bind_int(statement, 7, Int32(Self.cacheVersion))
        sqlite3_bind_int(statement, 8, Int32(sourceWidth))
        sqlite3_bind_int(statement, 9, Int32(sourceHeight))
        bind(rowChecksum(key: ticket.key.filename, item: renderKey.itemID.stableEncoding,
            source: ticket.sourceSHA256, path: payloadPath, byteCount: payloadBytes,
            payloadSHA256: payloadSHA256, width: sourceWidth, height: sourceHeight), to: statement, at: 10)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw ThumbnailStoreError.database(sqlite3_errcode(db)) }
        sqlite3_finalize(statement)
        statement = nil
        evictIfNeeded(using: db)
    }
}

private enum ThumbnailStoreError: Error {
    case database(Int32)

    var isPersistentWriteFailure: Bool {
        guard case .database(let code) = self else { return false }
        let primary = code & 0xff
        return primary == SQLITE_FULL || primary == SQLITE_IOERR || primary == SQLITE_READONLY
    }
}
private enum CachePathError: Error { case symbolicLinkDirectory }

/// Every app-owned SQLite connection for one cache directory uses this lock.
private final class CacheIndexLocks: @unchecked Sendable {
    static let shared = CacheIndexLocks()
    private let mapLock = NSLock()
    private var locks: [String: NSRecursiveLock] = [:]
    private var generations: [String: UInt64] = [:]

    func generation(for directory: URL) -> UInt64 {
        mapLock.lock()
        defer { mapLock.unlock() }
        return generations[directory.standardizedFileURL.path, default: 0]
    }

    func advanceGeneration(for directory: URL) {
        mapLock.lock()
        defer { mapLock.unlock() }
        generations[directory.standardizedFileURL.path, default: 0] &+= 1
    }

    func withLock<T>(for directory: URL, _ body: () throws -> T) rethrows -> T {
        let key = directory.standardizedFileURL.path
        mapLock.lock()
        let lock: NSRecursiveLock
        if let existing = locks[key] { lock = existing }
        else {
            lock = NSRecursiveLock()
            locks[key] = lock
        }
        mapLock.unlock()
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// Coordinates actors in this process that use the same cache directory.
private final class PayloadLeaseRegistry: @unchecked Sendable {
    static let shared = PayloadLeaseRegistry()
    private let lock = NSLock()
    // Positive values count readers; -1 is the sole writer.
    private var claims: [String: Int] = [:]
    private var deleting = Set<String>()
    private var pendingDeletion = Set<String>()
    private var failedDeletions: [String: String] = [:]
    private var drainWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private let logger = Logger(subsystem: "io.github.anzchy.picsee", category: "thumbnail-cache")

    func acquire(_ path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let key = URL(fileURLWithPath: path).standardizedFileURL.path
        guard !deleting.contains(key), claims[key, default: 0] >= 0 else { return false }
        claims[key, default: 0] += 1
        return true
    }

    func release(_ path: String) {
        lock.lock()
        defer { lock.unlock() }
        let key = URL(fileURLWithPath: path).standardizedFileURL.path
        // Every release follows a successful acquire; fail fast on an unbalanced lease.
        let count = claims[key]!
        precondition(count > 0)
        if count == 1 {
            claims.removeValue(forKey: key)
            finishPendingDeletion(key)
        }
        else { claims[key] = count - 1 }
    }

    func acquireWrite(_ path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let key = URL(fileURLWithPath: path).standardizedFileURL.path
        guard claims[key] == nil, !deleting.contains(key) else { return false }
        claims[key] = -1
        return true
    }

    func releaseWrite(_ path: String) {
        lock.lock()
        defer { lock.unlock() }
        let key = URL(fileURLWithPath: path).standardizedFileURL.path
        precondition(claims[key] == -1)
        claims.removeValue(forKey: key)
        finishPendingDeletion(key)
    }

    func removeWhenUnleased(_ path: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let key = URL(fileURLWithPath: path).standardizedFileURL.path
        guard claims[key] == nil else {
            pendingDeletion.insert(key)
            return
        }
        guard !deleting.contains(key) else { return }
        deleting.insert(key)
        defer { deleting.remove(key) }
        try FileManager.default.removeItem(atPath: key)
        failedDeletions.removeValue(forKey: key)
    }

    private func finishPendingDeletion(_ key: String) {
        guard pendingDeletion.remove(key) != nil else { return }
        deleting.insert(key)
        defer { deleting.remove(key) }
        do {
            try FileManager.default.removeItem(atPath: key)
            failedDeletions.removeValue(forKey: key)
        } catch {
            failedDeletions[key] = String(describing: error)
            logger.error("Deferred thumbnail cache deletion failed: \(ThumbnailDiskCache.publicErrorCode(error), privacy: .public)")
        }
        resumeDrainedWaiters()
    }

    func deferredClearFailure(in directory: URL) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let prefix = directory.standardizedFileURL.path + "/"
        for (path, message) in failedDeletions where path.hasPrefix(prefix) { return message }
        return nil
    }

    func waitForPendingDeletions(in directory: URL, onRegistered: (@Sendable () -> Void)? = nil) async {
        let prefix = directory.standardizedFileURL.path + "/"
        await withCheckedContinuation { continuation in
            lock.lock()
            if pendingDeletion.contains(where: { $0.hasPrefix(prefix) }) {
                drainWaiters[prefix, default: []].append(continuation)
                onRegistered?()
            } else {
                continuation.resume()
            }
            lock.unlock()
        }
    }

    private func resumeDrainedWaiters() {
        for prefix in Array(drainWaiters.keys) where !pendingDeletion.contains(where: { $0.hasPrefix(prefix) }) {
            let ready = drainWaiters.removeValue(forKey: prefix)!
            for continuation in ready { continuation.resume() }
        }
    }

    func beginDeletion(_ path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let key = URL(fileURLWithPath: path).standardizedFileURL.path
        guard claims[key] == nil, !deleting.contains(key) else { return false }
        deleting.insert(key)
        return true
    }

    func endDeletion(_ path: String) {
        lock.lock()
        defer { lock.unlock() }
        deleting.remove(URL(fileURLWithPath: path).standardizedFileURL.path)
    }
}
