import Foundation
import MadoApplication
import MadoCore
import UniformTypeIdentifiers

public struct SystemSidebarFolderEnumerator: SidebarFolderEnumerating {
    public init() {}
    public func children(in folder: URL, root: URL) async throws -> [URL] {
        try contents(in: folder, root: root).filter { url in
            let target = url.resolvingSymlinksInPath().standardizedFileURL
            guard AccessBoundary.contains(target, in: root) else { return false }
            let values = try? target.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            return values?.isDirectory == true && values?.isPackage != true
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
    public func imageCount(in folder: URL, root: URL) async throws -> Int {
        var count = 0
        for url in try contents(in: folder, root: root) {
            try Task.checkCancellation()
            let target = url.resolvingSymlinksInPath().standardizedFileURL
            guard AccessBoundary.contains(target, in: root) else { continue }
            let values = try? target.resourceValues(forKeys: [.isRegularFileKey, .contentTypeKey])
            if values?.isRegularFile == true, values?.contentType?.conforms(to: .image) == true { count += 1 }
        }
        return count
    }
    private func contents(in folder: URL, root: URL) throws -> [URL] {
        try Task.checkCancellation()
        guard AccessBoundary.contains(folder, in: root) else { throw FileAccessError.outsideRoot }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
    }
}
