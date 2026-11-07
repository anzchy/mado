import Foundation
import Testing
import MadoCore

private struct PersonalSplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func personalTempRoot() throws -> (base: URL, root: ItemIdentityRoot) {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let folder = base.appendingPathComponent("root")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return (base, ItemIdentityRoot(id: AccessRootID(), url: folder))
}

private func personalGeneratedPath(_ rng: inout PersonalSplitMix) -> String {
    let alphabet = ["a", "\u{e9}", "e\u{301}", " ", "\u{65e5}", "b"]
    let depth = Int.random(in: 1...3, using: &rng)
    return (0..<depth).map { level in
        var name = (0..<Int.random(in: 1...4, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! }.joined()
        if level == depth - 1 { name += ".jpg" }
        return name
    }.joined(separator: "/")
}

@Test func personalImageRefItemIDMatchesFolderEntry() throws {
    let fm = FileManager.default
    let (base, root) = try personalTempRoot()
    defer { try? fm.removeItem(at: base) }
    var files: [URL] = []
    for seed in UInt64(1)...20 {
        var rng = PersonalSplitMix(state: seed)
        let file = root.url.appendingPathComponent(personalGeneratedPath(&rng))
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([UInt8(seed)]).write(to: file)
        files.append(file)
    }
    let sub = root.url.appendingPathComponent("sub")
    try fm.createDirectory(at: sub, withIntermediateDirectories: true)
    try Data([1]).write(to: sub.appendingPathComponent("x.jpg"))
    try fm.createSymbolicLink(at: root.url.appendingPathComponent("link-dir"), withDestinationURL: sub)
    try fm.createSymbolicLink(at: root.url.appendingPathComponent("alias.jpg"), withDestinationURL: sub.appendingPathComponent("x.jpg"))
    files += [root.url.appendingPathComponent("link-dir/x.jpg"), root.url.appendingPathComponent("alias.jpg"),
              root.url.appendingPathComponent("sub/./x.jpg")]
    for file in files {
        let ref = try #require(PersonalImageRef(fileURL: file, root: root, fileNumber: 1), "\(file.path)")
        #expect(ref.itemID == FolderEntry(url: file, root: root).itemID, "\(file.path)")
        #expect(ref.rootID == root.id)
        #expect(!ref.relativePath.hasPrefix("/") && !ref.relativePath.split(separator: "/").contains(".."))
    }
    let alias = try #require(PersonalImageRef(fileURL: files[21], root: root, fileNumber: 2))
    #expect(alias.relativePath == "sub/x.jpg")
}

@Test func personalImageRefRejectsOutsideRoot() throws {
    let fm = FileManager.default
    let (base, root) = try personalTempRoot()
    defer { try? fm.removeItem(at: base) }
    let sibling = base.appendingPathComponent("root2"), outside = base.appendingPathComponent("out")
    try fm.createDirectory(at: sibling, withIntermediateDirectories: true)
    try fm.createDirectory(at: outside, withIntermediateDirectories: true)
    try Data([1]).write(to: sibling.appendingPathComponent("a.jpg"))
    try Data([2]).write(to: outside.appendingPathComponent("x.jpg"))
    try fm.createSymbolicLink(at: root.url.appendingPathComponent("esc.jpg"), withDestinationURL: outside.appendingPathComponent("x.jpg"))
    #expect(PersonalImageRef(fileURL: sibling.appendingPathComponent("a.jpg"), root: root, fileNumber: 1) == nil, "sibling prefix")
    #expect(PersonalImageRef(fileURL: root.url.appendingPathComponent("esc.jpg"), root: root, fileNumber: 1) == nil, "escape link")
    #expect(PersonalImageRef(fileURL: root.url.appendingPathComponent("sub/../../out/x.jpg"), root: root, fileNumber: 1) == nil, "dot-dot")
    #expect(PersonalImageRef(fileURL: root.url, root: root, fileNumber: 1) == nil, "root")
    #expect(PersonalImageRef(fileURL: URL(fileURLWithPath: root.url.path + "/"), root: root, fileNumber: 1) == nil, "root slash")
    #expect(PersonalImageRef(fileURL: URL(string: "https://example.org/root/a.jpg")!, root: root, fileNumber: 1) == nil, "not a file")
}

@Test func personalImageRefEqualityIgnoresFileNumber() throws {
    let fm = FileManager.default
    let (base, root) = try personalTempRoot()
    defer { try? fm.removeItem(at: base) }
    let file = root.url.appendingPathComponent("a.jpg"), other = root.url.appendingPathComponent("b.jpg")
    let refs = try [7, 8, 9].map { try #require(PersonalImageRef(fileURL: file, root: root, fileNumber: $0)) }
    #expect(refs[0] == refs[1] && refs[1] == refs[2])
    #expect(Set(refs).count == 1)
    #expect(refs.map(\.fileNumber) == [7, 8, 9])
    #expect(PersonalImageRef(fileURL: other, root: root, fileNumber: 7) != refs[0])
    let otherRoot = ItemIdentityRoot(id: AccessRootID(), url: root.url)
    let samePathOtherRoot = try #require(PersonalImageRef(fileURL: file, root: otherRoot, fileNumber: 7))
    #expect(samePathOtherRoot != refs[0])
    #expect(Set([refs[0], samePathOtherRoot]).count == 2)
}

@Test func personalImageRefCodableRoundTrip() throws {
    let root = ItemIdentityRoot(id: AccessRootID(), url: URL(fileURLWithPath: "/pictures"))
    let numbers: [UInt64] = [0, UInt64.max, 1]
    for seed in UInt64(1)...20 {
        var rng = PersonalSplitMix(state: seed)
        let path = personalGeneratedPath(&rng)
        let number = seed <= 3 ? numbers[Int(seed) - 1] : rng.next()
        let ref = try #require(PersonalImageRef(fileURL: root.url.appendingPathComponent(path), root: root, fileNumber: number))
        let decoded = try JSONDecoder().decode(PersonalImageRef.self, from: JSONEncoder().encode(ref))
        #expect(decoded == ref, "seed \(seed)")
        #expect(decoded.itemID == ref.itemID && decoded.fileNumber == number && decoded.relativePath == ref.relativePath)
    }
}

@Test func personalImageRefDecodeMalformedThrows() throws {
    let root = AccessRootID().rawValue.uuidString
    // Every payload carries a file number, so only the malformed field can reject it.
    let payloads = [#"{"relativePath":"a.jpg","fileNumber":1}"#, #"{"rootID":"\#(root)","relativePath":5,"fileNumber":1}"#,
                    #"{"rootID":"\#(root)","relativePath":"","fileNumber":1}"#,
                    #"{"rootID":"\#(root)","relativePath":"a/../../b.jpg","fileNumber":1}"#,
                    #"{"rootID":"\#(root)","relativePath":"/a.jpg","fileNumber":1}"#]
    for payload in payloads {
        #expect(throws: DecodingError.self, "\(payload)") {
            try JSONDecoder().decode(PersonalImageRef.self, from: Data(payload.utf8))
        }
    }
    let valid = try JSONDecoder().decode(PersonalImageRef.self,
        from: Data(#"{"rootID":"\#(root)","relativePath":"a/b.jpg","fileNumber":3}"#.utf8))
    #expect(valid.relativePath == "a/b.jpg" && valid.fileNumber == 3)
}

@Test func personalImageVisitRoundTrip() throws {
    let root = ItemIdentityRoot(id: AccessRootID(), url: URL(fileURLWithPath: "/pictures"))
    let ref = try #require(PersonalImageRef(fileURL: root.url.appendingPathComponent("a.jpg"), root: root, fileNumber: 4))
    let visit = PersonalImageVisit(ref: ref, viewedAt: Date(timeIntervalSince1970: 1_700_000_000.25))
    let decoded = try JSONDecoder().decode(PersonalImageVisit.self, from: JSONEncoder().encode(visit))
    #expect(decoded == visit)
    #expect(decoded.viewedAt.timeIntervalSince1970 == 1_700_000_000.25 && decoded.ref.fileNumber == 4)
    #expect(PersonalImageAvailability.present(root.url) != .missing && PersonalImageAvailability.missing != .revoked)
}

@Test func personalImageRefEqualityUsesPathBytes() throws {
    let root = ItemIdentityRoot(id: AccessRootID(), url: URL(fileURLWithPath: "/pictures-compat"))
    let compatibility = try #require(PersonalImageRef(fileURL: root.url.appendingPathComponent("\u{F900}.jpg"), root: root, fileNumber: 1))
    let unified = try #require(PersonalImageRef(fileURL: root.url.appendingPathComponent("\u{8C48}.jpg"), root: root, fileNumber: 1))
    try #require(compatibility.relativePath == unified.relativePath, "canonically equivalent names")
    try #require(Array(compatibility.relativePath.utf8) != Array(unified.relativePath.utf8), "two spellings on disk")
    #expect(compatibility.itemID != unified.itemID)
    #expect(compatibility != unified, "equality follows the item identity, not Unicode equivalence")
    #expect(Set([compatibility, unified]).count == 2)
    #expect(compatibility == PersonalImageRef(fileURL: root.url.appendingPathComponent("\u{F900}.jpg"), root: root, fileNumber: 5))
}

@Test func personalImageRefRequiresFileNumber() throws {
    let root = AccessRootID().rawValue.uuidString
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(PersonalImageRef.self, from: Data(#"{"rootID":"\#(root)","relativePath":"a.jpg"}"#.utf8))
    }
    let ref = try JSONDecoder().decode(PersonalImageRef.self, from: Data(#"{"rootID":"\#(root)","relativePath":"a.jpg","fileNumber":0}"#.utf8))
    #expect(ref.fileNumber == 0)
}
