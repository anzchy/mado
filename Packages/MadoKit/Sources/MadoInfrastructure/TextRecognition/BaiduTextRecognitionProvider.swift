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
    private var tokenWaiterCount = 0

    func pendingTokenWaiters() -> Int { tokenWaiterCount }

    public init(transport: any HTTPTransport, now: @escaping @Sendable () -> Date = Date.init) {
        self.transport = transport
        self.now = now
    }

    public func recognise(_ image: Data, credentials: CloudCredentials) async throws(TextRecognitionError) -> String {
        let upload = try Self.preparedImage(image)
        let accessToken = try await accessToken(for: credentials)
        if Task.isCancelled { throw TextRecognitionError.cancelled }
        var parts = URLComponents(string: "https://aip.baidubce.com/rest/2.0/ocr/v1/accurate_basic")!
        parts.queryItems = [URLQueryItem(name: "access_token", value: accessToken)]
        var request = URLRequest(url: parts.url!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("image=\(Self.form(upload.base64EncodedString()))".utf8)
        let response = try await send(request)
        if Task.isCancelled { throw TextRecognitionError.cancelled }
        let payload = try Self.object(response.body)
        if let code = payload["error_code"] as? Int {
            if [100, 110, 111].contains(code), token?.credentials == credentials { token = nil }
            throw Self.map(code)
        }
        guard response.statusCode == 200, let lines = payload["words_result"] as? [[String: Any]],
              lines.allSatisfy({ $0["words"] is String }) else { throw .cloudFailure }
        return lines.compactMap { $0["words"] as? String }.joined(separator: "\n")
    }

    private func accessToken(for credentials: CloudCredentials) async throws(TextRecognitionError) -> String {
        if Task.isCancelled { throw TextRecognitionError.cancelled }
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
                throw Self.mapTaskError(error)
            }
            if tokenTask?.id == pending.id {
                token = (result.0, result.1, pending.credentials)
                tokenTask = nil
            }
            if Task.isCancelled { throw TextRecognitionError.cancelled }
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
            catch { throw Self.mapTransportError(error) }
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
            if Task.isCancelled { throw TextRecognitionError.cancelled }
            if tokenTask?.id == taskID {
                token = (result.0, result.1, credentials)
                tokenTask = nil
            }
            return result.0
        } catch {
            if tokenTask?.id == taskID { tokenTask = nil }
            throw Self.mapTaskError(error)
        }
    }

    private func send(_ request: URLRequest) async throws(TextRecognitionError) -> HTTPResponse {
        do { return try await transport.send(request) }
        catch { throw Self.mapTransportError(error) }
    }

    private static func mapTaskError(_ error: Error) -> TextRecognitionError {
        if Task.isCancelled { return .cancelled }
        if let typed = error as? TextRecognitionError { return typed }
        return mapTransportError(error)
    }

    private static func mapTransportError(_ error: Error) -> TextRecognitionError {
        if Task.isCancelled || error is CancellationError { return .cancelled }
        if let urlError = error as? URLError {
            return urlError.code == .cancelled ? .cancelled : .cloudOffline
        }
        return .cloudFailure
    }

    private static func object(_ data: Data) throws(TextRecognitionError) -> [String: Any] {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw .cloudFailure }
        return value
    }

    private static func map(_ code: Int) -> TextRecognitionError {
        switch code {
        case 100, 110, 111: .cloudAuth
        case 17, 18, 19: .cloudQuota
        default: .cloudFailure
        }
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
              min(width, height) >= 15 else { throw .invalidImage }
        let maxBytes = 10 * 1024 * 1024
        let sourceType = CGImageSourceGetType(source) as String?
        let supported = sourceType.map { [UTType.jpeg.identifier, UTType.png.identifier, UTType.bmp.identifier].contains($0) } ?? false
        if supported, max(width, height) <= 8192, encodedImageSize(data) <= maxBytes { return data }

        var maxPixel = min(8192, max(width, height))
        while maxPixel >= 15 {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel
            ]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw .invalidImage }
            guard min(thumbnail.width, thumbnail.height) >= 15 else { throw .cloudImageTooLarge }
            let alpha = try containsTransparency(thumbnail)
            let output = NSMutableData()
            let type = alpha ? UTType.png : UTType.jpeg
            guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { throw .cloudImageTooLarge }
            CGImageDestinationAddImage(destination, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw .cloudImageTooLarge }
            let prepared = output as Data
            if encodedImageSize(prepared) <= maxBytes { return prepared }
            maxPixel = Int(Double(maxPixel) * 0.75)
        }
        throw .cloudImageTooLarge
    }

    private static func encodedImageSize(_ data: Data) -> Int {
        form(data.base64EncodedString()).utf8.count
    }

    private static func containsTransparency(_ image: CGImage) throws(TextRecognitionError) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: break
        }
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
              let bytes = context.data else { throw .cloudImageTooLarge }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = bytes.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * image.height)
        for y in 0..<image.height {
            for x in 0..<image.width {
                if pixels[y * context.bytesPerRow + x * 4 + 3] < 255 { return true }
            }
        }
        return false
    }
}
