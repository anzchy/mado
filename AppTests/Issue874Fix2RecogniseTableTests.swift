import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers
import MadoCore
import MadoApplication
import MadoInfrastructure
import MadoMacUI

// #874 fix round 2 (audits i874-confirm1) on the viewer. WI-1: the working sheet says "was sent" only once the
// transport has admitted the request. WI-2: a run's state changes check the image shown at once, not only through the
// queued generation observer. WI-3: a file's metadata never reaches the request. WI-4: Copy Table keeps working after
// the viewer moves on with the result panel open. WI-5: a long custom host fits the sent line.

// MARK: - WI-1: the sent line waits for the transport to admit the request

@MainActor @Test(.timeLimit(.minutes(3)))
func issue874Fix2CancelWhileTheTransportHoldsTheRequestAtItsEntryNeverShowsTheSentLine() async throws {
    let transport = Transport874F(holdAtEntry: true)
    let rig = try Rig874F(transport: transport)
    defer { rig.close() }
    try rig.installPicture()
    rig.adapter.start()
    try await rig.waitUntil("the transport holds the request at its entry") { await transport.holdingAtEntry }
    let working = try #require(rig.workingAlerts.first)
    #expect(ViewerRecogniseTableAdapter.sentLine(of: working)?.stringValue == "", "nothing admitted, nothing sent")
    rig.adapter.flow?.cancel()
    await transport.openEntry()
    try await rig.settle()
    #expect(rig.adapter.flow?.state == .cancelled)
    #expect(await transport.entered == 1)
    #expect(await transport.count == 0, "the transport sent nothing")
    #expect(rig.sentLineWhenDismissed == [""], "the sheet never said the image was sent")
}

@MainActor @Test(.timeLimit(.minutes(3)))
func issue874Fix2ATransportRefusalNeverShowsTheSentLine() async throws {
    let transport = Transport874F(refuseAtEntry: true)
    let rig = try Rig874F(transport: transport)
    defer { rig.close() }
    try rig.installPicture()
    rig.adapter.start()
    try await rig.settle()
    #expect(await transport.entered == 1)
    #expect(await transport.count == 0)
    #expect(rig.sentLineWhenDismissed == [""], "a refused request was never said to be sent")
    #expect(rig.adapter.panel == nil)
}

// MARK: - WI-2: the start reported before the move to B, run after it

/// Blocks the calling (main) thread until `flag` is set, then 50 ms more, so whatever the transport queued on the main
/// actor when it set the flag is queued before anything the caller does next.
private func blockTheMainThread874G(until flag: StartFlag874F) {
    while !flag.isSet { Thread.sleep(forTimeInterval: 0.001) }
    Thread.sleep(forTimeInterval: 0.05)
}

@MainActor @Test(.timeLimit(.minutes(3)))
func issue874Fix2AStartQueuedBeforeMovingToAnotherImageNeverShowsTheSentLine() async throws {
    let transport = Transport874F(gated: true, holdAtEntry: true)
    let rig = try Rig874F(transport: transport)
    defer { rig.close() }
    let a = Pipeline874F(image: try picture874F()), b = Pipeline874F(image: try picture874F(8, 5))
    try await rig.open(URL(fileURLWithPath: "/tmp/874-A.png"), pipeline: a, item: a.item)
    rig.adapter.start()
    try await rig.waitUntil("the request for A is at the transport's entry") { await transport.holdingAtEntry }
    await transport.openEntry()
    // Keep the main actor busy until the transport has reported the start, so the run's "sent" change is queued
    // here before the move to B queues the generation observer.
    blockTheMainThread874G(until: transport.reportingStart)
    let bURL = URL(fileURLWithPath: "/tmp/874-B.png")
    rig.controller.session.openImage(bURL, maximumPixelSize: 64) {
        try await AccessImageSource.open(.fileGrant(bURL), access: Leases874F(), pipeline: b)
    }
    try await rig.waitUntil("B is shown") {
        rig.controller.session.imageLoader.presented?.key.itemID == b.item
    }
    await transport.open()
    try await rig.settle()
    #expect(rig.sentLineWhenDismissed == [""], "A's sheet never said sent once the viewer showed B")
    #expect(rig.adapter.flow?.state == .idle)
    #expect(rig.adapter.panel == nil && rig.notices.isEmpty)
    #expect(rig.board.string(forType: .string) == "before")
}

// MARK: - WI-3: no metadata in the request

/// A JPEG or PNG carrying EXIF, GPS, TIFF camera fields, IPTC, XMP and (JPEG) an embedded thumbnail.
private func taggedFile874G(_ type: UTType, name: String) throws -> URL {
    let metadata = CGImageMetadataCreateMutable()
    #expect(CGImageMetadataSetValueWithPath(metadata, nil, "dc:description" as CFString, "MadoSecretXMP874" as CFString))
    var properties: [CFString: Any] = [
        kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 31.2304, kCGImagePropertyGPSLatitudeRef: "N",
                                       kCGImagePropertyGPSLongitude: 121.4737, kCGImagePropertyGPSLongitudeRef: "E"],
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "MadoSecretExif874"],
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "MadoCam874"],
        kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCaptionAbstract: "MadoSecretIPTC874"],
        kCGImageDestinationEmbedThumbnail: true,
    ]
    if type == .png { properties[kCGImagePropertyPNGDictionary] = [kCGImagePropertyPNGDescription: "MadoSecretPNG874"] }
    let buffer = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(buffer, type.identifier as CFString, 1, nil))
    CGImageDestinationAddImageAndMetadata(destination, try picture874F(40, 30), metadata, properties as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mado-874g-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent(name)
    try (buffer as Data).write(to: url)
    return url
}

@MainActor @Test(.timeLimit(.minutes(3)))
func issue874Fix2ATaggedFilesMetadataNeverReachesTheRequest() async throws {
    for (type, name) in [(UTType.jpeg, "tagged.jpg"), (UTType.png, "tagged.png")] {
        let transport = Transport874F()
        let rig = try Rig874F(transport: transport)
        defer { rig.close() }
        let url = try taggedFile874G(type, name: name)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let file = try Data(contentsOf: url)
        #expect(file.range(of: Data("MadoSecret".utf8)) != nil, "the fixture carries it")
        rig.controller.session.openImage(url, maximumPixelSize: 64) {
            try await AccessImageSource.open(.fileGrant(url), access: Leases874F(), pipeline: ImageIOPipeline())
        }
        try await rig.waitUntil("\(name) is shown") {
            rig.controller.session.imageLoader.phase == .settled && rig.controller.canvas.backdropFrame.image != nil
        }
        rig.adapter.start()
        try await rig.settle()
        let body = try #require(await transport.requests.last?.httpBody, "\(name)")
        let (mediaType, sent) = try #require(await transport.lastImage(), "\(name)")
        #expect(mediaType == (type == .jpeg ? "image/jpeg" : "image/png"), "\(name)")
        for secret in ["MadoSecret", "MadoCam874", "x:xmpmeta", "Exif\0\0", "Photoshop 3.0"] {
            #expect(sent.range(of: Data(secret.utf8)) == nil, "\(name): \(secret) in the image sent")
        }
        #expect(body.range(of: Data("MadoSecret".utf8)) == nil, "\(name): nothing in the request body")
        let source = try #require(CGImageSourceCreateWithData(sent as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyGPSDictionary] == nil && properties[kCGImagePropertyExifDictionary] == nil
                && properties[kCGImagePropertyIPTCDictionary] == nil && properties[kCGImagePropertyTIFFDictionary] == nil,
                "\(name)")
        #expect(TableImageSize874F.of(sent).map { $0.0 == 40 && $0.1 == 30 } == true, "\(name)")
        #expect(rig.adapter.panel != nil, "\(name)")
    }
}

// MARK: - WI-4: Copy Table after moving on with the panel open

@MainActor @Test(.timeLimit(.minutes(3)))
func issue874Fix2CopyTableStillWorksAfterTheViewerMovesOnWithThePanelOpen() async throws {
    let rig = try Rig874F()
    defer { rig.close() }
    let a = Pipeline874F(image: try picture874F()), b = Pipeline874F(image: try picture874F(8, 5))
    try await rig.open(URL(fileURLWithPath: "/tmp/874-A.png"), pipeline: a, item: a.item)
    rig.adapter.start()
    try await rig.settle()
    let panel = try #require(rig.adapter.panel)
    try await rig.open(URL(fileURLWithPath: "/tmp/874-B.png"), pipeline: b, item: b.item)
    try await Task.sleep(for: .milliseconds(100))
    #expect(rig.adapter.panel === panel, "the result stays in its panel with its own image")
    panel.copyButton.performClick(nil)
    #expect(rig.board.string(forType: .string) == "A\tB\n1\t2")
    #expect(!panel.copiedLabel.isHidden, "「表格已拷贝」 shows")
    guard case .result(let result) = rig.adapter.flow?.state else {
        Issue.record("the panel lost its flow: \(String(describing: rig.adapter.flow?.state))"); return
    }
    #expect(result.copied)
    rig.board.clearContents()
    rig.board.setString("again", forType: .string)
    panel.copyButton.performClick(nil)
    #expect(rig.board.string(forType: .string) == "A\tB\n1\t2", "a second Copy Table works too")
}

// MARK: - WI-5: a long custom host fits the sent line

@MainActor @Test(.timeLimit(.minutes(3)), arguments: ["en", "zh-Hans"])
func issue874Fix2ALongCustomHostFitsTheSentLineInBothLanguages(_ locale: String) throws {
    _ = NSApplication.shared
    let label = (0..<4).map { String(repeating: Character(UnicodeScalar(UInt8(97 + $0))), count: 59) }
    let host = label.joined(separator: ".") + ".example.com"
    #expect(host.count > 200)
    let format = try catalogue874F("The image was sent to %@. This usually takes a few seconds to over ten seconds.",
                                   locale)
    let text = ViewerRecogniseTableAdapter.sentText(host: host, format: format)
    let line = try #require(ViewerRecogniseTableAdapter.sentLine(of: ViewerRecogniseTableAdapter.workingAlert()))
    expectLayoutFits(layoutLabelMeasure(text, font: try #require(line.font), frame: line.frame.size),
                     view: line, shown: text, locale: locale,
                     test: "issue874Fix2ALongCustomHostFitsTheSentLineInBothLanguages-\(locale)")
    // The host keeps its start and its end, so the domain it belongs to stays readable.
    #expect(text.contains(String(host.prefix(8))) && text.contains("example.com"), "\(text)")
    // A host that fits is shown whole.
    #expect(ViewerRecogniseTableAdapter.sentText(host: "api.deepseek.com", format: format)
            == String(format: format, "api.deepseek.com"))
}
