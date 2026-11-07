import Foundation
import Testing
@testable import MadoCore

@Test func accessBoundaryResolvesComponentsAndSymlinks() throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: base) }
    let root = base.appendingPathComponent("photos")
    let outside = base.appendingPathComponent("photos2")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    try fm.createDirectory(at: outside, withIntermediateDirectories: true)
    let image = root.appendingPathComponent("a.jpg")
    let other = outside.appendingPathComponent("b.jpg")
    try Data().write(to: image); try Data().write(to: other)
    let insideLink = root.appendingPathComponent("inside.jpg")
    let outsideLink = root.appendingPathComponent("outside.jpg")
    let directoryLink = root.appendingPathComponent("linked")
    try fm.createSymbolicLink(at: insideLink, withDestinationURL: image)
    try fm.createSymbolicLink(at: outsideLink, withDestinationURL: other)
    try fm.createSymbolicLink(at: directoryLink, withDestinationURL: outside)
    #expect(AccessBoundary.contains(image, in: root))
    #expect(AccessBoundary.contains(root.appendingPathComponent("../photos/a.jpg"), in: root.appendingPathComponent("./")))
    #expect(!AccessBoundary.contains(other, in: root))
    #expect(!AccessBoundary.contains(outsideLink, in: root))
    #expect(!AccessBoundary.contains(directoryLink.appendingPathComponent("b.jpg"), in: root))
    #expect(AccessBoundary.contains(insideLink, in: root))
    #expect(AccessBoundary.fileGrant(image, covers: image))
    #expect(!AccessBoundary.fileGrant(image, covers: root))
    #expect(!AccessBoundary.fileGrant(image, covers: root.appendingPathComponent("sibling.jpg")))
    #expect(!AccessBoundary.contains(URL(string: "https://example.org/a")!, in: root))
}
