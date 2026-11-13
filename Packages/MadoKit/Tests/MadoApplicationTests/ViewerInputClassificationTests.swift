import Foundation
import Testing
import MadoApplication

private func classificationURL(_ name: String, directory: Bool = false) -> URL {
    URL(fileURLWithPath: "/photos/" + name, isDirectory: directory)
}

@Test func inputClassificationCombinedLiteralPartitions() {
    let a = classificationURL("A.png"), c = classificationURL("C.PNG")
    let zip = classificationURL("bad.zip"), plain = classificationURL("plain")
    let folder = classificationURL("folder", directory: true), other = classificationURL("other", directory: true)
    let remote = URL(string: "https://example.test/A.png")!
    let rows: [([URL], ViewerInput, Int)] = [
        ([], .rejected([]), 0), ([a], .single(a), 0),
        ([c, a, zip], .files([a, c]), 1), ([zip, plain], .rejected([zip, plain]), 2),
        ([zip, zip, classificationURL("./bad.zip"), a], .single(a), 1),
        ([folder, remote, a], .single(a), 0), ([folder], .folder(folder), 0),
        ([folder, other], .rejected([folder, other]), 0),
        ([remote], .rejected([]), 0), ([zip, folder], .folder(folder), 1)
    ]
    for (urls, expected, excluded) in rows {
        let result = ViewerInput.classification(urls)
        #expect(result.input == expected)
        #expect(result.excludedCount == excluded)
        #expect(ViewerInput.classify(urls) == result.input)
        #expect(ViewerInput.excludedCount(in: urls) == result.excludedCount)
    }
}

@Test func inputClassificationAliasAndPermutationInvariant() {
    let a = classificationURL("a.png"), two = classificationURL("image2.png"), ten = classificationURL("image10.png")
    let alias = classificationURL("./a.png"), zip = classificationURL("bad.zip")
    let remote = URL(string: "https://example.test/a.png")!
    let permutations = [[a, two, ten], [a, ten, two], [two, a, ten],
                        [two, ten, a], [ten, a, two], [ten, two, a]]
    for members in permutations {
        for aliasFirst in [false, true] {
            let urls = (aliasFirst ? [alias] : []) + members + [a, alias, zip, zip, classificationURL("./bad.zip"), remote]
            let expected = [aliasFirst ? alias : a, two, ten]
            let result = ViewerInput.classification(urls)
            #expect(result.input == .files(expected))
            #expect(result.excludedCount == 1)
            let reapplied = ViewerInput.classification(expected)
            #expect(reapplied.input == result.input)
            #expect(reapplied.excludedCount == 0)
        }
    }
}

@Test(.timeLimit(.minutes(2))) func inputClassificationRealSymlinkAliasesUseTargetAndCountOnce() throws {
    let tree = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tree) }
    let a = tree.appendingPathComponent("a.png"), b = tree.appendingPathComponent("b.png")
    let zip = tree.appendingPathComponent("bad.zip")
    let imageAlias = tree.appendingPathComponent("a-alias.png"), zipAlias = tree.appendingPathComponent("bad-alias.zip")
    for file in [a, b, zip] { try Data([1]).write(to: file) }
    try FileManager.default.createSymbolicLink(at: imageAlias, withDestinationURL: a)
    try FileManager.default.createSymbolicLink(at: zipAlias, withDestinationURL: zip)
    for aliasFirst in [false, true] {
        let urls = aliasFirst ? [imageAlias, zipAlias, b, a, zip, zipAlias] : [a, zip, b, imageAlias, zipAlias, zip]
        let expected = [a, b]
        let result = ViewerInput.classification(urls)
        #expect(result.input == .files(expected))
        #expect(result.excludedCount == 1)
        #expect(ViewerInput.classify(urls) == .files(expected))
        #expect(ViewerInput.excludedCount(in: urls) == 1)
        let reapplied = ViewerInput.classification(expected)
        #expect(reapplied.input == result.input)
        #expect(reapplied.excludedCount == 0)
    }
}
