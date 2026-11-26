import Foundation
import Testing
import MadoApplication
@testable import MadoInfrastructure

// #890 WI-2: the configured, consented table host passes the allow-list; any other host is refused before a
// connection (zero requests). Baidu's allow-list is not widened.

private let host890 = HTTPDestination.consentedHost(host: "host.example.com", port: nil)

extension Issue890TransportTests {
    @Test(.timeLimit(.minutes(2)))
    func issue890WI2TableRequestReachesTheConfiguredHostAsBuilt() async throws {
        Stub890.reset([.respond(200, table890)])
        let image = try png890(width: 3, height: 2)
        let result = await tableService890().recognise(image)
        #expect(result == .table(rows: [["A", "B"], ["1", "2"]]))
        let seen = Stub890.requests
        #expect(seen.count == 1)
        let wire = try #require(seen.first)
        // The bytes on the wire are the built request: URL, method, headers and the image, base64, in the body.
        #expect(wire.request.url?.absoluteString == "https://api.deepseek.com/chat/completions")
        #expect(wire.request.httpMethod == "POST")
        #expect(wire.request.value(forHTTPHeaderField: "Authorization") == "Bearer " + key890)
        #expect(wire.request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(wire.request.value(forHTTPHeaderField: "Cookie") == nil)
        let body = try #require(try JSONSerialization.jsonObject(with: wire.body) as? [String: Any])
        let messages = try #require(body["messages"] as? [[String: Any]])
        let parts = try #require(messages.first?["content"] as? [[String: Any]])
        let imageURL = try #require((parts.last?["image_url"] as? [String: Any])?["url"] as? String)
        #expect(imageURL == "data:image/png;base64," + image.base64EncodedString())
    }

    @Test(.timeLimit(.minutes(2)))
    func issue890WI2CustomHostWithPortReachesIt() async throws {
        Stub890.reset([.respond(200, table890)])
        let endpoint = TableRecognitionEndpoint(preset: .custom, baseURL: "https://GW.Example.com:8443/v1/", model: "m")
        let result = await tableService890(Settings890(endpoint: endpoint, consentHost: "gw.example.com"))
            .recognise(try png890(width: 3, height: 2))
        #expect(result == .table(rows: [["A", "B"], ["1", "2"]]))
        #expect(Stub890.requests.map { $0.request.url?.absoluteString } == ["https://GW.Example.com:8443/v1/chat/completions"])
    }

    @Test(.timeLimit(.minutes(2)), arguments: [
        "https://host.example.com/v1/chat/completions",
        "https://HOST.example.com/v1/chat/completions",
        "https://host.example.com./v1/chat/completions",
        "https://host.example.com:443/v1/chat/completions",
    ])
    func issue890WI2ConsentedHostVariantsPass(_ address: String) async throws {
        Stub890.reset([.respond(200, Data("ok".utf8))])
        let response = try await transport890().send(URLRequest(url: URL(string: address)!), to: host890)
        #expect(response.statusCode == 200)
        #expect(response.body == Data("ok".utf8))
        #expect(Stub890.requests.count == 1)
    }

    @Test(.timeLimit(.minutes(2)), arguments: [
        "http://host.example.com/v1/chat/completions",
        "https://evil.example.com/v1/chat/completions",
        "https://host.example.com:8443/v1/chat/completions",
        "https://a@host.example.com/v1/chat/completions",
        "https://a:b@host.example.com/v1/chat/completions",
        "https://host.example.com@evil.com/v1/chat/completions",
        "https://host.example.com.evil.com/v1/chat/completions",
        "https://sub.host.example.com/v1/chat/completions",
        "https://xhost.example.com/v1/chat/completions",
        "https://host.example.co/v1/chat/completions",
        "https://host.example.com../v1/chat/completions",
        "https://aip.baidubce.com/oauth/2.0/token",
    ])
    func issue890WI2OtherHostsAreRefusedBeforeAConnection(_ address: String) async throws {
        Stub890.reset([.respond(200, Data("ok".utf8))])
        await #expect(throws: URLSessionHTTPTransport.Refusal.notAllowedHost) {
            try await transport890().send(URLRequest(url: URL(string: address)!), to: host890)
        }
        #expect(Stub890.requests.isEmpty)
    }

    @Test(.timeLimit(.minutes(2)))
    func issue890WI2ConfiguredHostSpellingAndPortAreHonoured() async throws {
        // The configured host may itself carry case or a trailing dot.
        Stub890.reset([.respond(200, Data())])
        _ = try await transport890().send(URLRequest(url: URL(string: "https://host.example.com/x")!),
                                          to: .consentedHost(host: "HOST.Example.COM.", port: nil))
        #expect(Stub890.requests.count == 1)
        // A configured port admits that port only; 443 equals no port.
        let ported = HTTPDestination.consentedHost(host: "host.example.com", port: 8443)
        Stub890.reset([.respond(200, Data())])
        _ = try await transport890().send(URLRequest(url: URL(string: "https://host.example.com:8443/x")!), to: ported)
        #expect(Stub890.requests.count == 1)
        for address in ["https://host.example.com/x", "https://host.example.com:443/x", "https://host.example.com:8444/x"] {
            Stub890.reset([.respond(200, Data())])
            await #expect(throws: URLSessionHTTPTransport.Refusal.notAllowedHost) {
                try await transport890().send(URLRequest(url: URL(string: address)!), to: ported)
            }
            #expect(Stub890.requests.isEmpty, "\(address)")
        }
        Stub890.reset([.respond(200, Data())])
        _ = try await transport890().send(URLRequest(url: URL(string: "https://host.example.com/x")!),
                                          to: .consentedHost(host: "host.example.com", port: 443))
        #expect(Stub890.requests.count == 1)
        // An empty configured host admits nothing.
        Stub890.reset([.respond(200, Data())])
        await #expect(throws: URLSessionHTTPTransport.Refusal.notAllowedHost) {
            try await transport890().send(URLRequest(url: URL(string: "https://host.example.com/x")!), to: .consentedHost(host: "", port: nil))
        }
        #expect(Stub890.requests.isEmpty)
    }

    @Test(.timeLimit(.minutes(2)))
    func issue890WI2InternationalHostMatchesInEitherSpellingOnly() async throws {
        let idn = HTTPDestination.consentedHost(host: "bücher.example", port: nil)
        for address in ["https://xn--bcher-kva.example/x", "https://bücher.example/x"] {
            Stub890.reset([.respond(200, Data())])
            _ = try await transport890().send(URLRequest(url: URL(string: address)!), to: idn)
            #expect(Stub890.requests.count == 1, "\(address)")
        }
        for address in ["https://bucher.example/x", "https://xn--bcher-kva.example.evil.com/x"] {
            Stub890.reset([.respond(200, Data())])
            await #expect(throws: URLSessionHTTPTransport.Refusal.notAllowedHost) {
                try await transport890().send(URLRequest(url: URL(string: address)!), to: idn)
            }
            #expect(Stub890.requests.isEmpty, "\(address)")
        }
    }

    @Test(.timeLimit(.minutes(2)))
    func issue890WI2BaiduAllowListIsNotWidened() async throws {
        // Baidu's destination still admits only its two endpoints: a table host is refused under it.
        Stub890.reset([.respond(200, Data())])
        await #expect(throws: URLSessionHTTPTransport.Refusal.notBaiduOCR) {
            try await transport890().send(URLRequest(url: URL(string: "https://api.deepseek.com/chat/completions")!),
                                          to: .baiduOCR)
        }
        #expect(Stub890.requests.isEmpty)
        Stub890.reset([.respond(200, Data())])
        _ = try await transport890().send(URLRequest(url: URL(string: BaiduTextRecognitionProvider.tokenEndpoint)!),
                                          to: .baiduOCR)
        #expect(Stub890.hosts == ["aip.baidubce.com"])
    }

    @Test(.timeLimit(.minutes(2)))
    func issue890WI2RefusalCarriesNoRequestDetail() async throws {
        Stub890.reset([])
        var request = URLRequest(url: URL(string: "https://evil.example.com/v1/chat/completions?k=\(key890)")!)
        request.setValue("Bearer " + key890, forHTTPHeaderField: "Authorization")
        request.httpBody = Data("IMAGEBYTES-890".utf8)
        do {
            _ = try await transport890().send(request, to: host890)
            Issue.record("expected a refusal")
        } catch {
            let text = String(describing: error) + String(reflecting: error) + error.localizedDescription
            for secret in [key890, "evil.example.com", "IMAGEBYTES-890", "host.example.com"] {
                #expect(!text.contains(secret))
            }
        }
        #expect(Stub890.requests.isEmpty)
    }
}
