import Foundation
import MadoCore

public enum AccessRecoveryDecision: Equatable, Sendable {
    case browse(URL)
    case reconnect(rootID: AccessRootID, lastKnownFolder: URL, displayName: String)
    case error
}

@MainActor public protocol AccessRecoveryHost: AnyObject {
    func browseRecoveredFolder(_ url: URL, rootID: AccessRootID)
    func requestFolderReconnection(rootID: AccessRootID, lastKnownFolder: URL, displayName: String)
    func showAccessRecoveryError(_ error: any Error)
}

public enum AccessRecovery {
    public static func decision(for recent: RecentFolder, currentURL: Result<URL?, any Error>) -> AccessRecoveryDecision {
        switch currentURL {
        case .success(.some(let url)): .browse(url)
        case .success(.none): .reconnect(rootID: recent.rootID, lastKnownFolder: recent.url, displayName: recent.displayName)
        case .failure(let error) where error as? FileAccessError == .needsReconnection(recent.rootID):
            .reconnect(rootID: recent.rootID, lastKnownFolder: recent.url, displayName: recent.displayName)
        case .failure: .error
        }
    }

    @MainActor @discardableResult
    public static func openRecent(_ recent: RecentFolder, currentURL: Result<URL?, any Error>,
                                  host: any AccessRecoveryHost) -> AccessRecoveryDecision {
        let next = decision(for: recent, currentURL: currentURL)
        switch next {
        case .browse(let url): host.browseRecoveredFolder(url, rootID: recent.rootID)
        case .reconnect(let id, let folder, let name):
            host.requestFolderReconnection(rootID: id, lastKnownFolder: folder, displayName: name)
        case .error:
            if case .failure(let error) = currentURL { host.showAccessRecoveryError(error) }
        }
        return next
    }
}
