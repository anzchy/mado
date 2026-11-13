import Foundation
import Testing
import MadoCore
import MadoApplication

private struct SuccessorRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@MainActor private final class RecordingRouteHost: ViewerSessionHost {
    var hasImage = true
    var presented: [ItemID] = []
    var returned = 0
    func performCanvas(_ command: CommandID, from entry: CommandEntry) {}
    func requestOpen() {}
    func applyFocus(_ focus: FocusContext) {}
    func showInspector(_ visible: Bool) {}
    func presentGridItem(_ id: ItemID) { presented.append(id) }
    func returnToGrid() { returned += 1 }
}

/// Oracle: first survivor after `current` in the old order, else last survivor before it, else nil.
private func nearestSurvivor(of current: ItemID?, old: [ItemID], new: [ItemID]) -> ItemID? {
    guard let current, let index = old.firstIndex(of: current) else { return current }
    let alive = Set(new)
    if alive.contains(current) { return current }
    return old[(index + 1)...].first(where: alive.contains) ?? old[..<index].last(where: alive.contains)
}

@Test(.timeLimit(.minutes(2))) @MainActor func browsingRemovalMovesCurrentToNearestSurvivor() {
    let a = ItemID.ephemeral(UUID()), b = ItemID.ephemeral(UUID()), c = ItemID.ephemeral(UUID())
    let d = ItemID.ephemeral(UUID()), x = ItemID.ephemeral(UUID())
    func browse(_ items: [ItemID], current: ItemID) -> ViewerSession {
        let session = ViewerSession(host: FakeSessionHost())
        session.beginBrowsing(items: items, sourceVersion: .init(1), scrollAnchor: nil)
        session.select(current)
        return session
    }
    let rows: [(name: String, old: [ItemID], current: ItemID, new: [ItemID], expected: ItemID?)] = [
        ("S1", [a, b, c], b, [a, c], c),
        ("S2", [a, b, c], c, [a, b], b),
        ("S3", [a, b, c], a, [b, c], b),
        ("S4", [a, b, c], b, [], nil),
        ("S5", [a, b, c, d], b, [a, d], d),
        ("S6", [a, b, c], b, [a, b], b),
        ("S7", [a, b, c], b, [c, a], c),
        ("S8", [a, b, c], b, [x, a, c], c),
    ]
    for row in rows {
        let session = browse(row.old, current: row.current)
        session.updateItems(row.new, sourceVersion: .init(2))
        #expect(session.currentItemID == row.expected, "\(row.name)")
        #expect(session.selection.currentItemID == row.expected, "\(row.name)")
        #expect(session.selection.selectedItemIDs.isSubset(of: Set(row.new)), "\(row.name)")
    }

    // S9: selection and anchor still shrink; only the Current Item moves.
    let s9 = browse([a, b, c], current: a)
    s9.select(c, modifier: .command)
    #expect(s9.selection.selectedItemIDs == [a, c])
    #expect(s9.selection.anchorItemID == c)
    s9.updateItems([a, b], sourceVersion: .init(2))
    #expect(s9.currentItemID == b)
    #expect(s9.selection.selectedItemIDs == [a])
    #expect(s9.selection.anchorItemID == nil)

    // Property (S4) plus idempotence (S5) over 500 seeds.
    let modifiers: [SelectionModifier] = [.plain, .command, .shift]
    for seed in UInt64(0)..<500 {
        var random = SuccessorRandom(seed: seed)
        let old = sessionItems(Int.random(in: 0...12, using: &random))
        let session = ViewerSession(host: FakeSessionHost())
        session.beginBrowsing(items: old, sourceVersion: .init(1), scrollAnchor: old.randomElement(using: &random))
        if !old.isEmpty {
            for _ in 0..<Int.random(in: 0...3, using: &random) {
                session.select(old.randomElement(using: &random)!, modifier: modifiers.randomElement(using: &random)!)
            }
        }
        let before = session.selection.currentItemID
        var new = old.filter { _ in Bool.random(using: &random) }
        if Bool.random(using: &random) { new.shuffle(using: &random) }
        for _ in 0..<Int.random(in: 0...2, using: &random) {
            new.insert(ItemID.ephemeral(UUID()), at: Int.random(in: 0...new.count, using: &random))
        }
        session.updateItems(new, sourceVersion: .init(2))
        let expected = nearestSurvivor(of: before, old: old, new: new)
        #expect(session.currentItemID == expected, "seed \(seed)")
        if let current = session.currentItemID { #expect(new.contains(current), "seed \(seed)") }
        #expect(session.selection.selectedItemIDs.isSubset(of: Set(new)), "seed \(seed)")
        let once = session.selection
        session.updateItems(new, sourceVersion: .init(2))
        #expect(session.selection == once, "seed \(seed) idempotence")
    }

    // P1: a removal while a Preview Set is open keeps the Preview Set path unchanged.
    let host = RecordingRouteHost()
    let preview = ViewerSession(host: host)
    preview.beginBrowsing(items: [a, b, c], sourceVersion: .init(1), scrollAnchor: a)
    preview.select(b)
    #expect(CommandRouter().route(.preview, from: .key, to: preview))
    host.presented = []
    host.returned = 0
    preview.updateItems([a, c], sourceVersion: .init(2))
    #expect(preview.mode == .viewing)
    #expect(preview.previewSet?.currentItemID == c)
    #expect(preview.previewSet?.itemIDs == [a, c])
    #expect(host.presented == [c])
    #expect(host.returned == 0)
}

@Test(.timeLimit(.minutes(2))) @MainActor func browsingFilterThatHidesCurrentMovesItToTheNearestVisibleItem() {
    // Chosen rule (audit L1): updateItems gets the navigable IDs, so a filter that hides Current moves it like a deletion.
    let a = ItemID.ephemeral(UUID()), b = ItemID.ephemeral(UUID()), c = ItemID.ephemeral(UUID()), d = ItemID.ephemeral(UUID())
    let session = ViewerSession(host: FakeSessionHost())
    session.beginBrowsing(items: [a, b, c, d], sourceVersion: .init(1), scrollAnchor: nil)
    session.select(b)
    session.updateItems([a, d], sourceVersion: .init(1))
    #expect(session.selection.currentItemID == d)
    // Clearing the filter keeps the moved Current; the hidden item is not restored.
    session.updateItems([a, b, c, d], sourceVersion: .init(1))
    #expect(session.selection.currentItemID == d)
    // A filter that hides every later item falls back to the nearest earlier one.
    session.select(c)
    session.updateItems([a], sourceVersion: .init(1))
    #expect(session.selection.currentItemID == a)
}
