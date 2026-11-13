import Foundation
import Testing
import MadoCore
@testable import MadoApplication

private actor LoadLease: AccessLeasing {
    let root: URL
    init(root: URL) { self.root = root }
    func acquire(_ request: AccessRequest) -> AccessLease { AccessLease(url: root, rootID: AccessRootID()) }
    func release(_ lease: AccessLease) {}
}

private actor BlockedCounter: SidebarFolderEnumerating {
    let child: URL
    private var permitted = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(child: URL) { self.child = child }
    func children(in folder: URL, root: URL) -> [URL] { [child] }
    func imageCount(in folder: URL, root: URL) async -> Int {
        if !permitted { await withCheckedContinuation { waiters.append($0) } }
        return folder == root ? 5 : 1234
    }
    func release() {
        permitted = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

// The outer limit only guards a missing callback; the assertions follow actual row and count events.
@Test(.timeLimit(.minutes(3))) @MainActor func sidebarSlowCounterDoesNotDelayRows() async throws {
    let root = URL(fileURLWithPath: "/tmp/mado-sidebar-root")
    let child = root.appendingPathComponent("Trip")
    let counter = BlockedCounter(child: child)
    try await withAsyncTeardown {
        let browser = SidebarFolderBrowser(access: LoadLease(root: root), enumerator: counter)
        let session = SidebarFolderLoadSession(browser: browser)
        var rowURLs: [URL] = []
        var counts: [URL: Int] = [:]
        var rowsSignal: AsyncStream<Void>.Continuation!
        let rows = AsyncStream<Void> { rowsSignal = $0 }
        var countSignal: AsyncStream<Void>.Continuation!
        let countUpdates = AsyncStream<Void> { countSignal = $0 }
        session.start(folder: root, rootID: AccessRootID(), onRows: { urls, _ in
            rowURLs = urls
            rowsSignal.yield()
        }, onCount: { url, count in
            counts[url] = count
            countSignal.yield()
        })
        var rowIterator = rows.makeAsyncIterator()
        _ = await rowIterator.next()
        try #require(rowURLs == [child])
        #expect(counts.isEmpty)
        await counter.release()
        var countIterator = countUpdates.makeAsyncIterator()
        while counts[root] != 5 || counts[child] != 1234 {
            guard await countIterator.next() != nil else { break }
        }
        #expect(counts[root] == 5)
        #expect(counts[child] == 1234)
        session.cancel()
        #expect(counts[child] == 1234)
    } teardown: {
        await counter.release()
    }
}

private enum SidebarFailure: Error { case unavailable }

private actor FailingSidebarEnumerator: SidebarFolderEnumerating {
    enum Mode: Sendable { case listingCancelled, listingFailed, countCancelled, countFailed }
    let mode: Mode
    let child: URL
    let onFailure: @Sendable () -> Void
    init(mode: Mode, child: URL, onFailure: @escaping @Sendable () -> Void) {
        self.mode = mode; self.child = child; self.onFailure = onFailure
    }
    func children(in folder: URL, root: URL) throws -> [URL] {
        switch mode {
        case .listingCancelled:
            onFailure(); throw CancellationError()
        case .listingFailed:
            onFailure(); throw SidebarFailure.unavailable
        case .countCancelled, .countFailed:
            return [child]
        }
    }
    func imageCount(in folder: URL, root: URL) throws -> Int {
        if folder != root { return 3 }
        switch mode {
        case .countCancelled:
            onFailure(); throw CancellationError()
        case .countFailed:
            onFailure(); throw SidebarFailure.unavailable
        case .listingCancelled, .listingFailed:
            return 0
        }
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func sidebarFailuresLeaveUnknownCountsBlankAndKeepOtherRows() async throws {
    let root = URL(fileURLWithPath: "/tmp/sidebar-failure")
    let child = root.appendingPathComponent("Child")
    for mode in [FailingSidebarEnumerator.Mode.listingCancelled, .listingFailed,
        .countCancelled, .countFailed] {
        var streamContinuation: AsyncStream<Void>.Continuation!
        let events = AsyncStream<Void> { streamContinuation = $0 }
        let signal = streamContinuation!
        let counter = FailingSidebarEnumerator(mode: mode, child: child, onFailure: { signal.yield() })
        let session = SidebarFolderLoadSession(browser: SidebarFolderBrowser(
            access: LoadLease(root: root), enumerator: counter))
        var rows: [URL] = [], counts: [URL: Int] = [:]
        session.start(folder: root, rootID: AccessRootID(), onRows: { urls, _ in rows = urls },
            onCount: { counts[$0] = $1 })
        var iterator = events.makeAsyncIterator()
        _ = await iterator.next()
        try await Task.sleep(for: .milliseconds(20))
        switch mode {
        case .listingCancelled, .listingFailed:
            #expect(rows.isEmpty)
            #expect(counts.isEmpty)
        case .countCancelled:
            #expect(rows == [child])
            #expect(counts.isEmpty)
        case .countFailed:
            #expect(rows == [child])
            #expect(counts[root] == nil)
            #expect(counts[child] == 3)
        }
        session.cancel()
    }
}

private actor FixedSidebarEnumerator: SidebarFolderEnumerating {
    let child: URL
    init(child: URL) { self.child = child }
    func children(in folder: URL, root: URL) -> [URL] { [child] }
    func imageCount(in folder: URL, root: URL) -> Int {
        switch folder.lastPathComponent {
        case "Root": return 7
        case "Current": return 3
        default: return 2
        }
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func sidebarParentCurrentAndChildAllUseDirectCounter() async throws {
    let root = URL(fileURLWithPath: "/tmp/Root")
    let current = root.appendingPathComponent("Current")
    let child = current.appendingPathComponent("Child")
    let session = SidebarFolderLoadSession(browser: SidebarFolderBrowser(
        access: LoadLease(root: root), enumerator: FixedSidebarEnumerator(child: child)))
    var parent: URL?, counts: [URL: Int] = [:]
    var continuation: AsyncStream<Void>.Continuation!
    let events = AsyncStream<Void> { continuation = $0 }
    session.start(folder: current, rootID: AccessRootID(), onRows: { _, parentURL in parent = parentURL },
        onCount: { counts[$0] = $1; continuation.yield() })
    var iterator = events.makeAsyncIterator()
    for _ in 0..<3 { _ = await iterator.next() }
    #expect(parent?.pathComponents == root.pathComponents)
    #expect(counts[current] == 3)
    #expect(counts[child] == 2)
    #expect(counts.first(where: { $0.key.pathComponents == root.pathComponents })?.value == 7)
    session.cancel()
}
