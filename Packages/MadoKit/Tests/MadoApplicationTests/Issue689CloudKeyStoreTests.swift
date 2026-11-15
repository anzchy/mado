import Foundation
import Testing
@testable import MadoApplication

/// A keychain stand-in: items keyed by service and account; scripted failures per operation.
actor FakeSecretStore: CloudSecretStorePort {
    struct Key: Hashable { let service: String; let account: String }
    private(set) var items: [Key: String] = [:]
    var failSetAccount: String?
    var failRemoveAccount: String?
    var failRead = false
    private(set) var operations: [String] = []

    func failSet(on account: String?) { failSetAccount = account }
    func failRemove(on account: String?) { failRemoveAccount = account }
    func failReads(_ value: Bool) { failRead = value }
    func put(_ value: String, service: String, account: String) { items[Key(service: service, account: account)] = value }

    func secret(service: String, account: String) async throws(CloudSecretStoreError) -> String? {
        operations.append("read \(account)")
        if failRead { throw .failed(status: -25300) }
        return items[Key(service: service, account: account)]
    }
    func setSecret(_ value: String, service: String, account: String) async throws(CloudSecretStoreError) {
        operations.append("set \(account)")
        if failSetAccount == account { throw .failed(status: -25308) }
        items[Key(service: service, account: account)] = value
    }
    func removeSecret(service: String, account: String) async throws(CloudSecretStoreError) {
        operations.append("remove \(account)")
        if failRemoveAccount == account { throw .failed(status: -25244) }
        items[Key(service: service, account: account)] = nil
    }
}

private let baiduService = "io.github.anzchy.mado.cloud-recognition.baidu"

@Test(.timeLimit(.minutes(2)))
func issue689KeyStoreSavesReadsAndRemovesBothKeys() async throws {
    #expect(BaiduCloudCredentialStore.service == baiduService)
    #expect(BaiduCloudCredentialStore.apiKeyAccount == "api-key")
    #expect(BaiduCloudCredentialStore.secretKeyAccount == "secret-key")
    let secrets = FakeSecretStore()
    let store = BaiduCloudCredentialStore(secrets: secrets)
    #expect(await store.credentials() == nil)
    #expect(await store.hasKeys() == false)
    try await store.save(CloudCredentials(apiKey: "AK1234567890", secretKey: "SK-secret"))
    #expect(await secrets.items == [
        .init(service: baiduService, account: "api-key"): "AK1234567890",
        .init(service: baiduService, account: "secret-key"): "SK-secret",
    ])
    #expect(await store.credentials() == CloudCredentials(apiKey: "AK1234567890", secretKey: "SK-secret"))
    #expect(await store.hasKeys())
    // Saving again replaces both keys.
    try await store.save(CloudCredentials(apiKey: "AK-second-key", secretKey: "SK-second"))
    #expect(await store.credentials() == CloudCredentials(apiKey: "AK-second-key", secretKey: "SK-second"))
    try await store.remove()
    #expect(await secrets.items.isEmpty)
    #expect(await store.credentials() == nil)
    #expect(await store.hasKeys() == false)
}

@Test(.timeLimit(.minutes(2)))
func issue689KeyStoreRefusesEmptyKeysAndTrimsWhitespace() async throws {
    let secrets = FakeSecretStore()
    let store = BaiduCloudCredentialStore(secrets: secrets)
    for (api, secret) in [("", "secret"), ("api", ""), ("  \n", "secret"), ("api", " \t ")] {
        await #expect(throws: CloudKeyError.emptyKey) {
            try await store.save(CloudCredentials(apiKey: api, secretKey: secret))
        }
    }
    #expect(await secrets.operations.isEmpty)
    try await store.save(CloudCredentials(apiKey: "  AK123 \n", secretKey: "\tSK456  "))
    #expect(await store.credentials() == CloudCredentials(apiKey: "AK123", secretKey: "SK456"))
}

@Test(.timeLimit(.minutes(2)))
func issue689KeyStoreNeedsBothKeysAndTreatsReadFailureAsNoKey() async throws {
    let secrets = FakeSecretStore()
    let store = BaiduCloudCredentialStore(secrets: secrets)
    await secrets.put("AK", service: baiduService, account: "api-key")
    #expect(await store.credentials() == nil)
    #expect(await store.hasKeys() == false)
    await secrets.put("SK", service: baiduService, account: "secret-key")
    #expect(await store.credentials() == CloudCredentials(apiKey: "AK", secretKey: "SK"))
    // Another service's items are not Mado's Baidu keys.
    let other = BaiduCloudCredentialStore(secrets: secrets, service: "io.github.anzchy.mado.tests.other")
    #expect(await other.credentials() == nil)
    await secrets.failReads(true)
    #expect(await store.credentials() == nil)
    #expect(await store.hasKeys() == false)
}

@Test(.timeLimit(.minutes(2)))
func issue689KeyStoreSaveFailureLeavesNoHalfSavedKeys() async throws {
    let secrets = FakeSecretStore()
    let store = BaiduCloudCredentialStore(secrets: secrets)
    await secrets.failSet(on: "secret-key")
    await #expect(throws: CloudKeyError.storeFailed) {
        try await store.save(CloudCredentials(apiKey: "AK", secretKey: "SK"))
    }
    #expect(await secrets.items.isEmpty)
    await secrets.failSet(on: "api-key")
    await #expect(throws: CloudKeyError.storeFailed) {
        try await store.save(CloudCredentials(apiKey: "AK", secretKey: "SK"))
    }
    #expect(await secrets.items.isEmpty)
}

@Test(.timeLimit(.minutes(2)))
func issue689KeyStoreRemoveTriesBothKeysAndReportsFailure() async throws {
    let secrets = FakeSecretStore()
    let store = BaiduCloudCredentialStore(secrets: secrets)
    try await store.save(CloudCredentials(apiKey: "AK", secretKey: "SK"))
    await secrets.failRemove(on: "api-key")
    await #expect(throws: CloudKeyError.storeFailed) { try await store.remove() }
    // The secret key is gone even though the API key could not be removed, so the pair no longer works.
    #expect(await secrets.items == [.init(service: baiduService, account: "api-key"): "AK"])
    #expect(await store.credentials() == nil)
    await secrets.failRemove(on: nil)
    try await store.remove()
    #expect(await secrets.items.isEmpty)
}

@Test(.timeLimit(.minutes(2)))
func issue689KeyMaskShowsOnlyTheLastFourCharacters() {
    #expect(CloudKeyMask.masked("AK1234567890") == "••••••••7890")
    #expect(CloudKeyMask.masked("ABCDEFGH") == "••••••••EFGH")
    #expect(CloudKeyMask.masked("SHORT12") == "••••••••")
    #expect(CloudKeyMask.masked("") == "••••••••")
    #expect(CloudKeyMask.hidden == "••••••••")
    let errorText = String(describing: CloudSecretStoreError.failed(status: -25300))
    #expect(errorText.contains("-25300"))
}
