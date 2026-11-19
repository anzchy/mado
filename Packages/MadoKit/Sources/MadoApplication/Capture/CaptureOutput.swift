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

/// Opens a saved Capture in Mado through Launch Services, which gives Mado a File Grant for it (#686).
public protocol CaptureOpenPort: Sendable {
    func openInMado(_ url: URL) async throws
}

/// Thumbnail actions owned by #684, #686 (在 Mado 中打开) and #694 (标注). Recognise Text (#687) comes later.
public enum CaptureThumbnailAction: String, Equatable, Sendable {
    case save, copy, annotate, openInMado, moveToTrash
}

/// Where Mado is, seen from the helper (#686): the helper is embedded at `<Mado>.app/Contents/Library/LoginItems`.
public enum CaptureMadoLocation {
    public static func madoApp(containingHelper helper: URL) -> URL? {
        let parts = helper.standardizedFileURL.pathComponents
        guard parts.count >= 5, parts[parts.count - 1].hasSuffix(".app"),
              Array(parts[(parts.count - 4)...(parts.count - 2)]) == ["Contents", "Library", "LoginItems"],
              parts[parts.count - 5].hasSuffix(".app") else { return nil }
        return helper.standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
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

    /// capture-thumbnail.html:19-20 and :125: 存储 only while there is no file, then 拷贝, 标注, 在 Mado 中打开, then
    /// 移到废纸篓 only when a file exists.
    public var actions: [CaptureThumbnailAction] {
        savedURL == nil ? [.save, .copy, .annotate, .openInMado] : [.copy, .annotate, .openInMado, .moveToTrash]
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
    private var saving: Task<URL, any Error>?
    private var isOpening = false
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

    /// Saves an unsaved Capture to the Capture Folder; a saved one is left alone. A Save while another is
    /// still writing does nothing, so a double click writes one file (#684 fix r1).
    public func save() async throws {
        guard state.savedURL == nil, saving == nil else { return }
        _ = try await savedFile()
    }

    /// The Capture's file: the saved one, the write in flight (joined, #686 fix r1), or a new write.
    /// The write's task updates the state before any caller resumes.
    private func savedFile() async throws -> URL {
        if let url = state.savedURL { return url }
        if let saving { return try await saving.value }
        let png = state.png
        let task = Task { @MainActor [session] in
            defer { self.saving = nil }
            do {
                let url = try await session.save(png)
                self.state.savedURL = url
                self.state.saveFailed = false
                return url
            } catch {
                self.state.saveFailed = true
                throw error
            }
        }
        saving = task
        return try await task.value
    }

    /// Moves the saved file to the Trash and closes the thumbnail. Without a file there is nothing to move, and while
    /// an open in Mado is pending nothing moves, so Mado is never handed a file just moved to the Trash (#694 AC-4).
    public func moveToTrash() async throws {
        guard !isOpening, let url = state.savedURL else { return }
        try await trash.moveToTrash(url)
        isClosed = true
    }

    /// Opens the Capture's file in Mado and closes the thumbnail (#686). An unsaved Capture is first saved to the
    /// Capture Folder by the 存储 path (decision 3.5); if that write fails, nothing is opened.
    /// If Mado cannot be opened, the thumbnail stays. Clicked while a 存储 write is in flight, it waits for that write
    /// and opens its file; a second click while an open is pending, or after one succeeded and closed the thumbnail,
    /// does nothing, so a double click opens once (#686 fix r2).
    public func openInMado(_ opener: any CaptureOpenPort) async throws {
        try await open(opener, annotate: nil)
    }

    /// 标注 (#694): 在 Mado 中打开 with a one-shot hand-off record, so Mado opens the file in Annotate Mode. The record
    /// is written once the file exists and before the open, and cleared if the open fails. It shares 在 Mado 中打开's
    /// guard: while either is pending, a click on either does nothing, so the first click decides.
    public func annotateInMado(_ opener: any CaptureOpenPort, handoff: any CaptureAnnotateHandoffPort,
                               now: @escaping @Sendable () -> Date = Date.init) async throws {
        try await open(opener, annotate: (handoff, now))
    }

    /// True from a click on 在 Mado 中打开 or 标注 until its save and open have returned; the thumbnail's timer and
    /// 移到废纸篓 wait for it (#694 AC-4).
    public var isOpeningInMado: Bool { isOpening }

    private func open(_ opener: any CaptureOpenPort,
                      annotate: (handoff: any CaptureAnnotateHandoffPort, now: @Sendable () -> Date)?) async throws {
        guard !isOpening, !isClosed else { return }
        isOpening = true
        defer { isOpening = false }
        let url = try await savedFile()
        guard !isClosed else { return }
        if let annotate { annotate.handoff.write(CaptureAnnotateHandoffRecord(fileURL: url, createdAt: annotate.now())) }
        do { try await opener.openInMado(url) } catch {
            annotate?.handoff.clear()
            throw error
        }
        isClosed = true
    }

    public func close() { isClosed = true }
}
