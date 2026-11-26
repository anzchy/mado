import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
import MadoApplication
@testable import MadoInfrastructure

/// Answers every request made through a session that lists it; no request reaches the network.
/// Internal (not private) so the #787 extension in Issue787HungLoadTests.swift can drive it.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Outcome { case respond(Int, Data), bare(Data), redirect(Int, String), fail(URLError), hang }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var outcomes: [Outcome] = []
    nonisolated(unsafe) private static var seen: [(request: URLRequest, body: Data)] = []
    nonisolated(unsafe) private static var stopped = 0
    nonisolated(unsafe) private static var hung: [StubURLProtocol] = []
    nonisolated(unsafe) private static var afterRecord: (@Sendable () -> Void)?

    /// `afterRecord` runs in `startLoading` right after the request becomes visible through `requests`, outside the lock
    /// (#787: it lets a test act at the earliest moment it could observe the load).
    static func reset(_ outcomes: [Outcome], afterRecord: (@Sendable () -> Void)? = nil) {
        lock.lock(); defer { lock.unlock() }
        self.outcomes = outcomes; seen = []; stopped = 0
        hung = []
        self.afterRecord = afterRecord
    }
    static var requests: [(request: URLRequest, body: Data)] { lock.lock(); defer { lock.unlock() }; return seen }
    static var stopCount: Int { lock.lock(); defer { lock.unlock() }; return stopped }
    /// Ends every hanging load with `error`, as the network or the transport's timeout would later (#787: no test waits
    /// for the real 20-second timeout).
    static func failHung(_ error: URLError) {
        lock.lock(); let loads = hung; hung = []; lock.unlock()
        for load in loads { load.client?.urlProtocol(load, didFailWithError: error) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        Self.lock.lock()
        Self.seen.append((request, body))
        let outcome = Self.outcomes.isEmpty ? Outcome.fail(URLError(.unknown)) : Self.outcomes.removeFirst()
        // #787 i787-fix1: a hanging load is registered in the same critical section that makes its request visible, so
        // a test that has seen the request can always end the load with `failHung`.
        if case .hang = outcome { Self.hung.append(self) }
        let afterRecord = Self.afterRecord
        Self.lock.unlock()
        afterRecord?()
        switch outcome {
        case .respond(let status, let data):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .bare(let data):
            // A custom protocol may answer without an HTTP status line; URLSession itself never does for https.
            let response = URLResponse(url: request.url!, mimeType: "application/json", expectedContentLength: data.count,
                                       textEncodingName: nil)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .redirect(let status, let location):
            // A 30x that points somewhere else. Following it would start a new load, which this stub records.
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": location])!
            var next = URLRequest(url: URL(string: location)!)
            next.httpMethod = request.httpMethod
            next.httpBody = body
            next.allHTTPHeaderFields = request.allHTTPHeaderFields
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data())
            client?.urlProtocolDidFinishLoading(self)
        case .fail(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .hang:
            break
        }
    }

    override func stopLoading() {
        Self.lock.lock(); Self.stopped += 1; Self.lock.unlock()
    }
}

private func stubbedTransport(timeout: TimeInterval = 20) -> URLSessionHTTPTransport {
    URLSessionHTTPTransport(timeout: timeout, protocolClasses: [StubURLProtocol.self])
}

private func pngImage() throws -> Data {
    let context = try #require(CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

private struct LocalWords: OnDeviceTextRecognitionProviding {
    func recognise(_ image: Data) async throws(TextRecognitionError) -> String { "local words" }
}
private struct AllowedSettings: CloudRecognitionSettings {
    func options() async -> CloudRecognitionOptions { .init(enabled: true, consent: .granted, online: true) }
}
private struct SavedKeys: CloudCredentialStore {
    func credentials() async -> CloudCredentials? { CloudCredentials(apiKey: "api", secretKey: "secret") }
}

private let tokenBody = Data(#"{"access_token":"TOKEN","expires_in":2592000}"#.utf8)
private let wordsBody = Data(#"{"words_result":[{"words":"雲"}]}"#.utf8)

@Suite(.serialized) struct Issue689URLSessionTransportTests {
    @Test(.timeLimit(.minutes(2)))
    func issue689TransportSendsRequestAsShaped() async throws {
        StubURLProtocol.reset([.respond(201, Data("answer".utf8))])
        var request = URLRequest(url: URL(string: "https://aip.baidubce.com/oauth/2.0/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("grant_type=client_credentials&client_id=a&client_secret=b".utf8)
        let response = try await stubbedTransport().send(request, to: .baiduOCR)
        #expect(response.statusCode == 201)
        #expect(response.body == Data("answer".utf8))
        let seen = try #require(StubURLProtocol.requests.first)
        #expect(StubURLProtocol.requests.count == 1)
        #expect(seen.request.httpMethod == "POST")
        #expect(seen.request.url?.absoluteString == "https://aip.baidubce.com/oauth/2.0/token")
        #expect(seen.request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(seen.request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(seen.body == Data("grant_type=client_credentials&client_id=a&client_secret=b".utf8))
    }

    @Test(.timeLimit(.minutes(2)))
    func issue689TransportMapsAResponseWithoutStatusToZero() async throws {
        StubURLProtocol.reset([.bare(Data("odd".utf8))])
        let request = URLRequest(url: URL(string: "https://aip.baidubce.com/oauth/2.0/token")!)
        let response = try await stubbedTransport().send(request, to: .baiduOCR)
        // Status 0 is outside 200..<300, so the provider takes its failure path instead of trapping.
        #expect(response.statusCode == 0)
        #expect(response.body == Data("odd".utf8))
    }

    @Test(.timeLimit(.minutes(2)))
    func issue689TransportCarriesProviderRequestsAndStatus() async throws {
        let image = try pngImage()
        // Success: token, then OCR; both go through the real transport, shaped by slice A.
        StubURLProtocol.reset([.respond(200, tokenBody), .respond(200, wordsBody)])
        let provider = BaiduTextRecognitionProvider(transport: stubbedTransport())
        let text = try await provider.recognise(image, credentials: CloudCredentials(apiKey: "api", secretKey: "secret"))
        #expect(text == "雲")
        let seen = StubURLProtocol.requests
        #expect(seen.count == 2)
        #expect(seen.map { $0.request.url?.path } == ["/oauth/2.0/token", "/rest/2.0/ocr/v1/general_basic"])
        #expect(seen[1].request.url?.query == "access_token=TOKEN")
        #expect(String(data: seen[1].body, encoding: .utf8)?.hasPrefix("image=") == true)

        // A server error page and a quota error reach slice A's mapping unchanged.
        StubURLProtocol.reset([.respond(200, tokenBody), .respond(500, Data("<html>busy</html>".utf8))])
        await #expect(throws: TextRecognitionError.cloudFailure) {
            try await BaiduTextRecognitionProvider(transport: stubbedTransport())
                .recognise(image, credentials: CloudCredentials(apiKey: "api", secretKey: "secret"))
        }
        StubURLProtocol.reset([.respond(200, tokenBody), .respond(200, Data(#"{"error_code":17,"error_msg":"limit"}"#.utf8))])
        await #expect(throws: TextRecognitionError.cloudQuota) {
            try await BaiduTextRecognitionProvider(transport: stubbedTransport())
                .recognise(image, credentials: CloudCredentials(apiKey: "api", secretKey: "secret"))
        }
        StubURLProtocol.reset([.respond(401, Data(#"{"error":"invalid_client"}"#.utf8))])
        await #expect(throws: TextRecognitionError.cloudAuth) {
            try await BaiduTextRecognitionProvider(transport: stubbedTransport())
                .recognise(image, credentials: CloudCredentials(apiKey: "api", secretKey: "secret"))
        }
    }

    @Test(.timeLimit(.minutes(2)))
    func issue689TransportTimeoutFallsBackOffline() async throws {
        StubURLProtocol.reset([.hang])
        let started = Date()
        let service = TextRecognitionService(onDevice: LocalWords(), settings: AllowedSettings(), credentialStore: SavedKeys(),
                                             cloud: BaiduTextRecognitionProvider(transport: stubbedTransport(timeout: 0.5)))
        let result = try await service.recognise(try pngImage(), intent: .explicit)
        #expect(result.engine == .onDevice)
        #expect(result.text == "local words")
        #expect(result.fallbackReason == .offline)
        #expect(Date().timeIntervalSince(started) < 15)
        #expect(StubURLProtocol.requests.count == 1)
    }

    @Test(.timeLimit(.minutes(2)))
    func issue689TransportOfflineErrorFallsBackOffline() async throws {
        StubURLProtocol.reset([.fail(URLError(.notConnectedToInternet))])
        let service = TextRecognitionService(onDevice: LocalWords(), settings: AllowedSettings(), credentialStore: SavedKeys(),
                                             cloud: BaiduTextRecognitionProvider(transport: stubbedTransport()))
        let result = try await service.recognise(try pngImage(), intent: .explicit)
        #expect(result.engine == .onDevice)
        #expect(result.fallbackReason == .offline)
    }

    @Test(.timeLimit(.minutes(2)))
    func issue689TransportCancellationIsCancelled() async throws {
        StubURLProtocol.reset([.hang])
        let transport = stubbedTransport()
        let task = Task {
            var request = URLRequest(url: URL(string: "https://aip.baidubce.com/oauth/2.0/token")!)
            request.httpMethod = "POST"
            return try await transport.send(request, to: .baiduOCR)
        }
        // Up to 10 s for the load to start (it ends early); the count check below must not race a slow runner.
        for _ in 0..<2000 {
            if !StubURLProtocol.requests.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(StubURLProtocol.requests.count == 1)
        let cancelledAt = Date()
        task.cancel()
        let outcome = await task.result
        // Cancelling stops the request now, not at the 20-second timeout.
        #expect(Date().timeIntervalSince(cancelledAt) < 5)
        let error = try #require(outcome.failureValue)
        #expect(error is CancellationError || (error as? URLError)?.code == .cancelled)

        // Through the provider and service: cancelled, never an on-device fallback.
        StubURLProtocol.reset([.hang])
        let service = TextRecognitionService(onDevice: LocalWords(), settings: AllowedSettings(), credentialStore: SavedKeys(),
                                             cloud: BaiduTextRecognitionProvider(transport: stubbedTransport()))
        let image = try pngImage()
        let recognition = Task { try await service.recognise(image, intent: .explicit) }
        for _ in 0..<2000 {
            if !StubURLProtocol.requests.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        // The token load is registered with the request, so failHung below always reaches it (#787 i787-fix1).
        try #require(StubURLProtocol.requests.count == 1)
        let recognitionCancelledAt = Date()
        recognition.cancel()
        StubURLProtocol.failHung(URLError(.timedOut))
        let recognised = await recognition.result
        #expect(recognised.failureValue as? TextRecognitionError == .cancelled)
        // #787: the test ends the hung token load itself instead of waiting for the transport's 20-second timeout.
        #expect(Date().timeIntervalSince(recognitionCancelledAt) < 15)

        // Cancelled during the OCR upload: the request stops at once, and the result is cancelled, not on-device.
        // (A cancelled token exchange still waits for the shared token task; slice A Still open N3.)
        StubURLProtocol.reset([.respond(200, tokenBody), .hang])
        let upload = Task { try await service.recognise(image, intent: .explicit) }
        for _ in 0..<200 {
            if StubURLProtocol.requests.count == 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(StubURLProtocol.requests.count == 2)
        let uploadCancelledAt = Date()
        upload.cancel()
        let uploaded = await upload.result
        #expect(Date().timeIntervalSince(uploadCancelledAt) < 5)
        #expect(uploaded.failureValue as? TextRecognitionError == .cancelled)
        // stopLoading can arrive after the cancelled result (#904).
        #expect(try await stopReached { StubURLProtocol.stopCount })
    }

    @Test(.timeLimit(.minutes(2)), arguments: [
        "http://aip.baidubce.com/oauth/2.0/token",
        "https://example.com/oauth/2.0/token",
        "https://aip.baidubce.com.example.com/oauth/2.0/token",
        "https://aip.baidubce.com/rest/2.0/ocr/v1/general",
        "https://aip.baidubce.com:8443/oauth/2.0/token",
        "https://user@aip.baidubce.com/oauth/2.0/token",
    ])
    func issue689TransportRefusesOtherRequests(_ address: String) async throws {
        StubURLProtocol.reset([.respond(200, tokenBody)])
        await #expect(throws: URLSessionHTTPTransport.Refusal.notBaiduOCR) {
            try await stubbedTransport().send(URLRequest(url: URL(string: address)!), to: .baiduOCR)
        }
        #expect(StubURLProtocol.requests.isEmpty)
    }

    @Test(.timeLimit(.minutes(2)), arguments: [301, 302, 303, 307, 308])
    func issue689TransportRefusesRedirectsAndResendsNothing(_ status: Int) async throws {
        // The token request carries client_id/client_secret; a redirect must not carry them to another host.
        StubURLProtocol.reset([.redirect(status, "https://collector.example.com/steal"), .respond(200, tokenBody)])
        var request = URLRequest(url: URL(string: "https://aip.baidubce.com/oauth/2.0/token")!)
        request.httpMethod = "POST"
        request.httpBody = Data("grant_type=client_credentials&client_id=a&client_secret=b".utf8)
        // #890: the 30x comes back unfollowed, as the answer; the provider fails on it.
        #expect(try await stubbedTransport().send(request, to: .baiduOCR).statusCode == status)
        #expect(StubURLProtocol.requests.count == 1)
        #expect(StubURLProtocol.requests.allSatisfy { $0.request.url?.host == "aip.baidubce.com" })

        // A same-host redirect is refused too; Baidu's documented endpoints never redirect.
        StubURLProtocol.reset([.redirect(status, "https://aip.baidubce.com/rest/2.0/ocr/v1/general_basic"),
                               .respond(200, wordsBody)])
        #expect(try await stubbedTransport().send(request, to: .baiduOCR).statusCode == status)
        #expect(StubURLProtocol.requests.count == 1)

        // Through the provider: the image upload is redirected; the user gets the service error, and only Baidu saw it.
        StubURLProtocol.reset([.respond(200, tokenBody), .redirect(status, "https://collector.example.com/image"),
                               .respond(200, wordsBody)])
        await #expect(throws: TextRecognitionError.cloudFailure) {
            try await BaiduTextRecognitionProvider(transport: stubbedTransport())
                .recognise(try pngImage(), credentials: CloudCredentials(apiKey: "api", secretKey: "secret"))
        }
        #expect(StubURLProtocol.requests.count == 2)
        #expect(StubURLProtocol.requests.allSatisfy { $0.request.url?.host == "aip.baidubce.com" })
    }

    @Test(.timeLimit(.minutes(2)))
    func issue689TransportSessionIsEphemeralWithoutCookiesOrCache() throws {
        let configuration = URLSessionHTTPTransport().configuration
        #expect(configuration.timeoutIntervalForRequest == 20)
        #expect(configuration.timeoutIntervalForResource == 20)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(configuration.urlCache == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
        #expect(URLSessionHTTPTransport(timeout: 5).configuration.timeoutIntervalForRequest == 5)
    }
}

private extension Result {
    var failureValue: Failure? { if case .failure(let error) = self { error } else { nil } }
}
