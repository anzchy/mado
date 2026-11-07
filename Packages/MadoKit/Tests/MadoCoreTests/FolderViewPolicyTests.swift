import Foundation
import Testing
import MadoCore

private let viewPolicyRoot = ItemIdentityRoot(id: AccessRootID(), url: URL(fileURLWithPath: "/view-policy"))
private let viewPolicyVersion = SnapshotVersion(rootID: viewPolicyRoot.id, folder: viewPolicyRoot.url, generation: 1)

private func viewPolicyEntry(_ path: String, modified: Date? = nil, size: Int64? = nil) -> FolderEntry {
    FolderEntry(url: viewPolicyRoot.url.appendingPathComponent(path), root: viewPolicyRoot,
        modificationDate: modified, fileSize: size)
}

private func viewPolicyNames(_ entries: [FolderEntry], conditions: FolderViewConditions) -> [String] {
    FolderSnapshot(version: viewPolicyVersion, entries: entries, isComplete: true)
        .applying(conditions).entries.map(\.relativePath)
}

@Test func folderViewPolicySortsEveryKeyWithDeterministicTiesAndMissingLast() {
    let early = Date(timeIntervalSince1970: 10), late = Date(timeIntervalSince1970: 20)
    let entries = [
        viewPolicyEntry("z/img2.JPG", modified: late, size: 20),
        viewPolicyEntry("img10.png", modified: nil, size: nil),
        viewPolicyEntry("a/img2.jpg", modified: early, size: 10),
        viewPolicyEntry("img3", modified: early, size: 10),
    ]

    #expect(viewPolicyNames(entries, conditions: .init()) == ["a/img2.jpg", "z/img2.JPG", "img3", "img10.png"])
    #expect(viewPolicyNames(entries, conditions: .init(direction: .descending)) == ["img10.png", "img3", "a/img2.jpg", "z/img2.JPG"])
    #expect(viewPolicyNames(entries, conditions: .init(sort: .modificationDate)) == ["a/img2.jpg", "img3", "z/img2.JPG", "img10.png"])
    #expect(viewPolicyNames(entries, conditions: .init(sort: .modificationDate, direction: .descending)) == ["z/img2.JPG", "a/img2.jpg", "img3", "img10.png"])
    #expect(viewPolicyNames(entries, conditions: .init(sort: .size)) == ["a/img2.jpg", "img3", "z/img2.JPG", "img10.png"])
    #expect(viewPolicyNames(entries, conditions: .init(sort: .size, direction: .descending)) == ["z/img2.JPG", "a/img2.jpg", "img3", "img10.png"])
    #expect(viewPolicyNames(entries, conditions: .init(sort: .type)) == ["img3", "a/img2.jpg", "z/img2.JPG", "img10.png"])
    #expect(viewPolicyNames(entries, conditions: .init(sort: .type, direction: .descending)) == ["img10.png", "a/img2.jpg", "z/img2.JPG", "img3"])
    #expect(entries.map(\.normalizedExtension) == ["jpg", "png", "jpg", ""])
}

@Test func folderViewPolicyFiltersNormalizedExtensionsWithoutMutatingSource() {
    let entries = [viewPolicyEntry("img2.PNG"), viewPolicyEntry("img1.JpG"), viewPolicyEntry("README")]
    let source = FolderSnapshot(version: viewPolicyVersion, entries: entries, isComplete: false)
    let conditions = FolderViewConditions(selectedExtensions: ["PNG"])
    #expect(conditions.selectedExtensions == ["png"])
    let filtered = source.applying(conditions)
    #expect(filtered.entries.map(\.relativePath) == ["img2.PNG"])
    #expect(filtered.navigationEntries == filtered.entries)
    #expect(filtered.navigationIndex(for: entries[0].itemID) == 0)
    #expect(filtered.navigationIndex(for: entries[1].itemID) == nil)
    #expect(!filtered.isComplete && filtered.version == source.version)
    #expect(source.entries.count == 3 && source.navigationEntries.count == 3)
    #expect(source.applying(.init()).entries == source.entries)
    #expect(source.applying(.init(selectedExtensions: [])).entries.isEmpty)
    var directlyMutated = FolderViewConditions()
    directlyMutated.selectedExtensions = ["JPG"]
    #expect(source.applying(directlyMutated).entries.map(\.relativePath) == ["img1.JpG"])
}

@Test func issue127JpegChoiceIncludesBothFilenameExtensions() {
    let entries = [viewPolicyEntry("a.JPG"), viewPolicyEntry("b.JpEg"), viewPolicyEntry("c.png")]
    #expect(viewPolicyNames(entries, conditions: .init(selectedExtensions: ["jpg"])) == ["a.JPG", "b.JpEg"])
    #expect(viewPolicyNames(entries, conditions: .init(selectedExtensions: ["JPEG"])) == ["a.JPG", "b.JpEg"])
}

@Test func folderViewPolicyMissingMetadataTiesUseNaturalNameThenPath() {
    let entries = [viewPolicyEntry("z/img2.png"), viewPolicyEntry("img10.png"), viewPolicyEntry("a/img2.png")]
    for key in [FolderSortKey.modificationDate, .size] {
        for direction in [FolderSortDirection.ascending, .descending] {
            #expect(viewPolicyNames(entries, conditions: .init(sort: key, direction: direction)) == [
                "a/img2.png", "z/img2.png", "img10.png"])
        }
    }
}

@Test func issue108MetadataSortsKnownFirstAndComparesAreaWithoutOverflow() {
    let small = viewPolicyEntry("img10.jpg"), wide = viewPolicyEntry("img2.jpg")
    let unknown = viewPolicyEntry("img1.jpg"), huge = viewPolicyEntry("huge.jpg")
    let entries = [unknown, small, wide, huge]
    let metadata: [ItemID: FolderImageMetadata] = [
        small.itemID: .init(captureDate: Date(timeIntervalSince1970: 20), pixelWidth: 10, pixelHeight: 10),
        wide.itemID: .init(captureDate: Date(timeIntervalSince1970: 10), pixelWidth: 5, pixelHeight: 20),
        huge.itemID: .init(captureDate: Date(timeIntervalSince1970: 30), pixelWidth: Int.max, pixelHeight: 2)
    ]
    let source = FolderSnapshot(version: viewPolicyVersion, entries: entries, isComplete: true)
    func names(_ key: FolderSortKey, _ direction: FolderSortDirection) -> [String] {
        source.applying(.init(sort: key, direction: direction), metadata: metadata).entries.map(\.relativePath)
    }
    #expect(names(.captureDate, .ascending) == ["img2.jpg", "img10.jpg", "huge.jpg", "img1.jpg"])
    #expect(names(.captureDate, .descending) == ["huge.jpg", "img10.jpg", "img2.jpg", "img1.jpg"])
    #expect(names(.pixelDimensions, .ascending) == ["img2.jpg", "img10.jpg", "huge.jpg", "img1.jpg"])
    #expect(names(.pixelDimensions, .descending) == ["huge.jpg", "img2.jpg", "img10.jpg", "img1.jpg"])
}

@Test func issue108PixelAreaUsesFullWidthProductAndStableDimensionTies() {
    let smaller = viewPolicyEntry("a.jpg"), larger = viewPolicyEntry("b.jpg")
    let equalAreaTall = viewPolicyEntry("c.jpg"), equalAreaWide = viewPolicyEntry("d.jpg")
    let sameDimensions = viewPolicyEntry("e.jpg")
    let source = FolderSnapshot(version: viewPolicyVersion,
        entries: [larger, equalAreaWide, smaller, equalAreaTall, sameDimensions], isComplete: true)
    let metadata: [ItemID: FolderImageMetadata] = [
        smaller.itemID: .init(pixelWidth: Int.max - 1, pixelHeight: Int.max),
        larger.itemID: .init(pixelWidth: Int.max, pixelHeight: Int.max),
        equalAreaTall.itemID: .init(pixelWidth: 2, pixelHeight: 6),
        equalAreaWide.itemID: .init(pixelWidth: 3, pixelHeight: 4),
        sameDimensions.itemID: .init(pixelWidth: 3, pixelHeight: 4)
    ]
    #expect(source.applying(.init(sort: .pixelDimensions), metadata: metadata).entries.map(\.relativePath)
        == ["c.jpg", "d.jpg", "e.jpg", "a.jpg", "b.jpg"])
    #expect(source.applying(.init(sort: .pixelDimensions, direction: .descending), metadata: metadata)
        .entries.map(\.relativePath) == ["b.jpg", "a.jpg", "c.jpg", "d.jpg", "e.jpg"])
}

@Test func issue108MetadataAliasTieUsesStablePathAfterItemIdentity() throws {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    for name in ["a", "b", "target"] {
        try FileManager.default.createDirectory(at: rootURL.appendingPathComponent(name),
            withIntermediateDirectories: true)
    }
    let target = rootURL.appendingPathComponent("target/img.jpg")
    try Data([1]).write(to: target)
    let root = ItemIdentityRoot(id: AccessRootID(), url: rootURL)
    let aliases = try ["b", "a"].map { name -> FolderEntry in
        let url = rootURL.appendingPathComponent("\(name)/img.jpg")
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        return FolderEntry(url: url, root: root)
    }
    #expect(aliases[0].itemID == aliases[1].itemID)
    let source = FolderSnapshot(version: .init(rootID: root.id, folder: rootURL, generation: 1),
        entries: aliases, isComplete: true)
    #expect(source.applying(.init(sort: .captureDate)).entries.map(\.relativePath)
        == ["a/img.jpg", "b/img.jpg"])
}
