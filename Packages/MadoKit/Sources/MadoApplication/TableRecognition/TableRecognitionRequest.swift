import Foundation
import ImageIO

/// Builds the one chat-completions request a Recognise Table run sends (#869 AC-1, spec #866 request contract).
/// DeepSeek: thinking disabled, temperature 0, image detail "original". Custom: standard OpenAI-compatible fields
/// only, so a third-party endpoint never receives a DeepSeek-specific field.
enum TableRecognitionRequest {
    /// The table prompt (plan prompt v2): verbatim cells, first row is the header, `<br>` only for real paragraphs.
    static let prompt = "识别图片中的表格，输出 Markdown 表格。要求：保留全部行列和每个单元格的完整文字，逐字照抄，不要遗漏、不要改写、不要翻译、不要纠正；第一行是表头。图片里因为单元格宽度而自动折行的文字，是同一段话，必须连成一行，不要加 `<br>`，也不要加空格；只有单元格里明显分成多段（有段落间距或项目符号）时，才用 `<br>` 分隔。只输出表格本身，不要代码围栏，不要任何解释。"

    /// `{base}/chat/completions`, with any trailing slashes on the base removed first.
    static func url(base: URLComponents) -> URL? {
        var parts = base
        var path = parts.path
        while path.hasSuffix("/") { path.removeLast() }
        parts.path = path + "/chat/completions"
        return parts.url
    }

    /// The model to send, trimmed like the key: DeepSeek falls back to `deepseek-flash` when none is set; Custom
    /// sends what was entered (a blank Custom model never gets here: the address guard refuses it).
    static func model(for endpoint: TableRecognitionEndpoint) -> String {
        let model = endpoint.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if endpoint.preset == .deepSeek, model.isEmpty { return TableRecognitionEndpoint.deepSeekModel }
        return model
    }

    static func make(url: URL, endpoint: TableRecognitionEndpoint, key: String, image: Data,
                     mediaType: String) -> URLRequest {
        var imageURL: [String: Any] = ["url": "data:\(mediaType);base64," + image.base64EncodedString()]
        var body: [String: Any] = ["model": model(for: endpoint), "stream": false]
        switch endpoint.preset {
        case .deepSeek:
            imageURL["detail"] = "original"
            body["thinking"] = ["type": "disabled"]
            body["temperature"] = 0
        case .custom:
            break
        }
        body["messages"] = [[
            "role": "user",
            "content": [["type": "text", "text": prompt], ["type": "image_url", "image_url": imageURL]] as [[String: Any]],
        ] as [String: Any]]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The dictionary holds only strings, numbers, booleans, arrays and dictionaries, so serialising cannot fail.
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes])
        return request
    }
}

/// The image formats the service accepts, from the file's first bytes (DeepSeek: JPEG, PNG, GIF, WebP).
enum TableImageFormat {
    static func mediaType(of data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.starts(with: Array("GIF87a".utf8)) || bytes.starts(with: Array("GIF89a".utf8)) { return "image/gif" }
        if bytes.count == 12, bytes.starts(with: Array("RIFF".utf8)), Array(bytes[8..<12]) == Array("WEBP".utf8) {
            return "image/webp"
        }
        return nil
    }

    /// Width and height from the file's header, without decoding pixels; nil when ImageIO cannot read them.
    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { return nil }
        return (width, height)
    }

    /// No orientation tag, or the tag says the pixels are stored upright.
    static func isUpright(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let orientation = properties[kCGImagePropertyOrientation] as? Int else { return true }
        return orientation == 1
    }
}

/// What Recognise Table sends from the opened file (#874 fix1 WI-5): the file's own bytes when the service takes
/// them as they are, otherwise a PNG of the pixels. Uses the service limits in `TableRecognitionGuards`.
public enum TableRecognitionSource {
    /// The largest file whose base64 fits the service's cap: 32 MiB of base64 is 25,165,824 bytes.
    public static let maximumOriginalBytes = TableRecognitionGuards.maxEncodedImageBytes / 4 * 3

    /// A format the service accepts, within its size and side limits, and upright (no EXIF rotation the service
    /// might not apply).
    public static func sendsAsIs(_ data: Data) -> Bool {
        guard case .success = TableRecognitionGuards.image(data) else { return false }
        return TableImageFormat.isUpright(data)
    }
}

/// The checks before anything is sent (#869 AC-2). Each returns the reason a request must not go out.
enum TableRecognitionGuards {
    /// DeepSeek's limit on one image: 32 MiB of base64 and 8192 px per side (plan, API facts read 2026-11-24).
    /// Custom endpoints get the same limits. An image over them is refused, never downscaled.
    static let maxEncodedImageBytes = 32 * 1024 * 1024
    static let maxSide = 8192

    /// A usable address: https, a host, no user or password, no query or fragment. Custom also needs a model.
    /// Returns the request URL and the host that consent is checked against.
    static func validURL(for endpoint: TableRecognitionEndpoint) -> (url: URL, host: String)? {
        guard let parts = URLComponents(string: endpoint.baseURL), parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else { return nil }
        if endpoint.preset == .custom, endpoint.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }
        guard let url = TableRecognitionRequest.url(base: parts) else { return nil }
        return (url, host)
    }

    /// Hosts compare without case and with one trailing dot dropped; the port is not part of the consent.
    static func normalisedHost(_ host: String) -> String {
        var host = host.lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        return host
    }

    static func consentBlock(_ record: TableRecognitionConsentRecord?, host: String) -> TableRecognitionBlock? {
        guard let record else { return .consentNotAsked }
        guard normalisedHost(record.host) == normalisedHost(host) else { return .consentHostChanged }
        return record.granted ? nil : .consentDeclined
    }

    /// The media type when the image is a supported format within the limits, or why it cannot be sent.
    static func image(_ data: Data) -> Result<String, TableRecognitionBlock> {
        guard let mediaType = TableImageFormat.mediaType(of: data),
              let size = TableImageFormat.pixelSize(of: data) else { return .failure(.unsupportedImage) }
        let encodedBytes = (data.count + 2) / 3 * 4
        guard encodedBytes <= maxEncodedImageBytes, max(size.width, size.height) <= maxSide else {
            return .failure(.imageTooLarge)
        }
        return .success(mediaType)
    }
}
