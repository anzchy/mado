import AppKit
import ImageIO
import Testing
@testable import PicseeMacUI

@MainActor func wallTestView(_ id: String, in root: NSView) -> NSView? {
    if root.accessibilityIdentifier() == id { return root }
    for child in root.subviews {
        if let found = wallTestView(id, in: child) { return found }
    }
    return nil
}

@MainActor func wallTestIdentifiers(in root: NSView) -> [String] {
    [root.accessibilityIdentifier()] + root.subviews.flatMap { wallTestIdentifiers(in: $0) }
}

@MainActor func launch(in scene: StatesScene) throws -> FirstLaunchView {
    try #require(scene.state.subviews.compactMap { $0 as? FirstLaunchView }.first)
}

@MainActor func wallView(_ launch: FirstLaunchView) -> NSView? { wallTestView("first-launch.wall", in: launch) }

@MainActor func wallLayer(_ name: String, in launch: FirstLaunchView) -> CALayer? {
    wallView(launch)?.layer?.sublayers?.first { $0.name == name }
}

@MainActor func tileContainers(_ launch: FirstLaunchView) -> [CALayer] {
    wallLayer("first-launch.wall.tiles", in: launch)?.sublayers ?? []
}

func imageLayer(_ container: CALayer) -> CALayer? { container.sublayers?.first }
func tileRing(_ container: CALayer) -> CALayer? {
    container.sublayers?.first { $0.name == "first-launch.wall.ring" }
}
@MainActor func anyTileContainerMasks(_ launch: FirstLaunchView) -> Bool { tileContainers(launch).contains(where: \.masksToBounds) }

func cgImage(_ layer: CALayer?) -> CGImage? {
    guard let contents = layer?.contents, CFGetTypeID(contents as CFTypeRef) == CGImage.typeID else { return nil }
    return (contents as! CGImage)
}

@MainActor func resize(_ scene: StatesScene, to size: NSSize) throws {
    scene.window.setContentSize(size)
    scene.content.frame = NSRect(origin: .zero, size: size)
    scene.state.frame = scene.content.bounds
    let view = try launch(in: scene)
    view.frame = scene.state.bounds
    view.layoutSubtreeIfNeeded()
}

func srgb(_ cg: CGColor?) throws -> PinnedDesign.Color {
    let input = try #require(cg)
    let resolved = try #require(NSColor(cgColor: input)?.usingColorSpace(.deviceRGB))
    return .init(red: resolved.redComponent, green: resolved.greenComponent,
                 blue: resolved.blueComponent, alpha: resolved.alphaComponent)
}

/// Waits for the Home's bundled samples to finish loading on the shared cancellation-driven wait (#398): a load that
/// never finishes fails the test at this wait, naming `sampleLoadCompleted`, instead of returning without samples.
@MainActor func waitForSamples(_ launch: FirstLaunchView, fileID: String = #fileID, line: Int = #line) async throws {
    try await waitUntil("sampleLoadCompleted", fileID: fileID, line: line) { launch.sampleLoadCompleted }
    launch.layoutSubtreeIfNeeded()
}

struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func generatedSizes(seed: UInt64, count: Int, width: ClosedRange<CGFloat>, height: ClosedRange<CGFloat>) -> [NSSize] {
    var generator = SplitMix64(seed: seed)
    return (0..<count).map { _ in
        NSSize(width: CGFloat(Int.random(in: Int(width.lowerBound)...Int(width.upperBound), using: &generator)),
               height: CGFloat(Int.random(in: Int(height.lowerBound)...Int(height.upperBound), using: &generator)))
    }
}

@MainActor func centreViews(_ launch: FirstLaunchView) -> [NSView] {
    ["first-launch.heading", "state.open", "first-launch.shortcut", "first-launch.shortcut-key",
     "first-launch.chip.folder", "first-launch.chip.images", "first-launch.chip.formats"]
        .compactMap { wallTestView($0, in: launch) }
}

func rotated(_ v: CGVector, degrees: CGFloat) -> CGVector {
    let r = degrees * .pi / 180
    return CGVector(dx: v.dx * cos(r) - v.dy * sin(r), dy: v.dx * sin(r) + v.dy * cos(r))
}

/// Oracle from source metadata, not pixels: the 480 cap never upscales a smaller source.
func sourcePixels(_ url: URL) -> (maxSide: Int, landscape: Bool)? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
    let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
    let swapped = (5...8).contains(orientation)
    return (max(width, height), swapped ? height > width : width > height)
}

func expectedDecodedMaxSide(_ url: URL) -> Int? { sourcePixels(url).map { min(480, $0.maxSide) } }

/// WI-4 snapshot of everything the drag lifecycle, theme and Reduce Transparency can change on the Home.
/// Dynamic colours resolve under the Home's own effective appearance.
struct WallPresentation: Equatable {
    var wallAlpha: CGFloat
    var wallLayerOpacity: Float?
    var tilesOpacity: Float?
    var containerOpacity: [Float]
    var containerHidden: [Bool]
    var scrimOpacity: Float?
    var scrimHidden: Bool?
    var scrimColors: [PinnedDesign.Color]
    var heading: String
    var headingColor: PinnedDesign.Color
    var outlineHidden: Bool
    var outlineStroke: PinnedDesign.Color
    var dropFill: PinnedDesign.Color
    var semanticFrames: [NSRect]
}

@MainActor func dropOutline(_ launch: FirstLaunchView) -> CAShapeLayer? {
    wallTestView("first-launch.drop", in: launch)?.layer?.sublayers?.compactMap { $0 as? CAShapeLayer }.first
}

@MainActor func headingColour(_ launch: FirstLaunchView) throws -> PinnedDesign.Color {
    let heading = try #require(wallTestView("first-launch.heading", in: launch) as? NSTextField)
    var resolved: CGColor?
    launch.effectiveAppearance.performAsCurrentDrawingAppearance { resolved = heading.textColor?.cgColor }
    return try srgb(resolved)
}

@MainActor func wallPresentation(_ launch: FirstLaunchView) throws -> WallPresentation {
    let wall = try #require(wallView(launch))
    let heading = try #require(wallTestView("first-launch.heading", in: launch) as? NSTextField)
    let drop = try #require(wallTestView("first-launch.drop", in: launch))
    let outline = try #require(dropOutline(launch))
    let scrim = wallLayer("first-launch.wall.scrim", in: launch) as? CAGradientLayer
    let containers = tileContainers(launch)
    return WallPresentation(
        wallAlpha: wall.alphaValue,
        wallLayerOpacity: wall.layer?.opacity,
        tilesOpacity: wallLayer("first-launch.wall.tiles", in: launch)?.opacity,
        containerOpacity: containers.map(\.opacity),
        containerHidden: containers.map(\.isHidden),
        scrimOpacity: scrim?.opacity,
        scrimHidden: scrim?.isHidden,
        scrimColors: try ((scrim?.colors as? [CGColor]) ?? []).map { try srgb($0) },
        heading: heading.stringValue,
        headingColor: try headingColour(launch),
        outlineHidden: outline.isHidden,
        outlineStroke: try srgb(outline.strokeColor),
        dropFill: try srgb(drop.layer?.backgroundColor),
        semanticFrames: launch.semanticViews.map(\.frame))
}

/// Opacity animations currently attached to the wall view's layer.
@MainActor func wallOpacityAnimations(_ launch: FirstLaunchView) -> [CABasicAnimation] {
    guard let layer = wallView(launch)?.layer else { return [] }
    return (layer.animationKeys() ?? []).compactMap { layer.animation(forKey: $0) as? CABasicAnimation }
        .filter { $0.keyPath == "opacity" }
}

/// The window server owns a real drag session; this stub carries a real pasteboard.
@MainActor final class WallDragInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    init(_ board: NSPasteboard) { draggingPasteboard = board }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) { }
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
        classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) { }
    func resetSpringLoading() { }
}
