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
    #expect(requests[1].url?.absoluteString == "https://aip.baidubce.com/rest/2.0/ocr/v1/general_basic?access_token=TOKEN")
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
    let image = try testImage(width: 9000, height: 40)
    #expect(try await provider.recognise(image, credentials: baiduKeys) == "first\n第二行")
    let request = try #require(await http.requests.last)
    let body = try #require(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
    let encoded = String(body.dropFirst("image=".count))
    let base64 = try #require(encoded.removingPercentEncoding)
    let uploaded = try #require(Data(base64Encoded: base64))
    #expect(uploaded != image)
    let source = try #require(CGImageSourceCreateWithData(uploaded as CFData, nil))
    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    #expect((properties[kCGImagePropertyPixelWidth] as? Int) == 4096)
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
    await waitForTokenWaiter(provider)
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
    await waitForTokenWaiter(provider)
    await http.release()
    #expect(try await first.value == "first\n第二行")
    for await _ in stream.stream { break }
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
    await waitForTokenWaiter(provider)
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

private actor CancellationHTTP: HTTPTransport {
    enum Stage { case token, recognition }
    let stage: Stage
    let entered: AsyncStream<Void>.Continuation
    var pending: CheckedContinuation<HTTPResponse, Error>?
    var requests: [URLRequest] = []
    init(stage: Stage, entered: AsyncStream<Void>.Continuation) { self.stage = stage; self.entered = entered }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        let isToken = request.url?.path == "/oauth/2.0/token"
        if (isToken && stage == .token) || (!isToken && stage == .recognition) {
            return try await withCheckedThrowingContinuation { pending = $0; entered.yield(()) }
        }
        return try tokenJSON.get()
    }
    func cancelWithURLError() { pending?.resume(throwing: URLError(.cancelled)); pending = nil }
}

private actor CountingLocal: OnDeviceTextRecognitionProviding {
    var calls = 0
    func recognise(_ image: Data) async throws(TextRecognitionError) -> String { calls += 1; return "local" }
}
private struct FixedSettings: CloudRecognitionSettings {
    func options() async -> CloudRecognitionOptions { .init(enabled: true, consent: .granted, online: true) }
}
private struct FixedKeys: CloudCredentialStore {
    func credentials() async -> CloudCredentials? { baiduKeys }
}

@Test(.timeLimit(.minutes(2)), arguments: [false, true])
func issue689FixCancellationNeverFallsBack(atRecognition: Bool) async throws {
    let stream = AsyncStream<Void>.makeStream()
    let http = CancellationHTTP(stage: atRecognition ? .recognition : .token, entered: stream.continuation)
    let provider = BaiduTextRecognitionProvider(transport: http)
    let local = CountingLocal()
    let service = TextRecognitionService(onDevice: local, settings: FixedSettings(), credentialStore: FixedKeys(), cloud: provider)
    let image = try testImage()
    let task = Task { try await service.recognise(image, intent: .explicit) }
    for await _ in stream.stream { break }
    task.cancel()
    await http.cancelWithURLError()
    do { _ = try await task.value; Issue.record("Expected cancellation") }
    catch { #expect(error as? TextRecognitionError == .cancelled) }
    #expect(await local.calls == 0)
}

@Test(.timeLimit(.minutes(2)))
func issue689FixRejectedCachedTokenRefreshes() async throws {
    let http = StubHTTP([tokenJSON, wordsJSON, json(#"{"error_code":111}"#), tokenJSON, wordsJSON])
    let provider = BaiduTextRecognitionProvider(transport: http)
    let image = try testImage()
    _ = try await provider.recognise(image, credentials: baiduKeys)
    do { _ = try await provider.recognise(image, credentials: baiduKeys); Issue.record("Expected auth rejection") }
    catch { #expect(error as? TextRecognitionError == .cloudAuth) }
    _ = try await provider.recognise(image, credentials: baiduKeys)
    #expect(await http.requests.filter { $0.url?.path == "/oauth/2.0/token" }.count == 2)
}

@Test(.timeLimit(.minutes(2)))
func issue689FixCredentialsDescriptionRedacted() {
    let credentials = CloudCredentials(apiKey: "private-api", secretKey: "private-secret")
    #expect(!"\(credentials)".contains("private-api"))
    #expect(!"\(credentials)".contains("private-secret"))
    #expect(!String(reflecting: credentials).contains("private-api"))
    #expect(!String(reflecting: credentials).contains("private-secret"))
}

@Test(.timeLimit(.minutes(2)))
func issue689FixExpiryMargin() async throws {
    let http = StubHTTP([tokenJSON, wordsJSON, wordsJSON, tokenJSON, wordsJSON])
    let clock = TestClock()
    let provider = BaiduTextRecognitionProvider(transport: http, now: { clock.now() })
    let image = try testImage()
    _ = try await provider.recognise(image, credentials: baiduKeys)
    clock.advance(89)
    _ = try await provider.recognise(image, credentials: baiduKeys)
    #expect(await http.count == 3)
    clock.advance(2)
    _ = try await provider.recognise(image, credentials: baiduKeys)
    #expect(await http.count == 5)
}

@Test(.timeLimit(.minutes(2)))
func issue689FixEncodedImageLimitChecksUploadBytes() async throws {
    // #798: off the cooperative pool, one at a time; the provider re-encodes these large images synchronously.
    try await onSharedSerialQueue { () async throws -> Void in
        let image = try noiseTIFF(width: 1700, height: 1100)
        let encoded = image.base64EncodedString().addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"))!
        #expect(image.base64EncodedString().utf8.count < 10 * 1024 * 1024)
        #expect(encoded.utf8.count > 10 * 1024 * 1024)
        let http = StubHTTP([tokenJSON, wordsJSON])
        let provider = BaiduTextRecognitionProvider(transport: http)
        do {
            _ = try await provider.recognise(image, credentials: baiduKeys)
            let upload = try #require(await http.requests.last?.httpBody)
            #expect(upload.count <= 8 * 1024 * 1024 + "image=".utf8.count)
        } catch {
            #expect(error as? TextRecognitionError == .cloudImageTooLarge)
            #expect(await http.count == 0)
        }
    }
}

@Test(.timeLimit(.minutes(2)), arguments: [false, true])
func issue689FixTiffIsReencodedBeforeUpload(transparent: Bool) async throws {
    let image = try noiseTIFF(width: 20, height: 20, transparent: transparent)
    let http = StubHTTP([tokenJSON, wordsJSON])
    let provider = BaiduTextRecognitionProvider(transport: http)
    _ = try await provider.recognise(image, credentials: baiduKeys)
    let body = try #require(await http.requests.last?.httpBody)
    let encoded = try #require(String(data: body, encoding: .utf8))
    let base64 = try #require(String(encoded.dropFirst("image=".count)).removingPercentEncoding)
    let uploaded = try #require(Data(base64Encoded: base64))
    let source = try #require(CGImageSourceCreateWithData(uploaded as CFData, nil))
    let type = try #require(CGImageSourceGetType(source) as String?)
    #expect(type == UTType.png.identifier)
}

private func waitForTokenWaiter(_ provider: BaiduTextRecognitionProvider) async {
    for _ in 0..<10_000 {
        if await provider.pendingTokenWaiters() > 0 { return }
        await Task.yield()
    }
    Issue.record("Second caller did not enter the shared token exchange")
}

@Test(.timeLimit(.minutes(2)))
func issue689FixSupportedFormatByteOnlyReencode() async throws {
    // #798: off the cooperative pool, one at a time; the provider re-encodes these large images synchronously.
    try await onSharedSerialQueue { () async throws -> Void in
        let tiff = try noiseTIFF(width: 1700, height: 1100)
        let source = try #require(CGImageSourceCreateWithData(tiff as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let bitmap = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(bitmap, UTType.bmp.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        let original = bitmap as Data
        #expect(original.base64EncodedString().utf8.count < 10 * 1024 * 1024)
        #expect(original.base64EncodedString().addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"))!.utf8.count > 10 * 1024 * 1024)
        let http = StubHTTP([tokenJSON, wordsJSON])
        let provider = BaiduTextRecognitionProvider(transport: http)
        _ = try await provider.recognise(original, credentials: baiduKeys)
        let body = try #require(await http.requests.last?.httpBody)
        #expect(body.count <= 8 * 1024 * 1024 + "image=".utf8.count)
        #expect(body != Data("image=\(original.base64EncodedString())".utf8))
    }
}

@Test(.timeLimit(.minutes(2)))
func issue689FixDownscaleRejectsTooNarrowImageBeforeNetwork() async throws {
    let http = StubHTTP([])
    let provider = BaiduTextRecognitionProvider(transport: http)
    do { _ = try await provider.recognise(testImage(width: 9000, height: 15), credentials: baiduKeys); Issue.record("Expected narrow downscale rejection") }
    catch { #expect(error as? TextRecognitionError == .cloudImageTooLarge) }
    #expect(await http.count == 0)
}

private struct CancellationErrorHTTP: HTTPTransport {
    let atRecognition: Bool
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let isToken = request.url?.path == "/oauth/2.0/token"
        if isToken != atRecognition { throw CancellationError() }
        return try tokenJSON.get()
    }
}

@Test(.timeLimit(.minutes(2)), arguments: [false, true])
func issue689FixTransportCancellationErrorNeverFallsBack(atRecognition: Bool) async throws {
    let local = CountingLocal()
    let provider = BaiduTextRecognitionProvider(transport: CancellationErrorHTTP(atRecognition: atRecognition))
    let service = TextRecognitionService(onDevice: local, settings: FixedSettings(), credentialStore: FixedKeys(), cloud: provider)
    do { _ = try await service.recognise(testImage(), intent: .explicit); Issue.record("Expected cancellation") }
    catch { #expect(error as? TextRecognitionError == .cancelled) }
    #expect(await local.calls == 0)
}

private enum UnexpectedTransportError: Error { case failed }
private struct UnexpectedErrorHTTP: HTTPTransport {
    let atRecognition: Bool
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let isToken = request.url?.path == "/oauth/2.0/token"
        if isToken != atRecognition { throw UnexpectedTransportError.failed }
        return try tokenJSON.get()
    }
}

@Test(.timeLimit(.minutes(2)), arguments: [false, true])
func issue689FixUnexpectedTransportErrorIsCloudFailure(atRecognition: Bool) async throws {
    let provider = BaiduTextRecognitionProvider(transport: UnexpectedErrorHTTP(atRecognition: atRecognition))
    do { _ = try await provider.recognise(testImage(), credentials: baiduKeys); Issue.record("Expected cloud failure") }
    catch { #expect(error as? TextRecognitionError == .cloudFailure) }
}

@Test(.timeLimit(.minutes(2)))
func issue689FixAlphaUploadRetriesAtSmallerThumbnail() async throws {
    // #798: off the cooperative pool, one at a time; the provider re-encodes these large images synchronously.
    try await onSharedSerialQueue { () async throws -> Void in
        let image = try noiseTIFF(width: 1800, height: 1300, alphaValue: 254)
        let http = StubHTTP([tokenJSON, wordsJSON])
        let provider = BaiduTextRecognitionProvider(transport: http)
        _ = try await provider.recognise(image, credentials: baiduKeys)
        let body = try #require(await http.requests.last?.httpBody)
        #expect(body.count <= 8 * 1024 * 1024 + "image=".utf8.count)
        let text = try #require(String(data: body, encoding: .utf8))
        let base64 = try #require(String(text.dropFirst("image=".count)).removingPercentEncoding)
        let upload = try #require(Data(base64Encoded: base64))
        let source = try #require(CGImageSourceCreateWithData(upload as CFData, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try #require(props[kCGImagePropertyPixelWidth] as? Int)
        #expect(width < 1800)
        #expect((CGImageSourceGetType(source) as String?) == UTType.png.identifier)
    }
}
