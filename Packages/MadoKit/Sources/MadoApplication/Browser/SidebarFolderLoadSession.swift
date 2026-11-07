import Foundation
import MadoCore
import os

@MainActor public final class SidebarFolderLoadSession {
    private let browser: SidebarFolderBrowser
    private var task: Task<Void, Never>?
    private let logger = Logger(subsystem: "io.github.anzchy.mado", category: "sidebar")
    public init(browser: SidebarFolderBrowser) { self.browser = browser }
    public func start(folder: URL, rootID: AccessRootID,
        onRows: @escaping @MainActor ([URL], URL?) -> Void,
        onCount: @escaping @MainActor (URL, Int) -> Void,
        onFailure: (@MainActor (URL) -> Void)? = nil) {
        task?.cancel()
        let browser = self.browser
        task = Task(priority: .utility) {
            do {
                let children = try await browser.children(in: folder, rootID: rootID)
                let parent: URL?
                do { parent = try await browser.parent(in: folder, rootID: rootID) }
                catch is CancellationError { return }
                catch {
                    guard !Task.isCancelled else { return }
                    onFailure?(folder)
                    parent = nil
                }
                try Task.checkCancellation()
                onRows(children, parent)
                let countFolders = [folder] + children + (parent.map { [$0] } ?? [])
                for child in countFolders {
                    try Task.checkCancellation()
                    do {
                        let count = try await browser.imageCount(in: child, rootID: rootID)
                        try Task.checkCancellation()
                        onCount(child, count)
                    } catch is CancellationError {
                        return
                    } catch {
                        guard !Task.isCancelled else { return }
                        logger.error("Sidebar image count failed")
                        onFailure?(child)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                logger.error("Sidebar folder listing failed")
                onFailure?(folder)
            }
        }
    }
    public func cancel() { task?.cancel(); task = nil }
    deinit { task?.cancel() }
}
