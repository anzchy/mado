import CoreGraphics

extension CanvasTransform {
    /// Source dimensions are the decoder's displayed (orientation-applied) pixel size. `trailingReserve` (view
    /// points) is kept clear at the right edge, as Annotate Mode does for its tool strip (#690, page 39): the image
    /// fits and centres in the area to its left.
    public static func fitted(source: CGSize, viewport: CGSize, backingScale: Double,
                              margin: Double = 16, trailingReserve: Double = 0) -> CanvasTransform {
        let area = CGSize(width: viewport.width - trailingReserve, height: viewport.height)
        let zoom = min(1, min(max(1, area.width - margin * 2) * backingScale / source.width,
                              max(1, viewport.height - margin * 2) * backingScale / source.height))
        let clamped = max(zoomLimits.lowerBound, zoom)
        var result = CanvasTransform(backingScale: backingScale, zoom: clamped,
            origin: CGPoint(x: (area.width - source.width * clamped / backingScale) / 2,
                            y: (viewport.height - source.height * clamped / backingScale) / 2))
        if clamped == 1 { result.actualPixels(about: .zero) }
        return result
    }
}
