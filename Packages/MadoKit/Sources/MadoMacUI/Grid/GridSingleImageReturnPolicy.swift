import Foundation
import MadoCore

public struct GridSingleImageDestination: Equatable, Sendable {
    public let folder: URL
    public let currentItemID: ItemID
}

public enum GridSingleImageReturnPolicy {
    public static func destination(for file: URL, root: ItemIdentityRoot) -> GridSingleImageDestination {
        GridSingleImageDestination(folder: file.deletingLastPathComponent(),
            currentItemID: FolderEntry(url: file, root: root).itemID)
    }
}
