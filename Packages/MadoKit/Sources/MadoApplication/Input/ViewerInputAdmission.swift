import Foundation
import MadoCore
import os

public enum ViewerInputNotice: Equatable, Sendable { case unsupported(String), rejected, multipleFolders, accessFailed }
@MainActor public protocol ViewerInputHost: AnyObject {
    func openInputImage(_ url: URL, accessRequest: AccessRequest?)
    func showInputNotice(_ notice: ViewerInputNotice)
    func promptForInputFolder(_ folder: URL)
}
public enum ViewerInputProbeResult: Equatable, Sendable { case open(AccessRequest), unsupported, failed, discarded }
public struct ViewerInputAdmission: Sendable {
    private let access: any AccessLeasing
    private let pipeline: any ImagePipeline
    private let maximumPixelSize: Int
    private let rootCovering: @Sendable (URL) async -> AccessRootID?
    public init(access: any AccessLeasing, pipeline: any ImagePipeline, maximumPixelSize: Int,
                rootCovering: @escaping @Sendable (URL) async -> AccessRootID?) {
        self.access = access; self.pipeline = pipeline; self.maximumPixelSize = maximumPixelSize
        self.rootCovering = rootCovering
    }
    @MainActor public func probe(_ url: URL, operation: AccessOperation,
                                 requiresSuccessfulProbe: Bool = false) async -> ViewerInputProbeResult {
        do {
            let root = try await operation.wait { await rootCovering(url) }
            let request: AccessRequest = root.map { .root($0, file: url) } ?? .fileGrant(url)
            do {
                _ = try await operation.wait {
                    try await access.withLease(request) { lease in
                        try await pipeline.request(for: url, maximumPixelSize: maximumPixelSize,
                            identityRoot: lease.rootID.map { ItemIdentityRoot(id: $0, url: lease.url) })
                    }
                }
            } catch {
                try operation.check()
                if (error as? ImageLoadError)?.kind == .unsupportedFormat { return .unsupported }
                if requiresSuccessfulProbe { return .failed }
            }
            return .open(request)
        } catch {
            return .discarded
        }
    }
}

extension ViewerSession {
    public func recoverFilePreviewSetMember(_ expected: URL, with chosen: URL,
                                            operation: AccessOperation, admission: ViewerInputAdmission,
                                            host: any ViewerInputHost) async {
        guard operation.isCurrent, let set = filePreviewSet, set.current == expected else { return }
        let result = await admission.probe(chosen, operation: operation, requiresSuccessfulProbe: true)
        guard operation.isCurrent, filePreviewSet?.current == expected else { return }
        if case .open(let request) = result {
            var members = set.members
            members[set.index] = chosen
            var recovered = FilePreviewSet(files: members)
            for _ in 0..<set.index { _ = recovered.move(forward: true) }
            filePreviewSet = recovered
            host.openInputImage(chosen, accessRequest: request)
        } else if result == .unsupported {
            host.showInputNotice(.unsupported(chosen.lastPathComponent))
        } else if result == .failed {
            host.showInputNotice(.accessFailed)
        }
    }
    public func openInput(_ urls: [URL], operation: AccessOperation, admission: ViewerInputAdmission,
                          host: any ViewerInputHost) async {
        guard operation.isCurrent else { return }
        let classification = ViewerInput.classification(urls)
        let input = classification.input
        if case .files(let files) = input {
            logInputExclusions(classification.excludedCount)
            filePreviewSet = FilePreviewSet(files: files)
            host.openInputImage(files[0], accessRequest: nil)
        } else if case .single(let url) = input {
            logInputExclusions(classification.excludedCount)
            let navigation = inputNavigationIntent.current
            let generation = imageLoader.generation
            let result = await admission.probe(url, operation: operation)
            guard operation.isCurrent, navigation.isCurrent, imageLoader.generation == generation else { return }
            if case .open(let request) = result { endFilePreviewSet(); host.openInputImage(url, accessRequest: request) }
            else if result == .unsupported { host.showInputNotice(.unsupported(url.lastPathComponent)) }
        } else if case .folder(let folder) = input { host.promptForInputFolder(folder) }
        else if case .rejected(let files) = input {
            host.showInputNotice(files.filter(\.hasDirectoryPath).count > 1 ? .multipleFolders : .rejected)
        }
    }
}

private func logInputExclusions(_ count: Int) {
    if count > 0 { Logger(subsystem: "io.github.anzchy.mado", category: "filesystem").notice("Input excluded=\(count, privacy: .public)") }
}
