import Foundation
import Testing
@testable import MadoApplication

// #890 WI-1: the table service names the host its request may go to, with every request, and only after the consent
// guard passed. The transport refuses any other host (WI-2, MadoInfrastructureTests).

@Test(.timeLimit(.minutes(2)))
func issue890WI1DeepSeekRequestNamesTheConsentedHost() async throws {
    let transport = RecordingTransport869()
    let result = await makeService869(transport: transport).recognise(makePNG869(3, 2))
    #expect(result == .table(rows: [["A", "B"], ["1", "2"]]))
    #expect(await transport.destinations == [.consentedHost(host: "api.deepseek.com", port: nil)])
}

@Test(.timeLimit(.minutes(2)), arguments: [
    ("https://gw.example.com:8443/v1", "gw.example.com", "gw.example.com", 8443 as Int?),
    ("https://GW.Example.com/v1", "gw.example.com", "GW.Example.com", nil),
    ("https://gw.example.com./v1/", "gw.example.com", "gw.example.com.", nil),
])
func issue890WI1CustomRequestNamesTheConfiguredHostAndPort(base: String, consent: String, host: String,
                                                           port: Int?) async throws {
    let endpoint = TableRecognitionEndpoint.custom869(base)
    let transport = RecordingTransport869()
    let service = makeService869(settings: FakeTableSettings869(.options869(endpoint: endpoint, consentHost: consent)),
                                 keys: FakeTableKeys869([endpoint: "sk-test-custom-0001"]), transport: transport)
    #expect(await service.recognise(makePNG869(3, 2)) == .table(rows: [["A", "B"], ["1", "2"]]))
    #expect(await transport.destinations == [.consentedHost(host: consent, port: port)])
    // The request goes to the configured spelling of that same host.
    let url = try #require(await transport.requests.first?.url)
    #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.host == host)
}

@Test(.timeLimit(.minutes(2)))
func issue890WI1SettingsTestNamesTheConsentedHost() async throws {
    let transport = RecordingTransport869()
    _ = await makeService869(transport: transport).testService()
    #expect(await transport.destinations == [.consentedHost(host: "api.deepseek.com", port: nil)])
}
