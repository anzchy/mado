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
    public private(set) var state: RecogniseTableState = .idle

    public init(settings: any TableRecognitionSettings, credentials: any TableRecognitionCredentialStore,
                transport: any HTTPTransport, clipboard: any TableClipboardWriting,
                recordConsent: @escaping @Sendable (String) async -> Void,
                report: @escaping @Sendable (TableRecognitionDiagnostic) -> Void = TableRecognitionDiagnostic.record,
                onChange: @escaping @MainActor () -> Void = {}) {}

    /// Consent or working: a new run cannot start.
    public var isBusy: Bool { false }

    @discardableResult
    public func start(image: @escaping @Sendable () async throws -> Data) -> Task<Void, Never> { Task {} }

    public func answerConsent(_ granted: Bool) -> Task<Void, Never>? { nil }

    public func cancel() {}

    @discardableResult public func copyTable() -> Bool { false }

    public func close() {}
}
