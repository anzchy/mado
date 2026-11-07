import Foundation
import MadoCore
import UniformTypeIdentifiers

/// The caller holds a root lease during enumeration. Never recursively traverses folders.
public actor SiblingLister {
    public init() {}
    public func images(in folder: URL, root: URL) throws -> [URL] {
        guard AccessBoundary.contains(folder, in: root) else { throw FileAccessError.outsideRoot }
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        return try files.filter { file in
            // Check before stat/type lookup, so a link out never triggers target metadata reads here.
            guard AccessBoundary.contains(file, in: root) else { return false }
            let values = try file.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey, .contentTypeKey])
            return values.isRegularFile == true && values.contentType?.conforms(to: .image) == true
        }
    }
}
