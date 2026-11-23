import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
import MadoApplication
@testable import MadoInfrastructure

// #831 EXT-04 (spec #830, ADR-0019 amendment): Cloud Recognition calls Baidu's standard general-text product
// (general_basic) and shrinks images to its limits first: at most 4096 px on the longest side and at most 8 MB for the
// URL-encoded image value. An image that cannot fit fails as too large and the service falls back to On-device
// Recognition. Token exchange is unchanged.

private actor Stub831: HTTPTransport {
    var requests: [URLRequest] = []
    var responses: [HTTPResponse]
    init(_ responses: [String]) { self.responses = responses.map { HTTPResponse(statusCode: 200, body: Data($0.utf8)) } }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        return responses.removeFirst()
    }
}

private let token831 = #"{"access_token":"TOKEN","expires_in":120}"#
private let words831 = #"{"words_result":[{"words":"标准"}]}"#
private let keys831 = CloudCredentials(apiKey: "api", secretKey: "secret")
private let limit831 = 8 * 1024 * 1024
private let ascii831 = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")

private func png831(width: Int, height: Int) throws -> Data {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

/// The uploaded image: the form body's `image=` value, percent-decoded and base64-decoded.
private func uploaded831(_ request: URLRequest?) throws -> (body: Data, image: Data) {
    let body = try #require(request?.httpBody)
    let text = try #require(String(data: body, encoding: .utf8))
    #expect(text.hasPrefix("image="))
    let base64 = try #require(String(text.dropFirst("image=".count)).removingPercentEncoding)
    return (body, try #require(Data(base64Encoded: base64)))
}

private func pixels831(_ image: Data) throws -> (width: Int, height: Int) {
    let source = try #require(CGImageSourceCreateWithData(image as CFData, nil))
    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    return (try #require(properties[kCGImagePropertyPixelWidth] as? Int), try #require(properties[kCGImagePropertyPixelHeight] as? Int))
}

@Test(.timeLimit(.minutes(2)))
func issue831RecognitionUsesTheStandardEndpoint() async throws {
    let http = Stub831([token831, words831])
    let provider = BaiduTextRecognitionProvider(transport: http)
    #expect(try await provider.recognise(png831(width: 40, height: 20), credentials: keys831) == "标准")
    let requests = await http.requests
    #expect(requests.count == 2)
    #expect(requests[0].url?.absoluteString == "https://aip.baidubce.com/oauth/2.0/token", "the token request is unchanged")
    #expect(requests[0].httpMethod == "POST")
    #expect(requests[1].url?.absoluteString == "https://aip.baidubce.com/rest/2.0/ocr/v1/general_basic?access_token=TOKEN")
    #expect(requests[1].httpMethod == "POST")
    #expect(requests[1].value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
    // Defined once: the provider's constants, which the transport's allow-list uses too.
    #expect(BaiduTextRecognitionProvider.recognitionEndpoint == "https://aip.baidubce.com/rest/2.0/ocr/v1/general_basic")
    #expect(BaiduTextRecognitionProvider.maxLongSide == 4096)
    #expect(BaiduTextRecognitionProvider.maxEncodedImageBytes == limit831)
    #expect(URLSessionHTTPTransport.paths == ["/oauth/2.0/token", "/rest/2.0/ocr/v1/general_basic"])
}

@Test(.timeLimit(.minutes(2)), arguments: [(5000, 20, 4096, 16), (20, 5000, 16, 4096), (4096, 30, 4096, 30)])
func issue831LongestSideShrinksTo4096(width: Int, height: Int, expectedWidth: Int, expectedHeight: Int) async throws {
    let http = Stub831([token831, words831])
    let provider = BaiduTextRecognitionProvider(transport: http)
    _ = try await provider.recognise(png831(width: width, height: height), credentials: keys831)
    let upload = try uploaded831(await http.requests.last)
    let size = try pixels831(upload.image)
    #expect(max(size.width, size.height) <= 4096)
    #expect(size.width == expectedWidth && size.height == expectedHeight, "\(width)×\(height) → \(size)")
}

/// A supported BMP under 4096 px whose encoded value is between 8 and 10 MB: re-encoded to fit 8 MB.
@Test(.timeLimit(.minutes(2)))
func issue831EncodedValueNeverExceeds8MB() async throws {
    try await onSharedSerialQueue { () async throws -> Void in
        let tiff = try noiseTIFF(width: 1500, height: 850)
        let source = try #require(CGImageSourceCreateWithData(tiff as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let bitmap = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(bitmap, UTType.bmp.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        let original = bitmap as Data
        let encoded = original.base64EncodedString().addingPercentEncoding(withAllowedCharacters: ascii831)!.utf8.count
        #expect(encoded > limit831 && encoded <= 10 * 1024 * 1024, "fixture between the two limits: \(encoded)")
        let http = Stub831([token831, words831])
        let provider = BaiduTextRecognitionProvider(transport: http)
        _ = try await provider.recognise(original, credentials: keys831)
        let upload = try uploaded831(await http.requests.last)
        #expect(upload.body.count - "image=".utf8.count <= limit831)
        #expect(upload.image != original, "re-encoded")
    }
}

private actor Local831: OnDeviceTextRecognitionProviding {
    var calls = 0
    func recognise(_ image: Data) async throws(TextRecognitionError) -> String { calls += 1; return "本机" }
}
private struct Settings831: CloudRecognitionSettings {
    func options() async -> CloudRecognitionOptions { .init(enabled: true, consent: .granted, online: true) }
}
private struct Keys831: CloudCredentialStore {
    func credentials() async -> CloudCredentials? { keys831 }
}

/// 5000×15 fits 8192 but not 4096: shrunk, its short side drops under 15 px, so it is too large. Nothing is sent and
/// the service falls back to On-device Recognition with its label.
@Test(.timeLimit(.minutes(2)))
func issue831ImageThatCannotFitFallsBackOnDevice() async throws {
    let http = Stub831([token831, words831])
    let provider = BaiduTextRecognitionProvider(transport: http)
    let image = try png831(width: 5000, height: 15)
    do { _ = try await provider.recognise(image, credentials: keys831); Issue.record("Expected too large") }
    catch { #expect(error == .cloudImageTooLarge) }
    #expect(await http.requests.isEmpty)
    let local = Local831()
    let service = TextRecognitionService(onDevice: local, settings: Settings831(), credentialStore: Keys831(), cloud: provider)
    let result = try await service.recognise(image, intent: .explicit)
    #expect(result.engine == .onDevice)
    #expect(result.text == "本机")
    #expect(result.fallbackReason == .failure)
    #expect(await local.calls == 1)
    #expect(await http.requests.isEmpty)
}

/// The token request keeps its current shape (#831 doc review): a form body, not URL parameters. Baidu's token guide
/// puts the parameters in the URL; this body form works in existing live evidence, so this pins it rather than the
/// guide. The key and secret are percent-encoded with only ASCII letters and digits left as they are.
@Test(.timeLimit(.minutes(2)))
func issue831TokenRequestKeepsItsFormBody() async throws {
    let http = Stub831([token831, words831])
    let provider = BaiduTextRecognitionProvider(transport: http)
    let keys = CloudCredentials(apiKey: "api key+/=", secretKey: "sécret&x")
    #expect(try await provider.recognise(png831(width: 20, height: 20), credentials: keys) == "标准")
    let requests = await http.requests
    #expect(requests.count == 2)
    let token = try #require(requests.first)
    #expect(token.url?.absoluteString == "https://aip.baidubce.com/oauth/2.0/token")
    #expect(token.url?.query == nil)
    #expect(token.httpMethod == "POST")
    #expect(token.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
    let body = try #require(token.httpBody.flatMap { String(data: $0, encoding: .utf8) })
    #expect(body == "grant_type=client_credentials&client_id=api%20key%2B%2F%3D&client_secret=s%C3%A9cret%26x")
    #expect(requests.last?.url?.path == "/rest/2.0/ocr/v1/general_basic")
}
