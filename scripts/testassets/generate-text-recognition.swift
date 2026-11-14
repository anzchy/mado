import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
let folder = root.appendingPathComponent("TestAssets/TextRecognition", isDirectory: true)
let mixed = try Data(contentsOf: folder.appendingPathComponent("mixed.png"))
guard let source = CGImageSourceCreateWithData(mixed as CFData, nil),
      let upright = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let sideways = CGContext(data: nil, width: upright.height, height: upright.width,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("source decode") }
sideways.translateBy(x: 0, y: CGFloat(upright.width))
sideways.rotate(by: -.pi / 2)
sideways.draw(upright, in: CGRect(x: 0, y: 0, width: upright.width, height: upright.height))
guard let rotated = sideways.makeImage() else { fatalError("rotation") }
let oriented = NSMutableData()
guard let destination = CGImageDestinationCreateWithData(oriented, UTType.jpeg.identifier as CFString, 1, nil) else { fatalError("destination") }
CGImageDestinationAddImage(destination, rotated, [kCGImagePropertyOrientation: 6] as CFDictionary)
guard CGImageDestinationFinalize(destination) else { fatalError("JPEG") }
try (oriented as Data).write(to: folder.appendingPathComponent("mixed-orientation-6.jpg"))

guard let large = CGContext(data: nil, width: 5000, height: 1700,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("large context") }
large.setFillColor(CGColor(gray: 1, alpha: 1))
large.fill(CGRect(x: 0, y: 0, width: 5000, height: 1700))
large.draw(upright, in: CGRect(x: 200, y: 300, width: 1500, height: 510))
guard let largeImage = large.makeImage() else { fatalError("large image") }
let oversized = NSMutableData()
guard let largeJPEG = CGImageDestinationCreateWithData(oversized, UTType.jpeg.identifier as CFString, 1, nil) else { fatalError("JPEG destination") }
CGImageDestinationAddImage(largeJPEG, largeImage, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
guard CGImageDestinationFinalize(largeJPEG) else { fatalError("JPEG") }
try (oversized as Data).write(to: folder.appendingPathComponent("mixed-oversize.jpg"))

guard let dense = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1000, pixelsHigh: 2400,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0),
      let graphics = NSGraphicsContext(bitmapImageRep: dense) else { fatalError("dense bitmap") }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphics
NSColor.white.setFill()
NSBezierPath(rect: CGRect(x: 0, y: 0, width: 1000, height: 2400)).fill()
let attributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 34, weight: .semibold),
    .foregroundColor: NSColor.black
]
for row in 0..<40 {
    let label = String(format: "LINE %02d", row) as NSString
    label.draw(at: CGPoint(x: row == 19 ? 250 : 50, y: 2320 - row * 58), withAttributes: attributes)
}
graphics.flushGraphics()
NSGraphicsContext.restoreGraphicsState()
guard let densePNG = dense.representation(using: .png, properties: [:]) else { fatalError("dense PNG") }
try densePNG.write(to: folder.appendingPathComponent("dense-40.png"))

guard let tall = CGContext(data: nil, width: 1170, height: 12000,
                           bitsPerComponent: 8, bytesPerRow: 0,
                           space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("tall context") }
tall.setFillColor(CGColor(gray: 1, alpha: 1))
tall.fill(CGRect(x: 0, y: 0, width: 1170, height: 12000))
tall.draw(upright, in: CGRect(x: 80, y: 10900, width: 1000, height: 340))
guard let tallImage = tall.makeImage() else { fatalError("tall image") }
let tallData = NSMutableData()
guard let tallJPEG = CGImageDestinationCreateWithData(tallData, UTType.jpeg.identifier as CFString, 1, nil) else { fatalError("tall JPEG") }
CGImageDestinationAddImage(tallJPEG, tallImage, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
guard CGImageDestinationFinalize(tallJPEG) else { fatalError("tall JPEG finalize") }
try (tallData as Data).write(to: folder.appendingPathComponent("mixed-tall-narrow.jpg"))
