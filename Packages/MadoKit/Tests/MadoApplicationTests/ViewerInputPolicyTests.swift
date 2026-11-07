import Foundation
import Testing
import MadoApplication

private func inputURL(_ name: String, directory: Bool = false) -> URL {
    URL(fileURLWithPath: "/photos/" + name, isDirectory: directory)
}

@Test func inputPolicyLiteralPartitions() {
    let a = inputURL("a.png"), b = inputURL("b.jpg"), upper = inputURL("C.PNG")
    let two = inputURL("image2.png"), ten = inputURL("image10.png")
    let plain = inputURL("plain"), zip = inputURL("bad.zip")
    let folder = inputURL("folder", directory: true), other = inputURL("other", directory: true)
    let remote = URL(string: "https://example.test/a.png")!
    let alias = inputURL("./a.png")
    let rows: [([URL], ViewerInput)] = [
        ([], .rejected([])), ([a], .single(a)), ([b], .single(b)), ([upper], .single(upper)),
        ([two], .single(two)), ([ten], .single(ten)),
        ([plain], .rejected([plain])), ([zip], .rejected([zip])),
        ([ten, two], .files([two, ten])), ([b, a], .files([a, b])),
        ([ten, a, two], .files([a, two, ten])),
        ([a, a], .single(a)), ([a, alias], .single(a)), ([alias, a], .single(alias)),
        ([folder], .folder(folder)), ([folder, folder], .folder(folder)),
        ([folder, a], .single(a)), ([a, folder], .single(a)), ([zip, folder], .folder(folder)),
        ([remote, a], .single(a)), ([remote], .rejected([])),
        ([folder, other], .rejected([folder, other])),
        ([zip, plain], .rejected([zip, plain]))
    ]
    for (urls, expected) in rows { #expect(ViewerInput.classify(urls) == expected) }
}

@Test func inputPolicyDedupOrderingInvariant() {
    let a = inputURL("a.png"), two = inputURL("image2.png"), ten = inputURL("image10.png")
    let alias = inputURL("./a.png")
    let permutations = [[a, two, ten], [a, ten, two], [two, a, ten],
                        [two, ten, a], [ten, a, two], [ten, two, a]]
    for members in permutations {
        for aliases in [[a, a], [alias, a]] {
            let transformed = members + aliases + [inputURL("bad.zip"), URL(string: "https://example.test/a.png")!]
            let result = ViewerInput.classify(transformed)
            #expect(result == .files([a, two, ten]))
            #expect(ViewerInput.classify([a, two, ten]) == result)
        }
    }
    let aliasFirst = ViewerInput.classify([alias, ten, a, two])
    #expect(aliasFirst == .files([alias, two, ten]))
    #expect(ViewerInput.classify([alias, two, ten]) == aliasFirst)
}

@Test func inputPolicySymlinkAliases() throws {
    let tree = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tree) }
    let a = tree.appendingPathComponent("a.png"), b = tree.appendingPathComponent("b.png")
    let alias = tree.appendingPathComponent("alias.png")
    try Data([1]).write(to: a)
    try Data([2]).write(to: b)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: a)
    #expect(ViewerInput.classify([a, alias, b]) == .files([a, b]))
    #expect(ViewerInput.classify([alias, a, b]) == .files([alias, b]))
    #expect(ViewerInput.classify([alias, a]) == .single(alias))
    #expect(alias.resolvingSymlinksInPath().standardizedFileURL == a.resolvingSymlinksInPath().standardizedFileURL)
}

@Test func inputPolicyExclusions() {
    let a = inputURL("a.png"), c = inputURL("C.PNG"), zip = inputURL("bad.zip"), plain = inputURL("plain")
    let rows: [([URL], ViewerInput, Int)] = [
        ([c, zip, a], .files([a, c]), 1), ([zip, a], .single(a), 1),
        ([zip, plain], .rejected([zip, plain]), 2),
        ([zip, zip, inputURL("./bad.zip"), a], .single(a), 1),
        ([inputURL("folder", directory: true), URL(string: "https://example.test/a.png")!, a], .single(a), 0),
        ([], .rejected([]), 0)
    ]
    for (urls, expected, excluded) in rows {
        #expect(ViewerInput.classify(urls) == expected)
        #expect(ViewerInput.excludedCount(in: urls) == excluded)
    }
}
