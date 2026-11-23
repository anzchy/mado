import Foundation
import CoreGraphics
import ImageIO
import MadoApplication
import UniformTypeIdentifiers

public struct HTTPResponse: Sendable {
    public let statusCode: Int
    public let body: Data
    public init(statusCode: Int, body: Data) { self.statusCode = statusCode; self.body = body }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

public actor BaiduTextRecognitionProvider: CloudTextRecognitionProviding {
    /// Baidu's endpoints and upload limits, defined once (ADR-0019; the transport allows only these two paths).
    static let tokenEndpoint = "https://aip.baidubce.com/oauth/2.0/token"
    static let recognitionEndpoint = "https://aip.baidubce.com/rest/2.0/ocr/v1/accurate_basic"
    /// The URL-encoded `image` value's limit.
    static let maxEncodedImageBytes = 10 * 1024 * 1024
    /// The longest side's limit, in pixels.
    static let maxLongSide = 8192
    /// The shortest side's minimum, in pixels.
    static let minShortSide = 15

    private let transport: any HTTPTransport
    private let now: @Sendable () -> Date
    private var token: (value: String, expires: Date, credentials: CloudCredentials)?
    private var tokenTask: (id: UUID, credentials: CloudCredentials, task: Task<(String, Date), Error>)?
    private var tokenWaiterCount = 0

    func pendingTokenWaiters() -> Int { tokenWaiterCount }

    private let onFailure: (@Sendable (CloudFailureDetail) -> Void)?

    /// `onFailure` hears each failed attempt's detail (#689b dev1); it never carries server text, keys, the token or
    /// the image (#689b dev2).
    public init(transport: any HTTPTransport, now: @escaping @Sendable () -> Date = Date.init,
                onFailure: (@Sendable (CloudFailureDetail) -> Void)? = nil) {
        self.transport = transport
        self.now = now
        self.onFailure = onFailure
    }

    public func recognise(_ image: Data, credentials: CloudCredentials) async throws(TextRecognitionError) -> String {
        let upload = try Self.preparedImage(image)
        do throws(Failure) {
            return try await recognise(upload: upload, credentials: credentials)
        } catch {
            if let detail = error.detail { onFailure?(detail) }
            throw error.error
        }
    }

    /// A failed attempt: the error the service sees, and what Baidu or the network said (none for a cancellation).
    struct Failure: Error {
        let error: TextRecognitionError
        let detail: CloudFailureDetail?
        init(_ error: TextRecognitionError, _ detail: CloudFailureDetail? = nil) { self.error = error; self.detail = detail }
    }

    private func recognise(upload: Data, credentials: CloudCredentials) async throws(Failure) -> String {
        let accessToken = try await accessToken(for: credentials)
        if Task.isCancelled { throw Failure(.cancelled) }
        var parts = URLComponents(string: Self.recognitionEndpoint)!
        parts.queryItems = [URLQueryItem(name: "access_token", value: accessToken)]
        var request = URLRequest(url: parts.url!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("image=\(Self.form(upload.base64EncodedString()))".utf8)
        let response = try await send(request)
        if Task.isCancelled { throw Failure(.cancelled) }
        let payload = try Self.object(response, stage: .recognition)
        if let code = payload["error_code"] as? Int {
            if [100, 110, 111].contains(code), token?.credentials == credentials { token = nil }
            throw Failure(Self.map(code), CloudFailureDetail(stage: .recognition, httpStatus: response.statusCode,
                                                             errorCode: code, reason: Self.reason(code)))
        }
        guard response.statusCode == 200, let lines = payload["words_result"] as? [[String: Any]],
              lines.allSatisfy({ $0["words"] is String }) else {
            throw Failure(.cloudFailure, CloudFailureDetail(stage: .recognition, httpStatus: response.statusCode,
                                                            reason: .noWordsResult))
        }
        return lines.compactMap { $0["words"] as? String }.joined(separator: "\n")
    }

    private func accessToken(for credentials: CloudCredentials) async throws(Failure) -> String {
        if Task.isCancelled { throw Failure(.cancelled) }
        if let token, token.credentials == credentials, token.expires.timeIntervalSince(now()) > 30 { return token.value }
        if let pending = tokenTask {
            tokenWaiterCount += 1
            defer { tokenWaiterCount -= 1 }
            let result: (String, Date)
            do {
                result = try await pending.task.value
            } catch {
                if tokenTask?.id == pending.id { tokenTask = nil }
                if pending.credentials != credentials { return try await accessToken(for: credentials) }
                throw Self.transportFailure(error, stage: .token)
            }
            if tokenTask?.id == pending.id {
                token = (result.0, result.1, pending.credentials)
                tokenTask = nil
            }
            if Task.isCancelled { throw Failure(.cancelled) }
            if pending.credentials == credentials { return result.0 }
            return try await accessToken(for: credentials)
        }
        let transport = self.transport
        let now = self.now
        let task = Task<(String, Date), Error> {
            var request = URLRequest(url: URL(string: Self.tokenEndpoint)!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("grant_type=client_credentials&client_id=\(Self.form(credentials.apiKey))&client_secret=\(Self.form(credentials.secretKey))".utf8)
            let response: HTTPResponse
            do { response = try await transport.send(request) }
            catch { throw Self.transportFailure(error, stage: .token) }
            let payload = try Self.object(response, stage: .token)
            if payload["error"] != nil || payload["error_code"] != nil {
                // Baidu's OAuth answer is {error, error_description}; its API errors are {error_code, error_msg}. Only
                // the numeric code or an RFC 6749 error name is kept; the server's text is dropped.
                let code = payload["error_code"] as? Int
                throw Failure(.cloudAuth, CloudFailureDetail(stage: .token, httpStatus: response.statusCode, errorCode: code,
                    reason: code.map(Self.reason) ?? Self.oauthReason(payload["error"])))
            }
            guard response.statusCode == 200, let value = payload["access_token"] as? String,
                  !value.isEmpty, let lifetime = payload["expires_in"] as? Double, lifetime > 0 else {
                throw Failure(.cloudAuth, CloudFailureDetail(stage: .token, httpStatus: response.statusCode,
                                                             reason: .noAccessToken))
            }
            return (value, now().addingTimeInterval(lifetime))
        }
        let taskID = UUID()
        tokenTask = (taskID, credentials, task)
        do {
            let result = try await task.value
            if Task.isCancelled { throw Failure(.cancelled) }
            if tokenTask?.id == taskID {
                token = (result.0, result.1, credentials)
                tokenTask = nil
            }
            return result.0
        } catch {
            if tokenTask?.id == taskID { tokenTask = nil }
            throw Self.transportFailure(error, stage: .token)
        }
    }

    private func send(_ request: URLRequest) async throws(Failure) -> HTTPResponse {
        do { return try await transport.send(request) }
        catch { throw Self.transportFailure(error, stage: .recognition) }
    }

    /// A thrown error as a failure. A URLError's description holds the request URL (and so the token): only its code
    /// is kept. Any other error is named by its type, never described.
    private static func transportFailure(_ error: Error, stage: CloudFailureDetail.Stage) -> Failure {
        if Task.isCancelled || error is CancellationError { return Failure(.cancelled) }
        if let failure = error as? Failure { return failure }
        if let urlError = error as? URLError {
            return urlError.code == .cancelled ? Failure(.cancelled)
                : Failure(.cloudOffline, CloudFailureDetail(stage: stage, transportError: "URLError \(urlError.code.rawValue)"))
        }
        if let refusal = error as? URLSessionHTTPTransport.Refusal {
            return Failure(.cloudFailure, CloudFailureDetail(stage: stage, transportError: "refused \(refusal)"))
        }
        return Failure(.cloudFailure, CloudFailureDetail(stage: stage, transportError: String(describing: type(of: error))))
    }

    private static func object(_ response: HTTPResponse, stage: CloudFailureDetail.Stage) throws(Failure) -> [String: Any] {
        guard let value = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            throw Failure(.cloudFailure, CloudFailureDetail(stage: stage, httpStatus: response.statusCode,
                                                            reason: .unreadableResponse))
        }
        return value
    }

    private static func map(_ code: Int) -> TextRecognitionError {
        switch code {
        case 100, 110, 111: .cloudAuth
        case 17, 18, 19: .cloudQuota
        default: .cloudFailure
        }
    }

    /// The log's reason for a Baidu error_code (#689b dev2): 6 no permission, 17/18/19 quota, 100/110/111 token.
    private static func reason(_ code: Int) -> CloudFailureDetail.Reason {
        switch code {
        case 6: .permission
        case 17, 18, 19: .quota
        case 100, 110, 111: .auth
        default: .other
        }
    }

    /// The log's reason for an OAuth `error`: only an RFC 6749 §5.2 name is kept, anything else is `other`.
    private static func oauthReason(_ error: Any?) -> CloudFailureDetail.Reason {
        let names: [String: CloudFailureDetail.Reason] = [
            "invalid_request": .invalidRequest, "invalid_client": .invalidClient, "invalid_grant": .invalidGrant,
            "unauthorized_client": .unauthorizedClient, "unsupported_grant_type": .unsupportedGrantType,
            "invalid_scope": .invalidScope
        ]
        return (error as? String).flatMap { names[$0] } ?? .other
    }

    private static func form(_ value: String) -> String {
        let ascii = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        return value.addingPercentEncoding(withAllowedCharacters: ascii)!
    }

    private static func preparedImage(_ data: Data) throws(TextRecognitionError) -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              min(width, height) >= minShortSide else { throw .invalidImage }
        let maxBytes = maxEncodedImageBytes
        let sourceType = CGImageSourceGetType(source) as String?
        let supported = sourceType == UTType.jpeg.identifier || sourceType == UTType.png.identifier || sourceType == UTType.bmp.identifier
        if supported, max(width, height) <= maxLongSide, encodedImageSize(data) <= maxBytes { return data }

        return try reencodedThumbnail(source, maxPixel: min(maxLongSide, max(width, height)), maxBytes: maxBytes)
    }

    private static func reencodedThumbnail(_ source: CGImageSource, maxPixel: Int, maxBytes: Int) throws(TextRecognitionError) -> Data {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw .invalidImage }
        guard min(thumbnail.width, thumbnail.height) >= minShortSide else { throw .cloudImageTooLarge }
        let alpha = hasAlphaChannel(thumbnail)
        let output = NSMutableData()
        let type = alpha ? UTType.png : UTType.jpeg
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { throw .cloudImageTooLarge }
        CGImageDestinationAddImage(destination, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw .cloudImageTooLarge }
        let prepared = output as Data
        if encodedImageSize(prepared) <= maxBytes { return prepared }
        // At the minimum side the encoder cannot exceed the byte limit; the short-side guard handles narrow inputs.
        return try reencodedThumbnail(source, maxPixel: max(minShortSide, Int(Double(maxPixel) * 0.75)), maxBytes: maxBytes)
    }

    private static func encodedImageSize(_ data: Data) -> Int {
        form(data.base64EncodedString()).utf8.count
    }

    private static func hasAlphaChannel(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }
}
