import Foundation
import Security
import Testing
import MadoApplication

/// Real keychain, test-only service: the Baidu service is never touched, and teardown deletes every item it made.
private let testService = "io.github.anzchy.mado.tests.cloud-recognition.\(UUID().uuidString)"

private func deleteTestItems() {
    SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: testService] as CFDictionary)
}

private func attributes(account: String) -> [String: Any]? {
    var result: CFTypeRef?
    let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: testService,
                                      kSecAttrAccount: account, kSecReturnAttributes: true,
                                      kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &result)
    return status == errSecSuccess ? result as? [String: Any] : nil
}

@Test(.timeLimit(.minutes(2)))
func issue689RealKeychainRoundTripOnATestService() async throws {
    deleteTestItems()
    defer { deleteTestItems() }
    let secrets = KeychainSecretStore()
    #expect(try await secrets.secret(service: testService, account: "api-key") == nil)
    try await secrets.setSecret("AK-一", service: testService, account: "api-key")
    #expect(try await secrets.secret(service: testService, account: "api-key") == "AK-一")
    try await secrets.setSecret("AK-two", service: testService, account: "api-key")
    #expect(try await secrets.secret(service: testService, account: "api-key") == "AK-two")
    let saved = try #require(attributes(account: "api-key"))
    #expect(saved[kSecAttrService as String] as? String == testService)
    #expect((saved[kSecAttrSynchronizable as String] as? Bool ?? false) == false)
    try await secrets.removeSecret(service: testService, account: "api-key")
    #expect(try await secrets.secret(service: testService, account: "api-key") == nil)
    // Removing a key that is not there is not a failure.
    try await secrets.removeSecret(service: testService, account: "api-key")

    // Through the Baidu store on the test service: both keys saved, read, removed.
    let store = BaiduCloudCredentialStore(secrets: secrets, service: testService)
    try await store.save(CloudCredentials(apiKey: "AK", secretKey: "SK"))
    #expect(await store.credentials() == CloudCredentials(apiKey: "AK", secretKey: "SK"))
    #expect(attributes(account: "secret-key") != nil)
    try await store.remove()
    #expect(await store.credentials() == nil)
    #expect(attributes(account: "api-key") == nil && attributes(account: "secret-key") == nil)
}

@Test(.timeLimit(.minutes(2)))
func issue689KeychainQueriesNameTheGenericPasswordAndNoSync() {
    let query = KeychainSecretStore.itemQuery(service: "svc", account: "acct")
    #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
    #expect(query[kSecAttrService as String] as? String == "svc")
    #expect(query[kSecAttrAccount as String] as? String == "acct")
    #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
    let added = KeychainSecretStore.addAttributes(Data("v".utf8))
    #expect(added[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlock as String)
    #expect(added[kSecValueData as String] as? Data == Data("v".utf8))
}

@Test(.timeLimit(.minutes(2)))
func issue689AppServicesUseTheBaiduServiceAndStandardDefaults() async throws {
    #expect(CloudRecognitionAppServices.keychainService == "io.github.anzchy.mado.cloud-recognition.baidu")
    // Before the path monitor reports, the Mac counts as online: a real offline then reaches the user as the
    // transport's offline fallback, with its label, rather than as a silent on-device result.
    #expect(await NWPathReachability(startMonitoring: false).isOnline())
}
