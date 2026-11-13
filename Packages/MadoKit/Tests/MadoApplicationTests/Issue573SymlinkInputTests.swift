import Foundation
import Testing
import MadoApplication

@Test(.timeLimit(.minutes(2))) func issue573ClassifiesFileLinksByResolvedTargetAndDeduplicates() throws {
    let tree = FileManager.default.temporaryDirectory.appendingPathComponent("issue573-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tree) }
    let image = tree.appendingPathComponent("image.png")
    let noSuffix = tree.appendingPathComponent("no-suffix")
    let misleading = tree.appendingPathComponent("misleading.txt")
    let chain = tree.appendingPathComponent("chain")
    try Data([1]).write(to: image)
    try FileManager.default.createSymbolicLink(at: noSuffix, withDestinationURL: image)
    try FileManager.default.createSymbolicLink(at: misleading, withDestinationURL: image)
    try FileManager.default.createSymbolicLink(at: chain, withDestinationURL: noSuffix)

    for link in [noSuffix, misleading, chain] {
        let result = ViewerInput.classification([link])
        #expect(result.input == .single(image))
        #expect(result.excludedCount == 0)
    }
    for delivered in [[noSuffix, misleading, image], [image, misleading, noSuffix],
                      [misleading, noSuffix, noSuffix]] {
        let first = ViewerInput.classification(delivered)
        #expect(first.input == .single(image), "One resolved image should appear once")
        #expect(first.excludedCount == 0)
        #expect(ViewerInput.classification(delivered + delivered).input == first.input)
    }
    func permutations(_ urls: [URL]) -> [[URL]] {
        if urls.isEmpty { return [[]] }
        return urls.indices.flatMap { index in
            let remaining = Array(urls[..<index]) + Array(urls[(index + 1)...])
            return permutations(remaining).map { [urls[index]] + $0 }
        }
    }
    for order in permutations([image, noSuffix, misleading, chain]) {
        let result = ViewerInput.classification(order + order)
        #expect(result.input == .single(image), "Every delivery order must collapse to one target")
        #expect(result.excludedCount == 0)
    }
    #expect(ViewerInput.classify([image]) == .single(image), "Plain image remains unchanged")
}

@Test(.timeLimit(.minutes(2))) func issue573MixedFileSetUsesTargetNamesAndURLs() throws {
    let tree = FileManager.default.temporaryDirectory.appendingPathComponent("issue573-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tree) }
    let a = tree.appendingPathComponent("A.png")
    let b = tree.appendingPathComponent("B.png")
    let link = tree.appendingPathComponent("z-link")
    try Data([1]).write(to: a)
    try Data([2]).write(to: b)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: a)
    #expect(ViewerInput.classify([link, b]) == .files([a, b]))
    #expect(ViewerInput.classify([b, link]) == .files([a, b]))
}

@Test(.timeLimit(.minutes(2))) func issue573RejectsNonImageAndUnresolvableFileLinks() throws {
    let tree = FileManager.default.temporaryDirectory.appendingPathComponent("issue573-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tree) }
    let zip = tree.appendingPathComponent("data.zip")
    let wrong = tree.appendingPathComponent("wrong.png")
    let broken = tree.appendingPathComponent("broken.png")
    let selfLoop = tree.appendingPathComponent("self.png")
    let loopA = tree.appendingPathComponent("loop-a.png")
    let loopB = tree.appendingPathComponent("loop-b.png")
    try Data([1]).write(to: zip)
    try FileManager.default.createSymbolicLink(at: wrong, withDestinationURL: zip)
    try FileManager.default.createSymbolicLink(at: broken, withDestinationURL: tree.appendingPathComponent("missing.png"))
    try FileManager.default.createSymbolicLink(at: selfLoop, withDestinationURL: selfLoop)
    try FileManager.default.createSymbolicLink(at: loopA, withDestinationURL: loopB)
    try FileManager.default.createSymbolicLink(at: loopB, withDestinationURL: loopA)

    for link in [wrong, broken, selfLoop, loopA, loopB] {
        let result = ViewerInput.classification([link])
        #expect(result.input == .rejected([link]), "A non-image or unresolved target must not open")
        #expect(result.excludedCount == 1)
    }
}

@Test(.timeLimit(.minutes(2))) func issue573RelativeLinkAndOverlongChainHaveBoundedOutcomes() throws {
    let tree = FileManager.default.temporaryDirectory.appendingPathComponent("issue573-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tree) }
    let image = tree.appendingPathComponent("image.png")
    try Data([1]).write(to: image)
    let relative = tree.appendingPathComponent("relative")
    try FileManager.default.createSymbolicLink(atPath: relative.path, withDestinationPath: "image.png")
    #expect(ViewerInput.classify([relative]) == .single(image))

    for index in 0...40 {
        let link = tree.appendingPathComponent("link-\(index)")
        let destination = index == 40 ? "image.png" : "link-\(index + 1)"
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: destination)
    }
    let first = tree.appendingPathComponent("link-0")
    let result = ViewerInput.classification([first])
    #expect(result.input == .rejected([first]), "An overlong link chain must terminate without opening a partial target")
    #expect(result.excludedCount == 1)
}
