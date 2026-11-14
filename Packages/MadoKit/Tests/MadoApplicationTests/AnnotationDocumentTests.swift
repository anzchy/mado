import CoreGraphics
import Testing
import MadoCore
import MadoApplication

// #690 (P7-11) WI-1: the AnnotationDocument seam — rectangle marks, undo/redo and the unsaved state.

struct AnnotationRandom: RandomNumberGenerator {
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

private func mk(_ i: Int) -> AnnotationMark {
    AnnotationMark(rect: CGRect(x: i, y: i, width: 10, height: 10))
}

@Test(.timeLimit(.minutes(2))) func docAddUndoRedoRoundTrip() {
    var doc = AnnotationDocument()
    doc.add(mk(1)); doc.add(mk(2))
    #expect(doc.marks == [mk(1), mk(2)])
    let undoDonedoc = doc.undo(); #expect(undoDonedoc)
    #expect(doc.marks == [mk(1)])
    let redoDonedoc = doc.redo(); #expect(redoDonedoc)
    #expect(doc.marks == [mk(1), mk(2)])
}

@Test(.timeLimit(.minutes(2))) func docAddAfterUndoClearsRedo() {
    var doc = AnnotationDocument()
    doc.add(mk(1)); doc.add(mk(2))
    doc.undo()
    doc.add(mk(3))
    #expect(doc.marks == [mk(1), mk(3)])
    let redoRefused = doc.redo(); #expect(redoRefused == false)
    #expect(doc.canRedo == false)
    #expect(doc.canUndo)
}

@Test(.timeLimit(.minutes(2))) func docEmptyStacksAreNoOps() {
    var doc = AnnotationDocument()
    let undoRefused = doc.undo(); #expect(undoRefused == false)
    let redoRefused = doc.redo(); #expect(redoRefused == false)
    #expect(doc.marks == [])
    #expect(doc.hasUnsavedMarks == false)
    #expect(doc.canSave == false)
    doc.add(mk(1))
    let redoAgainRefused = doc.redo(); #expect(redoAgainRefused == false)
    #expect(doc.marks == [mk(1)])
}

@Test(.timeLimit(.minutes(2))) func docUnsavedFlagLifecycle() {
    var doc = AnnotationDocument()
    #expect(doc.hasUnsavedMarks == false)
    doc.add(mk(1)); #expect(doc.hasUnsavedMarks)
    doc.markSaved(); #expect(doc.hasUnsavedMarks == false)
    doc.add(mk(2)); #expect(doc.hasUnsavedMarks)
    doc.undo(); #expect(doc.hasUnsavedMarks == false, "back at the saved node")
    doc.undo(); #expect(doc.hasUnsavedMarks)
    doc.redo(); #expect(doc.hasUnsavedMarks == false)
    doc.markSaved(); doc.markSaved(); #expect(doc.hasUnsavedMarks == false)
}

@Test(.timeLimit(.minutes(2))) func docUndoThenNewMarkIsUnsaved() {
    var doc = AnnotationDocument()
    doc.add(mk(1)); doc.markSaved(); doc.undo(); doc.add(mk(2))
    #expect(doc.hasUnsavedMarks)
    var same = AnnotationDocument()
    same.add(mk(1)); same.markSaved(); same.undo(); same.add(mk(1))
    #expect(same.marks == [mk(1)])
    #expect(same.hasUnsavedMarks, "the saved node is unreachable once redo is cut")
}

@Test(.timeLimit(.minutes(2))) func docMarkSavedRevisionCapturedEarlier() {
    // #690 gap 3: a save marks the revision it started from, not the current one.
    var doc = AnnotationDocument()
    doc.add(mk(1))
    let started = doc.revision
    doc.add(mk(2))
    doc.markSaved(revision: started)
    #expect(doc.hasUnsavedMarks)
    doc.undo()
    #expect(doc.hasUnsavedMarks == false)
}

@Test(.timeLimit(.minutes(2))) func docCanSaveFollowsMarks() {
    var doc = AnnotationDocument()
    #expect(doc.canSave == false)
    doc.add(mk(1)); #expect(doc.canSave)
    doc.undo(); #expect(doc.canSave == false)
    doc.redo(); doc.markSaved(); #expect(doc.canSave, "saving twice is allowed")
}

/// Reference model: a history list of node ids, a cursor and the saved node.
private struct HistoryModel {
    var states: [[AnnotationMark]] = [[]]
    var nodes: [Int] = [0]
    var cursor = 0
    var savedNode: Int? = 0
    var nextNode = 1
    var marks: [AnnotationMark] { states[cursor] }
    var currentNode: Int { nodes[cursor] }
    mutating func add(_ mark: AnnotationMark) {
        states = Array(states[...cursor]) + [marks + [mark]]
        nodes = Array(nodes[...cursor]) + [nextNode]
        nextNode += 1
        cursor += 1
    }
    mutating func undo() -> Bool { guard cursor > 0 else { return false }; cursor -= 1; return true }
    mutating func redo() -> Bool { guard cursor + 1 < states.count else { return false }; cursor += 1; return true }
    mutating func save() { savedNode = currentNode }
}

@Test(.timeLimit(.minutes(2))) func docUnsavedTracksSavedHistoryNodeOverSeededOps() {
    for seed in UInt64(0)..<200 {
        var random = AnnotationRandom(seed: seed)
        var doc = AnnotationDocument()
        var model = HistoryModel()
        var marksAtLastSave: [AnnotationMark] = []
        var fresh = 0
        for _ in 0..<Int.random(in: 1...40, using: &random) {
            switch Int.random(in: 0..<4, using: &random) {
            case 0:
                fresh += 1
                doc.add(mk(fresh)); model.add(mk(fresh))
            case 1: let a = doc.undo(), b = model.undo(); #expect(a == b, "seed \(seed)")
            case 2: let a = doc.redo(), b = model.redo(); #expect(a == b, "seed \(seed)")
            default:
                doc.markSaved(); model.save(); marksAtLastSave = model.marks
            }
            #expect(doc.marks == model.marks, "seed \(seed)")
            #expect(doc.hasUnsavedMarks == (model.savedNode != model.currentNode), "seed \(seed)")
            #expect(doc.hasUnsavedMarks == (doc.marks != marksAtLastSave), "seed \(seed): distinct marks")
            #expect(doc.canUndo == (model.cursor > 0), "seed \(seed)")
            #expect(doc.canRedo == (model.cursor + 1 < model.states.count), "seed \(seed)")
        }
    }
}

@Test(.timeLimit(.minutes(2))) func docUndoRedoIsIdentityOverSeededStates() {
    struct Snapshot: Equatable {
        let marks: [AnnotationMark]; let unsaved: Bool; let undo: Bool; let redo: Bool; let save: Bool; let revision: Int
        init(_ doc: AnnotationDocument) {
            marks = doc.marks; unsaved = doc.hasUnsavedMarks; undo = doc.canUndo; redo = doc.canRedo
            save = doc.canSave; revision = doc.revision
        }
    }
    var checked = 0
    for seed in UInt64(0)..<200 {
        var random = AnnotationRandom(seed: seed)
        var doc = AnnotationDocument()
        var fresh = 0
        for _ in 0..<Int.random(in: 1...30, using: &random) {
            switch Int.random(in: 0..<4, using: &random) {
            case 0: fresh += 1; doc.add(mk(fresh))
            case 1: doc.undo()
            case 2: doc.redo()
            default: doc.markSaved()
            }
            guard doc.canUndo else { continue }
            let before = Snapshot(doc)
            var probe = doc
            let undone = probe.undo(); #expect(undone, "seed \(seed)")
            let redone = probe.redo(); #expect(redone, "seed \(seed)")
            #expect(Snapshot(probe) == before, "seed \(seed)")
            checked += 1
        }
    }
    #expect(checked > 500)
}
