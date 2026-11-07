import CoreServices
import Foundation
import Testing
import MadoCore
@testable import MadoInfrastructure

@Test func watchHubForcesRescanOnDropFlagsAndReconcile() async throws {
    // (a) Every subset of 4 drop flags and 5 ordinary flags: mustRescan iff a drop flag is present.
    // RootChanged is ordinary: FSEvents sends it only with WatchRoot, which the stream does not set.
    func flag(_ value: Int) -> FSEventStreamEventFlags { FSEventStreamEventFlags(value) }
    let drops = [kFSEventStreamEventFlagMustScanSubDirs, kFSEventStreamEventFlagUserDropped, kFSEventStreamEventFlagKernelDropped,
        kFSEventStreamEventFlagEventIdsWrapped].map(flag)
    let ordinary = [kFSEventStreamEventFlagItemCreated, kFSEventStreamEventFlagItemRemoved, kFSEventStreamEventFlagItemRenamed,
        kFSEventStreamEventFlagItemModified, kFSEventStreamEventFlagRootChanged].map(flag)
    let all = drops + ordinary, changed = FolderChangeHint.changed(URL(fileURLWithPath: "/r/x.png"))
    for mask in 0..<(1 << all.count) {
        let flags = all.indices.filter { mask & (1 << $0) != 0 }.reduce(FSEventStreamEventFlags(0)) { $0 | all[$1] }
        let expected: FolderChangeHint = drops.contains { flags & $0 != 0 } ? .mustRescan : changed
        #expect(FSEventSource.hint(path: "/r/x.png", flags: flags) == expected, "flags \(String(flags, radix: 2))")
    }
    for drop in drops { #expect(FSEventSource.hint(path: "/r/x.png", flags: drop) == .mustRescan, "drop \(drop) alone") }
    #expect(FSEventSource.hint(path: "/r/x.png", flags: ordinary[0]) == changed)
    #expect(FSEventSource.hint(path: "/r/x.png", flags: ordinary[0] | drops[0]) == .mustRescan)
    #expect(FSEventSource.hint(path: "/r/x.png", flags: 0) == changed)

    // (b) mustRescan on root 1 skips the filter for flat A and recursive sibling B; the other root hears nothing.
    let f = try WatchFixture(folders: ["root/A", "root/B", "other/C"])
    defer { f.remove() }
    let root = try await f.access.grant(folder: f.url("root")), other = try await f.access.grant(folder: f.url("other"))
    func logs() -> (ChangeLog, ChangeLog, ChangeLog) { (ChangeLog(clock: f.clock), ChangeLog(clock: f.clock), ChangeLog(clock: f.clock)) }
    var (a, b, o) = logs()
    var sa = try await f.hub.subscribe(rootID: root, folder: f.url("root/A"), recursive: false, onChange: a.sink)
    var sb = try await f.hub.subscribe(rootID: root, folder: f.url("root/B"), recursive: true, onChange: b.sink)
    var so = try await f.hub.subscribe(rootID: other, folder: f.url("other/C"), recursive: true, onChange: o.sink)
    f.source.emit([.mustRescan], on: f.url("root"))
    f.clock.advance(to: 200)
    #expect(a.times == [200])
    #expect(b.times == [200])
    #expect(o.count == 0)
    await sa.cancel(); await sb.cancel(); await so.cancel()

    // (c) reconcileAll: immediate, once per live subscriber, none for cancelled ones, no stream or lease churn.
    let g = try WatchFixture(folders: ["root/A", "root/B", "other/C"])
    defer { g.remove() }
    let root2 = try await g.access.grant(folder: g.url("root")), other2 = try await g.access.grant(folder: g.url("other"))
    (a, b, o) = (ChangeLog(clock: g.clock), ChangeLog(clock: g.clock), ChangeLog(clock: g.clock))
    sa = try await g.hub.subscribe(rootID: root2, folder: g.url("root/A"), recursive: false, onChange: a.sink)
    sb = try await g.hub.subscribe(rootID: root2, folder: g.url("root/B"), recursive: true, onChange: b.sink)
    so = try await g.hub.subscribe(rootID: other2, folder: g.url("other/C"), recursive: true, onChange: o.sink)
    await sb.cancel()
    let before = (starts: g.source.starts, scope: g.scope.counts)
    g.hub.reconcileAll()
    #expect(a.times == [0])
    #expect(o.times == [0])
    #expect(b.count == 0)
    g.clock.advance(to: 2000)
    #expect(a.count == 1 && o.count == 1, "reconcileAll left a debounce flush behind")
    g.hub.reconcileAll()
    #expect(a.count == 2 && o.count == 2 && b.count == 0)
    #expect(g.source.starts == before.starts && g.scope.counts == before.scope)
    await sa.cancel(); await so.cancel()
    let after = (starts: g.source.starts, scope: g.scope.counts)
    g.hub.reconcileAll()
    g.clock.advance(to: 4000)
    #expect(a.count == 2 && o.count == 2 && b.count == 0)
    #expect(g.source.starts == after.starts && g.scope.counts == after.scope)

    // (d) Chosen policy: a pending window is folded into the immediate delivery, so it flushes exactly once.
    let h = try WatchFixture(folders: ["root/A"])
    defer { h.remove() }
    let root3 = try await h.access.grant(folder: h.url("root")), log = ChangeLog(clock: h.clock)
    let s = try await h.hub.subscribe(rootID: root3, folder: h.url("root/A"), recursive: false, onChange: log.sink)
    let hint = FolderChangeHint.changed(h.url("root/A/x.png"))
    h.source.emit([hint], on: h.url("root"))
    h.clock.advance(to: 50)
    h.hub.reconcileAll()
    h.clock.advance(to: 2000)
    #expect(log.times == [50])
    await s.cancel()
}
