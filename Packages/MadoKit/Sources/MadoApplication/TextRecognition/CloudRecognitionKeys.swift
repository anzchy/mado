import Foundation

/// A keychain failure, by OSStatus only; it never carries the secret.
public enum CloudSecretStoreError: Error, Equatable, Sendable { case failed(status: Int32) }

/// Generic-password storage, one string per service and account (the App implements it over SecItem).
public protocol CloudSecretStorePort: Sendable {
    func secret(service: String, account: String) async throws(CloudSecretStoreError) -> String?
    func setSecret(_ value: String, service: String, account: String) async throws(CloudSecretStoreError)
    func removeSecret(service: String, account: String) async throws(CloudSecretStoreError)
}

public enum CloudKeyError: Error, Equatable, Sendable {
    case emptyKey, storeFailed
    /// The table service's address is not usable yet, so there is no configuration to save a key for (#871).
    case addressNeeded
}

/// The user's Baidu API Key and Secret Key, in the keychain only (ADR-0019, grilling 1.1). Keys never go to
/// UserDefaults or logs; a pair is usable only when both halves are saved.
public struct BaiduCloudCredentialStore: CloudCredentialStore {
    public static let service = "io.github.anzchy.mado.cloud-recognition.baidu"
    public static let apiKeyAccount = "api-key"
    public static let secretKeyAccount = "secret-key"

    private let secrets: any CloudSecretStorePort
    private let service: String

    public init(secrets: any CloudSecretStorePort, service: String = Self.service) {
        self.secrets = secrets
        self.service = service
    }

    public func credentials() async -> CloudCredentials? {
        guard let apiKey = try? await secrets.secret(service: service, account: Self.apiKeyAccount),
              let secretKey = try? await secrets.secret(service: service, account: Self.secretKeyAccount),
              !apiKey.isEmpty, !secretKey.isEmpty else { return nil }
        return CloudCredentials(apiKey: apiKey, secretKey: secretKey)
    }

    public func hasKeys() async -> Bool { await credentials() != nil }

    /// Saves both keys, trimmed. If a write fails while replacing a saved pair, the API Key already written is put
    /// back, so the old pair still works; on a first save, both are removed so no half pair is left behind.
    public func save(_ credentials: CloudCredentials) async throws(CloudKeyError) {
        let apiKey = credentials.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let secretKey = credentials.secretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty, !secretKey.isEmpty else { throw .emptyKey }
        let previous = await self.credentials()
        do {
            try await secrets.setSecret(apiKey, service: service, account: Self.apiKeyAccount)
        } catch {
            if previous == nil { await removeBoth() }
            throw .storeFailed
        }
        do {
            try await secrets.setSecret(secretKey, service: service, account: Self.secretKeyAccount)
        } catch {
            if let previous {
                // The Secret Key was not touched; restoring the API Key gives back the whole old pair.
                do { try await secrets.setSecret(previous.apiKey, service: service, account: Self.apiKeyAccount) }
                catch { await removeBoth() }
            } else {
                await removeBoth()
            }
            throw .storeFailed
        }
    }

    private func removeBoth() async {
        try? await secrets.removeSecret(service: service, account: Self.apiKeyAccount)
        try? await secrets.removeSecret(service: service, account: Self.secretKeyAccount)
    }

    /// Removes both keys; tries the second even when the first fails, and reports any failure.
    public func remove() async throws(CloudKeyError) {
        var failed = false
        for account in [Self.secretKeyAccount, Self.apiKeyAccount] {
            do { try await secrets.removeSecret(service: service, account: account) }
            catch { failed = true }
        }
        if failed { throw .storeFailed }
    }
}

/// How Settings shows a saved key: dots, plus the API Key's last four characters when it is long enough.
public enum CloudKeyMask {
    public static let hidden = "••••••••"
    public static func masked(_ key: String) -> String {
        key.count >= 8 ? hidden + String(key.suffix(4)) : hidden
    }
}
