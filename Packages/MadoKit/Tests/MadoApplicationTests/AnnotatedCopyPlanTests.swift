import Foundation
import Testing
import UniformTypeIdentifiers
import MadoCore
import MadoApplication

// #690 (P7-11) WI-1: Annotated Copy naming, format and destination (ADR-020, ADR-007).

private let writable: Set<UTType> = [.jpeg, .png, .heic, .tiff]

private func planned(_ source: String, _ existing: [String] = []) -> String {
    AnnotatedCopyPlan.name(for: source, existing: existing, writableTypes: writable).name
}

private func fold(_ name: String) -> String {
    name.precomposedStringWithCanonicalMapping.lowercased()
}

@Test(.timeLimit(.minutes(2))) func planNamingTable() {
    #expect(planned("photo.jpg") == "photo-annotated.jpg")
    #expect(planned("photo.jpg", ["photo.jpg", "photo-annotated.jpg"]) == "photo-annotated-2.jpg")
    #expect(planned("photo.jpg", ["photo-annotated.jpg", "photo-annotated-3.jpg"]) == "photo-annotated-2.jpg")
    #expect(planned("photo.jpg", ["photo-annotated.jpg", "photo-annotated-2.jpg"]) == "photo-annotated-3.jpg")
    #expect(planned("photo.jpg", ["PHOTO-ANNOTATED.JPG"]) == "photo-annotated-2.jpg")
    #expect(planned("caf\u{e9}.jpg", ["cafe\u{301}-annotated.jpg"]) == "caf\u{e9}-annotated-2.jpg")
    #expect(planned("a.b.JPG") == "a.b-annotated.JPG")
    #expect(planned("README") == "README-annotated.png")
    #expect(planned(".hidden.png") == ".hidden-annotated.png")
    let name = AnnotatedCopyPlan.name(for: "photo.jpg", existing: ["photo-annotated.jpg"], writableTypes: writable)
    #expect(name.stem == "photo" && name.pathExtension == "jpg" && name.type == .jpeg && name.number == 2)
    #expect(name.numbered(1).name == "photo-annotated.jpg")
    #expect(name.numbered(7).name == "photo-annotated-7.jpg")
}

@Test(.timeLimit(.minutes(2))) func planFormatKeptOrPNG() {
    let heic = AnnotatedCopyPlan.name(for: "x.heic", existing: [], writableTypes: writable)
    #expect(heic.name == "x-annotated.heic" && heic.type == .heic)
    let webp = AnnotatedCopyPlan.name(for: "x.webp", existing: [], writableTypes: writable)
    #expect(webp.name == "x-annotated.png" && webp.type == .png)
    #expect(planned("x.gif") == "x-annotated.png", "OQ-3: GIF saves as PNG")
    #expect(planned("x.webp", ["x-annotated.png"]) == "x-annotated-2.png", "clash on the final name")
    #expect(planned("x.jpeg") == "x-annotated.jpeg")
    #expect(planned("x.TIF") == "x-annotated.TIF")
    let raw = AnnotatedCopyPlan.name(for: "x.CR2", existing: [], writableTypes: writable)
    #expect(raw.name == "x-annotated.png" && raw.type == .png)
}

@Test(.timeLimit(.minutes(2))) func planNameIsFreshMinimalNeverSourceSeeded() {
    let stems = ["a", "\u{c9}", "e\u{301}", "\u{65e5}", "a.b"]
    let extensions = ["jpg", "JPG", "webp", "gif", ""]
    for seed in UInt64(0)..<200 {
        var random = AnnotationRandom(seed: seed)
        let stem = stems.randomElement(using: &random)!
        let ext = extensions.randomElement(using: &random)!
        let source = ext.isEmpty ? stem : "\(stem).\(ext)"
        let finalExt = ["jpg", "JPG"].contains(ext) ? ext : "png"
        var existing = [source]
        for k in 1...6 where Bool.random(using: &random) {
            var name = k == 1 ? "\(stem)-annotated.\(finalExt)" : "\(stem)-annotated-\(k).\(finalExt)"
            if Bool.random(using: &random) { name = name.uppercased() }
            if Bool.random(using: &random) { name = name.decomposedStringWithCanonicalMapping }
            existing.append(name)
        }
        let result = planned(source, existing.shuffled(using: &random))
        let taken = Set(existing.map(fold))
        #expect(!taken.contains(fold(result)), "seed \(seed): \(result)")
        #expect(fold(result) != fold(source), "seed \(seed)")
        #expect(result.contains("-annotated"), "seed \(seed)")
        let copy = AnnotatedCopyPlan.name(for: source, existing: existing, writableTypes: writable)
        for j in 1..<copy.number {
            #expect(taken.contains(fold(copy.numbered(j).name)), "seed \(seed): \(j) was free")
        }
        #expect(planned(source, existing) == result, "seed \(seed): deterministic")
    }
}

@Test(.timeLimit(.minutes(2))) func planDestinationDirectOrPanel() {
    let folder = URL(fileURLWithPath: "/tmp/photos", isDirectory: true)
    let name = "photo-annotated.jpg"
    #expect(AnnotatedCopyPlan.destination(folder: folder, name: name, access: .accessRoot, directRefused: false)
        == .direct(folder: folder, name: name))
    #expect(AnnotatedCopyPlan.destination(folder: folder, name: name, access: .accessRoot, directRefused: true)
        == .savePanel(folder: folder, name: name))
    #expect(AnnotatedCopyPlan.destination(folder: folder, name: name, access: .fileGrant, directRefused: false)
        == .savePanel(folder: folder, name: name))
    #expect(AnnotatedCopyPlan.destination(folder: folder, name: name, access: .fileGrant, directRefused: true)
        == .savePanel(folder: folder, name: name))
}

@Test(.timeLimit(.minutes(2))) func planRejectsPanelChoiceWithSourceIdentity() {
    #expect(throws: AnnotatedCopyError.sourceIsTarget) {
        try AnnotatedCopyPlan.validatePanelChoice("inode-7", source: "inode-7")
    }
    #expect(throws: Never.self) { try AnnotatedCopyPlan.validatePanelChoice("inode-8", source: "inode-7") }
}

@Test(.timeLimit(.minutes(2))) func annotateOnlyPermissionErrorsRefuseDirectWrite() {
    let all: [AnnotatedCopyError] = [.permissionDenied, .diskFull, .folderMissing, .sourceMissing, .sourceIsTarget,
                                     .encodeFailed, .nameExhausted, .accessLost, .writeFailed]
    for error in all {
        #expect(AnnotatedCopyPlan.refusesDirectWrite(error) == (error == .permissionDenied), "\(error)")
    }
}
