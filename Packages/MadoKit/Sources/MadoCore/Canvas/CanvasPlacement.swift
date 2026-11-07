import CoreGraphics

extension CanvasTransform {
    /// Source dimensions are the decoder's displayed (orientation-applied) pixel size.
    public static func fitted(source: CGSize, viewport: CGSize, backingScale: Double,
                              margin: Double = 16) -> CanvasTransform {
        let zoom = min(1, min(max(1, viewport.width - margin * 2) * backingScale / source.width,
                              max(1, viewport.height - margin * 2) * backingScale / source.height))
        let clamped = max(zoomLimits.lowerBound, zoom)
        var result = CanvasTransform(backingScale: backingScale, zoom: clamped,
            origin: CGPoint(x: (viewport.width - source.width * clamped / backingScale) / 2,
                            y: (viewport.height - source.height * clamped / backingScale) / 2))
        if clamped == 1 { result.actualPixels(about: .zero) }
        return result
    }
}
