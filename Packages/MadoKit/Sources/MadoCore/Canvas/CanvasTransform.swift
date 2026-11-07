import CoreGraphics
import Foundation

/// Image pixels ↔ top-left view points. Zoom is backing pixels per image pixel.
public struct CanvasTransform: Sendable {
    public private(set) var backingScale: Double
    public private(set) var zoom: Double
    public private(set) var origin: CGPoint
    // Viewport updates retain placement before projecting it onto the backing grid.
    private var viewportOrigin: CGPoint?
    public static let zoomLimits = (1.0 / 64.0)...64.0

    public init(backingScale: Double, zoom: Double = 1, origin: CGPoint = .zero) {
        precondition(backingScale.isFinite && backingScale > 0)
        self.backingScale = backingScale
        self.zoom = min(max(zoom, Self.zoomLimits.lowerBound), Self.zoomLimits.upperBound)
        self.origin = origin
    }

    public func imageToView(_ pixel: CGPoint) -> CGPoint {
        let ratio = CGFloat(zoom / backingScale)
        return CGPoint(x: origin.x + pixel.x * ratio, y: origin.y + pixel.y * ratio)
    }

    public func viewToImage(_ point: CGPoint) -> CGPoint {
        let ratio = CGFloat(zoom / backingScale)
        return CGPoint(x: (point.x - origin.x) / ratio, y: (point.y - origin.y) / ratio)
    }

    public func imageToBacking(_ pixel: CGPoint) -> CGPoint {
        let point = imageToView(pixel)
        return CGPoint(x: point.x * backingScale, y: point.y * backingScale)
    }

    public mutating func zoom(to proposed: Double, about anchor: CGPoint) {
        let pixel = viewToImage(anchor)
        zoom = proposed.isNaN ? zoom : min(max(proposed, Self.zoomLimits.lowerBound), Self.zoomLimits.upperBound)
        pin(pixel, to: anchor)
    }

    public mutating func actualPixels(about anchor: CGPoint) {
        zoom(to: 1, about: anchor)
        // Actual-pixel mode prefers the backing grid over a subpixel anchor:
        // at most half a backing pixel of movement on each axis.
        origin = CGPoint(x: (origin.x * backingScale).rounded() / backingScale,
                         y: (origin.y * backingScale).rounded() / backingScale)
    }

    public mutating func setBackingScale(_ scale: Double, about anchor: CGPoint) {
        precondition(scale.isFinite && scale > 0)
        let pixel = viewToImage(anchor)
        backingScale = scale
        pin(pixel, to: anchor)
    }

    public mutating func pan(by delta: CGPoint, source: CGSize, viewport: CGSize, snap: Bool = false) {
        origin = CGPoint(x: origin.x + delta.x, y: origin.y + delta.y)
        bound(source: source, viewport: viewport, snap: snap)
    }

    public mutating func bound(source: CGSize, viewport: CGSize, snap: Bool = false) {
        viewportOrigin = nil
        func bounded(_ value: Double, image: Double, view: Double) -> Double {
            let extent = view - image * zoom / backingScale
            var low = min(0, extent), high = max(0, extent)
            if snap {
                low = (low * backingScale).rounded(.up) / backingScale
                high = (high * backingScale).rounded(.down) / backingScale
            }
            let proposed = snap ? (value * backingScale).rounded() / backingScale : value
            return min(high, max(low, proposed))
        }
        origin = CGPoint(x: bounded(origin.x, image: source.width, view: viewport.width),
                         y: bounded(origin.y, image: source.height, view: viewport.height))
    }

    public mutating func zoom(to proposed: Double, about anchor: CGPoint, source: CGSize, viewport: CGSize) {
        zoom(to: proposed, about: anchor)
        let end = imageToView(CGPoint(x: source.width, y: source.height))
        if end.x <= 0 || end.y <= 0 || origin.x >= viewport.width || origin.y >= viewport.height {
            bound(source: source, viewport: viewport)
        }
    }

    public mutating func viewportChanged(source: CGSize, from old: CGSize, to new: CGSize,
                                         backingScale: Double, mode: CanvasZoomMode) {
        if mode == .fit {
            self = Self.fitted(source: source, viewport: new, backingScale: backingScale)
            return
        }
        origin = viewportOrigin ?? origin
        let oldCentre = CGPoint(x: old.width / 2, y: old.height / 2)
        setBackingScale(backingScale, about: oldCentre)
        if case .custom(let value) = mode {
            zoom(to: value, about: oldCentre)
        } else {
            zoom(to: 1, about: oldCentre)
        }
        pan(by: CGPoint(x: (new.width - old.width) / 2, y: (new.height - old.height) / 2),
            source: source, viewport: new)
        let placement = origin
        if mode == .actualPixels { bound(source: source, viewport: new, snap: true) }
        viewportOrigin = placement
    }

    private mutating func pin(_ pixel: CGPoint, to anchor: CGPoint) {
        viewportOrigin = nil
        let ratio = CGFloat(zoom / backingScale)
        origin = CGPoint(x: anchor.x - pixel.x * ratio, y: anchor.y - pixel.y * ratio)
    }
}
