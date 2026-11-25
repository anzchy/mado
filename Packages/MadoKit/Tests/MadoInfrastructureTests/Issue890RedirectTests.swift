import Foundation
import Testing
import MadoApplication
@testable import MadoInfrastructure

// #890 WI-3: a redirect is never followed; the transport returns the 3xx, and both services classify it as a failure.
// Nothing reaches the redirect target: not the image, not the key.

private let tableHost890 = HTTPDestination.consentedHost(host: "api.deepseek.com", port: nil)
private let tableURL890 = URL(string: "https://api.deepseek.com/chat/completions")!

extension Issue890TransportTests {
    @Test(.timeLimit(.minutes(2)), arguments: [301, 302, 303, 307, 308])
    func issue890WI3TransportReturnsTheRedirectUnfollowed(_ status: Int) async throws {
        for location in ["https://collector.example.com/steal", "https://api.deepseek.com/v2/chat/completions",
                         "/elsewhere"] {
            Stub890.reset([.redirect(status, location, Data("<a>moved</a>".utf8)), .respond(200, table890)])
            var request = URLRequest(url: tableURL890)
            request.httpMethod = "POST"
            request.httpBody = Data("secret-image".utf8)
            let response = try await transport890().send(request, to: tableHost890)
            #expect(response.statusCode == status, "\(location)")
            #expect(response.body == Data("<a>moved</a>".utf8), "\(location)")
            #expect(Stub890.hosts == ["api.deepseek.com"], "\(location)")
        }
        // Baidu's destination: same report.
        Stub890.reset([.redirect(status, "https://collector.example.com/steal", Data()), .respond(200, Data())])
        let baidu = try await transport890().send(URLRequest(url: URL(string: BaiduTextRecognitionProvider.tokenEndpoint)!),
                                                  to: .baiduOCR)
        #expect(baidu.statusCode == status)
        #expect(Stub890.hosts == ["aip.baidubce.com"])
    }

    @Test(.timeLimit(.minutes(2)))
    func issue890WI3ChainAndBareThreeHundredsStopAtTheFirstAnswer() async throws {
        Stub890.reset([.redirect(302, "https://api.deepseek.com/a", Data()),
                       .redirect(302, "https://collector.example.com/b", Data()), .respond(200, table890)])
        #expect(try await transport890().send(URLRequest(url: tableURL890), to: tableHost890).statusCode == 302)
        #expect(Stub890.requests.count == 1)
        for status in [300, 302, 304, 399] {
            Stub890.reset([.respond(status, Data("x".utf8))])
            let response = try await transport890().send(URLRequest(url: tableURL890), to: tableHost890)
            #expect(response.statusCode == status)
            #expect(Stub890.requests.count == 1)
        }
    }

    @Test(.timeLimit(.minutes(2)), arguments: [301, 302, 303, 307, 308])
    func issue890WI3TableServiceRedirectIsAddressUnreachableAndOnlyTheHostSawIt(_ status: Int) async throws {
        Stub890.reset([.redirect(status, "https://collector.example.com/steal", table890), .respond(200, table890)])
        let result = await tableService890().recognise(try png890(width: 3, height: 2))
        #expect(result == .failed(.addressUnreachable))
        #expect(Stub890.hosts == ["api.deepseek.com"])
        // No 3xx without Location is a table either.
        Stub890.reset([.respond(status, table890)])
        #expect(await tableService890().recognise(try png890(width: 3, height: 2)) == .failed(.addressUnreachable))
        #expect(Stub890.requests.count == 1)
    }

    @Test(.timeLimit(.minutes(2)), arguments: [301, 302, 303, 307, 308])
    func issue890WI3BaiduRedirectIsTheSameFailureAsBefore(_ status: Int) async throws {
        let tokenBody = Data(#"{"access_token":"TOKEN","expires_in":2592000}"#.utf8)
        let words = Data(#"{"words_result":[{"words":"x"}]}"#.utf8)
        let credentials = CloudCredentials(apiKey: "api", secretKey: "secret")
        // Token exchange redirected: the keys go nowhere else.
        Stub890.reset([.redirect(status, "https://collector.example.com/keys", tokenBody), .respond(200, tokenBody)])
        let tokenDetails = Details890()
        await #expect(throws: TextRecognitionError.cloudFailure) {
            try await BaiduTextRecognitionProvider(transport: transport890(), onFailure: tokenDetails.append)
                .recognise(try png890(), credentials: credentials)
        }
        #expect(Stub890.hosts == ["aip.baidubce.com"])
        #expect(tokenDetails.all == [CloudFailureDetail(stage: .token, transportError: "refused redirected")])
        // Upload redirected: the image goes nowhere else.
        Stub890.reset([.respond(200, tokenBody), .redirect(status, "https://collector.example.com/image", words),
                       .respond(200, words)])
        let uploadDetails = Details890()
        await #expect(throws: TextRecognitionError.cloudFailure) {
            try await BaiduTextRecognitionProvider(transport: transport890(), onFailure: uploadDetails.append)
                .recognise(try png890(), credentials: credentials)
        }
        #expect(Stub890.hosts == ["aip.baidubce.com", "aip.baidubce.com"])
        #expect(uploadDetails.all == [CloudFailureDetail(stage: .recognition, transportError: "refused redirected")])
    }
}
