import Foundation
import os

enum StoredSchema {
    // Root and recent data stay top-level arrays so pre-0.0.1 builds can still decode and
    // rewrite them. Each nonempty record carries the version; an empty array uses .schema.
    static let current = 1
    struct UnsupportedVersion: Error { let version: Int }
    enum Items<Value> {
        case current([Value])
        case unsupported(Int)
    }
    private struct Header: Codable { let schemaVersion: Int? }
    private struct Envelope<Value: Codable>: Codable {
        let schemaVersion: Int
        let items: [Value]
    }

    static func decodeItems<Value: Codable>(_ data: Data, as type: Value.Type, at url: URL) throws -> Items<Value> {
        let decoder = JSONDecoder()
        if let header = try? decoder.decode(Header.self, from: data), let version = header.schemaVersion {
            if version != current { return .unsupported(version) }
            return .current(try decoder.decode(Envelope<Value>.self, from: data).items)
        }
        if let version = try unsupportedArrayVersion(in: data, at: url) { return .unsupported(version) }
        return .current(try decoder.decode([Value].self, from: data))
    }

    static func encodeItems<Value: Codable>(_ items: [Value]) throws -> Data {
        let encoded = try JSONEncoder().encode(items)
        guard !items.isEmpty else { return encoded }
        // Callers pass records whose Codable representation is an object.
        var objects = try JSONSerialization.jsonObject(with: encoded) as! [[String: Any]]
        for index in objects.indices { objects[index]["schemaVersion"] = current }
        return try JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys])
    }

    static func isInterimEnvelope(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["items"] != nil
    }

    private static func unsupportedArrayVersion(in data: Data, at url: URL) throws -> Int? {
        guard let objects = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
        for object in objects {
            guard let fields = object as? [String: Any], let raw = fields["schemaVersion"] else { continue }
            guard let version = raw as? Int else { throw CorruptVersion() }
            if version != current { return version }
        }
        guard objects.isEmpty else { return nil }
        return try unsupportedMarkerVersion(at: url)
    }

    private static func unsupportedMarkerVersion(at url: URL) throws -> Int? {
        let marker = url.appendingPathExtension("schema")
        guard FileManager.default.fileExists(atPath: marker.path) else { return nil }
        let header = try JSONDecoder().decode(Header.self, from: Data(contentsOf: marker))
        guard let version = header.schemaVersion, version != current else { return nil }
        return version
    }
    struct CorruptVersion: Error {}

    /// Recheck the destination immediately before each atomic replacement. Callers serialize their
    /// own writes; a separate process changing the file between this check and rename remains a race.
    static func refuseUnsupportedWrite(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        if let header = try? JSONDecoder().decode(Header.self, from: data),
           let version = header.schemaVersion, version != current { throw UnsupportedVersion(version: version) }
        if let version = try unsupportedArrayVersion(in: data, at: url) {
            throw UnsupportedVersion(version: version)
        }
        if let version = try unsupportedMarkerVersion(at: url) {
            throw UnsupportedVersion(version: version)
        }
    }

    static func writeItems<Value: Codable>(_ items: [Value], to url: URL) throws {
        try refuseUnsupportedWrite(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encodeItems(items).write(to: url, options: .atomic)
        if items.isEmpty {
            let marker = try JSONEncoder().encode(Header(schemaVersion: current))
            try marker.write(to: url.appendingPathExtension("schema"), options: .atomic)
        }
    }

    private static let logState = LogState()
    static func logUnsupportedOnce(at url: URL, category: String, store: String, version: Int) {
        let key = category + ":" + store + ":" + url.standardizedFileURL.path
        let first = logState.lock.withLock { logState.paths.insert(key).inserted }
        if first {
            Logger(subsystem: "io.github.anzchy.mado", category: category)
                .error("StoredSchema store=\(store, privacy: .public) version=\(version, privacy: .public) kind=unsupportedVersion")
        }
    }

    private final class LogState: @unchecked Sendable {
        let lock = NSLock()
        var paths: Set<String> = []
    }
}
