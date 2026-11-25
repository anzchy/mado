import Foundation

/// Turns what the transport gave back into a result (#869 AC-4). Classes carry no server text, key or image.
enum TableRecognitionReply {
    static func classify(_ response: HTTPResponse) -> TableRecognitionResult {
        switch response.statusCode {
        case 200: return reply(response.body)
        // The service never follows a redirect: the image and key go only to the configured host (AC-3). A 3xx
        // means the address is not the service's own endpoint.
        case 300...399: return .failed(.addressUnreachable)
        case 401, 403: return .failed(.keyRejected)
        // A 404 that names an error (for example a model that does not exist) is not a wrong address; one without
        // an error object means the address has no such endpoint.
        case 404: return .failed(errorMessage(response.body) == nil ? .addressUnreachable : .other)
        case 400, 422: return .failed(saysModelCannotReadImages(errorMessage(response.body)) ? .modelCannotReadImages
                                                                                              : .other)
        case 402, 429: return .failed(.quotaOrBalance)
        case 413: return .failed(.tooLarge)
        default: return .failed(.other)
        }
    }

    /// A thrown transport error: cancellation, no network, an address that cannot be reached, or other.
    static func classify(_ error: any Error) -> TableRecognitionResult {
        if error is CancellationError { return .cancelled }
        guard let error = error as? URLError else { return .failed(.other) }
        switch error.code {
        case .cancelled: return .cancelled
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            return .failed(.offline)
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .secureConnectionFailed,
             .serverCertificateHasBadDate, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .badURL, .unsupportedURL:
            return .failed(.addressUnreachable)
        default: return .failed(.other)
        }
    }

    /// `error.message` of an OpenAI-style error body, if there is one.
    private static func errorMessage(_ body: Data) -> String? {
        let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        return (object?["error"] as? [String: Any])?["message"] as? String
    }

    /// Only an error that says the model does not take images: "does not support image(s)", "image(s) … not
    /// supported", or DeepSeek's text-only "unknown variant `image_url`". A message that merely mentions an image
    /// (a bad, large or undecodable one) is not this class; there is no guessing (grilling decision 7).
    private static func saysModelCannotReadImages(_ message: String?) -> Bool {
        guard let message else { return false }
        let patterns = [#"\b(does not|doesn't|do not|don't) support (image|vision)"#,
                        #"\bimages? (input )?(is |are )?not supported"#,
                        #"unknown variant [`'"]?image_url"#]
        return patterns.contains { message.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    /// A 200 body: the first choice's content and finish reason.
    private static func reply(_ body: Data) -> TableRecognitionResult {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]], let choice = choices.first,
              let message = choice["message"] as? [String: Any] else { return .failed(.other) }
        let content = message["content"]
        guard content == nil || content is NSNull || content is String else { return .failed(.other) }
        // Only a reply the service says it finished certifies a table (AC-5). A cut-off reply, or one that does not
        // say how it ended, is incomplete even when the part that arrived parses; any other ending is not a table.
        switch choice["finish_reason"] as? String {
        case "stop": break
        case nil, "length", "insufficient_system_resource": return .failed(.incomplete)
        default: return .failed(.other)
        }
        guard let text = content as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failed(.noTable)
        }
        switch MarkdownTableReader.read(text) {
        case .rows(let rows): return .table(rows: rows)
        case .noTable: return .failed(.noTable)
        case .incomplete: return .failed(.incomplete)
        }
    }
}
