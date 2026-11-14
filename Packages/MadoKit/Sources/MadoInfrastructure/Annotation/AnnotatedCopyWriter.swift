import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import MadoCore
import MadoApplication

/// The file-system steps of one Annotated Copy write, in order; tests inject failures between them.
public enum AnnotatedCopyWriteStep: CaseIterable, Sendable {
    case leaseAcquire, tempCreate, encode, identityCheck, move
}

/// What ⌘S writes: a new file named from the plan, or a save-panel choice that may replace an existing file.
public enum AnnotatedCopyTarget: Equatable, Sendable {
    case create(AnnotatedCopyName)
    case replace(URL, type: UTType)
}

/// Writes an Annotated Copy atomically (ADR-020). A planned copy is encoded into a hidden temporary file in the
/// destination folder and moved into place without overwriting another file; a save-panel choice goes through an
/// item-replacement directory and `replaceItemAt`. Any failure leaves the folder as it was, removes the temporary
/// file, releases the lease and reports a typed reason. No metadata of the original is copied.
public struct AnnotatedCopyWriter: Sendable {
    public typealias StepHook = @Sendable (AnnotatedCopyWriteStep, URL) async throws -> Void
    public static let defaultNameBound = 999
    let leases: any AccessLeasing
    let nameBound: Int
    let stepHook: StepHook?

    public init(leases: any AccessLeasing, nameBound: Int = defaultNameBound, stepHook: StepHook? = nil) {
        self.leases = leases; self.nameBound = nameBound; self.stepHook = stepHook
    }

    /// `request` is the original's access: a planned copy under an Access Root leases the destination file
    /// itself, which the same root covers; a save-panel choice keeps the original's request.
    public func write(_ image: CGImage, folder: URL, target: AnnotatedCopyTarget, source: URL,
                      request: AccessRequest) async throws(AnnotatedCopyError) -> URL {
        do { return try await leased(image, folder: folder, target: target, source: source, request: request) }
        catch { throw Self.map(error) }
    }

    private func leased(_ image: CGImage, folder: URL, target: AnnotatedCopyTarget, source: URL,
                        request: AccessRequest) async throws -> URL {
        try await stepHook?(.leaseAcquire, folder)
        let lease: AccessLease
        do { lease = try await leases.acquire(Self.leaseRequest(request, folder: folder, target: target)) }
        catch { throw AnnotatedCopyError.accessLost }
        do {
            let url = try await held(image, folder: folder, target: target, source: source)
            await leases.release(lease)
            return url
        } catch {
            await leases.release(lease)
            throw error
        }
    }

    private func held(_ image: CGImage, folder: URL, target: AnnotatedCopyTarget, source: URL) async throws -> URL {
        if case .replace(let chosen, _) = target { try Self.checkNotSource(chosen, source: Self.identity(of: source)) }
        let (finalName, type, scratch) = try Self.layout(target, folder: folder)
        let temp = scratch.appendingPathComponent(".\(finalName).mado-tmp-\(UUID().uuidString)")
        do {
            let url = try await place(image, type: type, temp: temp, folder: folder, target: target, source: source)
            Self.discard(scratch, unless: folder)
            return url
        } catch {
            unlink(temp.path)
            Self.discard(scratch, unless: folder)
            throw error
        }
    }

    private func place(_ image: CGImage, type: UTType, temp: URL, folder: URL, target: AnnotatedCopyTarget,
                       source: URL) async throws -> URL {
        try await stepHook?(.tempCreate, temp)
        let descriptor = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard descriptor >= 0 else { throw Self.map(errno: errno) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try await stepHook?(.encode, temp)
        try handle.write(contentsOf: Self.encode(image, as: type))
        try handle.synchronize()
        try handle.close()
        try await stepHook?(.identityCheck, source)
        let current = try Self.identity(of: source)
        if case .replace(let chosen, _) = target { try Self.checkNotSource(chosen, source: current) }
        try await stepHook?(.move, temp)
        return try move(temp, folder: folder, target: target)
    }

    private func move(_ temp: URL, folder: URL, target: AnnotatedCopyTarget) throws -> URL {
        switch target {
        case .create(let planned):
            for number in planned.number...max(planned.number, nameBound) {
                let url = folder.appendingPathComponent(planned.numbered(number).name)
                if renamex_np(temp.path, url.path, UInt32(RENAME_EXCL)) == 0 { return url }
                guard errno == EEXIST else { throw Self.map(errno: errno) }
            }
            throw AnnotatedCopyError.nameExhausted
        case .replace(let chosen, _):
            if renamex_np(temp.path, chosen.path, UInt32(RENAME_EXCL)) == 0 { return chosen }
            guard errno == EEXIST else { throw Self.map(errno: errno) }
            _ = try FileManager.default.replaceItemAt(chosen, withItemAt: temp)
            return chosen
        }
    }

    /// The final name, the encoded type and the folder that holds the temporary file.
    private static func layout(_ target: AnnotatedCopyTarget, folder: URL) throws -> (String, UTType, URL) {
        switch target {
        case .create(let planned):
            return (planned.name, planned.type, folder)
        case .replace(let chosen, let type):
            let scratch = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                      appropriateFor: chosen, create: true)
            return (chosen.lastPathComponent, type, scratch)
        }
    }

    private static func discard(_ scratch: URL, unless folder: URL) {
        if scratch != folder { try? FileManager.default.removeItem(at: scratch) }
    }

    static func leaseRequest(_ request: AccessRequest, folder: URL, target: AnnotatedCopyTarget) -> AccessRequest {
        guard case .root(let id, _) = request, case .create(let planned) = target else { return request }
        return .root(id, file: folder.appendingPathComponent(planned.name))
    }

    static func encode(_ image: CGImage, as type: UTType) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { throw AnnotatedCopyError.encodeFailed }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw AnnotatedCopyError.encodeFailed }
        return data as Data
    }

    private struct FileIdentity: Equatable { let device: dev_t, inode: ino_t }

    /// The original by resource identity, so hard links and case variants of its name count as the original.
    private static func identity(of source: URL) throws -> FileIdentity {
        var info = stat()
        guard stat(source.path, &info) == 0 else { throw errno == ENOENT ? AnnotatedCopyError.sourceMissing : map(errno: errno) }
        return FileIdentity(device: info.st_dev, inode: info.st_ino)
    }

    private static func checkNotSource(_ chosen: URL, source: FileIdentity) throws {
        var info = stat()
        guard stat(chosen.path, &info) == 0 else { return }
        try AnnotatedCopyPlan.validatePanelChoice(FileIdentity(device: info.st_dev, inode: info.st_ino), source: source)
    }

    static func map(errno code: Int32) -> AnnotatedCopyError {
        switch code {
        case EACCES, EPERM, EROFS: .permissionDenied
        case ENOSPC, EDQUOT: .diskFull
        case ENOENT, ENOTDIR: .folderMissing
        default: .writeFailed
        }
    }

    static func map(_ error: any Error) -> AnnotatedCopyError {
        if let typed = error as? AnnotatedCopyError { return typed }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain { return map(errno: Int32(ns.code)) }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError { return map(underlying) }
        return .writeFailed
    }
}

/// The image types ImageIO can encode on this system.
public enum ImageIOWritableTypes {
    public static var all: Set<UTType> {
        Set((CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).compactMap { UTType($0) })
    }
}
