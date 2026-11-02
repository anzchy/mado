import Foundation
import Testing
import PicseeApplication
import PicseeCore

/// A listing/store/old-source close that can return only when explicitly released.
private actor AccessSuspension {
    private var continuation: CheckedContinuation<Void, Never>?
    private var entered: CheckedContinuation<Void, Never>?
    private var waiting = false
    func suspend() async {
        await withCheckedContinuation {
            continuation = $0; waiting = true
            entered?.resume(); entered = nil
        }
    }
    func waitUntilEntered() async {
        if !waiting { await withCheckedContinuation { entered = $0 } }
    }
    func resume() { continuation!.resume(); continuation = nil }
}

private enum AccessTestFailure: Error { case expected }

@Test @MainActor func accessIntentDiscardsSuspendedOpensAndErrorsAfterCloseNewOpenOrCancellation() async {
    // Listing, Recent write, grant containment/listing, and old-source close
    // are all suspensions after which App must consult the same operation.
    for stage in 0..<4 {
        for invalidation in 0..<3 {
            for fails in [false, true] {
                let intent = AccessIntent()
                let operation = intent.begin()
                let suspended = AccessSuspension()
                var presented: [String] = []
                let task = Task { @MainActor in
                    do {
                        for index in 0..<4 {
                            try await operation.wait {
                                if index == stage {
                                    await suspended.suspend()
                                    if fails { throw AccessTestFailure.expected }
                                }
                            }
                        }
                        presented.append("A")
                    } catch {
                        if operation.isCurrent { presented.append("stale error") }
                    }
                }
                await suspended.waitUntilEntered()
                switch invalidation {
                case 0: intent.invalidate() // window closed
                case 1: _ = intent.begin(); presented.append("B")
                default: task.cancel()
                }
                await suspended.resume()
                await task.value
                #expect(presented == (invalidation == 1 ? ["B"] : []))
            }
        }
    }
}

@Test @MainActor func accessIntentAllowsCurrentResultsAndErrorsButDoesNotStartExpiredWork() async throws {
    let intent = AccessIntent()
    let operation = intent.begin()
    #expect(operation.isCurrent)
    #expect(try await operation.wait { 42 } == 42)
    await #expect(throws: AccessTestFailure.expected) {
        try await operation.wait { throw AccessTestFailure.expected }
    }
    intent.invalidate()
    var started = false
    await #expect(throws: CancellationError.self) {
        try await operation.wait { started = true }
    }
    #expect(!started)
}

@Test @MainActor func accessFolderOpenDiscardsBlockedListingAndRecentWriteAfterCloseOrNewOpen() async {
    for blockListing in [true, false] {
        for newOpen in [true, false] {
            for fails in [true, false] {
                let intent = AccessIntent()
                let operation = intent.begin()
                let suspended = AccessSuspension()
                let task = Task { @MainActor in
                    try await operation.firstImage(list: {
                        if blockListing {
                            await suspended.suspend()
                            if fails { throw AccessTestFailure.expected }
                        }
                        return [URL(fileURLWithPath: "/photos/a.jpg")]
                    }, remember: {
                        if !blockListing {
                            await suspended.suspend()
                            if fails { throw AccessTestFailure.expected }
                        }
                    })
                }
                await suspended.waitUntilEntered()
                if newOpen { _ = intent.begin() } else { intent.invalidate() }
                await suspended.resume()
                await #expect(throws: CancellationError.self) { try await task.value }
            }
        }
    }
}

@Test @MainActor func accessFolderOpenReturnsFirstImageAndRemembersOnlyNonemptyFolders() async throws {
    let operation = AccessIntent().begin()
    var remembered = 0
    let first = try await operation.firstImage(list: {
        [URL(fileURLWithPath: "/photos/b.jpg"), URL(fileURLWithPath: "/photos/a.jpg")]
    }, remember: { remembered += 1 })
    #expect(first == URL(fileURLWithPath: "/photos/a.jpg"))
    let empty = try await operation.firstImage(list: { [] }, remember: { remembered += 1 })
    #expect(empty == nil && remembered == 1)
}

/// Uses the native host's operation policy through the real Session dispatch.
@MainActor private final class PendingAccessHost: ViewerSessionNavigationHost {
    let intent = AccessIntent()
    let file = URL(fileURLWithPath: "/photos/only.jpg")
    var installed: URL?
    var hasImage: Bool { installed != nil }
    var canNavigate = true
    var covered = true
    var decision: NavigationDecision?
    func navigate(_ direction: NavigationDirection) {
        let operation = intent.navigation()
        guard operation.isCurrent else { return }
        decision = FolderNavigation(images: [file]).step(from: file, direction: direction, covered: covered)
    }
    func performCanvas(_ command: CommandID, from entry: CommandEntry) {}
    func requestOpen() {}
    func applyFocus(_ focus: FocusContext) {}
    func showInspector(_ visible: Bool) {}
}

@Test @MainActor func accessSessionNoopArrowPreservesSuspendedOpen() async throws {
    for covered in [true, false] {
        let host = PendingAccessHost()
        host.covered = covered
        let session = ViewerSession(host: host)
        let loaderGate = AccessSuspension()
        session.openImage(host.file, maximumPixelSize: 1) {
            await loaderGate.suspend()
            throw ImageLoadError(.cancelled)
        }
        await loaderGate.waitUntilEntered()
        try await withAsyncTeardown {
            let operation = host.intent.begin()
            let suspended = AccessSuspension()
            let opening = Task { @MainActor in
                try await operation.wait { await suspended.suspend() }
                host.installed = host.file
            }
            await suspended.waitUntilEntered()
            #expect(CommandRouter().route(.next, from: .key, to: session))
            #expect(host.decision == (covered ? .end : .needsGrant(URL(fileURLWithPath: "/photos", isDirectory: false))))
            // Cancel the prompt, or grant the containing folder and still reach the end.
            if !covered {
                host.covered = true
                #expect(CommandRouter().route(.next, from: .menu, to: session))
                #expect(host.decision == .end)
            }
            await suspended.resume()
            let result = await opening.result
            #expect(throws: Never.self) { try result.get() }
            #expect(host.installed == host.file)
        } teardown: {
            session.closeImage(); await loaderGate.resume()
        }
    }
}

@Test @MainActor func accessSessionGrantCancelStillInstallsDecodedPendingImage() async throws {
    let host = PendingAccessHost()
    host.covered = false
    let session = ViewerSession(host: host)
    let loaderGate = AccessSuspension()
    session.openImage(host.file, maximumPixelSize: 1) {
        await loaderGate.suspend()
        throw ImageLoadError(.cancelled)
    }
    await loaderGate.waitUntilEntered()
    try await withAsyncTeardown { () async throws in
        let operation = host.intent.begin()
        let suspended = AccessSuspension()
        let access = AccessProbe()
        let pipeline = AccessPipelineProbe(access: access)
        let opening = Task { @MainActor in
            // Controlled suspension at the access-services boundary, before source acquisition.
            try await operation.wait { await suspended.suspend() }
            let source = try await AccessImageSource.open(.fileGrant(host.file), access: access, pipeline: pipeline)
            guard operation.isCurrent else { await source.close(); return false }
            let (request, image) = try await source.image(maximumPixelSize: 1)
            let installed = operation.isCurrent && image.image.width == 1 && image.image.height == 1
            if installed { host.installed = request.fileURL }
            await source.close()
            return installed
        }
        await suspended.waitUntilEntered()
        #expect(CommandRouter().route(.next, from: .button, to: session))
        #expect(host.decision == .needsGrant(URL(fileURLWithPath: "/photos", isDirectory: false)))
        // Cancel performs no grant and no new open.
        await suspended.resume()
        #expect(try await opening.value)
        #expect(host.installed == host.file)
        #expect(await access.count() == 0)
    } teardown: {
        session.closeImage(); await loaderGate.resume()
    }
}
