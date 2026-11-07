import Foundation

public struct AccessRootID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public enum AccessBoundary {
    public static func contains(_ file: URL, in root: URL) -> Bool {
        guard file.isFileURL, root.isFileURL else { return false }
        let components = canonical(file).pathComponents
        let boundary = canonical(root).pathComponents
        return components.starts(with: boundary)
    }
    public static func fileGrant(_ grant: URL, covers file: URL) -> Bool {
        grant.isFileURL && file.isFileURL && canonical(grant).pathComponents == canonical(file).pathComponents
    }
    private static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    }
}
