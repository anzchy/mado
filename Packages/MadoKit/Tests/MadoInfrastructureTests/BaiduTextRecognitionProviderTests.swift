import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
import MadoApplication
@testable import MadoInfrastructure

private actor StubHTTP: HTTPTransport {
    var requests: [URLRequest] = []
    var responses: [Result<HTTPResponse, URLError>]
    init(_ responses: [Result<HTTPResponse, URLError>]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        return try responses.removeFirst().get()
    }
    var count: Int { requests.count }
}
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 100)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; value += seconds }
}
private func json(_ text: String, status: Int = 200) -> Result<HTTPResponse, URLError> {
    .success(.init(statusCode: status, body: Data(text.utf8)))
}
private let baiduKeys = CloudCredentials(apiKey: "api+key", secretKey: "secret key")
private let tokenJSON = json(#"{"access_token":"TOKEN","expires_in":120}"#)
private let wordsJSON = json(#"{"words_result":[{"words":"first"},{"words":"第二行"}]}"#)

private func testImage(width: Int = 20, height: Int = 20) throws -> Data {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

@Test(.timeLimit(.minutes(2)))
func issue689BaiduRequestAndTokenCache() async throws {
    let http = StubHTTP([tokenJSON, wordsJSON, wordsJSON, tokenJSON, wordsJSON])
    let clock = TestClock()
    let provider = BaiduTextRecognitionProvider(transport: http, now: { clock.now() })
    let image = try testImage()
    #expect(try await provider.recognise(image, credentials: baiduKeys) == "first\n第二行")
    #expect(try await provider.recognise(image, credentials: baiduKeys) == "first\n第二行")
    #expect(await http.count == 3)
    clock.advance(121)
    #expect(try await provider.recognise(image, credentials: baiduKeys) == "first\n第二行")
    let requests = await http.requests
    #expect(requests.count == 5)
    #expect(requests[0].url?.absoluteString == "https://aip.baidubce.com/oauth/2.0/token")
    #expect(requests[0].httpMethod == "POST")
    let tokenBody = try #require(requests[0].httpBody.flatMap { String(data: $0, encoding: .utf8) })
    #expect(tokenBody.contains("grant_type=client_credentials"))
    #expect(tokenBody.contains("client_id=api%2Bkey"))
    #expect(tokenBody.contains("client_secret=secret%20key"))
    #expect(requests[1].url?.absoluteString == "https://aip.baidubce.com/rest/2.0/ocr/v1/accurate_basic?access_token=TOKEN")
    #expect(requests[1].httpMethod == "POST")
    let form = try #require(requests[1].httpBody.flatMap { String(data: $0, encoding: .utf8) })
    #expect(form.hasPrefix("image="))
    #expect(form.contains(image.base64EncodedString().addingPercentEncoding(withAllowedCharacters: .alphanumerics)!))
}

@Test(.timeLimit(.minutes(2)))
func issue689BaiduRejectsImageBeforeNetwork() async throws {
    let http = StubHTTP([])
    let provider = BaiduTextRecognitionProvider(transport: http)
    for image in [Data([0]), try testImage(width: 14, height: 20), try testImage(width: 9000, height: 14)] {
        do { _ = try await provider.recognise(image, credentials: baiduKeys); Issue.record("Expected image rejection") }
        catch { #expect(error as? TextRecognitionError == .invalidImage || error as? TextRecognitionError == .cloudImageTooLarge) }
    }
    #expect(await http.count == 0)
}

@Test(.timeLimit(.minutes(2)), arguments: [(110, TextRecognitionError.cloudAuth), (111, .cloudAuth), (17, .cloudQuota), (18, .cloudQuota), (19, .cloudQuota), (999, .cloudFailure)])
func issue689BaiduErrorMapping(code: Int, expected: TextRecognitionError) async throws {
    let http = StubHTTP([tokenJSON, json("{\"error_code\":\(code),\"error_msg\":\"secret key\"}")])
    let provider = BaiduTextRecognitionProvider(transport: http)
    do { _ = try await provider.recognise(testImage(), credentials: baiduKeys); Issue.record("Expected cloud error") }
    catch { #expect(error as? TextRecognitionError == expected) }
}

@Test(.timeLimit(.minutes(2)))
func issue689BaiduTokenAndOfflineErrors() async throws {
    let auth = BaiduTextRecognitionProvider(transport: StubHTTP([json(#"{"error":"invalid_client","error_description":"secret key"}"#, status: 400)]))
    do { _ = try await auth.recognise(testImage(), credentials: baiduKeys); Issue.record("Expected auth error") }
    catch { #expect(error as? TextRecognitionError == .cloudAuth) }
    let offline = BaiduTextRecognitionProvider(transport: StubHTTP([.failure(URLError(.notConnectedToInternet))]))
    do { _ = try await offline.recognise(testImage(), credentials: baiduKeys); Issue.record("Expected offline error") }
    catch { #expect(error as? TextRecognitionError == .cloudOffline) }
}

@Test(.timeLimit(.minutes(2)))
func issue689BaiduDownscalesBeforeUpload() async throws {
    let http = StubHTTP([tokenJSON, wordsJSON])
    let provider = BaiduTextRecognitionProvider(transport: http)
    let image = try testImage(width: 9000, height: 20)
    #expect(try await provider.recognise(image, credentials: baiduKeys) == "first\n第二行")
    let request = try #require(await http.requests.last)
    let body = try #require(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
    let encoded = String(body.dropFirst("image=".count))
    let base64 = try #require(encoded.removingPercentEncoding)
    let uploaded = try #require(Data(base64Encoded: base64))
    #expect(uploaded != image)
    let source = try #require(CGImageSourceCreateWithData(uploaded as CFData, nil))
    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    #expect((properties[kCGImagePropertyPixelWidth] as? Int) == 8192)
}

private actor PausingHTTP: HTTPTransport {
    var requests: [URLRequest] = []
    var resume: CheckedContinuation<Void, Never>?
    let entered: AsyncStream<Void>.Continuation
    init(entered: AsyncStream<Void>.Continuation) { self.entered = entered }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        if request.url?.path == "/oauth/2.0/token" {
            await withCheckedContinuation { resume = $0; entered.yield(()) }
            return try tokenJSON.get()
        }
        return try wordsJSON.get()
    }
    func release() { resume?.resume(); resume = nil }
}

@Test(.timeLimit(.minutes(2)))
func issue689BaiduConcurrentCallsShareTokenExchange() async throws {
    let stream = AsyncStream<Void>.makeStream()
    let http = PausingHTTP(entered: stream.continuation)
    let provider = BaiduTextRecognitionProvider(transport: http)
    let image = try testImage()
    let first = Task { try await provider.recognise(image, credentials: baiduKeys) }
    for await _ in stream.stream { break }
    let second = Task { try await provider.recognise(image, credentials: baiduKeys) }
    try await Task.sleep(for: .milliseconds(30))
    await http.release()
    #expect(try await first.value == "first\n第二行")
    #expect(try await second.value == "first\n第二行")
    let requests = await http.requests
    #expect(requests.filter { $0.url?.path == "/oauth/2.0/token" }.count == 1)
}

@Test(.timeLimit(.minutes(2)))
func issue689BaiduConcurrentDifferentKeysUseTheirOwnTokens() async throws {
    let stream = AsyncStream<Void>.makeStream()
    let http = PausingHTTP(entered: stream.continuation)
    let provider = BaiduTextRecognitionProvider(transport: http)
    let image = try testImage()
    let otherKeys = CloudCredentials(apiKey: "other", secretKey: "other-secret")
    let first = Task { try await provider.recognise(image, credentials: baiduKeys) }
    for await _ in stream.stream { break }
    let second = Task { try await provider.recognise(image, credentials: otherKeys) }
    try await Task.sleep(for: .milliseconds(30))
    await http.release()
    #expect(try await first.value == "first\n第二行")
    try await Task.sleep(for: .milliseconds(30))
    await http.release()
    #expect(try await second.value == "first\n第二行")
    let requests = await http.requests
    #expect(requests.filter { $0.url?.path == "/oauth/2.0/token" }.count == 2)
}

private actor PausingFailHTTP: HTTPTransport {
    var tokenCount = 0
    var resume: CheckedContinuation<Void, Never>?
    let entered: AsyncStream<Void>.Continuation
    init(entered: AsyncStream<Void>.Continuation) { self.entered = entered }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        if request.url?.path == "/oauth/2.0/token" {
            tokenCount += 1
            if tokenCount == 1 {
                await withCheckedContinuation { resume = $0; entered.yield(()) }
                return .init(statusCode: 400, body: Data(#"{"error":"invalid_client"}"#.utf8))
            }
            return try tokenJSON.get()
        }
        return try wordsJSON.get()
    }
    func release() { resume?.resume(); resume = nil }
}

@Test(.timeLimit(.minutes(2)), arguments: [false, true])
func issue689BaiduFailedConcurrentTokenExchangeRetriesOnlyForOtherKeys(sameKeys: Bool) async throws {
    let stream = AsyncStream<Void>.makeStream()
    let http = PausingFailHTTP(entered: stream.continuation)
    let provider = BaiduTextRecognitionProvider(transport: http)
    let image = try testImage()
    let secondKeys = sameKeys ? baiduKeys : CloudCredentials(apiKey: "other", secretKey: "other-secret")
    let first = Task { try await provider.recognise(image, credentials: baiduKeys) }
    for await _ in stream.stream { break }
    let second = Task { try await provider.recognise(image, credentials: secondKeys) }
    try await Task.sleep(for: .milliseconds(30))
    await http.release()
    do { _ = try await first.value; Issue.record("Expected first auth failure") }
    catch { #expect(error as? TextRecognitionError == .cloudAuth) }
    if sameKeys {
        do { _ = try await second.value; Issue.record("Expected shared auth failure") }
        catch { #expect(error as? TextRecognitionError == .cloudAuth) }
        #expect(await http.tokenCount == 1)
    } else {
        #expect(try await second.value == "first\n第二行")
        #expect(await http.tokenCount == 2)
    }
}
