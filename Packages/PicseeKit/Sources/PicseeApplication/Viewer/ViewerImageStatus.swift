import Foundation
import PicseeCore

public enum ViewerImageFailure: Equatable, Sendable {
    case corruptImage, unsupportedFormat, resourceLimit, sourceChanged, access
}

/// The single presentation state consumed by native state surfaces.
public enum ViewerImageStatus: Equatable, Sendable {
    case empty, loading(String), readingFolder, folderScanFailed(String, String), noMatches, showing, detailLimited, failed(ViewerImageFailure, String)
    /// A folder session whose complete scan found no images: page 22 on whichever surface shows (ADR-014, #137).
    case emptyFolder

    public init(phase: ViewerImagePhase, fileName: String, failure: (any Error)?) {
        switch phase {
        case .idle: self = .empty
        case .opening: self = .loading(fileName)
        case .refining, .settled: self = .showing
        case .detailLimited: self = .detailLimited
        case .failed:
            let kind: ViewerImageFailure
            switch (failure as? ImageLoadError)?.kind {
            case .corruptImage: kind = .corruptImage
            case .unsupportedFormat: kind = .unsupportedFormat
            case .resourceLimit: kind = .resourceLimit
            case .sourceChanged: kind = .sourceChanged
            case .cancelled: self = .empty; return
            case nil:
                let error = failure as NSError?
                let cocoaPermission = error?.domain == NSCocoaErrorDomain &&
                    (error?.code == NSFileReadNoPermissionError || error?.code == NSFileWriteNoPermissionError)
                let posixPermission = error?.domain == NSPOSIXErrorDomain &&
                    (error?.code == Int(POSIXError.Code.EACCES.rawValue) || error?.code == Int(POSIXError.Code.EPERM.rawValue))
                kind = failure is FileAccessError || cocoaPermission || posixPermission ? .access : .corruptImage
            }
            self = .failed(kind, fileName)
        }
    }
}

extension ViewerSession {
    var imageCommandsAvailable: Bool {
        guard mode == .viewing else { return false }
        guard host?.hasImage == true else { return false }
        switch imageStatus {
        case .loading, .readingFolder, .noMatches, .failed: return false
        default: return true
        }
    }
    public var imageStatus: ViewerImageStatus {
        if folderScan?.isReadingFolder == true || folderScan?.isAwaitingFilteredMatch == true { return .readingFolder }
        if let reason = folderScan?.failureReason {
            return .folderScanFailed(reason, folderScan?.failedFolderName ?? "")
        }
        if filePreviewSet == nil, previewSet == nil, folderScan?.hasNoMatches == true { return .noMatches }
        if filePreviewSet == nil, previewSet == nil, folderScan?.isEmptyFolder == true, imageLoader.phase == .idle {
            return .emptyFolder
        }
        return ViewerImageStatus(phase: imageLoader.phase,
            fileName: imageLoader.fileURL?.lastPathComponent ?? "", failure: imageLoader.failure)
    }
}
