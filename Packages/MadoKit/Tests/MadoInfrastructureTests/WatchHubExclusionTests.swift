import Foundation
import Testing
import MadoCore
@testable import MadoInfrastructure

@Test(.timeLimit(.minutes(2))) func watchHubIgnoresHiddenAndPackageContentsBelowTheFolder() async throws {
    // (name, subscriber folder, changed path, delivers to recursive, delivers to flat)
    let rows: [(name: String, folder: String, changed: String, recursive: Bool, flat: Bool)] = [
        ("E1 .git object", "root/F", "root/F/.git/objects/ab/cd", false, false),
        ("E2 hidden file", "root/F", "root/F/.h.png", false, false),
        ("E3 hidden file in subfolder", "root/F", "root/F/sub/.DS_Store", false, false),
        ("E4 app package contents", "root/F", "root/F/p.app/Contents/i.png", false, false),
        ("E5 photos library contents", "root/F", "root/F/lib.photoslibrary/x.jpg", false, false),
        ("E6 package itself", "root/F", "root/F/p.app", false, false),
        ("E7 hidden directory itself", "root/F", "root/F/.git", false, false),
        ("E8 sentinel subfolder image", "root/F", "root/F/sub/x.png", true, false),
        ("E9 sentinel child image", "root/F", "root/F/x.png", true, true),
        ("E10 hidden ancestor above folder", "root/.h/F", "root/.h/F/a.png", true, true),
        ("E11 hidden folder opened directly", "root/.hid", "root/.hid/a.png", true, true),
        ("E12 package opened directly", "root/lib.photoslibrary", "root/lib.photoslibrary/a.png", true, true),
        ("E13 subfolder inside a package opened directly", "root/lib.photoslibrary", "root/lib.photoslibrary/m/a.png", true, false),
        ("E14 dotted but not hidden name", "root/F", "root/F/v1.2/a.png", true, false),
    ]
    for row in rows {
        let f = try WatchFixture(folders: [row.folder, "root/F/sub"])
        defer { f.remove() }
        let root = try await f.access.grant(folder: f.url("root"))
        let recursiveLog = ChangeLog(clock: f.clock), flatLog = ChangeLog(clock: f.clock)
        let r = try await f.hub.subscribe(rootID: root, folder: f.url(row.folder), recursive: true, onChange: recursiveLog.sink)
        let s = try await f.hub.subscribe(rootID: root, folder: f.url(row.folder), recursive: false, onChange: flatLog.sink)
        f.emit([.changed(f.url(row.changed))], at: 0)
        f.clock.advance(to: 1000)
        #expect(recursiveLog.count == (row.recursive ? 1 : 0), "row \(row.name) recursive")
        #expect(flatLog.count == (row.flat ? 1 : 0), "row \(row.name) flat")
        // mustRescan is never filtered.
        f.emit([.mustRescan], at: 1000)
        f.clock.advance(to: 2000)
        #expect(recursiveLog.count == (row.recursive ? 2 : 1) && flatLog.count == (row.flat ? 2 : 1), "row \(row.name) mustRescan")
        await r.cancel(); await s.cancel()
    }

    // One batch with an excluded and a relevant path delivers once; a batch of only excluded paths delivers nothing.
    let f = try WatchFixture(folders: ["root/F"])
    defer { f.remove() }
    let root = try await f.access.grant(folder: f.url("root"))
    let log = ChangeLog(clock: f.clock)
    let s = try await f.hub.subscribe(rootID: root, folder: f.url("root/F"), recursive: true, onChange: log.sink)
    f.emit([.changed(f.url("root/F/.git/x")), .changed(f.url("root/F/p.app/y"))], at: 0)
    f.clock.advance(to: 1000)
    #expect(log.count == 0)
    f.emit([.changed(f.url("root/F/.git/x")), .changed(f.url("root/F/a.png"))], at: 1000)
    f.clock.advance(to: 2000)
    #expect(log.times == [1200])
    await s.cancel()
}
