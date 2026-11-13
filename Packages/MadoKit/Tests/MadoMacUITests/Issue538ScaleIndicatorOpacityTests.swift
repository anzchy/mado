import AppKit
import SwiftUI
import Testing
@testable import MadoMacUI

/// Page 25 image-error.html disables the zoom controls at a single component opacity of 0.4.
/// Compare the real Button raster to independent Text: a second style-owned dim must fail.
@MainActor private func issue538Raster<V: View>(_ view: V, theme: DesignTheme) throws -> [UInt8] {
    let renderer = ImageRenderer(content: view.frame(width: 122, height: 28)
        .environment(\.colorScheme, theme == .dark ? .dark : .light))
    renderer.scale = 1
    let image = try #require(renderer.cgImage)
    #expect(image.width == 122 && image.height == 28)
    let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
        bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let data = try #require(context.data)
    return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self),
                                     count: image.width * image.height * 4))
}

private func issue538Reference(_ label: String, opacity: Double) -> some View {
    Text(label)
        .font(Font(DesignMetrics.font("uiSmall")))
        .foregroundStyle(DesignColor.textPrimary.color)
        .padding(5)
        .frame(minWidth: 100)
        .opacity(opacity)
}

private func issue538Compare(_ actual: [UInt8], _ expected: [UInt8], context: String) {
    #expect(actual.count == expected.count)
    let actualAlpha = stride(from: 3, to: actual.count, by: 4).map { Int(actual[$0]) }
    let expectedAlpha = stride(from: 3, to: expected.count, by: 4).map { Int(expected[$0]) }
    #expect(actualAlpha.filter { $0 > 25 }.count > 20, "nonempty actual label ink: \(context)")
    #expect(expectedAlpha.filter { $0 > 25 }.count > 20, "nonempty reference label ink: \(context)")
    let maximumDifference = zip(actual, expected).map { abs(Int($0) - Int($1)) }.max() ?? 255
    let actualInk = actualAlpha.reduce(0, +)
    let expectedInk = expectedAlpha.reduce(0, +)
    let inkRatio = Double(actualInk) / Double(max(expectedInk, 1))
    print("issue538 \(context): alpha peak \(actualAlpha.max() ?? 0)/\(expectedAlpha.max() ?? 0), ink ratio \(inkRatio), max pixel delta \(maximumDifference)")
    #expect(maximumDifference <= 2, "RGBA raster matches independent Text: \(context)")
    #expect(abs(inkRatio - 1) < 0.02, "integrated ink matches single opacity: \(context)")
}

@Test(.timeLimit(.minutes(2)), arguments: [DesignTheme.light, .dark]) @MainActor
func issue538DisabledScaleLabelUsesSingleComponentOpacity(_ theme: DesignTheme) throws {
    _ = NSApplication.shared
    let actual = ScaleIndicator(actualPixels: false, state: .disabled, theme: theme, input: .live) {}
    let actualPixels = try issue538Raster(actual, theme: theme)
    let reference = try issue538Raster(issue538Reference(String(localized: "Fit window"), opacity: 0.4), theme: theme)
    issue538Compare(actualPixels, reference, context: "disabled \(theme)")
}

@Test(.timeLimit(.minutes(2)), arguments: [DesignTheme.light, .dark]) @MainActor
func issue538EnabledScaleLabelKeepsFullOpacity(_ theme: DesignTheme) throws {
    _ = NSApplication.shared
    for (actualPixels, customZoom, label) in [(false, nil, String(localized: "Fit window")),
                                             (true, nil, "1:1 · 100%"), (false, 1.25, "125%")] {
        let actual = ScaleIndicator(actualPixels: actualPixels, customZoom: customZoom,
                                    theme: theme, input: .live) {}
        let pixels = try issue538Raster(actual, theme: theme)
        let reference = try issue538Raster(issue538Reference(label, opacity: 1), theme: theme)
        issue538Compare(pixels, reference, context: "enabled \(theme) \(label)")
    }
}
