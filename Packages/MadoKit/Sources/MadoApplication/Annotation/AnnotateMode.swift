import CoreGraphics
import Foundation
import MadoCore

/// Why Annotate Mode is being left; each one asks 存储/不存储/取消 when marks are unsaved.
public enum AnnotateLeaveReason: CaseIterable, Sendable {
    case escape, closeWindow, quitApp, changeImage
}

/// The answer to the unsaved-marks prompt.
public enum AnnotateLeaveChoice: CaseIterable, Sendable {
    case save, discard, cancel
}

/// What the host does next with the action that asked to leave.
public enum AnnotateLeaveOutcome: Equatable, Sendable {
    /// Annotate Mode has ended; carry on (exit, close, quit, change image).
    case proceed
    /// Marks are unsaved; show the prompt and pass the answer to `resolveAnnotatePrompt(_:)`.
    case ask
    /// A save started; the outcome arrives from `annotateSaveFinished(_:)`.
    case saving
    /// Stay in Annotate Mode; abort the close, quit or image change.
    case refused
}

public enum AnnotateTool: Sendable {
    /// V: picks a mark to nudge.
    case select
    /// R: draws a rectangle.
    case rectangle
}

/// How a save that the host performed ended.
public enum AnnotateSaveResult: Equatable, Sendable {
    case saved(URL)
    case failed(AnnotatedCopyError)
    case panelCancelled
}

/// One ⌘S, handed to the host: the marks to flatten, the original, and whether the direct write was refused before.
public struct AnnotateSaveRequest: Equatable, Sendable {
    public let fileURL: URL?
    public let marks: [AnnotationMark]
    public let directRefused: Bool
    public init(fileURL: URL?, marks: [AnnotationMark], directRefused: Bool) {
        self.fileURL = fileURL; self.marks = marks; self.directRefused = directRefused
    }
    /// Direct into an Access Root unless a write there was refused; otherwise a prefilled save panel.
    public func destination(folder: URL, name: String, access: AnnotatedCopyAccess) -> AnnotatedCopyDestination {
        AnnotatedCopyPlan.destination(folder: folder, name: name, access: access, directRefused: directRefused)
    }
}

/// The host that performs an Annotated Copy save (planning, panel, write) and reports back.
@MainActor public protocol AnnotateSaveHost: ViewerSessionHost {
    func performAnnotatedCopySave(_ request: AnnotateSaveRequest)
}

/// The state of one Annotate Mode session on the image that was shown when it began.
public struct AnnotateModeState: Equatable, Sendable {
    public let itemID: ItemID?
    public let fileURL: URL?
    public internal(set) var document = AnnotationDocument()
    public internal(set) var tool: AnnotateTool?
    /// The mark ←/→/↑/↓ nudge; nil or an index into `document.marks`.
    public internal(set) var selectedMark: Int?
    /// The reason waiting for an answer to 存储/不存储/取消.
    public internal(set) var prompt: AnnotateLeaveReason?
    /// The revision an in-flight save started from, and the leave it completes.
    var saving: (revision: Int, leave: AnnotateLeaveReason?)?
    public var isSaving: Bool { saving != nil }
    /// A direct write was refused for permission; later saves go to the panel.
    public internal(set) var directRefused = false
    public internal(set) var lastSaveError: AnnotatedCopyError?
    public internal(set) var lastSavedURL: URL?

    init(itemID: ItemID?, fileURL: URL?) { self.itemID = itemID; self.fileURL = fileURL }

    /// Leaving loses something only when there are marks that are not saved.
    public var needsPrompt: Bool { document.hasUnsavedMarks && !document.marks.isEmpty }

    /// ⌘E works only while viewing a shown image, and never while typing.
    public static func canEnter(mode: ViewerMode, hasImage: Bool, status: ViewerImageStatus, focus: FocusContext) -> Bool {
        guard mode == .viewing, hasImage, focus != .textInput else { return false }
        return status == .showing || status == .detailLimited
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.itemID == rhs.itemID && lhs.fileURL == rhs.fileURL && lhs.document == rhs.document && lhs.tool == rhs.tool
            && lhs.selectedMark == rhs.selectedMark && lhs.prompt == rhs.prompt && lhs.saving?.revision == rhs.saving?.revision
            && lhs.saving?.leave == rhs.saving?.leave && lhs.directRefused == rhs.directRefused
            && lhs.lastSaveError == rhs.lastSaveError && lhs.lastSavedURL == rhs.lastSavedURL
    }
}

/// Keys inside Annotate Mode. Outside it nothing is consumed, so browsing keeps every key.
public enum AnnotateKey: Equatable, Sendable {
    case character(String)
    case escape, leftArrow, rightArrow, upArrow, downArrow
}

public struct AnnotateKeyModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = Self(rawValue: 1 << 0)
    public static let shift = Self(rawValue: 1 << 1)
    public static let option = Self(rawValue: 1 << 2)
    public static let control = Self(rawValue: 1 << 3)
}

public enum AnnotateKeyAction: Equatable, Sendable {
    case selectRectangle, selectTool, undo, redo, requestLeave
    /// ←/→/↑/↓ move the selected mark by one image pixel, ten with Shift (5.6); never a change of image.
    case nudge(dx: Int, dy: Int)
}

public enum AnnotateKeyPolicy {
    public static func action(key: AnnotateKey, modifiers: AnnotateKeyModifiers, active: Bool,
                              typing: Bool) -> AnnotateKeyAction? {
        guard active, !typing else { return nil }
        let command = modifiers.contains(.command)
        switch key {
        case .escape: return modifiers.isEmpty ? .requestLeave : nil
        case .leftArrow, .rightArrow, .upArrow, .downArrow:
            guard modifiers.isDisjoint(with: [.command, .control, .option]) else { return nil }
            let step = modifiers.contains(.shift) ? 10 : 1
            switch key {
            case .leftArrow: return .nudge(dx: -step, dy: 0)
            case .rightArrow: return .nudge(dx: step, dy: 0)
            case .upArrow: return .nudge(dx: 0, dy: -step)
            default: return .nudge(dx: 0, dy: step)
            }
        case .character(let text):
            let letter = text.lowercased()
            let plain = modifiers.isDisjoint(with: [.command, .control, .option])
            if letter == "r", plain { return .selectRectangle }
            if letter == "v", plain { return .selectTool }
            if letter == "z", command, modifiers.isDisjoint(with: [.control, .option]) {
                return modifiers.contains(.shift) ? .redo : .undo
            }
            return nil
        }
    }
}
