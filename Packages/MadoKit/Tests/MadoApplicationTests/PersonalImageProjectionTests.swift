import Foundation
import Testing
import MadoCore
import MadoApplication

private let projectionRoot = ItemIdentityRoot(id: AccessRootID(), url: URL(fileURLWithPath: "/pictures-projection"))
private func projectionRef(_ name: String) -> PersonalImageRef {
    PersonalImageRef(fileURL: projectionRoot.url.appendingPathComponent(name), root: projectionRoot, fileNumber: 1)!
}
private struct ProjectionRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state ^ (state >> 29)
    }
}

@Test func personalImageProjectionOrderAndCountLaw() {
    let outcomes: [PersonalImageAvailability?] = [.present(projectionRoot.url), .missing, .revoked, nil]
    for seed in UInt64(1)...30 {
        var rng = ProjectionRandom(state: seed)
        let favorites = (0..<Int.random(in: 0...40, using: &rng)).map { projectionRef("f\($0).jpg") }.shuffled(using: &rng)
        let recents = (0..<Int.random(in: 0...40, using: &rng)).map {
            PersonalImageVisit(ref: projectionRef("r\($0).jpg"), viewedAt: Date(timeIntervalSince1970: Double(100 - $0)))
        }
        var availability: [PersonalImageRef: PersonalImageAvailability] = [:]
        for ref in favorites + recents.map(\.ref) { availability[ref] = outcomes.randomElement(using: &rng)! }
        let projection = PersonalImageProjection(favorites: favorites, recents: recents, availability: availability)
        #expect(projection.favorites.map(\.ref) == favorites, "seed \(seed)")
        #expect(projection.recents.map(\.ref) == recents.map(\.ref), "seed \(seed)")
        #expect(projection.recents.map(\.viewedAt) == recents.map(\.viewedAt), "seed \(seed)")
        #expect(projection.favorites.map(\.itemID) == favorites.map(\.itemID), "seed \(seed)")
        #expect(projection.favorites.map(\.availability) == favorites.map { availability[$0] }, "seed \(seed)")
        func expectedCount(_ refs: [PersonalImageRef]) -> Int? {
            refs.contains { availability[$0] == nil } ? nil
                : refs.filter { if case .present = availability[$0] { true } else { false } }.count
        }
        #expect(projection.favoriteCount == expectedCount(favorites), "seed \(seed)")
        #expect(projection.recentCount == expectedCount(recents.map(\.ref)), "seed \(seed)")
    }
}

@Test func personalImageProjectionCountBoundaries() {
    let unloaded = PersonalImageProjection()
    #expect(unloaded.favoriteCount == nil && unloaded.recentCount == nil)
    #expect(unloaded.favorites.isEmpty && unloaded.recents.isEmpty)
    let empty = PersonalImageProjection(favorites: [], recents: [], availability: [:])
    #expect(empty.favoriteCount == 0 && empty.recentCount == 0)
    let refs = (0..<4).map { projectionRef("p\($0).jpg") }
    var availability = Dictionary(uniqueKeysWithValues: refs.prefix(3).map { ($0, PersonalImageAvailability.present(projectionRoot.url)) })
    let pending = PersonalImageProjection(favorites: refs, recents: [], availability: availability)
    #expect(pending.favoriteCount == nil && pending.recentCount == 0)
    availability[refs[3]] = .missing
    #expect(PersonalImageProjection(favorites: refs, recents: [], availability: availability).favoriteCount == 3)
    let gone = PersonalImageProjection(favorites: [refs[0], refs[1]], recents: [], availability: [refs[0]: .missing, refs[1]: .revoked])
    #expect(gone.favoriteCount == 0 && gone.favorites.count == 2)
}

@Test func personalImageProjectionFavoriteMembership() throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: base) }
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    let root = ItemIdentityRoot(id: AccessRootID(), url: base)
    let files = (0..<6).map { base.appendingPathComponent("img\($0).jpg") }
    for file in files { try Data([1]).write(to: file) }
    let entries = files.map { FolderEntry(url: $0, root: root) }
    let refs = try files.map { try #require(PersonalImageRef(fileURL: $0, root: root, fileNumber: 1)) }
    let projection = PersonalImageProjection(favorites: Array(refs[0...2]),
        recents: refs[3...4].map { PersonalImageVisit(ref: $0, viewedAt: Date()) }, availability: [:])
    #expect(entries.map { projection.isFavorite($0.itemID) } == [true, true, true, false, false, false])
    #expect(!PersonalImageProjection().isFavorite(entries[0].itemID))
}
