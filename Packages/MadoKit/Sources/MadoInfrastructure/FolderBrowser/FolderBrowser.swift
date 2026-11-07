import Foundation
import MadoCore
import UniformTypeIdentifiers

public actor FolderBrowser: FolderScanning {
    private let rootResolvers = RootIdentityResolvers.shared
    // Provisional after WI-0's first-64 probe; later P2 device validation calibrates these.
    public static let firstBatchSize = 64
    public static let batchSize = 256
    private let readValues: @Sendable (URL) throws -> URLResourceValues
    private let resourceReader: any FileIdentityResourceReading
    public init() {
        resourceReader = URLIdentityResourceReader()
        readValues = { url in try url.resourceValues(forKeys: [
            .isRegularFileKey, .isDirectoryKey, .isPackageKey, .contentTypeKey,
            .contentModificationDateKey, .fileSizeKey, .volumeUUIDStringKey, .fileIdentifierKey]) }
    }
    // Test seam for a real traversal with a deterministic metadata failure.
    init(readValues: @escaping @Sendable (URL) throws -> URLResourceValues,
         resourceReader: any FileIdentityResourceReading = URLIdentityResourceReader()) {
        self.readValues = readValues
        self.resourceReader = resourceReader
    }
    public func scan(in folder: URL, root: ItemIdentityRoot, options: FolderScanOptions,
        emit: @Sendable ([FolderEntry]) async throws -> Void) async throws {
        try Task.checkCancellation()
        let canonicalFolder = folder.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        guard AccessBoundary.contains(canonicalFolder, in: root.url) else { throw FileAccessError.outsideRoot }
        let resolver = await rootResolvers.resolver(for: root)
        var batch: [FolderEntry] = []
        var limit = Self.firstBatchSize
        var admittedImages = 0
        var visitedEntries = 0
        var directories: [(url: URL, depth: Int)] = [(canonicalFolder, 0)]
        var seenDirectories: Set<URL> = [canonicalFolder]
        do {
        while let directory = directories.popLast() {
            try Task.checkCancellation()
            guard AccessBoundary.contains(directory.url, in: root.url) else { continue }
            var enumerationError: (any Error)?
            guard let enumerator = FileManager.default.enumerator(at: directory.url, includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, error in enumerationError = error; return false }) else { throw FileAccessError.invalidFolder }
            while let file = enumerator.nextObject() as? URL {
                try Task.checkCancellation()
                if options.recursive && visitedEntries >= options.maxVisitedEntries {
                    if !batch.isEmpty {
                        let pending = batch; batch.removeAll(keepingCapacity: true)
                        try await emit(pending); try Task.checkCancellation()
                    }
                    throw FolderScanLimitError.entryLimit(limit: options.maxVisitedEntries, admittedImages: admittedImages)
                }
                visitedEntries += 1
                // Canonical boundary comes before resource lookup, including aliases and symlinks.
                let target = file.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
                guard AccessBoundary.contains(target, in: root.url) else { continue }
                let values = try readValues(target)
                if options.recursive, values.isDirectory == true, values.isPackage != true {
                    guard !seenDirectories.contains(target) else { continue }
                    let nextDepth = directory.depth + 1
                    if nextDepth > options.maxDepth {
                        if !batch.isEmpty {
                            let pending = batch; batch.removeAll(keepingCapacity: true)
                            try await emit(pending); try Task.checkCancellation()
                        }
                        throw FolderScanLimitError.depthLimit(limit: options.maxDepth, admittedImages: admittedImages)
                    }
                    _ = seenDirectories.insert(target)
                    directories.append((target, nextDepth))
                    continue
                }
                guard values.isRegularFile == true, values.contentType?.conforms(to: .image) == true else { continue }
                // A file can disappear between metadata admission and identity lookup.
                guard let identity = try? await resolver.identity(for: target) else { continue }
                let resource = try? resourceReader.identity(for: target)
                let token = resource.map {
                    ItemID.resource(volumeUUID: $0.volumeUUID, fileIdentifier: $0.fileIdentifier).stableEncoding
                }
                let entry = FolderEntry(url: file, root: root, modificationDate: values.contentModificationDate,
                    fileSize: values.fileSize.map(Int64.init), itemID: identity, resourceIdentifier: token,
                    recoveryIdentifier: URLRecoveryIdentityResourceReader.token(from: values))
                // Keep alias URLs through filtering; FolderSnapshot chooses one navigable URL per identity.
                batch.append(entry)
                admittedImages += 1
                if batch.count == limit {
                    let pending = batch; batch.removeAll(keepingCapacity: true)
                    try await emit(pending)
                    try Task.checkCancellation()
                    limit = Self.batchSize
                }
            }
            try Task.checkCancellation()
            if let enumerationError { throw enumerationError }
        }
        if !batch.isEmpty {
            let pending = batch; batch.removeAll(keepingCapacity: true)
            try await emit(pending); try Task.checkCancellation()
        }
        try Task.checkCancellation()
        await resolver.pruneMissing(in: canonicalFolder, recursive: options.recursive)
        } catch {
            if !(error is CancellationError), !Task.isCancelled, !batch.isEmpty {
                let pending = batch; batch.removeAll(keepingCapacity: true)
                try await emit(pending)
                try Task.checkCancellation()
            }
            throw error
        }
    }
}
