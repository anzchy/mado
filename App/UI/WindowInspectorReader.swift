import Foundation
import os
import MadoApplication
import MadoCore
import MadoInfrastructure

struct WindowInspectorReader: InspectorMetadataReading {
    let services: Task<AccessServices, Error>
    let pipeline: any ImagePipeline
    func read(_ url: URL, access: AccessRequest) async throws -> InspectorMetadata {
        do {
            let services = try await services.value
            let files = services.files
            let request: AccessRequest
            if case .fileGrant = access, let root = await files.rootCovering(url) {
                request = .root(root, file: url)
            } else {
                request = access
            }
            let context: AccessMonitor.ReadContext?
            if case .root(let id, _) = request { context = try await services.monitor.readContext(for: id) }
            else { context = nil }
            do {
                try Task.checkCancellation()
                try context?.permit.check()
                let metadata = try await ImageIOInspectorMetadataReader(access: files, pipeline: pipeline, accessPermit: context?.permit)
                    .read(url, access: request)
                try context?.permit.check()
                return metadata
            } catch {
                if let context, !Task.isCancelled, !(error is CancellationError), case .root(let id, _) = request {
                    await services.monitor.reportReadFailure(id, from: context.stamp, error: error, file: url)
                }
                throw error
            }
        } catch {
            if !Task.isCancelled {
                let outcome = (error as? InspectorReadError) == .noPermission ? "no-permission" : "unreadable"
                Logger(subsystem: "io.github.anzchy.mado", category: "inspector")
                    .notice("Metadata read outcome=\(outcome, privacy: .public)")
            }
            throw error
        }
    }
}
