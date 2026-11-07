import Foundation
import Testing
import MadoCore
import MadoInfrastructure

private let personalStoreRoot = ItemIdentityRoot(id: AccessRootID(), url: URL(fileURLWithPath: "/pictures-personal"))
private func personalRef(_ name: String, fileNumber: UInt64 = 1, root: ItemIdentityRoot = personalStoreRoot) -> PersonalImageRef {
    PersonalImageRef(fileURL: root.url.appendingPathComponent(name), root: root, fileNumber: fileNumber)!
}
private func personalStoreDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
}
private func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + seconds) }

@Test func personalImageStoreRecentsBoundOrderUnique() async throws {
    let base = personalStoreDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    for seed in UInt64(1)...20 {
        var rng = SplitMix64(seed: seed)
        let store = PersonalImageStore(url: base.appendingPathComponent("\(seed).json"))
        let refs = (0..<Int.random(in: 1...80, using: &rng)).map { personalRef("r\($0).jpg") }
        var oracle: [PersonalImageRef] = []
        for step in 0..<Int.random(in: 0...120, using: &rng) {
            let ref = refs.randomElement(using: &rng)!
            try await store.recordVisit(ref, at: at(Double(step)))
            oracle.removeAll { $0 == ref }; oracle.insert(ref, at: 0)
        }
        let recents = try await store.recents()
        #expect(recents.count == min(PersonalImageStore.recentLimit, oracle.count), "seed \(seed)")
        #expect(recents.map(\.ref) == Array(oracle.prefix(50)), "seed \(seed)")
        #expect(zip(recents, recents.dropFirst()).allSatisfy { $0.viewedAt >= $1.viewedAt }, "seed \(seed)")
        #expect(Set(recents.map(\.ref)).count == recents.count, "seed \(seed)")
    }
    #expect(PersonalImageStore.recentLimit == 50)
}

@Test func personalImageStoreRecentsOrderByVisitTime() async throws {
    let base = personalStoreDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let (a, b) = (personalRef("a.jpg"), personalRef("b.jpg"))
    let older = PersonalImageStore(url: base.appendingPathComponent("older.json"))
    try await older.recordVisit(a, at: at(3)); try await older.recordVisit(b, at: at(1))
    #expect(try await older.recents().map(\.ref) == [a, b])
    let tie = PersonalImageStore(url: base.appendingPathComponent("tie.json"))
    try await tie.recordVisit(a, at: at(4)); try await tie.recordVisit(b, at: at(4))
    #expect(try await tie.recents().map(\.ref) == [b, a])
    let back = PersonalImageStore(url: base.appendingPathComponent("back.json"))
    try await back.recordVisit(a, at: at(5)); try await back.recordVisit(b, at: at(6)); try await back.recordVisit(a, at: at(2))
    #expect(try await back.recents() == [PersonalImageVisit(ref: b, viewedAt: at(6)), PersonalImageVisit(ref: a, viewedAt: at(2))])
    #expect(try await back.recents().map(\.viewedAt) == [at(6), at(2)])
}

@Test func personalImageStoreRecentsBoundaries() async throws {
    let base = personalStoreDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let store = PersonalImageStore(url: base.appendingPathComponent("p.json"))
    #expect(try await store.recents().isEmpty)
    #expect(try await store.favorites().isEmpty)
    let refs = (0...50).map { personalRef("v\($0).jpg") }
    for (index, ref) in refs.prefix(50).enumerated() { try await store.recordVisit(ref, at: at(100 + Double(index))) }
    let full = try await store.recents()
    #expect(full.count == 50 && full.last?.ref == refs[0] && full.first?.ref == refs[49])
    try await store.recordVisit(refs[50], at: at(1))
    #expect(try await store.recents() == full)
    #expect(try await !store.recents().contains { $0.ref == refs[50] })
    try await store.recordVisit(refs[50], at: at(200))
    let shifted = try await store.recents()
    #expect(shifted.count == 50 && shifted.first?.ref == refs[50] && !shifted.contains { $0.ref == refs[0] })
}

@Test func personalImageStoreRevisitMovesToFrontAndRefreshesFingerprint() async throws {
    let base = personalStoreDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let store = PersonalImageStore(url: base.appendingPathComponent("p.json"))
    try await store.recordVisit(personalRef("a.jpg", fileNumber: 1), at: at(1))
    try await store.recordVisit(personalRef("b.jpg"), at: at(2))
    try await store.recordVisit(personalRef("a.jpg", fileNumber: 9), at: at(3))
    let recents = try await store.recents()
    #expect(recents.map(\.ref) == [personalRef("a.jpg"), personalRef("b.jpg")])
    #expect(recents.first?.viewedAt == at(3) && recents.first?.ref.fileNumber == 9)
}

@Test func personalImageStoreToggleFavoriteInvolution() async throws {
    let base = personalStoreDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let store = PersonalImageStore(url: base.appendingPathComponent("p.json"))
    let (a, b, c) = (personalRef("a.jpg"), personalRef("b.jpg"), personalRef("c.jpg"))
    #expect(try await store.toggleFavorite(a)); #expect(try await store.toggleFavorite(b))
    #expect(try await store.favorites() == [b, a])
    #expect(try await store.toggleFavorite(c))
    #expect(try await store.isFavorite(c.itemID))
    #expect(try await !store.toggleFavorite(personalRef("c.jpg", fileNumber: 42)))
    #expect(try await !store.isFavorite(c.itemID))
    #expect(try await store.favorites() == [b, a])
    #expect(try await !store.toggleFavorite(a)); #expect(try await !store.isFavorite(a.itemID))
    #expect(try await store.toggleFavorite(a)); #expect(try await store.isFavorite(a.itemID))
    #expect(try await store.favorites() == [a, b])
    try await store.recordVisit(c, at: at(1))
    #expect(try await !store.isFavorite(c.itemID))
    let otherRoot = ItemIdentityRoot(id: AccessRootID(), url: personalStoreRoot.url)
    #expect(try await store.toggleFavorite(personalRef("a.jpg", root: otherRoot)))
    #expect(try await store.favorites().count == 3)
    let many = PersonalImageStore(url: base.appendingPathComponent("many.json"))
    let refs = (0..<60).map { personalRef("f\($0).jpg") }
    for ref in refs { #expect(try await many.toggleFavorite(ref)) }
    #expect(try await many.favorites() == refs.reversed())
}

@Test func personalImageStoreRelaunchRoundTrip() async throws {
    let base = personalStoreDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let path = base.appendingPathComponent("support/personal-images.json")
    let store = PersonalImageStore(url: path)
    for name in ["x.jpg", "y.jpg", "z.jpg"] { _ = try await store.toggleFavorite(personalRef(name, fileNumber: 5)) }
    let times = [0.25, 1.125, 2.5, 3.0625, 4.75]
    for (index, time) in times.enumerated() {
        try await store.recordVisit(personalRef("v\(index).jpg", fileNumber: UInt64(index)), at: at(time))
    }
    let favorites = try await store.favorites(), recents = try await store.recents()
    let relaunched = PersonalImageStore(url: path)
    #expect(try await relaunched.favorites() == favorites)
    #expect(try await relaunched.favorites().map(\.fileNumber) == [5, 5, 5])
    let reread = try await relaunched.recents()
    #expect(reread == recents)
    #expect(reread.map(\.viewedAt) == times.reversed().map(at))
    #expect(reread.map(\.ref.fileNumber) == [4, 3, 2, 1, 0])
    #expect(await !relaunched.storeCorrupt)
}

@Test func personalImageStoreCorruptRecoversToSidecar() async throws {
    let fm = FileManager.default
    for bytes in [Data("{nope".utf8)] {
        let base = personalStoreDirectory()
        defer { try? fm.removeItem(at: base) }
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let path = base.appendingPathComponent("personal-images.json")
        let recovery = path.appendingPathExtension("recovered")
        try bytes.write(to: path)
        let store = PersonalImageStore(url: path)
        #expect(try await store.favorites().isEmpty)
        #expect(try await store.recents().isEmpty)
        #expect(await store.storeCorrupt)
        let (a, b) = (personalRef("a.jpg"), personalRef("b.jpg"))
        #expect(try await store.toggleFavorite(a))
        try await store.recordVisit(b, at: at(1))
        #expect(try Data(contentsOf: path) == bytes)
        #expect(fm.fileExists(atPath: recovery.path))
        let relaunched = PersonalImageStore(url: path)
        #expect(try await relaunched.favorites() == [a])
        #expect(try await relaunched.recents().map(\.ref) == [b])
        #expect(await relaunched.storeCorrupt)
        #expect(try await relaunched.toggleFavorite(b))
        #expect(try Data(contentsOf: path) == bytes)
        #expect(try await PersonalImageStore(url: path).favorites() == [b, a])
        try Data("broken recovery".utf8).write(to: recovery)
        let both = PersonalImageStore(url: path)
        #expect(try await both.favorites().isEmpty)
        #expect(try await both.toggleFavorite(a))
        #expect(try await PersonalImageStore(url: path).favorites() == [a])
        #expect(try Data(contentsOf: path) == bytes)
    }
}

@Test func personalImageStoreLeavesRecentFoldersUntouched() async throws {
    let fm = FileManager.default
    let base = personalStoreDirectory()
    defer { try? fm.removeItem(at: base) }
    let folders = RecentFolderStore(url: base.appendingPathComponent("recent-folders.json"))
    let first = RecentFolder(rootID: personalStoreRoot.id, url: personalStoreRoot.url, displayName: "pictures")
    let second = RecentFolder(rootID: AccessRootID(), url: base, displayName: "other")
    try await folders.add(first); try await folders.add(second)
    let before = try Data(contentsOf: base.appendingPathComponent("recent-folders.json"))
    let listed = try await folders.load()
    let store = PersonalImageStore(url: base.appendingPathComponent("personal-images.json"))
    _ = try await store.toggleFavorite(personalRef("a.jpg")); _ = try await store.toggleFavorite(personalRef("a.jpg"))
    for index in 0..<60 { try await store.recordVisit(personalRef("v\(index).jpg"), at: at(Double(index))) }
    try Data("{nope".utf8).write(to: base.appendingPathComponent("personal-images.json"))
    _ = try await PersonalImageStore(url: base.appendingPathComponent("personal-images.json")).toggleFavorite(personalRef("b.jpg"))
    #expect(try Data(contentsOf: base.appendingPathComponent("recent-folders.json")) == before)
    #expect(try await RecentFolderStore(url: base.appendingPathComponent("recent-folders.json")).load() == listed)
    #expect(try await store.recents().allSatisfy { $0.ref.rootID == personalStoreRoot.id && $0.ref.relativePath.hasSuffix(".jpg") })
}

@Test func personalImageStoreFileHoldsRefsOnly() async throws {
    let fm = FileManager.default
    let base = personalStoreDirectory()
    defer { try? fm.removeItem(at: base) }
    let path = base.appendingPathComponent("personal-images.json")
    let store = PersonalImageStore(url: path)
    _ = try await store.toggleFavorite(personalRef("a.jpg")); _ = try await store.toggleFavorite(personalRef("sub/b.jpg"))
    try await store.recordVisit(personalRef("c.jpg"), at: at(1)); try await store.recordVisit(personalRef("d.jpg", fileNumber: 2), at: at(2))
    try #require(fm.fileExists(atPath: path.path), "the store wrote its file")
    let data = try Data(contentsOf: path)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(object.keys) == ["version", "favorites", "recents"])
    #expect(object["version"] as? Int == 1)
    let favorites = try #require(object["favorites"] as? [[String: Any]])
    let recents = try #require(object["recents"] as? [[String: Any]])
    #expect(favorites.allSatisfy { Set($0.keys).isSubset(of: ["rootID", "relativePath", "fileNumber"]) })
    #expect(recents.allSatisfy { Set($0.keys) == ["ref", "viewedAt"] })
    let text = String(decoding: data, as: UTF8.self)
    #expect(!text.contains(personalStoreRoot.url.path) && !text.contains("/Users") && !text.contains("/private"))
    #expect(data.count < 2048)
}

/// Writes a valid store file at `url`: favorites toggled in order, then visits, through a store on a
/// scratch path, so that no store on `url` reads or retires a recovery file next to it.
private func personalStoreFile(_ url: URL, favorites: [PersonalImageRef] = [], visits: [(PersonalImageRef, Double)] = []) async throws {
    let fm = FileManager.default
    let scratch = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    let writer = PersonalImageStore(url: scratch)
    for ref in favorites { _ = try await writer.toggleFavorite(ref) }
    for (ref, time) in visits { try await writer.recordVisit(ref, at: at(time)) }
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
    try fm.moveItem(at: scratch, to: url)
}
private func setPermissions(_ url: URL, _ mode: Int) throws {
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
}

@Test func personalImageStoreTransientReadErrorWritesNothing() async throws {
    let fm = FileManager.default
    let base = personalStoreDirectory()
    defer { try? fm.removeItem(at: base) }
    let path = base.appendingPathComponent("personal-images.json")
    let recovery = path.appendingPathExtension("recovered")
    let (a, b) = (personalRef("a.jpg"), personalRef("b.jpg"))
    let store = PersonalImageStore(url: path)
    #expect(try await store.toggleFavorite(a))
    let bytes = try Data(contentsOf: path)
    try setPermissions(path, 0o000)
    for reader in [store, PersonalImageStore(url: path)] {
        await #expect(throws: (any Error).self) { try await reader.favorites() }
        await #expect(throws: (any Error).self) { try await reader.recents() }
        await #expect(throws: (any Error).self) { try await reader.isFavorite(a.itemID) }
        await #expect(throws: (any Error).self) { try await reader.toggleFavorite(b) }
        await #expect(throws: (any Error).self) { try await reader.recordVisit(b, at: at(1)) }
        #expect(await !reader.storeCorrupt)
    }
    #expect(!fm.fileExists(atPath: recovery.path), "an unreadable file is not a damaged one")
    try setPermissions(path, 0o644)
    #expect(try Data(contentsOf: path) == bytes)
    #expect(try await store.favorites() == [a])
    #expect(try await store.toggleFavorite(b))
    #expect(try await PersonalImageStore(url: path).favorites() == [b, a])

    // While the primary is damaged, an unreadable recovery file is not replaced either.
    try Data("{nope".utf8).write(to: path)
    #expect(try await store.toggleFavorite(a))
    let recovered = try Data(contentsOf: recovery)
    try setPermissions(recovery, 0o000)
    let damaged = PersonalImageStore(url: path)
    await #expect(throws: (any Error).self) { try await damaged.toggleFavorite(b) }
    await #expect(throws: (any Error).self) { try await damaged.favorites() }
    #expect(await damaged.storeCorrupt)
    try setPermissions(recovery, 0o644)
    #expect(try Data(contentsOf: recovery) == recovered)
    #expect(try await damaged.favorites() == [a])
}

@Test func personalImageStoreRecoveredWritesSurviveRepair() async throws {
    let fm = FileManager.default
    let (a, b, c, d) = (personalRef("a.jpg"), personalRef("b.jpg"), personalRef("c.jpg"), personalRef("d.jpg"))
    let (x, y) = (personalRef("x.jpg"), personalRef("y.jpg"))
    func paths() throws -> (base: URL, path: URL, recovery: URL) {
        let base = personalStoreDirectory()
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let path = base.appendingPathComponent("personal-images.json")
        return (base, path, path.appendingPathExtension("recovered"))
    }

    // Writes made while the primary was damaged survive its repair, then move into it.
    let repair = try paths()
    defer { try? fm.removeItem(at: repair.base) }
    try Data("{nope".utf8).write(to: repair.path)
    let store = PersonalImageStore(url: repair.path)
    #expect(try await store.toggleFavorite(a))
    try await store.recordVisit(x, at: at(1))
    try fm.removeItem(at: repair.path)
    try await personalStoreFile(repair.path, favorites: [b], visits: [(y, 2)])
    let repaired = PersonalImageStore(url: repair.path)
    #expect(try await repaired.favorites() == [a, b])
    #expect(try await repaired.recents().map(\.ref) == [y, x])
    #expect(await !repaired.storeCorrupt)
    #expect(try await repaired.toggleFavorite(c))
    #expect(!fm.fileExists(atPath: repair.recovery.path))
    #expect(try await PersonalImageStore(url: repair.path).favorites() == [c, a, b])
    #expect(try await PersonalImageStore(url: repair.path).recents().map(\.ref) == [y, x])

    // A deleted primary does not hide the recovery file.
    let deleted = try paths()
    defer { try? fm.removeItem(at: deleted.base) }
    try Data("{nope".utf8).write(to: deleted.path)
    #expect(try await PersonalImageStore(url: deleted.path).toggleFavorite(a))
    try fm.removeItem(at: deleted.path)
    let fresh = PersonalImageStore(url: deleted.path)
    #expect(try await fresh.favorites() == [a])
    #expect(try await fresh.toggleFavorite(d))
    #expect(!fm.fileExists(atPath: deleted.recovery.path))
    #expect(try await PersonalImageStore(url: deleted.path).favorites() == [d, a])

    // Merge: recovery favorites first, then the primary's others; each ref keeps its newest visit; by date; at most 50.
    let merge = try paths()
    defer { try? fm.removeItem(at: merge.base) }
    try await personalStoreFile(merge.recovery, favorites: [c, personalRef("a.jpg", fileNumber: 7)],
        visits: [(x, 3), (personalRef("o.jpg", fileNumber: 2), 5)])
    try await personalStoreFile(merge.path, favorites: [personalRef("a.jpg", fileNumber: 3), b],
        visits: [(y, 2), (personalRef("o.jpg", fileNumber: 1), 1), (personalRef("p.jpg", fileNumber: 6), 4)])
    let merged = PersonalImageStore(url: merge.path)
    #expect(try await merged.favorites() == [a, c, b])
    #expect(try await merged.favorites().first?.fileNumber == 7)
    let mergedRecents = try await merged.recents()
    #expect(mergedRecents.map(\.ref) == [personalRef("o.jpg"), personalRef("p.jpg"), x, y])
    #expect(mergedRecents.first?.ref.fileNumber == 2 && mergedRecents.first?.viewedAt == at(5))
    try fm.removeItem(at: merge.recovery)
    try await personalStoreFile(merge.recovery, visits: [(personalRef("p.jpg", fileNumber: 9), 0)])
    let older = try await PersonalImageStore(url: merge.path).recents()
    #expect(older.first { $0.ref == personalRef("p.jpg") }?.ref.fileNumber == 6, "the primary's newer visit wins")

    let bound = try paths()
    defer { try? fm.removeItem(at: bound.base) }
    try await personalStoreFile(bound.recovery, visits: (0..<30).map { (personalRef("s\($0).jpg"), 100 + Double($0) * 2) })
    try await personalStoreFile(bound.path, visits: (0..<30).map { (personalRef("p\($0).jpg"), 101 + Double($0) * 2) })
    let boundStore = PersonalImageStore(url: bound.path)
    let newest = try await boundStore.recents()
    #expect(newest.count == 50)
    #expect(newest.map(\.viewedAt) == (0..<50).map { at(159 - Double($0)) })
    _ = try await boundStore.toggleFavorite(a)
    #expect(try await PersonalImageStore(url: bound.path).recents() == newest)
}

@Test func personalImageStoreTwoInstancesKeepEveryWrite() async throws {
    let fm = FileManager.default
    let base = personalStoreDirectory()
    defer { try? fm.removeItem(at: base) }
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    let path = base.appendingPathComponent("personal-images.json")
    // The same file through the /var link and through its /private target.
    let alias = URL(fileURLWithPath: path.path.hasPrefix("/private/") ? String(path.path.dropFirst(8)) : "/private" + path.path)
    try #require(alias.path != path.path)
    try Data().write(to: alias.appendingPathExtension("probe"))
    try #require(fm.fileExists(atPath: path.appendingPathExtension("probe").path), "both spellings name one folder")
    let (visits, favorites) = (PersonalImageStore(url: path), PersonalImageStore(url: alias))
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { for i in 0..<200 { try await visits.recordVisit(personalRef("v\(i).jpg"), at: at(Double(i))) } }
        group.addTask { for i in 0..<200 { _ = try await favorites.toggleFavorite(personalRef("f\(i).jpg")) } }
        try await group.waitForAll()
    }
    let fresh = PersonalImageStore(url: path)
    #expect(try await fresh.favorites() == (0..<200).reversed().map { personalRef("f\($0).jpg") })
    #expect(try await fresh.recents().map(\.ref) == (150..<200).reversed().map { personalRef("v\($0).jpg") })
}

@Test func personalImageStoreRevisitRefreshesFavoriteFileNumber() async throws {
    let base = personalStoreDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let path = base.appendingPathComponent("personal-images.json")
    let store = PersonalImageStore(url: path)
    let (a, b) = (personalRef("a.jpg", fileNumber: 1), personalRef("b.jpg", fileNumber: 1))
    _ = try await store.toggleFavorite(a); _ = try await store.toggleFavorite(b)
    try await store.recordVisit(personalRef("a.jpg", fileNumber: 9), at: at(1))
    #expect(try await store.favorites() == [b, a])
    #expect(try await store.favorites().map(\.fileNumber) == [1, 9])
    try await store.recordVisit(personalRef("c.jpg", fileNumber: 4), at: at(2))
    #expect(try await store.favorites() == [b, a], "a visit never adds a favorite")
    #expect(try await PersonalImageStore(url: path).favorites().map(\.fileNumber) == [1, 9])
}

@Test func personalImageStoreKeepsUnicodeSpellingsApart() async throws {
    let base = personalStoreDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let store = PersonalImageStore(url: base.appendingPathComponent("p.json"))
    let (compatibility, unified) = (personalRef("\u{F900}.jpg"), personalRef("\u{8C48}.jpg"))
    #expect(try await store.toggleFavorite(compatibility))
    #expect(try await store.isFavorite(compatibility.itemID))
    #expect(try await !store.isFavorite(unified.itemID))
    #expect(try await store.toggleFavorite(unified), "the other spelling is another favorite")
    #expect(try await store.favorites().map(\.itemID) == [unified.itemID, compatibility.itemID])
    try await store.recordVisit(compatibility, at: at(1)); try await store.recordVisit(unified, at: at(2))
    #expect(try await store.recents().map(\.ref.itemID) == [unified.itemID, compatibility.itemID])
}

@Test func personalImageStoreOldRevisitStaysKept() async throws {
    let base = personalStoreDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let store = PersonalImageStore(url: base.appendingPathComponent("p.json"))
    for index in 0..<50 { try await store.recordVisit(personalRef("v\(index).jpg"), at: at(100 + Double(index))) }
    // A revisit is kept at its own date, even one older than every kept visit (a clock change).
    try await store.recordVisit(personalRef("v10.jpg"), at: at(1))
    let recents = try await store.recents()
    #expect(recents.count == 50)
    #expect(recents.last == PersonalImageVisit(ref: personalRef("v10.jpg"), viewedAt: at(1)))
    #expect(recents.contains { $0.ref == personalRef("v0.jpg") })
}

@Test func personalImageStoreRecoveryRemovalSurvivesRepair() async throws {
    let fm = FileManager.default
    let (a, b) = (personalRef("a.jpg"), personalRef("b.jpg"))
    // The last of n toggles made during recovery decides: odd adds A back, even leaves it removed.
    for toggles in 1...4 {
        let base = personalStoreDirectory()
        defer { try? fm.removeItem(at: base) }
        let path = base.appendingPathComponent("personal-images.json")
        let recovery = path.appendingPathExtension("recovered")
        try await personalStoreFile(path, favorites: [b, a])
        let healthy = try Data(contentsOf: path)
        try Data("{nope".utf8).write(to: path)
        let store = PersonalImageStore(url: path)
        for step in 1...toggles { #expect(try await store.toggleFavorite(a) == (step % 2 == 1), "toggles \(toggles)") }
        try healthy.write(to: path)
        let expected = toggles % 2 == 1 ? [a, b] : [b]
        let repaired = PersonalImageStore(url: path)
        #expect(try await repaired.favorites() == expected, "toggles \(toggles)")
        #expect(try await repaired.isFavorite(a.itemID) == (toggles % 2 == 1), "toggles \(toggles)")
        try await repaired.recordVisit(b, at: at(1))
        #expect(!fm.fileExists(atPath: recovery.path), "toggles \(toggles)")
        #expect(try await PersonalImageStore(url: path).favorites() == expected, "toggles \(toggles)")
        let text = try String(contentsOf: path, encoding: .utf8)
        #expect(!text.contains("removed"), "markers stay out of the primary")
    }
}

@Test func personalImageStoreRecoveryVisitSurvivesRepairOnce() async throws {
    let fm = FileManager.default
    let base = personalStoreDirectory()
    defer { try? fm.removeItem(at: base) }
    let path = base.appendingPathComponent("personal-images.json")
    let (x, y) = (personalRef("x.jpg"), personalRef("y.jpg"))
    try await personalStoreFile(path, visits: [(x, 1), (y, 2)])
    let healthy = try Data(contentsOf: path)
    try Data("{nope".utf8).write(to: path)
    let store = PersonalImageStore(url: path)
    try await store.recordVisit(x, at: at(5))
    _ = try await store.toggleFavorite(x); _ = try await store.toggleFavorite(x)
    try healthy.write(to: path)
    let repaired = PersonalImageStore(url: path)
    #expect(try await repaired.recents() == [PersonalImageVisit(ref: x, viewedAt: at(5)), PersonalImageVisit(ref: y, viewedAt: at(2))])
    _ = try await repaired.toggleFavorite(y)
    #expect(try await PersonalImageStore(url: path).recents().map(\.ref) == [x, y])
    #expect(try await PersonalImageStore(url: path).favorites() == [y])
}
