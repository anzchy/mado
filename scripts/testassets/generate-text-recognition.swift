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
