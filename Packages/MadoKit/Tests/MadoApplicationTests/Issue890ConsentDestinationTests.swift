import Foundation
import Testing
@testable import MadoApplication

// #890 WI-5 (review M): the destination names the host from the consent record, not one read back from the request,
// so the transport's allow-list checks the request against what the user consented to.

@Test(.timeLimit(.minutes(2)), arguments: [
    ("https://gw.example.com/v1", "GW.Example.COM", nil as Int?),
    ("https://gw.example.com:8443/v1", "gw.example.com.", 8443 as Int?),
])
func issue890WI5DestinationIsTheConsentedHost(base: String, consent: String, port: Int?) async throws {
    let endpoint = TableRecognitionEndpoint.custom869(base)
    let transport = RecordingTransport869()
    let service = makeService869(settings: FakeTableSettings869(.options869(endpoint: endpoint, consentHost: consent)),
                                 keys: FakeTableKeys869([endpoint: "sk-test-custom-0001"]), transport: transport)
    #expect(await service.recognise(makePNG869(3, 2)) == .table(rows: [["A", "B"], ["1", "2"]]))
    #expect(await transport.destinations == [.consentedHost(host: consent, port: port)])
}
