import Foundation
import UniformTypeIdentifiers

/// Keeps original grant URLs while comparing canonical paths for duplicate input.
public enum ViewerInput: Equatable, Sendable {
    case single(URL), files([URL]), folder(URL), rejected([URL])

    public static func classification(_ urls: [URL]) -> (input: ViewerInput, excludedCount: Int) {
        var seen = Set<String>()
        var unique: [URL] = [], images: [URL] = [], folders: [URL] = []
        var excluded = 0
        for url in urls where url.isFileURL {
            guard seen.insert(url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL.path).inserted else { continue }
            unique.append(url)
            if url.hasDirectoryPath { folders.append(url) }
            else if isImage(url) { images.append(url) }
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
}
