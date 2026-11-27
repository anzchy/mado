import Foundation
import MadoCore

/// The one clipboard write Copy Table makes: an HTML table (bordered, for Word) and tab-separated text (Excel,
/// Numbers, plain-text editors) on the same item (spec #866 decision 9). False when the write failed.
@MainActor public protocol TableClipboardWriting: AnyObject {
    func writeTable(html: String, tabSeparated: String) -> Bool
}

/// A recognised table as the result panel shows it (state 41 `result`).
public struct RecognisedTableResult: Equatable, Sendable {
    public let table: RecognisedTable
    /// 「DeepSeek」 for the preset; a custom service is named by its host.
    public let serviceName: String
    /// Copy Table succeeded; 「表格已拷贝」 shows only then (story 45).
    public var copied: Bool

    public init(table: RecognisedTable, serviceName: String, copied: Bool = false) {
        self.table = table; self.serviceName = serviceName; self.copied = copied
    }
}

/// Where one Recognise Table run is (spec #866 testing decisions: setup needed, consent needed, working, result,
/// failure, cancelled). Only `working` has sent, or may be sending, anything.
public enum RecogniseTableState: Equatable, Sendable {
    case idle
    /// No usable address or no access key: nothing was sent (state 41 `setup`, #877 draws the dialog).
    case setupNeeded
    /// The global Allow Cloud Recognition switch is off: nothing was sent (state 41 `off`, #877).
    case cloudOff
    /// Waiting for the answer to the consent dialog that names `host` (state 41 `consent`).
    case consent(host: String)
    /// The image is with `host`; Cancel stops it (state 41 `working`).
    case working(host: String)
    case result(RecognisedTableResult)
    /// Refused before sending (format, size, settings changed meanwhile); #876 draws these.
    case notSent(TableRecognitionBlock)
    /// Sent, and the service's answer was not a table (#876 draws these).
    case failed(TableRecognitionFailure)
    /// Cancel was clicked while working. Never retried.
    case cancelled
}

/// Recognise Table from the viewer (#874): the switch, setup and per-host consent checks before anything is sent,
/// one request with Cancel, the result, and Copy Table. Nothing is copied or dismissed by itself.
@MainActor public final class RecogniseTableFlow {
    public private(set) var state: RecogniseTableState = .idle {
        didSet { if state != oldValue { onChange() } }
    }

    private let settings: any TableRecognitionSettings
    private let credentials: any TableRecognitionCredentialStore
    private let service: TableRecognitionService
    private let clipboard: any TableClipboardWriting
    private let recordConsent: @Sendable (String) async -> Void
    private let onChange: @MainActor () -> Void
    /// Moves on with every start, cancel and close, so a superseded run cannot change the state.
    private var run = UUID()
    private var request: Task<TableRecognitionResult, Never>?
    private var pendingImage: (@Sendable () async throws -> Data)?
    private var pendingService = ""
    /// The checks before consent are running: a second start is ignored until they end.
    private var checking = false

    public init(settings: any TableRecognitionSettings, credentials: any TableRecognitionCredentialStore,
                transport: any HTTPTransport, clipboard: any TableClipboardWriting,
                recordConsent: @escaping @Sendable (String) async -> Void,
                report: @escaping @Sendable (TableRecognitionDiagnostic) -> Void = TableRecognitionDiagnostic.record,
                onChange: @escaping @MainActor () -> Void = {}) {
        self.settings = settings
        self.credentials = credentials
        service = TableRecognitionService(settings: settings, credentials: credentials, transport: transport,
                                          report: report)
        self.clipboard = clipboard
        self.recordConsent = recordConsent
        self.onChange = onChange
    }

    /// Consent or working: a new run cannot start.
    public var isBusy: Bool {
        if checking { return true }
        switch state {
        case .consent, .working: return true
        default: return false
        }
    }

    /// Checks the switch, the address and key, and the consent for the host, in that order, reading each fresh;
    /// asks for consent when the host has none, otherwise sends. Ignored while a run is busy.
    @discardableResult
    public func start(image: @escaping @Sendable () async throws -> Data) -> Task<Void, Never> {
        guard !isBusy else { return Task {} }
        run = UUID()
        let thisRun = run
        checking = true
        state = .idle
        return Task { [weak self] in
            guard let self else { return }
            let options = await settings.options()
            let target = options.endpoint.flatMap { endpoint in
                TableRecognitionGuards.validURL(for: endpoint).map { (endpoint, $0.host) }
            }
            var key: String?
            if let target { key = await credentials.accessKey(for: target.0) }
            guard thisRun == run else { return }
            checking = false
            guard options.cloudEnabled else { state = .cloudOff; return }
            guard let target, !(key ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                state = .setupNeeded
                return
            }
            let (endpoint, rawHost) = target
            let host = TableRecognitionGuards.normalisedHost(rawHost)
            let serviceName = endpoint.preset == .deepSeek ? "DeepSeek" : host
            if TableRecognitionGuards.consentBlock(options.consent, host: host) != nil {
                pendingImage = image
                pendingService = serviceName
                state = .consent(host: host)
                return
            }
            await send(image, host: host, serviceName: serviceName, run: thisRun)
        }
    }

    /// The consent dialog's answer. Agreeing records consent for that host, then sends; declining sends and records
    /// nothing (story 27).
    @discardableResult
    public func answerConsent(_ granted: Bool) -> Task<Void, Never>? {
        guard case .consent(let host) = state, let image = pendingImage else { return nil }
        pendingImage = nil
        guard granted else { state = .idle; return nil }
        let thisRun = run
        let serviceName = pendingService
        state = .working(host: host)
        return Task { [weak self] in
            guard let self else { return }
            await recordConsent(host)
            guard thisRun == run else { return }
            await send(image, host: host, serviceName: serviceName, run: thisRun)
        }
    }

    /// One request, never retried. The service checks the switch, consent and key again before it sends.
    private func send(_ image: @escaping @Sendable () async throws -> Data, host: String, serviceName: String,
                      run thisRun: UUID) async {
        state = .working(host: host)
        let service = self.service
        let request = Task { () -> TableRecognitionResult in
            let data: Data
            do { data = try await image() } catch {
                return Task.isCancelled || error is CancellationError ? .cancelled : .notSent(.unsupportedImage)
            }
            return await service.recognise(data)
        }
        self.request = request
        let result = await request.value
        guard thisRun == run else { return }
        self.request = nil
        switch result {
        case .table(let rows):
            state = .result(RecognisedTableResult(table: RecognisedTable(rows: rows), serviceName: serviceName))
        case .notSent(.cloudOff): state = .cloudOff
        case .notSent(.noAccessKey), .notSent(.invalidEndpoint): state = .setupNeeded
        case .notSent(let block): state = .notSent(block)
        case .failed(let failure): state = .failed(failure)
        case .cancelled: state = .cancelled
        }
    }

    /// Cancel in the working sheet: the request is cancelled where it is (the transport call included) and its
    /// answer, whatever it is, is ignored. At the consent dialog it is the same as declining.
    public func cancel() {
        switch state {
        case .consent: answerConsent(false)
        case .working:
            run = UUID()
            request?.cancel()
            request = nil
            state = .cancelled
        default: break
        }
    }

    /// Copy Table: one write of HTML and tab-separated text from the table shown. Only a successful write says
    /// 「表格已拷贝」.
    @discardableResult public func copyTable() -> Bool {
        guard case .result(var result) = state,
              let payload = try? TableClipboardPayload.build(from: result.table),
              clipboard.writeTable(html: payload.html, tabSeparated: payload.tabSeparated) else { return false }
        result.copied = true
        state = .result(result)
        return true
    }

    /// The panel or the window closed: whatever is running stops, and nothing is left pending.
    public func close() {
        run = UUID()
        request?.cancel()
        request = nil
        pendingImage = nil
        checking = false
        state = .idle
    }
}
