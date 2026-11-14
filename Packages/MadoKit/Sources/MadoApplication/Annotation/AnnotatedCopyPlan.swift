import Foundation
import UniformTypeIdentifiers
import MadoCore

/// How Mado may reach the original's folder.
public enum AnnotatedCopyAccess: Equatable, Sendable {
    /// The folder lies inside an Access Root; a direct write is attempted.
    case accessRoot
    /// Only the file itself was granted; the folder needs a save panel.
    case fileGrant
}

/// Where ⌘S writes the Annotated Copy.
public enum AnnotatedCopyDestination: Equatable, Sendable {
    case direct(folder: URL, name: String)
    /// A save panel prefilled with this folder and name.
    case savePanel(folder: URL, name: String)
}

/// The planned file name and the type it is encoded as: `<stem>-annotated[-n].<pathExtension>`.
public struct AnnotatedCopyName: Equatable, Sendable {
    public let stem: String
    public let pathExtension: String
    public let type: UTType
    /// 1 is the bare `-annotated`; 2 and up add `-n`.
    public let number: Int
    public init(stem: String, pathExtension: String, type: UTType, number: Int = 1) {
        self.stem = stem; self.pathExtension = pathExtension; self.type = type; self.number = number
    }
    public var name: String {
        let base = stem + AnnotatedCopyPlan.suffix + (number > 1 ? "-\(number)" : "")
        return pathExtension.isEmpty ? base : base + "." + pathExtension
    }
    /// The same copy with another sequence number, for a writer that finds a clash only at write time.
    public func numbered(_ number: Int) -> AnnotatedCopyName {
        AnnotatedCopyName(stem: stem, pathExtension: pathExtension, type: type, number: number)
    }
}

/// Pure planning for an Annotated Copy: name, format and destination (ADR-020, ADR-007).
public enum AnnotatedCopyPlan {
    public static let suffix = "-annotated"

    /// `<stem>-annotated.<ext>`, then `-annotated-2`, `-3`: the smallest number free in `existing`, compared
    /// without case and Unicode normalisation differences. Keeps the original type when `writableTypes` has it,
    /// otherwise PNG.
    public static func name(for sourceName: String, existing: [String], writableTypes: Set<UTType>) -> AnnotatedCopyName {
        let ext = (sourceName as NSString).pathExtension
        let stem = ext.isEmpty ? sourceName : String(sourceName.dropLast(ext.count + 1))
        let sourceType = ext.isEmpty ? nil : UTType(filenameExtension: ext)
        let first: AnnotatedCopyName
        if let sourceType, let kept = writableTypes.first(where: { sourceType.conforms(to: $0) && $0.conforms(to: sourceType) }) {
            first = AnnotatedCopyName(stem: stem, pathExtension: ext, type: kept)
        } else {
            first = AnnotatedCopyName(stem: stem, pathExtension: "png", type: .png)
        }
        let taken = Set((existing + [sourceName]).map(folded))
        var number = 1
        while taken.contains(folded(first.numbered(number).name)) { number += 1 }
        return first.numbered(number)
    }

    /// APFS compares names without case and with canonical Unicode equivalence.
    static func folded(_ name: String) -> String { name.precomposedStringWithCanonicalMapping.lowercased() }

    public static func destination(folder: URL, name: String, access: AnnotatedCopyAccess,
                                   directRefused: Bool) -> AnnotatedCopyDestination {
        access == .accessRoot && !directRefused ? .direct(folder: folder, name: name) : .savePanel(folder: folder, name: name)
    }

    /// A save-panel choice must not be the original file (by resource identity, so hard links and case variants count).
    public static func validatePanelChoice<Identity: Equatable>(_ choice: Identity, source: Identity) throws(AnnotatedCopyError) {
        if choice == source { throw .sourceIsTarget }
    }

    /// Whether a failed direct write should send the next ⌘S to the save panel. Only a permission refusal does.
    public static func refusesDirectWrite(_ error: AnnotatedCopyError) -> Bool { error == .permissionDenied }
}
