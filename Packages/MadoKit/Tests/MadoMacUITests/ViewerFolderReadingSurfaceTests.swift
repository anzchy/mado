import AppKit
import Testing
import MadoCore
@testable import MadoApplication
@testable import MadoMacUI

private actor ReadingSurfaceScanner: FolderScanning {
    private var end: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?
    func scan(in folder: URL, root: ItemIdentityRoot, options: FolderScanOptions, emit: @Sendable ([FolderEntry]) async throws -> Void) async {
        await withCheckedContinuation { end = $0; arrival?.resume(); arrival = nil }
    }
    func entered() async { if end == nil { await withCheckedContinuation { arrival = $0 } } }
    func finish() { end?.resume(); end = nil }
}

@Test(.timeLimit(.minutes(2))) @MainActor func viewerFolderFixOpaqueReadingSurfaceAndRestoration() async throws {
    for theme in DesignTheme.allCases {
        for priorImage in [false, true] {
            let scene = StatesScene(), pipeline = StatesPipeline(), leases = StatesLeases(), scanner = ReadingSurfaceScanner()
            defer { scene.window.close() }
            scene.content.appearance = NSAppearance(named: theme == .light ? .aqua : .darkAqua)
            if priorImage { await scene.open(URL(fileURLWithPath: "/prior.png"), pipeline: pipeline, leases: leases)?.value }
            let prior = scene.session.imageStatus, key = scene.session.imageLoader.presented?.key
            let coordinator = FolderScanCoordinator(access: leases, scanner: scanner)
            scene.session.folderScan = coordinator
            let task = coordinator.begin(folder: URL(fileURLWithPath: "/surface"), rootID: AccessRootID())
            await scanner.entered(); scene.state.refresh()
            let expected = DesignColor.canvasBackground.components(theme)
            for size in [NSSize(width: 960, height: 640), NSSize(width: 700, height: 420)] {
                scene.state.setFrameSize(size)
                let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
                    pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
                bitmap.size = size
                bitmap.setProperty(.colorSyncProfileData, withValue: try #require(NSColorSpace.sRGB.iccProfileData))
                scene.state.cacheDisplay(in: scene.state.bounds, to: bitmap)
                for (x, y) in [(10, 10), (Int(size.width)-10, 10), (10, Int(size.height)-10), (Int(size.width)-10, Int(size.height)-10)] {
                    let pixel = try #require(bitmap.colorAt(x: x, y: y))
                    #expect(pixel.alphaComponent == 1)
                    #expect(abs(pixel.redComponent - expected[0]) < 0.025)
                    #expect(abs(pixel.greenComponent - expected[1]) < 0.025)
                    #expect(abs(pixel.blueComponent - expected[2]) < 0.025)
                }
            }
            #expect(scene.state.textLines == ["Reading Folder…", "Looking for images to browse. Please wait."])
            #expect(scene.state.buttons.map { $0.identifier?.rawValue } == ["state.cancel-folder"])
            let readingSubviews = scene.state.subviews
            scene.state.buttons.first?.performClick(nil); scene.state.refresh()
            #expect(scene.session.imageStatus == prior && scene.session.imageLoader.presented?.key == key)
            #expect(readingSubviews.allSatisfy { $0.superview == nil })
            #expect(scene.state.isHidden == priorImage)
            // First-image transition also removes the surface, without touching the stored prior image.
            scene.state.display(.readingFolder); let secondReading = scene.state.subviews
            scene.state.display(.showing)
            #expect(scene.state.isHidden && secondReading.allSatisfy { $0.superview == nil })
            await scanner.finish(); try await task.value
            scene.session.closeImage()
        }
    }
}
