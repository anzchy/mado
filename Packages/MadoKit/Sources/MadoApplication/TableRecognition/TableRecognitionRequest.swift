import Foundation

/// Builds the one chat-completions request a Recognise Table run sends (#869 AC-1, spec #866 request contract).
/// DeepSeek: thinking disabled, temperature 0, image detail "original". Custom: standard OpenAI-compatible fields
/// only, so a third-party endpoint never receives a DeepSeek-specific field.
enum TableRecognitionRequest {
    /// The table prompt (plan prompt v2): verbatim cells, first row is the header, `<br>` only for real paragraphs.
    static let prompt = "识别图片中的表格，输出 Markdown 表格。要求：保留全部行列和每个单元格的完整文字，逐字照抄，不要遗漏、不要改写、不要翻译、不要纠正；第一行是表头。图片里因为单元格宽度而自动折行的文字，是同一段话，必须连成一行，不要加 `<br>`，也不要加空格；只有单元格里明显分成多段（有段落间距或项目符号）时，才用 `<br>` 分隔。只输出表格本身，不要代码围栏，不要任何解释。"

    /// `{base}/chat/completions`, with any trailing slashes on the base removed first.
    static func url(base: URL) -> URL? {
        var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)
        var path = parts?.path ?? ""
        while path.hasSuffix("/") { path.removeLast() }
        parts?.path = path + "/chat/completions"
        return parts?.url
    }

    /// The model to send: DeepSeek falls back to `deepseek-flash` when none is set; Custom sends what was entered.
    static func model(for endpoint: TableRecognitionEndpoint) -> String {
        let model = endpoint.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if endpoint.preset == .deepSeek, model.isEmpty { return TableRecognitionEndpoint.deepSeekModel }
        return endpoint.model
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
}
