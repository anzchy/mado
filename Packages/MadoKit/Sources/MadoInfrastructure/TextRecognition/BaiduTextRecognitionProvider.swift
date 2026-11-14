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
    private let transport: any HTTPTransport
    private let now: @Sendable () -> Date
    private var token: (value: String, expires: Date, credentials: CloudCredentials)?
    private var tokenTask: (id: UUID, credentials: CloudCredentials, task: Task<(String, Date), Error>)?

    public init(transport: any HTTPTransport, now: @escaping @Sendable () -> Date = Date.init) {
        self.transport = transport
        self.now = now
    }

    public func recognise(_ image: Data, credentials: CloudCredentials) async throws(TextRecognitionError) -> String {
        let upload = try Self.preparedImage(image)
        let accessToken = try await accessToken(for: credentials)
        var parts = URLComponents(string: "https://aip.baidubce.com/rest/2.0/ocr/v1/accurate_basic")!
        parts.queryItems = [URLQueryItem(name: "access_token", value: accessToken)]
        var request = URLRequest(url: parts.url!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("image=\(Self.form(upload.base64EncodedString()))".utf8)
        let response = try await send(request)
        let payload = try Self.object(response.body)
        if let code = payload["error_code"] as? Int { throw Self.map(code) }
        guard response.statusCode == 200, let lines = payload["words_result"] as? [[String: Any]],
              lines.allSatisfy({ $0["words"] is String }) else { throw .cloudFailure }
        return lines.compactMap { $0["words"] as? String }.joined(separator: "\n")
    }

    private func accessToken(for credentials: CloudCredentials) async throws(TextRecognitionError) -> String {
        if let token, token.credentials == credentials, token.expires.timeIntervalSince(now()) > 30 { return token.value }
        if let pending = tokenTask {
            let result: (String, Date)
            do {
                result = try await pending.task.value
            } catch {
                if tokenTask?.id == pending.id { tokenTask = nil }
                if pending.credentials != credentials { return try await accessToken(for: credentials) }
                throw error as! TextRecognitionError
            }
            if tokenTask?.id == pending.id {
                token = (result.0, result.1, pending.credentials)
                tokenTask = nil
            }
            if pending.credentials == credentials { return result.0 }
            return try await accessToken(for: credentials)
        }
        let transport = self.transport
        let now = self.now
        let task = Task<(String, Date), Error> {
            var request = URLRequest(url: URL(string: "https://aip.baidubce.com/oauth/2.0/token")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("grant_type=client_credentials&client_id=\(Self.form(credentials.apiKey))&client_secret=\(Self.form(credentials.secretKey))".utf8)
            let response: HTTPResponse
            do { response = try await transport.send(request) }
            catch is URLError { throw TextRecognitionError.cloudOffline }
            catch { throw TextRecognitionError.cloudFailure }
            let payload = try Self.object(response.body)
            if payload["error"] != nil || payload["error_code"] != nil { throw TextRecognitionError.cloudAuth }
            guard response.statusCode == 200, let value = payload["access_token"] as? String,
                  !value.isEmpty, let lifetime = payload["expires_in"] as? Double, lifetime > 0 else { throw TextRecognitionError.cloudAuth }
            return (value, now().addingTimeInterval(lifetime))
        }
        let taskID = UUID()
        tokenTask = (taskID, credentials, task)
        do {
            let result = try await task.value
            if tokenTask?.id == taskID {
                token = (result.0, result.1, credentials)
                tokenTask = nil
            }
            return result.0
        } catch {
            if tokenTask?.id == taskID { tokenTask = nil }
            throw error as! TextRecognitionError
        }
    }

    private func send(_ request: URLRequest) async throws(TextRecognitionError) -> HTTPResponse {
        do { return try await transport.send(request) }
        catch is URLError { throw .cloudOffline }
        catch { throw .cloudFailure }
    }

    private static func object(_ data: Data) throws(TextRecognitionError) -> [String: Any] {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw .cloudFailure }
        return value
    }

    private static func map(_ code: Int) -> TextRecognitionError {
        switch code {
        case 110, 111: .cloudAuth
        case 17, 18, 19: .cloudQuota
        default: .cloudFailure
        }
    }

    private static func form(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
    }

    private static func preparedImage(_ data: Data) throws(TextRecognitionError) -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              min(width, height) >= 15 else { throw .invalidImage }
        let maxBytes = 10 * 1024 * 1024
        if max(width, height) <= 8192, ((data.count + 2) / 3) * 4 <= maxBytes { return data }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw .invalidImage }
        let ratio = min(1.0, 8192.0 / Double(max(width, height)))
        let newWidth = Int(Double(width) * ratio)
        let newHeight = Int(Double(height) * ratio)
        guard min(newWidth, newHeight) >= 15,
              let context = CGContext(data: nil, width: newWidth, height: newHeight, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw .cloudImageTooLarge }
        context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        guard let scaled = context.makeImage() else { throw .cloudImageTooLarge }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw .cloudImageTooLarge }
        CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw .cloudImageTooLarge }
        let prepared = output as Data
        guard ((prepared.count + 2) / 3) * 4 <= maxBytes else { throw .cloudImageTooLarge }
        return prepared
    }
}
