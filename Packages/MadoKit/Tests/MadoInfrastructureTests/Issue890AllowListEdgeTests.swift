import Foundation
import Testing
import MadoApplication
@testable import MadoInfrastructure

// #890 review L: more spellings at the allow-list. Upper-case scheme and a zero-padded 443 are the same origin; an IP
// literal is another host.

extension Issue890TransportTests {
    @Test(.timeLimit(.minutes(2)), arguments: [
        ("HTTPS://host.example.com/x", true),
        ("https://host.example.com:0443/x", true),
        ("https://[::1]/x", false),
        ("https://127.0.0.1/x", false),
        ("https://host.example.com:80/x", false),
    ])
    func issue890WI5AllowListEdgeSpellings(_ address: String, _ admitted: Bool) async throws {
        Stub890.reset([.respond(200, Data())])
        let outcome = await Task {
            try await transport890().send(URLRequest(url: URL(string: address)!),
                                          to: .consentedHost(host: "host.example.com", port: nil))
        }.result
        if admitted {
            #expect((try? outcome.get())?.statusCode == 200, "\(address)")
            #expect(Stub890.requests.count == 1, "\(address)")
        } else {
            guard case .failure(let error) = outcome else { Issue.record("admitted \(address)"); return }
            #expect(error as? URLSessionHTTPTransport.Refusal == .notAllowedHost)
            #expect(Stub890.requests.isEmpty, "\(address)")
        }
    }
}
