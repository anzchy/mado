import Foundation

/// Members are a frozen input snapshot; later file revisions do not change the path list.
public struct FilePreviewSet: Sendable {
    public let members: [URL]
    public private(set) var index = 0
    public init(files: [URL]) { members = files }
    public var current: URL? { members.indices.contains(index) ? members[index] : nil }
    public func canMove(forward: Bool, mayWrap: Bool = false) -> Bool {
        members.count > 1 && (mayWrap || members.indices.contains(index + (forward ? 1 : -1)))
    }
    @discardableResult public mutating func move(forward: Bool, mayWrap: Bool = false) -> URL? {
        guard canMove(forward: forward, mayWrap: mayWrap) else { return nil }
        let next = index + (forward ? 1 : -1)
        index = members.indices.contains(next) ? next : (forward ? 0 : members.count - 1)
        return members[index]
    }
}

extension ViewerSession {
    public func endFilePreviewSet() { inputNavigationIntent.invalidate(); filePreviewSet = nil }
    func moveInputFile(forward: Bool) {
        guard let url = filePreviewSet?.move(forward: forward, mayWrap: displayPreferences.loopThroughImages) else { return }
        (host as? any ViewerInputHost)?.openInputImage(url, accessRequest: nil)
    }
}
