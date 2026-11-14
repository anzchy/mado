import CoreGraphics
import Testing
import MadoCore
@testable import MadoInfrastructure

/// Mean of the source pixels in [x0, x1) × [y0, y1), rounded to nearest, per premultiplied channel.
private func mean(_ source: RedactionPixels, _ xs: Range<Int>, _ ys: Range<Int>) -> [UInt8] {
    var sums = [0, 0, 0, 0]
    for y in ys { for x in xs { for c in 0..<4 { sums[c] += Int(source.pixel(x, y)[c]) } } }
    let count = xs.count * ys.count
    return sums.map { UInt8(($0 + count / 2) / count) }
}

/// Every pixel's expected value: outside the area it is unchanged; inside, it is the mean of its cell, the cells
/// starting at the area's origin and clipped to the area.
private func expectMosaic(_ result: RedactionPixels, source: RedactionPixels, xs: Range<Int>, ys: Range<Int>, cell: Int) {
    #expect(result.width == source.width && result.height == source.height)
    for y in 0..<source.height {
        for x in 0..<source.width {
            guard xs.contains(x), ys.contains(y) else {
                #expect(result.pixel(x, y) == source.pixel(x, y), "outside (\(x), \(y))")
                continue
            }
            let cx = xs.lowerBound + (x - xs.lowerBound) / cell * cell
            let cy = ys.lowerBound + (y - ys.lowerBound) / cell * cell
            let expected = mean(source, cx..<min(cx + cell, xs.upperBound), cy..<min(cy + cell, ys.upperBound))
            #expect(result.pixel(x, y) == expected, "inside (\(x), \(y))")
        }
    }
}

@Test func issue693MosaicCellsAreAlignedToTheRectOriginAndHoldTheirMean() throws {
    let source = RedactionPixels.distinct(width: 24, height: 20)
    let rect = CGRect(x: 3, y: 2, width: 12, height: 8)
    let result = RedactionPixels(try RedactionRenderer.pixelate(source.image, rect: rect, cell: 4))
    expectMosaic(result, source: source, xs: 3..<15, ys: 2..<10, cell: 4)
    // Spot check one cell by hand: its four corners share one value and it differs from the neighbouring cell.
    #expect(result.pixel(3, 2) == result.pixel(6, 5))
    #expect(result.pixel(6, 5) != result.pixel(7, 5))
}

@Test func issue693MosaicEdgeCellsAreClippedToTheRect() throws {
    let source = RedactionPixels.distinct(width: 30, height: 25)
    let rect = CGRect(x: 5, y: 4, width: 13, height: 11)
    let result = RedactionPixels(try RedactionRenderer.pixelate(source.image, rect: rect, cell: 5))
    expectMosaic(result, source: source, xs: 5..<18, ys: 4..<15, cell: 5)
    // The last column of cells is 3 pixels wide, the last row 1 pixel high.
    #expect(result.pixel(15, 14) == mean(source, 15..<18, 14..<15))
}

@Test func issue693MosaicAveragesTranslucentPixelsInPremultipliedSpace() throws {
    var source = RedactionPixels(width: 2, height: 2, bytes: [UInt8](repeating: 0, count: 16))
    source.set(0, 0, [200, 100, 50, 255])
    source.set(1, 0, [100, 50, 25, 128])
    let result = RedactionPixels(try RedactionRenderer.pixelate(source.image, rect: CGRect(x: 0, y: 0, width: 2, height: 2),
                                                                cell: 2))
    for y in 0..<2 { for x in 0..<2 { #expect(result.pixel(x, y) == [75, 38, 19, 96]) } }
}

@Test func issue693MosaicOfOnePixelCellsChangesNothing() throws {
    let source = RedactionPixels.distinct(width: 9, height: 7)
    let result = try RedactionRenderer.pixelate(source.image, rect: CGRect(x: 1, y: 1, width: 6, height: 5), cell: 1)
    #expect(RedactionPixels(result) == source)
}

@Test func issue693MosaicRectIsWidenedAndClippedLikeSolid() throws {
    let source = RedactionPixels.distinct(width: 16, height: 12)
    let result = RedactionPixels(try RedactionRenderer.pixelate(source.image,
                                                                rect: CGRect(x: 9.5, y: -2, width: 10, height: 6.2),
                                                                cell: 3))
    expectMosaic(result, source: source, xs: 9..<16, ys: 0..<5, cell: 3)
}
