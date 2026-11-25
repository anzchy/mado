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
        case 404: return .failed(.addressUnreachable)
        case 400, 422: return .failed(errorMessage(response.body)?.lowercased().contains("image") == true
                                      ? .modelCannotReadImages : .other)
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

    /// A 200 body: the first choice's content and finish reason.
    private static func reply(_ body: Data) -> TableRecognitionResult {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]], let choice = choices.first,
              let message = choice["message"] as? [String: Any] else { return .failed(.other) }
        let content = message["content"]
        guard content == nil || content is NSNull || content is String else { return .failed(.other) }
        // A cut-off reply is never a table, even when the part that arrived parses (AC-5).
        switch choice["finish_reason"] as? String {
        case "length": return .failed(.incomplete)
        case "content_filter": return .failed(.other)
        default: break
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
