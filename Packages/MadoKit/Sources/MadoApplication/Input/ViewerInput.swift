import Foundation
import UniformTypeIdentifiers
import Darwin

/// File links name their image targets; ordinary URLs keep their delivered spelling.
public enum ViewerInput: Equatable, Sendable {
    case single(URL), files([URL]), folder(URL), rejected([URL])

    public static func classification(_ urls: [URL]) -> (input: ViewerInput, excludedCount: Int) {
        var seen = Set<String>()
        var unique: [URL] = [], images: [URL] = [], folders: [URL] = []
        var excluded = 0
        for url in urls {
            guard url.isFileURL else { continue }
            let imageURL = url.hasDirectoryPath ? url : resolvedFileLink(url)
            let key = (imageURL ?? url).standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL.path
            guard seen.insert(key).inserted else { continue }
            unique.append(url)
            if url.hasDirectoryPath { folders.append(url) }
            else if let imageURL, isImage(imageURL) { images.append(imageURL) }
            else { excluded += 1 }
        }
        images.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let input: ViewerInput
        if images.count == 1 { input = .single(images[0]) }
        else if images.count > 1 { input = .files(images) }
        else { input = folders.count == 1 ? .folder(folders[0]) : .rejected(unique) }
        return (input, excluded)
    }

    public static func classify(_ urls: [URL]) -> ViewerInput {
        classification(urls).input
    }
    public static func excludedCount(in urls: [URL]) -> Int {
        classification(urls).excludedCount
    }
    private static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }

    /// Read each link's own destination so a missing target and an ELOOP are rejected,
    /// while a target hidden by sandbox permissions can still reach File Grant recovery.
    private static func resolvedFileLink(_ delivered: URL) -> URL? {
        var path = delivered.standardizedFileURL.path
        var visited = Set<String>()
        var followedLink = false
        for _ in 0..<40 {
            var metadata = stat()
            let result = path.withCString { lstat($0, &metadata) }
            if result != 0 {
                if !followedLink { return delivered } // Preserve ordinary missing-file behavior.
                if errno == EACCES || errno == EPERM { return URL(fileURLWithPath: path).standardizedFileURL }
                return nil
            }
            if metadata.st_mode & mode_t(S_IFMT) != mode_t(S_IFLNK) {
                guard followedLink else { return delivered }
                guard metadata.st_mode & mode_t(S_IFMT) != mode_t(S_IFDIR) else { return nil }
                return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
            }
            guard visited.insert(path).inserted,
                  let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { return nil }
            followedLink = true
            if destination.hasPrefix("/") { path = URL(fileURLWithPath: destination).standardizedFileURL.path }
            else {
                path = URL(fileURLWithPath: path).deletingLastPathComponent()
                    .appendingPathComponent(destination).standardizedFileURL.path
            }
        }
        return nil
    }
}
