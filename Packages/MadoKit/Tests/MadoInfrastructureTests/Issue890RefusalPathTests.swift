import Foundation
import Testing
import MadoApplication
@testable import MadoInfrastructure

// #890: a request without a URL is refused under either destination; the Baidu provider logs a refusal by its case
// name only.

extension Issue890TransportTests {
    @Test(.timeLimit(.minutes(2)))
    func issue890RequestWithoutAURLIsRefused() async throws {
        var request = URLRequest(url: URL(string: "https://api.deepseek.com/chat/completions")!)
        request.url = nil
        Stub890.reset([.respond(200, Data())])
        await #expect(throws: URLSessionHTTPTransport.Refusal.notAllowedHost) {
            try await transport890().send(request, to: .consentedHost(host: "api.deepseek.com", port: nil))
        }
        await #expect(throws: URLSessionHTTPTransport.Refusal.notBaiduOCR) {
            try await transport890().send(request, to: .baiduOCR)
        }
        #expect(Stub890.requests.isEmpty)
    }
}

private struct Refusing890: HTTPTransport {
    let refusal: URLSessionHTTPTransport.Refusal
    func send(_ request: URLRequest, to destination: HTTPDestination) async throws -> HTTPResponse { throw refusal }
}

@Test(.timeLimit(.minutes(2)), arguments: [URLSessionHTTPTransport.Refusal.notBaiduOCR, .notAllowedHost])
func issue890BaiduLogsATransportRefusalByName(_ refusal: URLSessionHTTPTransport.Refusal) async throws {
    let details = Details890()
    await #expect(throws: TextRecognitionError.cloudFailure) {
        try await BaiduTextRecognitionProvider(transport: Refusing890(refusal: refusal), onFailure: details.append)
            .recognise(try png890(), credentials: CloudCredentials(apiKey: "api", secretKey: "secret"))
    }
    #expect(details.all == [CloudFailureDetail(stage: .token, transportError: "refused \(refusal)")])
}
