import Foundation
import Testing
import MadoCore
@testable import MadoInfrastructure

@Test func bitDepthReservationCoversRealSixteenBitPixels() throws {
    let item = ItemID.ephemeral(UUID())
    let request = ImageDecodeRequest(fileURL: fixture("gradient-16bit.png"), maximumPixelSize: 256)
    let header = try ImageSourceHeader.read(request, budget: 1_000_000, itemID: item)
    let image = try ImageIODecoder().decode(request)
    let reserved = try DecodeBudget.sourceCost(width: 256, height: 128, budget: 1_000_000, bytesPerPixel: header.bytesPerPixel)
    #expect(DecodeBudget.bytesPerPixel(depth: 16, components: 3, hasAlpha: false, isFloat: false) == 8)
    #expect(DecodeBudget.bytesPerPixel(depth: 32, components: 3, hasAlpha: true, isFloat: true) == 16)
    #expect(reserved >= image.image.bytesPerRow * image.image.height)
    #expect(throws: ImageDecodeError.budgetExceeded) {
        try DecodeBudget.sourceCost(width: 256, height: 128, budget: 200_000, bytesPerPixel: 8)
    }
    let eight = ImageDecodeRequest(fileURL: fixture("alpha-gradient.png"), maximumPixelSize: 256)
    let eightHeader = try ImageSourceHeader.read(eight, budget: 1_000_000, itemID: item)
    #expect(eightHeader.bytesPerPixel == 4)
    #expect(try DecodeBudget.sourceCost(width: 256, height: 128, budget: 1_000_000, bytesPerPixel: eightHeader.bytesPerPixel) == 131_072)
}

import ImageIO

@Test func bitDepthReportRealFixtureCostsAndAlignedLimits() throws {
    for name in ["gradient-16bit.png", "alpha-gradient.png"] {
        let request = ImageDecodeRequest(fileURL: fixture(name), maximumPixelSize: 256)
        let header = try ImageSourceHeader.read(request, budget: 1_000_000, itemID: .ephemeral(UUID()))
        let source = CGImageSourceCreateWithURL(fixture(name) as CFURL, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)! as NSDictionary
        let decoded = try ImageIODecoder().decode(request)
        let reserved = try DecodeBudget.outputCost(width: 256, height: 128, maximumPixelSize: 256, bytesPerPixel: header.bytesPerPixel, budget: 1_000_000)
        let actual = decoded.image.bytesPerRow * decoded.image.height
        print("COST fixture=\(name) depth=\(properties[kCGImagePropertyDepth]!) bpp=\(header.bytesPerPixel) reserved=\(reserved) decoded=\(actual)")
        if name == "gradient-16bit.png" { #expect(reserved == 65_536) }
        else { #expect(reserved == 131_072) }
        #expect(reserved >= actual)
    }
    #expect(ImageSourceHeader.pixelBytes([:]) == 4)
    #expect(ImageSourceHeader.pixelBytes([kCGImagePropertyDepth: 32, kCGImagePropertyIsFloat: true,
        kCGImagePropertyColorModel: kCGImagePropertyColorModelRGB, kCGImagePropertyHasAlpha: true]) == 16)
    #expect(DecodeBudget.bytesPerPixel(depth: 16, components: 1, hasAlpha: true, isFloat: false) == 4)
    #expect(try DecodeBudget.outputCost(width: 1280, height: 960, maximumPixelSize: 512, bytesPerPixel: 4, budget: 1_000_000) == 786_432)
    #expect(throws: ImageDecodeError.budgetExceeded) { try DecodeBudget.outputCost(width: 2, height: 2, maximumPixelSize: 0, bytesPerPixel: 4, budget: 1000) }
    #expect(throws: ImageDecodeError.budgetExceeded) { try DecodeBudget.outputCost(width: Int.max / 4, height: 1, maximumPixelSize: Int.max, bytesPerPixel: 4, budget: Int.max) }
    #expect(throws: ImageDecodeError.budgetExceeded) { try DecodeBudget.sourceCost(width: 1, height: 1, budget: 1000, bytesPerPixel: 0) }
}

@Test func bitDepthGraySixteenUsesTwoComponentsBytesWithoutEightBitFloor() async throws {
    #expect(DecodeBudget.bytesPerPixel(depth: 16, components: 1, hasAlpha: false, isFloat: false) == 2)
    let request = ImageDecodeRequest(fileURL: fixture("gradient-16bit.png"), maximumPixelSize: 256)
    let pipeline = ImageIOPipeline(configuration: DecodeConfiguration(budget: 80_000))
    var delivered: DecodedImage?
    do { delivered = try await pipeline.image(for: request) } catch { }
    #expect(delivered?.image.width == 256)
    if let delivered { #expect(delivered.image.bytesPerRow * delivered.image.height <= 80_000) }
}
