import Testing
import PicseeCore
import PicseeApplication

private struct Issue492Trace: Sendable {
    let start: Int
    let steps: [CommandID]
    let end: Int
    let wraps: Bool
}

private let issue492Traces: [Issue492Trace] = [
    .init(start: 0, steps: [.next], end: 1, wraps: false),
    .init(start: 0, steps: [.next, .next, .previous], end: 1, wraps: false),
    .init(start: 4, steps: [.next], end: 0, wraps: true),
    .init(start: 0, steps: [.previous], end: 4, wraps: true),
    .init(start: 0, steps: [.next, .previous], end: 0, wraps: false)
]

@Test(arguments: issue492Traces) @MainActor
private func issue492SingleReturnTransfersSelection(trace: Issue492Trace) throws {
    let ids = sessionItems(5), session = ViewerSession(), router = CommandRouter()
    let host = FakeSessionHost(); session.host = host
    defer { withExtendedLifetime(host) {} }
    session.beginBrowsing(items: ids, sourceVersion: .init(1), scrollAnchor: ids[3])
    session.select(ids[trace.start])
    session.setFolderLoopEnabled(trace.wraps)
    try #require(router.route(.preview, from: .key, to: session))
    for step in trace.steps { try #require(router.route(step, from: .key, to: session)) }
    try #require(session.currentItemID == ids[trace.end])
    #expect(session.previewSet?.itemIDs == ids)
    try #require(router.route(.escape, from: .key, to: session))
    #expect(session.mode == .browsing)
    #expect(session.selection.selectedItemIDs == [ids[trace.end]])
    #expect(session.currentItemID == ids[trace.end])
    #expect(session.scrollAnchor == ids[trace.end])
    try #require(router.route(.preview, from: .key, to: session))
    #expect(session.currentItemID == ids[trace.end])
}

@Test(arguments: [0, 1, 2, 3]) @MainActor
func issue492MultiReturnConservesPicks(trace: Int) throws {
    let ids = sessionItems(5), session = ViewerSession(), router = CommandRouter()
    let host = FakeSessionHost(); session.host = host
    defer { withExtendedLifetime(host) {} }
    session.beginBrowsing(items: ids, sourceVersion: .init(1), scrollAnchor: ids[1])
    for index in [0, 2, 4] { session.select(ids[index], modifier: .command) }
    if trace == 2 { session.focus(ids[0]) }
    let start = trace == 2 ? ids[0] : ids[4]
    session.setFolderLoopEnabled(trace == 1 || trace == 2)
    try #require(router.route(.preview, from: .key, to: session))
    try #require(session.currentItemID == start)
    let steps: [CommandID] = trace == 0 ? [.previous] : trace == 1 ? [.next, .next] : trace == 2 ? [.previous] : [.previous, .next]
    let end = trace <= 1 ? ids[2] : ids[4]
    for step in steps { try #require(router.route(step, from: .key, to: session)) }
    try #require(session.currentItemID == end)
    #expect(session.previewSet?.itemIDs == [ids[0], ids[2], ids[4]])
    try #require(router.route(.escape, from: .key, to: session))
    #expect(session.selection.selectedItemIDs == [ids[0], ids[2], ids[4]])
    #expect(session.selection.anchorItemID == ids[4])
    #expect(session.currentItemID == end)
    #expect(session.scrollAnchor == end)
    try #require(router.route(.preview, from: .key, to: session))
    #expect(session.currentItemID == end)
}

@Test(arguments: [false, true], [false, true]) @MainActor
func issue492NoPageRestoresConcreteScroll(multi: Bool, blockedPage: Bool) throws {
    let ids = sessionItems(5), session = ViewerSession(), router = CommandRouter()
    let host = FakeSessionHost(); session.host = host
    defer { withExtendedLifetime(host) {} }
    session.beginBrowsing(items: ids, sourceVersion: .init(1), scrollAnchor: ids[1])
    if multi { for index in [0, 2] { session.select(ids[index], modifier: .command) } }
    session.select(ids[4], modifier: multi ? .command : .plain)
    let entry = session.selection
    try #require(router.route(.preview, from: .key, to: session))
    try #require(session.mode == .viewing)
    if blockedPage { _ = router.route(.next, from: .key, to: session) }
    try #require(router.route(.escape, from: .key, to: session))
    #expect(session.mode == .browsing)
    #expect(session.selection == entry)
    #expect(session.currentItemID == ids[4])
    #expect(session.scrollAnchor == ids[1])
}

@Test @MainActor func issue492MultiDeletedScrollAnchorRestoresNil() throws {
    let ids = sessionItems(5), session = ViewerSession(), router = CommandRouter()
    let host = FakeSessionHost(); session.host = host
    defer { withExtendedLifetime(host) {} }
    session.beginBrowsing(items: ids, sourceVersion: .init(1), scrollAnchor: ids[1])
    for index in [0, 2, 4] { session.select(ids[index], modifier: .command) }
    try #require(session.scrollAnchor == ids[1])
    try #require(router.route(.preview, from: .key, to: session))
    session.updateItems([ids[0], ids[2], ids[3], ids[4]], sourceVersion: .init(2))
    try #require(session.mode == .viewing)
    try #require(router.route(.escape, from: .key, to: session))
    #expect(session.mode == .browsing)
    #expect(session.selection.selectedItemIDs == [ids[0], ids[2], ids[4]])
    #expect(session.currentItemID == ids[4])
    #expect(session.selection.anchorItemID == ids[4])
    #expect(session.scrollAnchor == nil)
}

@Test(arguments: [false, true]) @MainActor
func issue492MultiShrinkRetainsEntryClassification(deleteBeforePage: Bool) throws {
    let ids = sessionItems(5), session = ViewerSession(), router = CommandRouter()
    let host = FakeSessionHost(); session.host = host
    defer { withExtendedLifetime(host) {} }
    session.beginBrowsing(items: ids, sourceVersion: .init(1), scrollAnchor: ids[1])
    for index in [0, 2, 4] { session.select(ids[index], modifier: .command) }
    try #require(router.route(.preview, from: .key, to: session))
    try #require(router.route(.previous, from: .key, to: session))
    // Both orders retain a successful page, and deletion cannot turn this into a folder preview.
    if !deleteBeforePage { try #require(router.route(.next, from: .key, to: session)) }
    let available = [ids[2], ids[3]]
    session.updateItems(available, sourceVersion: .init(2))
    session.updateItems(available, sourceVersion: .init(3))
    #expect(session.previewSet?.itemIDs == [ids[2]])
    #expect(session.previewSet?.origin.selection.anchorItemID == nil)
    if deleteBeforePage { _ = router.route(.next, from: .key, to: session) }
    try #require(router.route(.escape, from: .key, to: session))
    #expect(session.selection.selectedItemIDs == [ids[2]])
    #expect(session.selection.anchorItemID == nil)
    #expect(session.currentItemID == ids[2])
    #expect(session.scrollAnchor == ids[2])
    try #require(router.route(.preview, from: .key, to: session))
    session.updateItems([], sourceVersion: .init(4))
    #expect(session.mode == .browsing)
    #expect(session.currentItemID == nil)
    #expect(session.selection.selectedItemIDs.isEmpty)
    #expect(session.scrollAnchor == nil)
}
