import Foundation
import Testing
@testable import MadoApplication

// #869 WI-4: a redirect is an answer, not an instruction (AC-3). The service sends once, to the configured host,
// and never on to the address a 3xx names. Whether the real transport follows redirects is owed by INT-1 (c).

private let tableBody = String(decoding: chatReply869(content: goodTable869), as: UTF8.self)

@Test(.timeLimit(.minutes(2)), arguments: [301, 302, 303, 307, 308])
func issue869WI4RedirectStatusesFailAsUnreachable(status: Int) async {
    let transport = RecordingTransport869([reply869(status, "Location: https://evil.example/chat/completions\n" + tableBody)])
    let result = await makeService869(transport: transport).recognise(makePNG869(3, 2))
    #expect(result == .failed(.addressUnreachable))
    let requests = await transport.requests
    #expect(requests.count == 1)
    #expect(requests.allSatisfy { $0.url?.host == "api.deepseek.com" })
}

@Test(.timeLimit(.minutes(2)))
func issue869WI4EveryThreeHundredStatusIsUnreachable() async {
    let png = makePNG869(3, 2)
    let custom = TableRecognitionEndpoint.custom869()
    for (endpoint, host) in [(TableRecognitionEndpoint.deepSeekDefault869, "api.deepseek.com"), (custom, "gw.example.com")] {
        for status in 300...399 {
            let transport = RecordingTransport869([reply869(status, tableBody)])
            let result = await makeService869(settings: FakeTableSettings869(.options869(endpoint: endpoint, consentHost: host)),
                                              keys: FakeTableKeys869([endpoint: "sk-1"]), transport: transport).recognise(png)
            #expect(result == .failed(.addressUnreachable), "\(status) \(host)")
            let requests = await transport.requests
            #expect(requests.count == 1, "\(status) \(host)")
            #expect(requests.allSatisfy { $0.url?.host == host }, "\(status) \(host)")
        }
    }
}
