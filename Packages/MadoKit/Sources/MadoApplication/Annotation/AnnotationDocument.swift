import CoreGraphics
import MadoCore

/// The marks of one Annotate Mode session, with undo and redo. Each change creates a new history node;
/// the document is unsaved exactly when the current node is not the node that was last saved.
public struct AnnotationDocument: Equatable, Sendable {
    private struct Entry: Equatable, Sendable {
        let marks: [AnnotationMark]
        let crop: CGRect?
        let node: Int
    }
    public private(set) var marks: [AnnotationMark] = []
    /// #693: the applied crop in upright image pixels; at most one, nil for none.
    public private(set) var crop: CGRect?
    private var undoStack: [Entry] = []
    private var redoStack: [Entry] = []
    private var node = 0
    private var nextNode = 1
    private var savedNode: Int? = 0

    public init() {}

    /// The current history node; a save captures it when it starts and marks it saved when it finishes.
    public var revision: Int { node }
    public var hasUnsavedMarks: Bool { node != savedNode }
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    /// ⌘S needs at least one mark or a crop (#693); saving again without a change is allowed.
    public var canSave: Bool { !marks.isEmpty || crop != nil }

    public mutating func add(_ mark: AnnotationMark) {
        undoStack.append(Entry(marks: marks, crop: crop, node: node))
        redoStack.removeAll()
        marks.append(mark)
        node = nextNode
        nextNode += 1
    }

    /// Replaces one mark as an undoable change; an index outside the marks changes nothing.
    @discardableResult public mutating func replace(at index: Int, with mark: AnnotationMark) -> Bool {
        guard marks.indices.contains(index) else { return false }
        undoStack.append(Entry(marks: marks, crop: crop, node: node))
        redoStack.removeAll()
        marks[index] = mark
        node = nextNode
        nextNode += 1
        return true
    }

    /// Removes one mark as an undoable change; an index outside the marks changes nothing.
    @discardableResult public mutating func remove(at index: Int) -> Bool {
        guard marks.indices.contains(index) else { return false }
        undoStack.append(Entry(marks: marks, crop: crop, node: node))
        redoStack.removeAll()
        marks.remove(at: index)
        node = nextNode
        nextNode += 1
        return true
    }

    @discardableResult public mutating func undo() -> Bool {
        guard let entry = undoStack.popLast() else { return false }
        redoStack.append(Entry(marks: marks, crop: crop, node: node))
        marks = entry.marks
        crop = entry.crop
        node = entry.node
        return true
    }

    @discardableResult public mutating func redo() -> Bool {
        guard let entry = redoStack.popLast() else { return false }
        undoStack.append(Entry(marks: marks, crop: crop, node: node))
        marks = entry.marks
        crop = entry.crop
        node = entry.node
        return true
    }

    /// #693: sets, replaces or clears (nil) the crop as one undoable change; the same crop again changes nothing.
    @discardableResult public mutating func setCrop(_ rect: CGRect?) -> Bool {
        guard rect != crop else { return false }
        undoStack.append(Entry(marks: marks, crop: crop, node: node))
        redoStack.removeAll()
        crop = rect
        node = nextNode
        nextNode += 1
        return true
    }

    public mutating func markSaved() { markSaved(revision: node) }
    /// Marks the revision a save started from; later changes stay unsaved.
    public mutating func markSaved(revision: Int) { savedNode = revision }
}
