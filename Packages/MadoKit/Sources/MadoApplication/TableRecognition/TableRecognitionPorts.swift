import Foundation

/// How requests are shaped: DeepSeek gets its own fields (thinking off, temperature 0); Custom gets standard
/// OpenAI-compatible fields only (spec #866, decision 6).
public enum TableRecognitionPreset: String, Sendable, Hashable { case deepSeek, custom }

/// The table service the user configured: preset, address and model. The address is kept as the user typed it, so
/// an unusable one can be refused before anything is sent.
public struct TableRecognitionEndpoint: Sendable, Hashable {
    public static let deepSeekBaseURL = "https://api.deepseek.com"
    public static let deepSeekModel = "deepseek-flash"

    public let preset: TableRecognitionPreset
    public let baseURL: String
    public let model: String

    public init(preset: TableRecognitionPreset, baseURL: String, model: String) {
        self.preset = preset; self.baseURL = baseURL; self.model = model
    }

    public static let deepSeek = TableRecognitionEndpoint(preset: .deepSeek, baseURL: deepSeekBaseURL, model: deepSeekModel)
}

/// The user's answer to the consent dialog for one service host (spec #866: consent is per host; a changed host asks
/// again). The host is the one named in the dialog.
public struct TableRecognitionConsentRecord: Sendable, Equatable {
    public let host: String
    public let granted: Bool
    public init(host: String, granted: Bool) { self.host = host; self.granted = granted }
}

/// What the service reads before every request: the global Allow Cloud Recognition switch, the configured endpoint
/// and the consent record. Never the key: that comes from `TableRecognitionCredentialStore`.
public struct TableRecognitionOptions: Sendable, Equatable {
    public let cloudEnabled: Bool
    public let endpoint: TableRecognitionEndpoint?
    public let consent: TableRecognitionConsentRecord?
    public init(cloudEnabled: Bool, endpoint: TableRecognitionEndpoint?, consent: TableRecognitionConsentRecord?) {
        self.cloudEnabled = cloudEnabled; self.endpoint = endpoint; self.consent = consent
    }
}

public protocol TableRecognitionSettings: Sendable {
    func options() async -> TableRecognitionOptions
}

/// The access key saved for one endpoint (Keychain in the App). A key saved for another address is not returned.
public protocol TableRecognitionCredentialStore: Sendable {
    func accessKey(for endpoint: TableRecognitionEndpoint) async -> String?
}

/// Why nothing was sent. Every case means zero transport calls.
public enum TableRecognitionBlock: Sendable, Equatable {
    case cloudOff
    case invalidEndpoint
    case consentNotAsked
    case consentDeclined
    case consentHostChanged
    case noAccessKey
    case unsupportedImage
    case imageTooLarge
}

/// The failure classes after a request was sent (#869 AC-4). They carry no server text, key or image.
public enum TableRecognitionFailure: Sendable, Equatable {
    case keyRejected
    case addressUnreachable
    case modelCannotReadImages
    case offline
    case quotaOrBalance
    case tooLarge
    case noTable
    case incomplete
    case other
}

public enum TableRecognitionResult: Sendable, Equatable {
    /// Rows of cells; row 0 is the table's first row (the header). Replaced by `RecognisedTable` once #868 lands.
    case table(rows: [[String]])
    case notSent(TableRecognitionBlock)
    case failed(TableRecognitionFailure)
    case cancelled
}

/// The Settings Test button's answer: the built-in sample came back as the expected table, or why not.
public enum TableRecognitionTestResult: Sendable, Equatable {
    case passed
    case notSent(TableRecognitionBlock)
    case failed(TableRecognitionFailure)
    case cancelled
}
