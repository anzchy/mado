import Foundation
import Testing
import MadoApplication
import MadoInfrastructure

// #684 AC-6: both 「截图之后」 switches default on and persist across relaunch.

@Test(.timeLimit(.minutes(2))) func issue684OutputPreferencesDefaultOnAndPersistAcrossInstances() async throws {
    let suite = "issue684-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = UserDefaultsCaptureOutputPreferences(defaults: defaults)
    #expect(await first.outputPolicy() == .standard)
    await first.setSavesToFolder(false)
    let relaunched = UserDefaultsCaptureOutputPreferences(defaults: try #require(UserDefaults(suiteName: suite)))
    #expect(await relaunched.outputPolicy() == CaptureOutputPolicy(savesToFolder: false, copiesToClipboard: true))
    await relaunched.setCopiesToClipboard(false)
    await relaunched.setSavesToFolder(true)
    #expect(await first.outputPolicy() == CaptureOutputPolicy(savesToFolder: true, copiesToClipboard: false))
    #expect(defaults.object(forKey: CaptureBarIdentity.saveToFolderKey) as? Bool == true)
    #expect(defaults.object(forKey: CaptureBarIdentity.copyToClipboardKey) as? Bool == false)
}

@Test(.timeLimit(.minutes(2))) func issue684SettingsAndHelperShareSuite() {
    #expect(UserDefaultsCaptureOutputPreferences.sharedSuiteName == CaptureBarIdentity.appGroupID)
    #expect(UserDefaultsCaptureOutputPreferences.shared() != nil)
}
