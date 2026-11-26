import Foundation
import Testing
@testable import MadoApplication

// #871 (EXT-06 T4, spec #866): Settings › 截图 › 表格识别. Key per service configuration in the keychain, the global
// switch and per-host consent through the real TableRecognitionService guards (T3 fakes for the transport), the
// Test of the built-in sample with a plain status per failure class, and what a changed address or model clears.

// MARK: - Fakes

actor Secrets871: CloudSecretStorePort {
    private(set) var items: [String: String] = [:]
    private var failing = false
    func fail() { failing = true }
    func recover() { failing = false }
    func secret(service: String, account: String) async throws(CloudSecretStoreError) -> String? {
        items["\(service)/\(account)"]
    }
    func setSecret(_ value: String, service: String, account: String) async throws(CloudSecretStoreError) {
        if failing { throw .failed(status: -25308) }
        items["\(service)/\(account)"] = value
    }
    func removeSecret(service: String, account: String) async throws(CloudSecretStoreError) {
        if failing { throw .failed(status: -25308) }
        items["\(service)/\(account)"] = nil
    }
}

actor CloudPreferences871: CloudRecognitionPreferencePort {
    var enabled: Bool
    var record: CloudRecognitionConsentRecord?
    init(enabled: Bool = true, record: CloudRecognitionConsentRecord? = nil) {
        self.enabled = enabled
        self.record = record
    }
    func isEnabled() async -> Bool { enabled }
    func setEnabled(_ enabled: Bool) async { self.enabled = enabled }
    func consentRecord() async -> CloudRecognitionConsentRecord? { record }
    func setConsentRecord(_ record: CloudRecognitionConsentRecord) async { self.record = record }
}

actor TablePreferences871: TableRecognitionPreferencePort {
    var stored: TableRecognitionStoredSettings
    private(set) var consents: [String: Bool]
    init(_ stored: TableRecognitionStoredSettings = .defaults, consents: [String: Bool] = [:]) {
        self.stored = stored
        self.consents = consents
    }
    func storedSettings() async -> TableRecognitionStoredSettings { stored }
    func setStoredSettings(_ settings: TableRecognitionStoredSettings) async { stored = settings }
    func consent(forHost host: String) async -> Bool? { consents[host] }
    func setConsent(_ granted: Bool?, forHost host: String) async { consents[host] = granted }
}

private struct Fixture871 {
    let cloud: CloudPreferences871
    let table: TablePreferences871
    let secrets: Secrets871
    let keys: TableRecognitionKeyStore
    let transport: RecordingTransport869
    let model: TableRecognitionSettingsModel
}

private let sampleTable871 = "| Item | Qty | Price |\n|---|---|---|\n| Apple | 3 | 1.20 |\n| Pear | 5 | 0.80 |"
private func sampleReply871() -> RecordingTransport869.Reply {
    .response(HTTPResponse(statusCode: 200, body: chatReply869(content: sampleTable871)))
}

private func fixture871(enabled: Bool = true, baidu: CloudRecognitionConsentRecord? = nil,
                        stored: TableRecognitionStoredSettings = .defaults, consents: [String: Bool] = [:],
                        replies: [RecordingTransport869.Reply] = [], gated: Bool = false) -> Fixture871 {
    let cloud = CloudPreferences871(enabled: enabled, record: baidu)
    let table = TablePreferences871(stored, consents: consents)
    let secrets = Secrets871()
    let keys = TableRecognitionKeyStore(secrets: secrets)
    let transport = RecordingTransport869(replies, fallback: sampleReply871(), gated: gated)
    let model = TableRecognitionSettingsModel(cloud: cloud, preferences: table, keys: keys, transport: transport)
    return Fixture871(cloud: cloud, table: table, secrets: secrets, keys: keys, transport: transport, model: model)
}

private let deepSeek871 = TableRecognitionEndpoint.deepSeekDefault869

// MARK: - WI-1 key store per service configuration

@Test(.timeLimit(.minutes(2)))
func issue871WI1KeyIsStoredPerConfigurationAndTrimmed() async throws {
    let secrets = Secrets871()
    let keys = TableRecognitionKeyStore(secrets: secrets)
    try await keys.save("  sk-live-abcd1234 \n", for: deepSeek871)
    #expect(await keys.accessKey(for: deepSeek871) == "sk-live-abcd1234")
    // Only the keychain service of the table store holds it, under one account.
    let items = await secrets.items
    #expect(items.count == 1)
    #expect(items.keys.allSatisfy { $0.hasPrefix(TableRecognitionKeyStore.service + "/") })
    #expect(TableRecognitionKeyStore.service != BaiduCloudCredentialStore.service)
    // The model is not part of the configuration; case and trailing slashes of the address are not either.
    let otherModel = TableRecognitionEndpoint(preset: .deepSeek, baseURL: "https://api.deepseek.com", model: "other")
    #expect(await keys.accessKey(for: otherModel) == "sk-live-abcd1234")
    let sameAddress = TableRecognitionEndpoint(preset: .deepSeek, baseURL: " HTTPS://API.DeepSeek.com/ ",
                                               model: "deepseek-flash")
    #expect(await keys.accessKey(for: sameAddress) == "sk-live-abcd1234")
}

@Test(.timeLimit(.minutes(2)))
func issue871WI1NewAddressOrPresetDoesNotInheritTheKey() async throws {
    let keys = TableRecognitionKeyStore(secrets: Secrets871())
    try await keys.save("sk-live-abcd1234", for: deepSeek871)
    let otherHost = TableRecognitionEndpoint(preset: .deepSeek, baseURL: "https://api.deepseek.example", model: "deepseek-flash")
    let otherPath = TableRecognitionEndpoint(preset: .deepSeek, baseURL: "https://api.deepseek.com/v1", model: "deepseek-flash")
    let custom = TableRecognitionEndpoint(preset: .custom, baseURL: "https://api.deepseek.com", model: "deepseek-flash")
    #expect(await keys.accessKey(for: otherHost) == nil)
    #expect(await keys.accessKey(for: otherPath) == nil)
    #expect(await keys.accessKey(for: custom) == nil)
    #expect(TableRecognitionKeyStore.account(for: deepSeek871) != TableRecognitionKeyStore.account(for: otherHost))
    #expect(TableRecognitionKeyStore.account(for: deepSeek871) != TableRecognitionKeyStore.account(for: custom))
}

@Test(.timeLimit(.minutes(2)))
func issue871WI1RemoveDeletesOnlyThisConfigurationAndErrorsAreTyped() async throws {
    let secrets = Secrets871()
    let keys = TableRecognitionKeyStore(secrets: secrets)
    let custom = TableRecognitionEndpoint.custom869()
    try await keys.save("sk-ds-00000001", for: deepSeek871)
    try await keys.save("sk-cu-00000002", for: custom)
    try await keys.remove(for: deepSeek871)
    #expect(await keys.accessKey(for: deepSeek871) == nil)
    #expect(await keys.accessKey(for: custom) == "sk-cu-00000002")
    await #expect(throws: CloudKeyError.emptyKey) { try await keys.save("  \n", for: deepSeek871) }
    #expect(await keys.accessKey(for: deepSeek871) == nil)
    await secrets.fail()
    await #expect(throws: CloudKeyError.storeFailed) { try await keys.save("sk-new-00000003", for: custom) }
    await #expect(throws: CloudKeyError.storeFailed) { try await keys.remove(for: custom) }
}

// MARK: - WI-2 configuration the service reads

@Test(.timeLimit(.minutes(2)))
func issue871WI2OptionsCarryTheSwitchEndpointAndThisHostsConsent() async {
    let cloud = CloudPreferences871(enabled: true)
    let table = TablePreferences871(consents: ["api.deepseek.com": true, "gw.example.com": false])
    let options = await TableRecognitionConfiguration(cloud: cloud, preferences: table).options()
    #expect(options == TableRecognitionOptions(cloudEnabled: true, endpoint: deepSeek871,
                                               consent: TableRecognitionConsentRecord(host: "api.deepseek.com", granted: true)))
    await cloud.setEnabled(false)
    let custom = TableRecognitionStoredSettings(preset: .custom, customAddress: "https://GW.example.com./v1",
                                                customModel: "vision-x")
    await table.setStoredSettings(custom)
    let off = await TableRecognitionConfiguration(cloud: cloud, preferences: table).options()
    #expect(off == TableRecognitionOptions(cloudEnabled: false, endpoint: .custom869("https://GW.example.com./v1"),
                                           consent: TableRecognitionConsentRecord(host: "gw.example.com", granted: false)))
}

@Test(.timeLimit(.minutes(2)))
func issue871WI2BaiduConsentDoesNotAuthoriseDeepSeek() async throws {
    let fixture = fixture871(baidu: CloudRecognitionConsentRecord(granted: true, date: Date(timeIntervalSince1970: 0)))
    try await fixture.keys.save("sk-live-abcd1234", for: deepSeek871)
    let options = await TableRecognitionConfiguration(cloud: fixture.cloud, preferences: fixture.table).options()
    #expect(options.consent == nil)
    let service = TableRecognitionService(settings: TableRecognitionConfiguration(cloud: fixture.cloud,
                                                                                  preferences: fixture.table),
                                          credentials: fixture.keys, transport: fixture.transport)
    #expect(await service.testService() == .notSent(.consentNotAsked))
    #expect(await service.recognise(makePNG869(8, 8)) == .notSent(.consentNotAsked))
    #expect(await fixture.model.test() == .needsConsent(host: "api.deepseek.com"))
    #expect(await fixture.transport.callCount == 0)
}

@Test(.timeLimit(.minutes(2)))
func issue871WI2ConsentForAnotherHostNeverAuthorisesThisOne() async throws {
    let fixture = fixture871(consents: ["gw.example.com": true])
    try await fixture.keys.save("sk-live-abcd1234", for: deepSeek871)
    #expect(await fixture.model.test() == .needsConsent(host: "api.deepseek.com"))
    #expect(await fixture.transport.callCount == 0)
}

// MARK: - WI-3 settings model

@Test(.timeLimit(.minutes(2)))
func issue871WI3DefaultStateIsDeepSeekWithItsHostAndNoKey() async {
    let state = await fixture871().model.state()
    #expect(state == TableRecognitionSettingsState(preset: .deepSeek, address: "https://api.deepseek.com",
                                                   model: "deepseek-flash", host: "api.deepseek.com", hasKey: false,
                                                   maskedKey: nil, advancedRequired: false, canTest: false, test: nil))
}

@Test(.timeLimit(.minutes(2)))
func issue871WI3SaveReplaceAndRemoveTheKey() async throws {
    let fixture = fixture871()
    try await fixture.model.saveKey("sk-live-00003f9a")
    var state = await fixture.model.state()
    #expect(state.hasKey && state.canTest)
    #expect(state.maskedKey == "••••••••••••3f9a")
    try await fixture.model.saveKey("sk-live-0000beef")
    #expect(await fixture.keys.accessKey(for: deepSeek871) == "sk-live-0000beef")
    #expect(await fixture.model.state().maskedKey == "••••••••••••beef")
    try await fixture.model.removeKey()
    state = await fixture.model.state()
    #expect(!state.hasKey && !state.canTest && state.maskedKey == nil)
    #expect(await fixture.secrets.items.isEmpty)
    #expect(TableRecognitionSettingsState.masked("short") == "••••••••••••")
}

@Test(.timeLimit(.minutes(2)))
func issue871WI3CustomOpensAdvancedAndNeedsAddressAndModel() async throws {
    let fixture = fixture871()
    try await fixture.model.saveKey("sk-ds-00000001")
    await fixture.model.selectPreset(.custom)
    var state = await fixture.model.state()
    #expect(state.preset == .custom && state.advancedRequired)
    #expect(state.address == "" && state.model == "" && state.host == nil)
    // The DeepSeek key is not the Custom configuration's key.
    #expect(!state.hasKey && !state.canTest)
    await fixture.model.setAddress("https://gw.example.com/v1")
    state = await fixture.model.state()
    #expect(state.host == nil, "Custom needs a model before the address is usable")
    await fixture.model.setModel("vision-x")
    try await fixture.model.saveKey("sk-cu-00000002")
    state = await fixture.model.state()
    #expect(state.host == "gw.example.com" && state.canTest)
    await fixture.model.selectPreset(.deepSeek)
    state = await fixture.model.state()
    #expect(state.preset == .deepSeek && !state.advancedRequired && state.hasKey && state.host == "api.deepseek.com")
    #expect(await fixture.table.stored.customAddress == "https://gw.example.com/v1")
}

@Test(.timeLimit(.minutes(2)))
func issue871WI3ChangingTheAddressCarriesNeitherKeyNorConsent() async throws {
    let fixture = fixture871(consents: ["api.deepseek.com": true])
    try await fixture.model.saveKey("sk-live-abcd1234")
    #expect(await fixture.model.test() == .finished(.passed))
    await fixture.model.setAddress("https://api.deepseek.com/beta")
    let state = await fixture.model.state()
    #expect(state.address == "https://api.deepseek.com/beta")
    #expect(state.host == "api.deepseek.com")
    #expect(!state.hasKey && state.test == nil)
    #expect(await fixture.table.consents["api.deepseek.com"] == nil)
    try await fixture.model.saveKey("sk-live-new00001")
    #expect(await fixture.model.test() == .needsConsent(host: "api.deepseek.com"))
    #expect(await fixture.transport.callCount == 1)
}

@Test(.timeLimit(.minutes(2)))
func issue871WI3SameAddressAgainClearsNothing() async throws {
    let fixture = fixture871(consents: ["api.deepseek.com": true])
    try await fixture.model.saveKey("sk-live-abcd1234")
    _ = await fixture.model.test()
    await fixture.model.setAddress(" https://api.deepseek.com ")
    await fixture.model.setModel("deepseek-flash")
    let state = await fixture.model.state()
    #expect(state.test == .passed && state.hasKey)
    #expect(await fixture.table.consents["api.deepseek.com"] == true)
}

@Test(.timeLimit(.minutes(2)))
func issue871WI3ChangingTheModelClearsTheTestResult() async throws {
    let fixture = fixture871(consents: ["api.deepseek.com": true])
    try await fixture.model.saveKey("sk-live-abcd1234")
    #expect(await fixture.model.test() == .finished(.passed))
    #expect(await fixture.model.state().test == .passed)
    await fixture.model.setModel("deepseek-vision")
    let state = await fixture.model.state()
    #expect(state.test == nil && state.model == "deepseek-vision" && state.hasKey)
    #expect(await fixture.table.consents["api.deepseek.com"] == true)
}

@Test(.timeLimit(.minutes(2)))
func issue871WI3ModelChangeDuringATestDropsItsAnswer() async throws {
    let fixture = fixture871(consents: ["api.deepseek.com": true], gated: true)
    try await fixture.model.saveKey("sk-live-abcd1234")
    let model = fixture.model
    let run = Task { await model.test() }
    #expect(await awaitHeldSend869(fixture.transport, run))
    #expect(await fixture.model.state().test == .testing)
    await fixture.model.setModel("deepseek-vision")
    #expect(await fixture.model.state().test == nil)
    await fixture.transport.open()
    #expect(await run.value == .finished(nil))
    #expect(await fixture.model.state().test == nil)
}

@Test(.timeLimit(.minutes(2)))
func issue871WI3CancelledTestShowsNothing() async throws {
    let fixture = fixture871(consents: ["api.deepseek.com": true], gated: true)
    try await fixture.model.saveKey("sk-live-abcd1234")
    let model = fixture.model
    let run = Task { await model.test() }
    #expect(await awaitHeldSend869(fixture.transport, run))
    run.cancel()
    await fixture.transport.open()
    #expect(await run.value == .finished(nil))
    #expect(await fixture.model.state().test == nil)
    #expect(await fixture.transport.callCount == 1)
}

@Test(.timeLimit(.minutes(2)), arguments: [
    (reply869(401, #"{"error":{"message":"Authentication Fails"}}"#), TableRecognitionTestStatus.keyRejected),
    (reply869(404, ""), .addressUnreachable),
    (RecordingTransport869.Reply.failure(URLError(.cannotFindHost)), .addressUnreachable),
    (reply869(400, #"{"error":{"message":"This model does not support image input"}}"#), .modelCannotReadImages),
    (RecordingTransport869.Reply.failure(URLError(.notConnectedToInternet)), .offline),
    (reply869(402, #"{"error":{"message":"Insufficient Balance"}}"#), .quotaOrBalance),
    (reply869(500, "oops"), .undetermined),
    (reply869(413, ""), .undetermined),
    (.response(goodReply869()), .undetermined),
    (.response(HTTPResponse(statusCode: 200, body: chatReply869(content: "no table here"))), .undetermined),
    (.response(HTTPResponse(statusCode: 200, body: chatReply869(content: sampleTable871, finish: "length"))), .undetermined),
    (sampleReply871(), .passed),
])
func issue871WI3EveryTestResultHasItsPlainStatus(reply: RecordingTransport869.Reply,
                                                 status: TableRecognitionTestStatus) async throws {
    let fixture = fixture871(consents: ["api.deepseek.com": true], replies: [reply])
    try await fixture.model.saveKey("sk-live-abcd1234")
    #expect(await fixture.model.test() == .finished(status))
    #expect(await fixture.model.state().test == status)
    // Test sends the built-in sample only, once, to the configured host.
    let requests = await fixture.transport.requests
    #expect(requests.count == 1)
    #expect(requests.first?.url?.host == "api.deepseek.com")
    #expect(requests.first.flatMap(payload869)?.base64 == TableRecognitionSample.png.base64EncodedString())
}

@Test(.timeLimit(.minutes(2)))
func issue871WI3SwitchOffTestSendsNothing() async throws {
    let fixture = fixture871(enabled: false, consents: ["api.deepseek.com": true])
    try await fixture.model.saveKey("sk-live-abcd1234")
    #expect(await fixture.model.test() == .finished(.cloudOff))
    #expect(await fixture.model.state().test == .cloudOff)
    #expect(await fixture.transport.callCount == 0)
}

@Test(.timeLimit(.minutes(2)))
func issue871WI3ConsentAgreedIsStoredForThatHostOnly() async throws {
    let fixture = fixture871()
    try await fixture.model.saveKey("sk-live-abcd1234")
    #expect(await fixture.model.test() == .needsConsent(host: "api.deepseek.com"))
    #expect(await fixture.model.state().test == nil)
    await fixture.model.answerConsent(granted: true, host: "API.DeepSeek.com.")
    #expect(await fixture.table.consents == ["api.deepseek.com": true])
    #expect(await fixture.model.test() == .finished(.passed))
    #expect(await fixture.transport.callCount == 1)
    #expect(await fixture.cloud.record == nil, "the Baidu consent is not touched")
}

@Test(.timeLimit(.minutes(2)))
func issue871WI3ConsentDeclinedChangesNothingAndSendsNothing() async throws {
    let fixture = fixture871()
    try await fixture.model.saveKey("sk-live-abcd1234")
    #expect(await fixture.model.test() == .needsConsent(host: "api.deepseek.com"))
    await fixture.model.answerConsent(granted: false, host: "api.deepseek.com")
    #expect(await fixture.table.consents.isEmpty)
    #expect(await fixture.model.test() == .needsConsent(host: "api.deepseek.com"))
    #expect(await fixture.transport.callCount == 0)
}

@Test(.timeLimit(.minutes(2)))
func issue871WI3KeyChangeClearsTheTestResult() async throws {
    let fixture = fixture871(consents: ["api.deepseek.com": true], replies: [reply869(401, "")])
    try await fixture.model.saveKey("sk-live-abcd1234")
    #expect(await fixture.model.test() == .finished(.keyRejected))
    try await fixture.model.saveKey("sk-live-0000beef")
    #expect(await fixture.model.state().test == nil)
    _ = await fixture.model.test()
    try await fixture.model.removeKey()
    #expect(await fixture.model.state().test == nil)
}

@Test(.timeLimit(.minutes(2)))
func issue871WI3WithoutAKeyTestSendsNothing() async {
    let fixture = fixture871(consents: ["api.deepseek.com": true])
    #expect(await fixture.model.test() == .finished(.undetermined))
    #expect(await fixture.transport.callCount == 0)
}

/// The stored address changes to an unusable one while Test runs: the first read gives the DeepSeek default, every
/// later read a Custom service with no address.
private actor ChangingPreferences871: TableRecognitionPreferencePort {
    private(set) var reads = 0
    private(set) var consents: [String: Bool] = [:]
    func storedSettings() async -> TableRecognitionStoredSettings {
        reads += 1
        return reads == 1 ? .defaults : TableRecognitionStoredSettings(preset: .custom)
    }
    func setStoredSettings(_ settings: TableRecognitionStoredSettings) async {}
    func consent(forHost host: String) async -> Bool? { consents[host] }
    func setConsent(_ granted: Bool?, forHost host: String) async { consents[host] = granted }
}

@Test(.timeLimit(.minutes(2)))
func issue871WI3ConsentBlockForAnAddressChangedMeanwhileAsksNothing() async {
    let preferences = ChangingPreferences871()
    let transport = RecordingTransport869([], fallback: sampleReply871())
    let model = TableRecognitionSettingsModel(cloud: CloudPreferences871(enabled: true, record: nil), preferences: preferences,
                                              keys: TableRecognitionKeyStore(secrets: Secrets871()), transport: transport)
    // The service saw api.deepseek.com without consent; by then the address is gone, so no host is named for consent.
    #expect(await model.test() == .finished(.undetermined))
    #expect(await preferences.reads == 2)
    #expect(await preferences.consents.isEmpty)
    #expect(await transport.requests.isEmpty)
}

// MARK: - Fix round 1: no orphaned key (opus M2), what to fill in (opus L1), an address change mid-Test (opus M6)

@Test(.timeLimit(.minutes(2)))
func issue871Fix1ChangingTheAddressRemovesTheOldKey() async throws {
    let fixture = fixture871(consents: ["api.deepseek.com": true])
    try await fixture.model.saveKey("sk-live-abcd1234")
    await fixture.model.setAddress("https://api.deepseek.com/beta")
    // Nothing is left behind that the group can no longer show or remove.
    #expect(await fixture.secrets.items.isEmpty)
    // Going back to the old address does not bring a key back.
    await fixture.model.setAddress("https://api.deepseek.com")
    #expect(await !fixture.model.state().hasKey)
    // Remove deletes the key the group shows, for the address now set.
    try await fixture.model.saveKey("sk-live-0000beef")
    try await fixture.model.removeKey()
    #expect(await fixture.secrets.items.isEmpty)
}

@Test(.timeLimit(.minutes(2)))
func issue871Fix1ChangingTheAddressKeepsTheOtherPresetsKey() async throws {
    let fixture = fixture871()
    try await fixture.model.saveKey("sk-ds-00000001")
    await fixture.model.selectPreset(.custom)
    await fixture.model.setAddress("https://gw.example.com/v1")
    await fixture.model.setModel("vision-x")
    try await fixture.model.saveKey("sk-cu-00000002")
    await fixture.model.setAddress("https://gw2.example.com/v1")
    #expect(await fixture.secrets.items.values.sorted() == ["sk-ds-00000001"])
}

@Test(.timeLimit(.minutes(2)))
func issue871Fix1CustomRefusesAKeyUntilTheAddressIsUsable() async throws {
    let fixture = fixture871()
    await fixture.model.selectPreset(.custom)
    // Filled top to bottom (service, key, then Advanced): the key has no configuration to belong to yet.
    await #expect(throws: CloudKeyError.addressNeeded) { try await fixture.model.saveKey("sk-cu-00000002") }
    await fixture.model.setAddress("https://gw.example.com/v1")
    await #expect(throws: CloudKeyError.addressNeeded) { try await fixture.model.saveKey("sk-cu-00000002") }
    #expect(await fixture.secrets.items.isEmpty)
    await fixture.model.setModel("vision-x")
    try await fixture.model.saveKey("sk-cu-00000002")
    #expect(await fixture.model.state().hasKey)
    #expect(await fixture.secrets.items.count == 1)
}

@Test(.timeLimit(.minutes(2)))
func issue871Fix1StateNamesWhatToFillInFirst() async {
    let fixture = fixture871()
    #expect(await fixture.model.state().missing == nil)
    await fixture.model.selectPreset(.custom)
    #expect(await fixture.model.state().missing == .address)
    await fixture.model.setModel("vision-x")
    #expect(await fixture.model.state().missing == .address)
    await fixture.model.setAddress("http://gw.example.com/v1")
    #expect(await fixture.model.state().missing == .address, "only https is usable")
    await fixture.model.setAddress("https://gw.example.com/v1")
    #expect(await fixture.model.state().missing == nil)
    await fixture.model.setModel("")
    let state = await fixture.model.state()
    #expect(state.missing == .model && state.host == nil)
}

@Test(.timeLimit(.minutes(2)))
func issue871Fix1AddressChangeDuringATestDropsItsAnswer() async throws {
    let fixture = fixture871(consents: ["api.deepseek.com": true], gated: true)
    try await fixture.model.saveKey("sk-live-abcd1234")
    let model = fixture.model
    let run = Task { await model.test() }
    #expect(await awaitHeldSend869(fixture.transport, run))
    await fixture.model.setAddress("https://api.deepseek.com/beta")
    #expect(await fixture.model.state().test == nil)
    await fixture.transport.open()
    #expect(await run.value == .finished(nil))
    #expect(await fixture.model.state().test == nil)
}

// MARK: - Fix round 2: a failed keychain removal is not swallowed (gpt F5 / opus N1)

@Test(.timeLimit(.minutes(2)))
func issue871Fix2AFailedKeyRemovalKeepsTheAddress() async throws {
    let fixture = fixture871(consents: ["api.deepseek.com": true])
    try await fixture.model.saveKey("sk-live-abcd1234")
    await fixture.secrets.fail()
    await fixture.model.setAddress("https://api.deepseek.com/beta")
    // The address does not change: the old configuration and its key stay visible and removable.
    let state = await fixture.model.state()
    #expect(state.addressChangeFailed)
    #expect(state.address == TableRecognitionEndpoint.deepSeekBaseURL)
    #expect(state.host == "api.deepseek.com")
    #expect(state.hasKey && state.maskedKey == TableRecognitionSettingsState.masked("sk-live-abcd1234"))
    #expect(await fixture.table.stored.deepSeekAddress == TableRecognitionEndpoint.deepSeekBaseURL)
    #expect(await fixture.secrets.items.values.sorted() == ["sk-live-abcd1234"])
    // No consent is dropped.
    #expect(await fixture.table.consents["api.deepseek.com"] == true)
    // Once the keychain works again, the change goes through and the failure is gone.
    await fixture.secrets.recover()
    await fixture.model.setAddress("https://api.deepseek.com/beta")
    let changed = await fixture.model.state()
    #expect(!changed.addressChangeFailed)
    #expect(changed.address == "https://api.deepseek.com/beta" && !changed.hasKey)
    #expect(await fixture.secrets.items.isEmpty)
    #expect(await fixture.table.consents["api.deepseek.com"] == nil)
}

@Test(.timeLimit(.minutes(2)))
func issue871Fix2NoKeyToRemoveIsNotAFailure() async {
    // Nothing saved for the old address ("not found" in the keychain): the address changes as before.
    let fixture = fixture871()
    await fixture.model.setAddress("https://api.deepseek.com/beta")
    let state = await fixture.model.state()
    #expect(!state.addressChangeFailed && state.address == "https://api.deepseek.com/beta")
}
