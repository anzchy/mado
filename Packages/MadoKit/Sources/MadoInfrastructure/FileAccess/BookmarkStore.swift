import Foundation
import MadoCore

public struct BookmarkStore: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> [AccessRootRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            switch try StoredSchema.decodeItems(data, as: AccessRootRecord.self, at: url) {
            case .current(let roots):
                guard StoredSchema.isInterimEnvelope(data), url.pathExtension != "recovered" else { return roots }
                let recovered = (try? BookmarkStore(url: url.appendingPathExtension("recovered")).load()) ?? []
                let refreshed = roots.map { record in recovered.first { $0.id == record.id } ?? record }
                return refreshed + recovered.filter { item in !roots.contains { $0.id == item.id } }
            case .unsupported(let version):
                StoredSchema.logUnsupportedOnce(at: url, category: "access", store: "access-roots", version: version)
                return []
            }
        }
        catch { throw FileAccessError.corruptStore }
    }
    public func save(_ roots: [AccessRootRecord]) throws {
        do { try StoredSchema.writeItems(roots, to: url) }
        catch is StoredSchema.UnsupportedVersion {
            // FileAccess publishes the records in its actor only after this returns. They remain
            // session-only; a future-version file keeps its exact bytes.
            return
        }
    }
}
