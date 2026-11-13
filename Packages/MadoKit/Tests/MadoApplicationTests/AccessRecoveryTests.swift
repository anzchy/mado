import Foundation
import Testing
import MadoCore
import MadoApplication

private enum RecoveryPresentation: Equatable {
    case idle
    case browsing(AccessRootID, URL)
    case reconnecting(AccessRootID, URL, String)
    case error
}

@MainActor private final class RecoveryHost: AccessRecoveryHost {
    var state = RecoveryPresentation.idle
    var history: [RecoveryPresentation] = []
    var lastError: (any Error)?
    func browseRecoveredFolder(_ url: URL, rootID: AccessRootID) {
        state = .browsing(rootID, url); history.append(state)
    }
    func requestFolderReconnection(rootID: AccessRootID, lastKnownFolder: URL, displayName: String) {
        state = .reconnecting(rootID, lastKnownFolder, displayName); history.append(state)
    }
    func showAccessRecoveryError(_ error: any Error) {
        lastError = error; state = .error; history.append(state)
    }
}

@MainActor @Test(.timeLimit(.minutes(2))) func p201RecoveryBrowseRoutesCurrentURLInsteadOfRecentReference() {
    let id = AccessRootID(); let other = AccessRootID()
    let old = URL(fileURLWithPath: "/fixtures/old", isDirectory: true)
    let unrelated = URL(fileURLWithPath: "/fixtures/unrelated", isDirectory: true)
    let current = URL(fileURLWithPath: "/fixtures/current", isDirectory: true)
    let otherCurrent = URL(fileURLWithPath: "/fixtures/other", isDirectory: true)
    let host = RecoveryHost()
    let first = RecentFolder(rootID: id, url: old, displayName: "old")
    #expect(AccessRecovery.decision(for: first, currentURL: .success(current)) == .browse(current))
    #expect(AccessRecovery.openRecent(first, currentURL: .success(current), host: host) == .browse(current))
    #expect(host.state == .browsing(id, current))
    let staleReference = RecentFolder(rootID: id, url: unrelated, displayName: "different")
    #expect(AccessRecovery.openRecent(staleReference, currentURL: .success(current), host: host) == .browse(current))
    #expect(host.state == .browsing(id, current))
    let second = RecentFolder(rootID: other, url: old, displayName: "old")
    #expect(AccessRecovery.openRecent(second, currentURL: .success(otherCurrent), host: host) == .browse(otherCurrent))
    #expect(host.state == .browsing(other, otherCurrent))
    #expect(host.history == [.browsing(id, current), .browsing(id, current), .browsing(other, otherCurrent)])
    #expect(host.lastError == nil)
}

@MainActor @Test(.timeLimit(.minutes(2)), arguments: [0, 1, 2, 3])
func p201RecoveryReconnectRoutesCompleteOriginalContextAndCanBrowseAgain(variation: Int) {
    let originalID = AccessRootID(); let otherID = AccessRootID()
    let old = URL(fileURLWithPath: "/fixtures/old", isDirectory: true)
    let other = URL(fileURLWithPath: "/fixtures/other", isDirectory: true)
    let current = URL(fileURLWithPath: "/fixtures/current", isDirectory: true)
    let id = variation == 1 ? otherID : originalID
    let lastKnown = variation == 2 ? other : old
    let name = variation == 3 ? "" : "Holiday"
    let recent = RecentFolder(rootID: id, url: lastKnown, displayName: name)
    let host = RecoveryHost()
    AccessRecovery.openRecent(recent, currentURL: .success(current), host: host)
    #expect(host.state == .browsing(id, current))
    let expected = AccessRecoveryDecision.reconnect(rootID: id, lastKnownFolder: lastKnown, displayName: name)
    #expect(AccessRecovery.decision(for: recent, currentURL: .success(nil)) == expected)
    #expect(AccessRecovery.openRecent(recent, currentURL: .success(nil), host: host) == expected)
    #expect(host.state == .reconnecting(id, lastKnown, name))
    #expect(AccessRecovery.openRecent(recent, currentURL: .success(current), host: host) == .browse(current))
    #expect(host.state == .browsing(id, current))
    #expect(host.history == [.browsing(id, current), .reconnecting(id, lastKnown, name), .browsing(id, current)])
    #expect(host.lastError == nil)
}

@MainActor @Test(.timeLimit(.minutes(2)), arguments: [FileAccessError.startFailed, .outsideRoot])
func p201RecoveryServiceErrorRoutesActualFailureWithoutGrant(error: FileAccessError) {
    let id = AccessRootID()
    let folder = URL(fileURLWithPath: "/fixtures/old", isDirectory: true)
    let recent = RecentFolder(rootID: id, url: folder, displayName: "Holiday")
    let host = RecoveryHost()
    AccessRecovery.openRecent(recent, currentURL: .success(folder), host: host)
    #expect(host.state == .browsing(id, folder))
    #expect(AccessRecovery.decision(for: recent, currentURL: .failure(error)) == .error)
    #expect(AccessRecovery.openRecent(recent, currentURL: .failure(error), host: host) == .error)
    #expect(host.state == .error)
    #expect(host.lastError as? FileAccessError == error)
    #expect(host.history == [.browsing(id, folder), .error])
}

private struct RecoveryProbeError: Error, Equatable { let code: Int }

@MainActor @Test(.timeLimit(.minutes(2))) func p201Fix1RecoveryOnlyMatchingRootFailureReconnects() {
    let id = AccessRootID(); let other = AccessRootID()
    let folder = URL(fileURLWithPath: "/fixtures/holiday", isDirectory: true)
    let recent = RecentFolder(rootID: id, url: folder, displayName: "Holiday")
    let host = RecoveryHost()
    let expected = AccessRecoveryDecision.reconnect(rootID: id, lastKnownFolder: folder, displayName: "Holiday")
    #expect(AccessRecovery.decision(for: recent, currentURL: .failure(FileAccessError.needsReconnection(id))) == expected)
    #expect(AccessRecovery.openRecent(recent, currentURL: .failure(FileAccessError.needsReconnection(id)), host: host) == expected)
    #expect(host.history == [.reconnecting(id, folder, "Holiday")])
    #expect(host.lastError == nil)
    let otherFailure = FileAccessError.needsReconnection(other)
    #expect(AccessRecovery.openRecent(recent, currentURL: .failure(otherFailure), host: host) == .error)
    #expect(host.lastError as? FileAccessError == otherFailure)
    #expect(AccessRecovery.openRecent(recent, currentURL: .failure(FileAccessError.outsideRoot), host: host) == .error)
    #expect(host.lastError as? FileAccessError == .outsideRoot)
    let unrelated = RecoveryProbeError(code: 17)
    #expect(AccessRecovery.openRecent(recent, currentURL: .failure(unrelated), host: host) == .error)
    #expect(host.lastError as? RecoveryProbeError == unrelated)
    #expect(host.history == [.reconnecting(id, folder, "Holiday"), .error, .error, .error])
}
