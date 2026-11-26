import Foundation
import Testing
@testable import MadoApplication

private final class TableDiagnostics872: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TableRecognitionDiagnostic] = []
    func append(_ value: TableRecognitionDiagnostic) { lock.lock(); values.append(value); lock.unlock() }
    var all: [TableRecognitionDiagnostic] { lock.lock(); defer { lock.unlock() }; return values }
}

private struct DelayedTableTransport872: HTTPTransport {
    let response: HTTPResponse
    func send(_ request: URLRequest, to destination: HTTPDestination) async throws -> HTTPResponse {
        try await Task.sleep(for: .milliseconds(20))
        return response
    }
}

@Test(.timeLimit(.minutes(2)))
func issue872SentTableRequestReportsCountsTimingWithoutPayload() async {
    let image = makePNG869(3, 2)
    let cell = "PRIVATE_CELL_872"
    let key = "PRIVATE_KEY_872"
    let credentialedURL = "https://user:password@gw.example.com/v1"
    let table = "| A | B |\n|---|---|\n| \(cell) | \(credentialedURL) |"
    let message: [String: Any] = ["role": "assistant", "content": table]
    let body = try! JSONSerialization.data(withJSONObject: [
        "choices": [["message": message, "finish_reason": "stop"]],
        "usage": ["prompt_tokens": 17, "completion_tokens": 11]
    ])
    let endpoint = TableRecognitionEndpoint.custom869()
    let settings = FakeTableSettings869(.options869(endpoint: endpoint, consentHost: "gw.example.com"))
    let credentials = FakeTableKeys869([endpoint: key])
    let reports = TableDiagnostics872()
    let service = TableRecognitionService(settings: settings, credentials: credentials,
        transport: DelayedTableTransport872(response: HTTPResponse(statusCode: 200, body: body)),
        report: { reports.append($0) })

    let result = await service.recognise(image)
    guard case .table = result else { Issue.record("Expected a table, got \(result)"); return }
    let diagnostic = reports.all.first
    #expect(reports.all.count == 1)
    #expect(diagnostic?.promptTokens == 17)
    #expect(diagnostic?.completionTokens == 11)
    #expect((diagnostic?.durationMilliseconds ?? -1) >= 15)
    #expect(diagnostic?.errorClass == nil)
    let output = diagnostic?.logMessage ?? ""
    #expect(output.contains("prompt_tokens=17"))
    #expect(output.contains("completion_tokens=11"))
    #expect(output.contains("duration_ms="))
    #expect(output.contains("error=none"))
    for secret in [image.base64EncodedString(), String(decoding: image, as: UTF8.self),
                   cell, key, credentialedURL, endpoint.baseURL, table] {
        #expect(!output.contains(secret), "Diagnostics leaked a request or response value")
    }
}
