import CryptoKit
import Foundation

/// Versioned disk identity. Source content replaces the session-only revision token.
public struct DurableThumbnailKey: Sendable, Equatable {
    public let encoding: String
    public let filename: String
    public init?(renderKey: RenderKey, sourceSHA256: String, encoderVersion: Int = 1) {
        guard renderKey.itemID.stableEncoding.hasPrefix("id1:root:"),
              renderKey.revision.byteCount >= 0,
              renderKey.maximumPixelSize > 0, renderKey.frameIndex >= 0,
              renderKey.decoderVersion > 0, encoderVersion > 0,
              sourceSHA256.utf8.count == 64,
              sourceSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        // Base64 is delimiter-free here; source mtime and resource tokens are deliberately absent.
        let fields = ["rkt1", Data(renderKey.itemID.stableEncoding.utf8).base64EncodedString(),
                      sourceSHA256, String(renderKey.revision.byteCount),
                      String(renderKey.frameIndex), String(renderKey.maximumPixelSize),
                      renderKey.isPreview ? "1" : "0", renderKey.policy.rawValue,
                      String(renderKey.decoderVersion), renderKey.purpose.rawValue,
                      String(encoderVersion), "png-rgba8-sdr-v1"]
        let encoding = fields.joined(separator: "|")
        self.encoding = encoding
        self.filename = SHA256.hash(data: Data(encoding.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
