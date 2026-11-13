import Foundation

@MainActor public protocol FileRevealing: AnyObject {
    func reveal(_ urls: [URL])
}

@MainActor public protocol PathCopying: AnyObject {
    func copyPaths(_ urls: [URL])
}

/// Pasteable text uses the original URL paths recorded by the grid, one per line.
public enum ImageFileActionPaths {
    public static func plainText(_ urls: [URL]) -> String { urls.map(\.path).joined(separator: "\n") }
}
