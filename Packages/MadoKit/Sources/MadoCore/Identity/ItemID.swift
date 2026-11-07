import Foundation

/// Opaque, Codable identity. Only root-relative tokens identify an item across launches;
/// resource and ephemeral tokens are session-only. Codable round trips do not imply durable identity.
/// Components use Base64 so separators cannot collide with filenames.
public struct ItemID: Hashable, Codable, Sendable {
    public let stableEncoding: String
    private init(_ encoding: String) { stableEncoding = encoding }

    public static func ephemeral(_ value: UUID) -> Self {
        Self("id1:ephemeral:" + value.uuidString)
    }
    public static func resource(volumeUUID: String, fileIdentifier: String) -> Self {
        Self("id1:res:" + component(volumeUUID) + ":" + component(fileIdentifier))
    }
    /// This is a value constructor, not an authorization check; the resolver checks AccessBoundary first.
    public static func rootRelative(rootID: AccessRootID, relativePath: String) -> Self {
        let path = String(URL(fileURLWithPath: "/" + relativePath).standardizedFileURL.path.dropFirst())
        return Self("id1:root:" + rootID.rawValue.uuidString + ":" + component(path))
    }
    private static func component(_ value: String) -> String { Data(value.utf8).base64EncodedString() }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(stableEncoding)
    }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        let parts = value.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        var decoded: Self?
        if parts.count == 3, parts[0] == "id1", parts[1] == "ephemeral", let uuid = UUID(uuidString: parts[2]) {
            decoded = .ephemeral(uuid)
        } else if parts.count == 4, parts[0] == "id1",
                  let data = Data(base64Encoded: parts[3]), let last = String(data: data, encoding: .utf8) {
            if parts[1] == "res", let data = Data(base64Encoded: parts[2]), let volume = String(data: data, encoding: .utf8) {
                decoded = .resource(volumeUUID: volume, fileIdentifier: last)
            } else if parts[1] == "root", let uuid = UUID(uuidString: parts[2]) {
                decoded = .rootRelative(rootID: AccessRootID(rawValue: uuid), relativePath: last)
            }
        }
        guard let decoded, decoded.stableEncoding == value else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid or noncanonical ItemID")
        }
        self = decoded
    }
}
