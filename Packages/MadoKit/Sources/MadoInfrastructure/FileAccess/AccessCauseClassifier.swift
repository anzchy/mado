import Foundation

public struct AccessProbeVolume: Codable, Equatable, Sendable {
    public let uuid: String?
    public let url: URL?
    public let name: String?

    public init(uuid: String?, url: URL?, name: String?) {
        self.uuid = uuid
        self.url = url
        self.name = name
    }
}

public struct AccessProbeError: Codable, Equatable, Sendable {
    public let domain: String
    public let code: Int
    public let underlyingErrors: [AccessProbeError]

    public init(domain: String, code: Int, underlyingErrors: [AccessProbeError] = []) {
        self.domain = domain
        self.code = code
        self.underlyingErrors = underlyingErrors
    }
}

public struct AccessProbeResolution: Codable, Equatable, Sendable {
    public let url: URL?
    public let stale: Bool?
    public let error: AccessProbeError?

    public static func resolved(_ url: URL, stale: Bool) -> Self {
        Self(url: url, stale: stale, error: nil)
    }

    public static func failed(_ error: AccessProbeError) -> Self {
        Self(url: nil, stale: nil, error: error)
    }

    public static func failed(domain: String, code: Int) -> Self {
        .failed(AccessProbeError(domain: domain, code: code))
    }
}

public struct AccessProbeDirectoryListing: Codable, Equatable, Sendable {
    public let entryCount: Int?
    public let error: AccessProbeError?

    public static func succeeded(entryCount: Int) -> Self {
        Self(entryCount: entryCount, error: nil)
    }

    public static func failed(_ error: AccessProbeError) -> Self {
        Self(entryCount: nil, error: error)
    }
}

public struct AccessProbeFacts: Equatable, Sendable {
    public let volume: AccessProbeVolume
    public let mountedVolumes: [AccessProbeVolume]
    public let resolution: AccessProbeResolution
    public let scopeStarted: Bool?
    public let listing: AccessProbeDirectoryListing?
    public let isInTrash: Bool

    public init(
        volume: AccessProbeVolume,
        mountedVolumes: [AccessProbeVolume],
        resolution: AccessProbeResolution,
        scopeStarted: Bool?,
        listing: AccessProbeDirectoryListing?,
        isInTrash: Bool
    ) {
        self.volume = volume
        self.mountedVolumes = mountedVolumes
        self.resolution = resolution
        self.scopeStarted = scopeStarted
        self.listing = listing
        self.isInTrash = isInTrash
    }
}

public enum AccessProbeCause: String, Codable, Sendable {
    case diskNotConnected, notFound, accessExpired, unknown, readable
}

public struct AccessProbeClassification: Codable, Equatable, Sendable {
    public let cause: AccessProbeCause
    public let isInTrash: Bool

    public init(cause: AccessProbeCause, isInTrash: Bool) {
        self.cause = cause
        self.isInTrash = isInTrash
    }
}

public enum AccessCauseClassifier {
    public static func classify(_ facts: AccessProbeFacts) -> AccessProbeClassification {
        let classification = AccessProbeClassification(cause: cause(for: facts), isInTrash: facts.isInTrash)
        return classification
    }

    private static func cause(for facts: AccessProbeFacts) -> AccessProbeCause {
        if facts.isInTrash { return .notFound }
        if let uuid = facts.volume.uuid,
           !facts.mountedVolumes.contains(where: { $0.uuid == uuid }) {
            return .diskNotConnected
        }
        if facts.resolution.error != nil {
            return facts.volume.uuid == nil ? .unknown : .notFound
        }
        if facts.resolution.url != nil, let error = facts.listing?.error, isPermissionRefusal(error) {
            return .accessExpired
        }
        if facts.resolution.url != nil, facts.listing?.entryCount != nil {
            return .readable
        }
        return .unknown
    }

    private static func isPermissionRefusal(_ error: AccessProbeError) -> Bool {
        if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError {
            return true
        }
        if error.domain == NSPOSIXErrorDomain && (error.code == Int(EPERM) || error.code == Int(EACCES)) {
            return true
        }
        return error.underlyingErrors.contains(where: isPermissionRefusal)
    }
}
