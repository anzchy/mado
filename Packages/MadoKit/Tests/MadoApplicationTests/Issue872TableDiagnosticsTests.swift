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

@Test(.timeLimit(.minutes(2)))
func issue872FailureDiagnosticsUseFixedClassAndUnknownForMissingCounts() async {
    let message = "PRIVATE_SERVER_TEXT_872 https://user:password@gw.example.com/v1 PRIVATE_KEY_872"
    let body = try! JSONSerialization.data(withJSONObject: [
        "error": ["message": message], "usage": ["prompt_tokens": 5, "completion_tokens": -9]
    ])
    let reports = TableDiagnostics872()
    let transport = RecordingTransport869([.response(HTTPResponse(statusCode: 429, body: body)),
                                           .failure(NSError(domain: message, code: 9))])
    let service = TableRecognitionService(settings: FakeTableSettings869(), credentials: FakeTableKeys869(),
        transport: transport, report: { reports.append($0) })

    #expect(await service.recognise(makePNG869(3, 2)) == .failed(.quotaOrBalance))
    #expect(await service.recognise(makePNG869(3, 2)) == .failed(.other))
    let recorded = reports.all
    #expect(recorded.count == 2)
    guard recorded.count == 2 else { return }
    #expect(recorded[0].promptTokens == 5)
    #expect(recorded[0].completionTokens == nil)
    #expect(recorded[0].errorClass == .quotaOrBalance)
    #expect(recorded[1].promptTokens == nil && recorded[1].completionTokens == nil)
    #expect(recorded[1].errorClass == .other)
    #expect(recorded[0].logMessage.contains("error=quotaOrBalance"))
    #expect(recorded[1].logMessage.contains("prompt_tokens=unknown completion_tokens=unknown"))
    for diagnostic in recorded {
        #expect(!diagnostic.logMessage.contains(message))
        #expect(!diagnostic.logMessage.contains("user:password"))
        #expect(!diagnostic.logMessage.contains("PRIVATE_KEY_872"))
    }
}

@Test(.timeLimit(.minutes(2)))
func issue872NoRequestMeansNoDiagnosticEvenForCredentialedAddress() async {
    let endpoint = TableRecognitionEndpoint.custom869("https://user:password@gw.example.com/v1")
    let settings = FakeTableSettings869(.options869(endpoint: endpoint, consentHost: "gw.example.com"))
    let reports = TableDiagnostics872()
    let transport = RecordingTransport869()
    let service = TableRecognitionService(settings: settings, credentials: FakeTableKeys869(),
        transport: transport, report: { reports.append($0) })

    #expect(await service.recognise(makePNG869(3, 2)) == .notSent(.invalidEndpoint))
    #expect(await service.testService() == .notSent(.invalidEndpoint))
    #expect(await transport.callCount == 0)
    #expect(reports.all.isEmpty)
}

@Test(.timeLimit(.minutes(2)))
func issue872SettingsTestReportsFinalSampleFailureOnce() async {
    let reports = TableDiagnostics872()
    let service = TableRecognitionService(settings: FakeTableSettings869(), credentials: FakeTableKeys869(),
        transport: RecordingTransport869(), report: { reports.append($0) })
    #expect(await service.testService() == .failed(.other))
    let recorded = reports.all
    #expect(recorded.count == 1)
    guard let diagnostic = recorded.first else { return }
    #expect(diagnostic.errorClass == .other)
    #expect(diagnostic.promptTokens == nil && diagnostic.completionTokens == nil)
    #expect(diagnostic.logMessage.contains("error=other"))
}

@Test(.timeLimit(.minutes(2)))
func issue872RequestBuiltInitializerUsesDefaultRecorderAfterSend() async {
    let transport = RecordingTransport869([.response(HTTPResponse(statusCode: 429, body: Data()))])
    let service = TableRecognitionService(settings: FakeTableSettings869(), credentials: FakeTableKeys869(),
        transport: transport, requestBuilt: {})

    #expect(await service.recognise(makePNG869(3, 2)) == .failed(.quotaOrBalance))
    #expect(await transport.callCount == 1)
}
