import Dispatch
import Foundation
import MadoCore

public struct AccessProbeLatencies: Codable, Equatable, Sendable {
    public let volumePropertiesMilliseconds: Double
    public let mountedVolumeScanMilliseconds: Double
    public let resolutionMilliseconds: Double
    public let scopeStartMilliseconds: Double?
    public let listingMilliseconds: Double?

    public init(
        volumePropertiesMilliseconds: Double,
        mountedVolumeScanMilliseconds: Double,
        resolutionMilliseconds: Double,
        scopeStartMilliseconds: Double?,
        listingMilliseconds: Double?
    ) {
        self.volumePropertiesMilliseconds = volumePropertiesMilliseconds
        self.mountedVolumeScanMilliseconds = mountedVolumeScanMilliseconds
        self.resolutionMilliseconds = resolutionMilliseconds
        self.scopeStartMilliseconds = scopeStartMilliseconds
        self.listingMilliseconds = listingMilliseconds
    }
}

public struct AccessProbeTrashCheckInputs: Codable, Equatable, Sendable {
    public let resolvedPath: String
    public let standardizedPath: String
    public let userTrashPath: String?
    public let volumePath: String?
    public let perUserVolumeTrashPath: String?

    public init(
        resolvedPath: String,
        standardizedPath: String,
        userTrashPath: String?,
        volumePath: String?,
        perUserVolumeTrashPath: String?
    ) {
        self.resolvedPath = resolvedPath
        self.standardizedPath = standardizedPath
        self.userTrashPath = userTrashPath
        self.volumePath = volumePath
        self.perUserVolumeTrashPath = perUserVolumeTrashPath
    }
}

public struct AccessProbeReport: Codable, Equatable, Sendable {
    public let volume: AccessProbeVolume
    public let volumePropertiesError: AccessProbeError?
    public let mountedVolumes: [AccessProbeVolume]
    public let resolution: AccessProbeResolution
    public let resolvedPath: String?
    public let trashCheckInputs: AccessProbeTrashCheckInputs?
    public let scopeStarted: Bool?
    public let listing: AccessProbeDirectoryListing?
    public let isInTrash: Bool
    public let latencyMilliseconds: Double
    public let latencies: AccessProbeLatencies
    public let classification: AccessProbeClassification

    public init(
        volume: AccessProbeVolume,
        volumePropertiesError: AccessProbeError?,
        mountedVolumes: [AccessProbeVolume],
        resolution: AccessProbeResolution,
        resolvedPath: String?,
        trashCheckInputs: AccessProbeTrashCheckInputs?,
        scopeStarted: Bool?,
        listing: AccessProbeDirectoryListing?,
        isInTrash: Bool,
        latencyMilliseconds: Double,
        latencies: AccessProbeLatencies,
        classification: AccessProbeClassification
    ) {
        self.volume = volume
        self.volumePropertiesError = volumePropertiesError
        self.mountedVolumes = mountedVolumes
        self.resolution = resolution
        self.resolvedPath = resolvedPath
        self.trashCheckInputs = trashCheckInputs
        self.scopeStarted = scopeStarted
        self.listing = listing
        self.isInTrash = isInTrash
        self.latencyMilliseconds = latencyMilliseconds
        self.latencies = latencies
        self.classification = classification
    }
}

public protocol AccessProbeBookmarkCoding: Sendable {
    func makeBookmark(for url: URL, includingResourceValuesForKeys keys: Set<URLResourceKey>?) throws -> Data
    func volumeProperties(in data: Data) throws -> AccessProbeVolume
    func resolve(_ data: Data, options: URL.BookmarkResolutionOptions) throws -> AccessProbeResolution
}

public struct AccessProbeFactGatherer: Sendable {
    private static let volumeKeys: [URLResourceKey] = [.volumeUUIDStringKey, .volumeURLKey, .volumeNameKey]
    private let bookmarks: any AccessProbeBookmarkCoding
    private let scope: any SecurityScope
    private let mountedVolumesProvider: @Sendable () -> [AccessProbeVolume]
    private let lister: @Sendable (URL) throws -> Int
    private let trashCheck: @Sendable (URL) -> Bool

    /// Reads the bookmark's saved volume identity without resolving or mounting it.
    public static func bookmarkVolume(in data: Data) -> AccessProbeVolume {
        (try? SystemAccessProbeBookmarkCoding().volumeProperties(in: data)) ??
            AccessProbeVolume(uuid: nil, url: nil, name: nil)
    }

    public static func bookmarkIdentity(in data: Data) -> FileResourceIdentity? {
        let keys: Set<URLResourceKey> = [.volumeUUIDStringKey, .fileResourceIdentifierKey]
        guard let values = URL.resourceValues(forKeys: keys, fromBookmarkData: data),
              let uuid = values.volumeUUIDString,
              let identifier = values.fileResourceIdentifier as? Data else { return nil }
        return FileResourceIdentity(volumeUUID: uuid, fileIdentifier: identifier.base64EncodedString())
    }

    public init() {
        bookmarks = SystemAccessProbeBookmarkCoding()
        scope = SystemSecurityScope()
        mountedVolumesProvider = {
            Self.mountedVolumes(at: FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: Self.volumeKeys,
                options: []
            ))
        }
        lister = { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil).count }
        trashCheck = { FileAccess.isTrashed($0) }
    }

    init(
        bookmarks: any AccessProbeBookmarkCoding,
        scope: any SecurityScope,
        mountedVolumes: @escaping @Sendable () -> [AccessProbeVolume],
        lister: @escaping @Sendable (URL) throws -> Int,
        isInTrash: @escaping @Sendable (URL) -> Bool
    ) {
        self.bookmarks = bookmarks
        self.scope = scope
        mountedVolumesProvider = mountedVolumes
        self.lister = lister
        trashCheck = isInTrash
    }

    public func makeBookmark(for url: URL, storingVolumeProperties: Bool) throws -> Data {
        try bookmarks.makeBookmark(
            for: url,
            includingResourceValuesForKeys: storingVolumeProperties ? Set(Self.volumeKeys) : nil
        )
    }

    public func gather(bookmarkData: Data) -> AccessProbeReport {
        func milliseconds(since started: UInt64) -> Double {
            Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        }

        let startedAt = DispatchTime.now().uptimeNanoseconds
        let volumeStartedAt = DispatchTime.now().uptimeNanoseconds
        let volume: AccessProbeVolume
        let volumePropertiesError: AccessProbeError?
        do {
            volume = try bookmarks.volumeProperties(in: bookmarkData)
            volumePropertiesError = nil
        } catch {
            volume = AccessProbeVolume(uuid: nil, url: nil, name: nil)
            volumePropertiesError = AccessProbeError(error)
        }
        let volumePropertiesMilliseconds = milliseconds(since: volumeStartedAt)

        let mountedVolumeScanStartedAt = DispatchTime.now().uptimeNanoseconds
        let mountedVolumes = mountedVolumesProvider()
        let mountedVolumeScanMilliseconds = milliseconds(since: mountedVolumeScanStartedAt)

        let resolutionStartedAt = DispatchTime.now().uptimeNanoseconds
        let resolution: AccessProbeResolution
        let resolutionMilliseconds: Double
        var scopeStarted: Bool?
        var scopeStartMilliseconds: Double?
        var listing: AccessProbeDirectoryListing?
        var listingMilliseconds: Double?
        var isInTrash = false
        var resolvedPath: String?
        var trashCheckInputs: AccessProbeTrashCheckInputs?
        do {
            let resolved = try bookmarks.resolve(
                bookmarkData,
                options: [.withSecurityScope, .withoutMounting, .withoutUI]
            )
            resolution = resolved
            resolutionMilliseconds = milliseconds(since: resolutionStartedAt)
            if let url = resolved.url {
                resolvedPath = url.path
                trashCheckInputs = Self.trashCheckInputs(for: url)
                isInTrash = trashCheck(url)
                let scopeStartStartedAt = DispatchTime.now().uptimeNanoseconds
                let started = scope.start(url)
                scopeStartMilliseconds = milliseconds(since: scopeStartStartedAt)
                scopeStarted = started
                do {
                    defer { if started { scope.stop(url) } }
                    let listingStartedAt = DispatchTime.now().uptimeNanoseconds
                    do {
                        listing = .succeeded(entryCount: try lister(url))
                    } catch {
                        listing = .failed(AccessProbeError(error))
                    }
                    listingMilliseconds = milliseconds(since: listingStartedAt)
                }
            }
        } catch {
            resolution = .failed(AccessProbeError(error))
            resolutionMilliseconds = milliseconds(since: resolutionStartedAt)
        }

        let facts = AccessProbeFacts(
            volume: volume,
            mountedVolumes: mountedVolumes,
            resolution: resolution,
            scopeStarted: scopeStarted,
            listing: listing,
            isInTrash: isInTrash
        )
        return AccessProbeReport(
            volume: volume,
            volumePropertiesError: volumePropertiesError,
            mountedVolumes: mountedVolumes,
            resolution: resolution,
            resolvedPath: resolvedPath,
            trashCheckInputs: trashCheckInputs,
            scopeStarted: scopeStarted,
            listing: listing,
            isInTrash: isInTrash,
            latencyMilliseconds: milliseconds(since: startedAt),
            latencies: AccessProbeLatencies(
                volumePropertiesMilliseconds: volumePropertiesMilliseconds,
                mountedVolumeScanMilliseconds: mountedVolumeScanMilliseconds,
                resolutionMilliseconds: resolutionMilliseconds,
                scopeStartMilliseconds: scopeStartMilliseconds,
                listingMilliseconds: listingMilliseconds
            ),
            classification: AccessCauseClassifier.classify(facts)
        )
    }

    private static func trashCheckInputs(for url: URL) -> AccessProbeTrashCheckInputs {
        let standardized = url.standardizedFileURL
        let userTrash = try? FileManager.default.url(
            for: .trashDirectory,
            in: .userDomainMask,
            appropriateFor: standardized,
            create: false
        )
        let volume = try? standardized.resourceValues(forKeys: [.volumeURLKey]).volume
        let perUserVolumeTrash = volume.map {
            $0.appendingPathComponent(".Trashes/\(getuid())", isDirectory: true).path
        }
        return AccessProbeTrashCheckInputs(
            resolvedPath: url.path,
            standardizedPath: standardized.path,
            userTrashPath: userTrash?.path,
            volumePath: volume?.path,
            perUserVolumeTrashPath: perUserVolumeTrash
        )
    }

    public static func mountedVolumes(at urls: [URL]?) -> [AccessProbeVolume] {
        (urls ?? []).map { url in
            let values = try? url.resourceValues(forKeys: Set(volumeKeys))
            return AccessProbeVolume(
                uuid: values?.volumeUUIDString,
                url: values?.volume ?? url,
                name: values?.volumeName
            )
        }
    }
}

private struct SystemAccessProbeBookmarkCoding: AccessProbeBookmarkCoding {
    func makeBookmark(for url: URL, includingResourceValuesForKeys keys: Set<URLResourceKey>?) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: keys, relativeTo: nil)
    }

    func volumeProperties(in data: Data) throws -> AccessProbeVolume {
        let keys: Set<URLResourceKey> = [.volumeUUIDStringKey, .volumeURLKey, .volumeNameKey]
        guard let values = URL.resourceValues(forKeys: keys, fromBookmarkData: data) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return AccessProbeVolume(
            uuid: values.volumeUUIDString,
            url: values.volume,
            name: values.volumeName
        )
    }

    func resolve(_ data: Data, options: URL.BookmarkResolutionOptions) throws -> AccessProbeResolution {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: options,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        return .resolved(url, stale: stale)
    }
}

private extension AccessProbeError {
    init(_ error: Error) {
        let nsError = error as NSError
        var underlyingErrors: [AccessProbeError] = []
        var underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        while let error = underlying {
            underlyingErrors.append(AccessProbeError(domain: error.domain, code: error.code))
            underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        self.init(domain: nsError.domain, code: nsError.code, underlyingErrors: underlyingErrors)
    }
}
