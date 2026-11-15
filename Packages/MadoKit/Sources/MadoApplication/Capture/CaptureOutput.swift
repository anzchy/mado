import Foundation

/// The two Settings › Screenshots 「截图之后」 switches (#684, grilling 3.1 / 3.5). Both default on.
public struct CaptureOutputPolicy: Equatable, Sendable {
    public var savesToFolder: Bool
    public var copiesToClipboard: Bool

    public init(savesToFolder: Bool, copiesToClipboard: Bool) {
        self.savesToFolder = savesToFolder
        self.copiesToClipboard = copiesToClipboard
    }

    public static let standard = CaptureOutputPolicy(savesToFolder: true, copiesToClipboard: true)
}

public protocol CaptureClipboardPort: Sendable {
    /// Replaces the clipboard with the PNG; false when the write failed.
    func writePNG(_ png: Data) async -> Bool
}

/// Moves a saved Capture to the Trash. Mado never deletes a Capture permanently (#684 AC-3).
public protocol CaptureTrashPort: Sendable {
    func moveToTrash(_ url: URL) async throws
}

public protocol CaptureOutputPreferencePort: Sendable {
    func outputPolicy() async -> CaptureOutputPolicy
    func setSavesToFolder(_ enabled: Bool) async
    func setCopiesToClipboard(_ enabled: Bool) async
}

public enum CaptureClipboardState: Equatable, Sendable {
    case copied, notCopied, copyFailed
}

/// Thumbnail actions owned by #684. Annotate, Open in Mado and Recognise Text belong to later tickets.
public enum CaptureThumbnailAction: String, Equatable, Sendable {
    case save, copy, moveToTrash
}

public enum CaptureThumbnailStatus: Equatable, Sendable {
    case saved(folder: String, clipboard: CaptureClipboardState)
    case notSaved(clipboard: CaptureClipboardState, saveFailed: Bool)
}

public enum CaptureDragPayload: Equatable, Sendable {
    case file(URL)
    case png(Data)
}

/// What one Capture produced, and therefore what its Capture Thumbnail offers.
public struct CaptureThumbnailState: Equatable, Sendable {
    public let png: Data
    public var savedURL: URL?
    public var clipboard: CaptureClipboardState
    public let folderDisplay: String
    /// Saving was on (or Save was chosen) but the file could not be written.
    public var saveFailed: Bool

    public init(png: Data, savedURL: URL?, clipboard: CaptureClipboardState, folderDisplay: String,
                saveFailed: Bool = false) {
        self.png = png
        self.savedURL = savedURL
        self.clipboard = clipboard
        self.folderDisplay = folderDisplay
        self.saveFailed = saveFailed
    }

    /// 存储 only while there is no file, then 拷贝, then 移到废纸篓 only when a file exists.
    public var actions: [CaptureThumbnailAction] {
        savedURL == nil ? [.save, .copy] : [.copy, .moveToTrash]
    }

    public var status: CaptureThumbnailStatus {
        if savedURL != nil { return .saved(folder: folderDisplay, clipboard: clipboard) }
        return .notSaved(clipboard: clipboard, saveFailed: saveFailed)
    }

    /// Dragging gives the file once it exists, and the image data before (#684 AC-4).
    public var dragPayload: CaptureDragPayload {
        if let savedURL { return .file(savedURL) }
        return .png(png)
    }
}

/// A Capture Thumbnail stays about 5 s, never while the pointer is over it, and restarts when the pointer leaves.
public struct CaptureThumbnailLifetime: Equatable, Sendable {
    public static let visibleSeconds: TimeInterval = 5
    public private(set) var deadline: Date?

    public init(shownAt: Date) {
        deadline = shownAt.addingTimeInterval(Self.visibleSeconds)
    }

    public mutating func pointerEntered() { deadline = nil }

    public mutating func pointerExited(at date: Date) {
        deadline = date.addingTimeInterval(Self.visibleSeconds)
    }

    public func isExpired(at date: Date) -> Bool {
        guard let deadline else { return false }
        return date >= deadline
    }
}

@MainActor public final class CaptureThumbnailModel {
    public private(set) var state: CaptureThumbnailState
    public private(set) var isClosed = false
    private let session: CaptureSession
    private let clipboard: any CaptureClipboardPort
    private let trash: any CaptureTrashPort

    public init(state: CaptureThumbnailState, session: CaptureSession,
                clipboard: any CaptureClipboardPort, trash: any CaptureTrashPort) {
        self.state = state
        self.session = session
        self.clipboard = clipboard
        self.trash = trash
    }

    public func copy() async {
        state.clipboard = await clipboard.writePNG(state.png) ? .copied : .copyFailed
    }

    /// Saves an unsaved Capture to the Capture Folder; a saved one is left alone.
    public func save() async throws {
        guard state.savedURL == nil else { return }
        do {
            state.savedURL = try await session.save(state.png)
            state.saveFailed = false
        } catch {
            state.saveFailed = true
            throw error
        }
    }

    /// Moves the saved file to the Trash and closes the thumbnail. Without a file there is nothing to move.
    public func moveToTrash() async throws {
        guard let url = state.savedURL else { return }
        try await trash.moveToTrash(url)
        isClosed = true
    }

    public func close() { isClosed = true }
}
