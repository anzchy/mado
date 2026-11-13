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
            I676SidebarHandoffTiming.mark("loader task started; waiting for children")
            do {
                let children = try await browser.children(in: folder, rootID: rootID)
                I676SidebarHandoffTiming.mark("loader children finished count=\(children.count); waiting for parent")
                let parent: URL?
                do { parent = try await browser.parent(in: folder, rootID: rootID) }
                catch is CancellationError { return }
                catch {
                    guard !Task.isCancelled else { return }
                    onFailure?(folder)
                    parent = nil
                }
                try Task.checkCancellation()
                I676SidebarHandoffTiming.mark("loader parent finished; publishing rows")
                onRows(children, parent)
                let countFolders = [folder] + children + (parent.map { [$0] } ?? [])
                for child in countFolders {
                    try Task.checkCancellation()
                    do {
                        I676SidebarHandoffTiming.mark("loader waiting for image count")
                        let count = try await browser.imageCount(in: child, rootID: rootID)
                        try Task.checkCancellation()
                        I676SidebarHandoffTiming.mark("loader image count finished count=\(count)")
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
                I676SidebarHandoffTiming.mark("loader canceled")
                return
            } catch {
                I676SidebarHandoffTiming.mark("loader failed \(type(of: error))")
                guard !Task.isCancelled else { return }
                logger.error("Sidebar folder listing failed")
                onFailure?(folder)
            }
        }
    }
    public func cancel() { task?.cancel(); task = nil }
    deinit { task?.cancel() }
}
