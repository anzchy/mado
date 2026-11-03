import AppKit
import Testing
import PicseeCore
import PicseeApplication
@testable import PicseeMacUI

@MainActor private func imageError446Node(_ id: String, _ root: NSView) -> NSView? {
    if root.accessibilityIdentifier() == id { return root }
    return root.subviews.lazy.compactMap { imageError446Node(id, $0) }.first
}

@MainActor private func imageError446Scene() -> StatesScene {
    let scene = StatesScene(width: 1280)
    scene.window.appearance = NSAppearance(named: .darkAqua)
    scene.window.setContentSize(NSSize(width: 1280, height: 800))
    scene.content.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
    scene.state.frame = scene.content.bounds
    return scene
}

@MainActor private func imageError446Color(_ color: NSColor, _ hex: UInt32) {
    let rgb = color.usingColorSpace(.sRGB)!
    #expect(abs(rgb.redComponent - CGFloat((hex >> 16) & 255) / 255) <= 1.0 / 255)
    #expect(abs(rgb.greenComponent - CGFloat((hex >> 8) & 255) / 255) <= 1.0 / 255)
    #expect(abs(rgb.blueComponent - CGFloat(hex & 255) / 255) <= 1.0 / 255)
}

/// image-error.html: SVG32, h2 margin18/normal23, p margin9/line22.1,
/// actions margin18 + flex row43, Retry box35 at row+4, Next box35 at row+8.
@Test @MainActor func imageError446PinnedDarkFramesAndColors() throws {
    let scene = imageError446Scene()
    defer { scene.window.close() }
    scene.state.display(.failed(.corruptImage, "DSC_0342.jpg"), nextEnabled: true)
    scene.state.layoutSubtreeIfNeeded()
    let page = try PinnedDesign.page("image-error")
    #expect(try page.length(".empty-state h2", "margin-top", viewport: 1280) == 18)
    #expect(try page.length(".empty-state p", "margin-top", viewport: 1280) == 9)
    #expect(abs(try page.lineHeight(".empty-state p", viewport: 1280) - 22.1) < 0.001)
    #expect(try page.length(".mock-actions", "gap", viewport: 1280) == 16)
    #expect(try page.length(".text-button", "margin-top", viewport: 1280) == 8)
    let icon = try #require(imageError446Node("state.icon", scene.state) as? NSImageView)
    let heading = try #require(imageError446Node("state.heading", scene.state) as? NSTextField)
    let message = try #require(imageError446Node("state.filename", scene.state) as? NSTextField)
    let retry = try #require(scene.state.buttons.first)
    let next = try #require(scene.state.buttons.last)
    let expectedTops: [(NSView, CGFloat, CGFloat)] = [
        (icon, 317.453125, 32), (heading, 367.453125, 23), (message, 399.45, 22.1),
        (retry, 443.546875, 35), (next, 447.546875, 35)
    ]
    for (view, top, height) in expectedTops {
        let frame = scene.state.convert(view.bounds, from: view)
        #expect(abs(800 - frame.maxY - top) <= 1)
        #expect(abs(frame.height - height) <= 1)
    }
    #expect(icon.frame.size == NSSize(width: 32, height: 32))
    for view in [icon as NSView, heading, message] { #expect(abs(view.frame.midX - 640) <= 1) }
    #expect(abs(retry.frame.union(next.frame).midX - 640) <= 1)
    let photo = try #require(NSImage(systemSymbolName: "photo", accessibilityDescription: "Unreadable image"))
    #expect(icon.image?.tiffRepresentation == photo.tiffRepresentation)
    #expect(icon.accessibilityLabel() == "Unreadable image")
    #expect(message.stringValue == "DSC_0342.jpg · The file may be damaged or its format unreadable.")
    #expect(imageError446Node("state.reason", scene.state) == nil)
    #expect(heading.font?.pointSize == 16 && message.font?.pointSize == 13)
    #expect(heading.lineBreakMode == .byTruncatingMiddle)
    #expect(!retry.isBordered && !next.isBordered)
    #expect(retry.layer?.cornerRadius == 6)
    #expect(abs(next.frame.minX - retry.frame.maxX - 16) <= 1)
    for (button, padding) in [(retry, CGFloat(32)), (next, CGFloat(16))] {
        let ink = (button.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width
        #expect(abs(button.frame.width - ink - padding) <= 1)
    }
    var appearanceError: Error?
    scene.window.appearance?.performAsCurrentDrawingAppearance {
        do {
            imageError446Color(try #require(icon.contentTintColor), 0x9aa4b2)
            imageError446Color(try #require(message.textColor), 0x9aa4b2)
            imageError446Color(try #require(heading.textColor), 0xe5e7eb)
            let primaryFill = try #require(retry.layer?.backgroundColor)
            imageError446Color(try #require(NSColor(cgColor: primaryFill)), 0x1d4ed8)
            imageError446Color(try #require(retry.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor), 0xffffff)
            imageError446Color(try #require(next.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor), 0x60a5fa)
            #expect(next.layer?.backgroundColor == nil || NSColor(cgColor: next.layer!.backgroundColor!)?.alphaComponent == 0)
        } catch { appearanceError = error }
    }
    if let appearanceError { throw appearanceError }
}

@Test @MainActor func imageError446OneLineTruncatesAndCompositionIsIdempotent() throws {
    let scene = imageError446Scene()
    defer { scene.window.close() }
    for width: CGFloat in [1280, 800, 1280] {
        scene.state.frame.size = NSSize(width: width, height: 800)
        for name in ["", "月亮🌙.jpg", String(repeating: "摄影旅行照片-long-name-", count: 40) + ".jpg"] {
            for nextEnabled in [true, false, true] {
                let status = ViewerImageStatus.failed(.corruptImage, name)
                scene.state.display(status, nextEnabled: nextEnabled)
                scene.state.display(status, nextEnabled: nextEnabled)
                scene.state.layoutSubtreeIfNeeded()
                let message = try #require(imageError446Node("state.filename", scene.state) as? NSTextField)
                let full = (name.isEmpty ? "" : name + " · ") + "The file may be damaged or its format unreadable."
                #expect(message.toolTip == full)
                #expect(message.stringValue.hasSuffix("The file may be damaged or its format unreadable."))
                if name.isEmpty { #expect(message.stringValue == full) }
                #expect(message.maximumNumberOfLines == 1 && message.cell?.usesSingleLineMode == true)
                #expect(message.lineBreakMode == .byClipping)
                #expect(abs(message.frame.height - 22.1) <= 1)
                #expect(scene.state.bounds.insetBy(dx: 24, dy: 24).contains(message.frame))
                #expect(message.accessibilityLabel() == full)
                #expect(scene.state.textLines == ["Unable to read this image", name, "The file may be damaged or its format unreadable."])
                #expect(scene.state.buttons.compactMap { $0.identifier?.rawValue } == (nextEnabled ? ["state.retry", "state.next"] : ["state.retry"]))
                #expect(scene.state.subviews.compactMap { $0 as? NSTextField }.count == 2)
                if !nextEnabled { #expect(abs(scene.state.buttons[0].frame.midX - scene.state.bounds.midX) <= 1) }
            }
        }
    }
    let old = scene.state.buttons
    scene.state.display(.loading("new.png"))
    #expect(old.allSatisfy { $0.superview == nil && !$0.isEnabled })
    scene.state.display(.failed(.corruptImage, "again.png"), nextEnabled: true)
    #expect(scene.state.buttons.count == 2)
    let failures: [(ViewerImageFailure, String)] = [
        (.corruptImage, "The file may be damaged or its format unreadable."),
        (.unsupportedFormat, "This image format is not supported."),
        (.resourceLimit, "This image exceeds the available resources."),
        (.sourceChanged, "The file changed again while it was being opened."),
        (.access, "Access to this image is unavailable.")
    ]
    for (kind, reason) in failures {
        scene.state.display(.failed(kind, "kind.jpg"))
        let message = try #require(imageError446Node("state.filename", scene.state) as? NSTextField)
        #expect(message.stringValue == "kind.jpg · " + reason)
        #expect(scene.state.textLines == ["Unable to read this image", "kind.jpg", reason])
    }
}

@Test @MainActor func imageError446ActionsFocusAndLabels() throws {
    let scene = imageError446Scene()
    defer { scene.window.close() }
    defer { scene.session.closeImage() }
    // Put the real router in viewing mode; display() alone only changes the presentation surface.
    scene.session.openImage(URL(fileURLWithPath: "/B.jpg"), maximumPixelSize: 512) { throw ImageLoadError(.corruptImage) }
    var retries = 0
    scene.state.onRetry = { retries += 1 }
    scene.host.canNavigate = true
    scene.state.display(.failed(.corruptImage, "B.jpg"), nextEnabled: true)
    scene.state.linkKeyViews(to: scene.canvas, chrome: scene.chrome)
    let retry = try #require(scene.state.buttons.first)
    let next = try #require(scene.state.buttons.last)
    #expect(retry.accessibilityLabel() == "Retry" && next.accessibilityLabel() == "Next")
    #expect(scene.canvas.nextKeyView === retry && retry.nextKeyView === next)
    #expect(scene.window.makeFirstResponder(retry))
    #expect(scene.window.firstResponder === retry)
    scene.window.selectNextKeyView(nil)
    #expect(scene.window.firstResponder === next)
    retry.performClick(nil); next.performClick(nil)
    #expect(retries == 1 && scene.host.navigation == [.next])
}

@Test @MainActor func imageError446FolderFailuresKeepOriginalGlyphAndColors() throws {
    let scene = imageError446Scene()
    defer { scene.window.close() }
    for surface: ViewerStateHost.Surface in [.gridReading, .viewer] {
        scene.state.display(.loading("folder-transition.png"))
        scene.state.surface = surface
        scene.state.display(.folderScanFailed("Folder scan failed", "待整理"))
        scene.state.layoutSubtreeIfNeeded()
        let original = scene.state.subviews.map(\.frame)
        let image = surface == .gridReading ? scene.state.readFailedView?.iconView : imageError446Node("state.icon", scene.state) as? NSImageView
        let glyph = try #require(image?.image?.tiffRepresentation)
        if surface == .gridReading {
            #expect(image?.image?.tiffRepresentation == ReadFailedStateView.folderAlertImage.tiffRepresentation)
            #expect(image?.contentTintColor == DesignColor.textSecondary.nsColor)
            #expect(scene.state.readFailedView?.detailLabel.textColor == DesignColor.textSecondary.nsColor)
        } else {
            #expect(image?.image?.tiffRepresentation == NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Unreadable image")?.tiffRepresentation)
            #expect((imageError446Node("state.reason", scene.state) as? NSTextField)?.textColor == DesignColor.errorText.nsColor)
        }
        scene.state.display(.failed(.corruptImage, "x.jpg"), nextEnabled: true)
        scene.state.display(.folderScanFailed("Folder scan failed", "待整理"))
        scene.state.layoutSubtreeIfNeeded()
        let restored = surface == .gridReading ? scene.state.readFailedView?.iconView : imageError446Node("state.icon", scene.state) as? NSImageView
        #expect(restored?.image?.tiffRepresentation == glyph)
        #expect(scene.state.subviews.map(\.frame) == original)
        if surface == .gridReading {
            #expect(restored?.contentTintColor == DesignColor.textSecondary.nsColor)
            #expect(scene.state.readFailedView?.detailLabel.textColor == DesignColor.textSecondary.nsColor)
            #expect(scene.state.readFailedView?.titleLabel.textColor == DesignColor.textPrimary.nsColor)
        } else {
            #expect((imageError446Node("state.reason", scene.state) as? NSTextField)?.textColor == DesignColor.errorText.nsColor)
            #expect((imageError446Node("state.heading", scene.state) as? NSTextField)?.textColor == DesignColor.textPrimary.nsColor)
        }
    }
}

@Test func imageError446CatalogCopyIsExactlyPinnedInBothLanguages() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let catalog = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("App/Resources/Localizable.xcstrings"))) as? [String: Any])
    let strings = try #require(catalog["strings"] as? [String: Any])
    let key = "The file may be damaged or its format unreadable."
    let localizations = try #require((strings[key] as? [String: Any])?["localizations"] as? [String: Any])
    for (language, expected) in [("en", key), ("zh-Hans", "文件可能已损坏或当前格式不可读取。")] {
        let unit = try #require((localizations[language] as? [String: Any])?["stringUnit"] as? [String: Any])
        #expect(unit["value"] as? String == expected)
    }
}

/// #446 fix1: preserve every reason glyph; only the name may elide. At the
/// 238pt content minimum the reason itself must wrap inside the pin's 24pt padding.
@Test @MainActor func imageError446FilenameOnlyEllipsisKeepsReasonDrawnAcrossResize() throws {
    let scene = imageError446Scene()
    defer { scene.window.close() }
    let failures: [(ViewerImageFailure, String)] = [
        (.corruptImage, "The file may be damaged or its format unreadable."),
        (.unsupportedFormat, "This image format is not supported."),
        (.resourceLimit, "This image exceeds the available resources."),
        (.sourceChanged, "The file changed again while it was being opened."),
        (.access, "Access to this image is unavailable.")
    ]
    let longName = String(repeating: "摄影🌙e\u{301}-long-name-", count: 80) + ".jpg"
    for (kind, reason) in failures {
        for name in [longName, "月亮🌙.jpg", ""] {
            scene.state.frame.size = NSSize(width: 1280, height: 800)
            scene.state.display(.failed(kind, name), nextEnabled: true)
            let message = try #require(imageError446Node("state.filename", scene.state) as? NSTextField)
            let wideText = message.stringValue
            let wideFrame = message.frame
            let full = (name.isEmpty ? "" : name + " · ") + reason
            for width: CGFloat in [1280, 238, 800, 238, 1280] {
                scene.window.setContentSize(NSSize(width: width, height: 800))
                scene.content.frame.size = NSSize(width: width, height: 800)
                scene.state.frame = scene.content.bounds
                scene.state.needsLayout = true
                scene.state.layoutSubtreeIfNeeded()
                #expect(message.stringValue.hasSuffix(reason))
                #expect(message.toolTip == full && message.accessibilityLabel() == full)
                #expect(scene.state.bounds.insetBy(dx: 24, dy: 24).contains(message.frame))
                #expect(message.lineBreakMode != .byTruncatingMiddle && message.lineBreakMode != .byTruncatingTail)
                let cell = try #require(message.cell)
                let measured = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: message.bounds.width, height: 10000))
                #expect(measured.height <= message.bounds.height + 0.5)
                if width >= 800 {
                    let ink = (message.stringValue as NSString).size(withAttributes: [.font: message.font!]).width
                    #expect(ink <= message.bounds.width)
                    #expect(abs(message.frame.height - 22.1) <= 1)
                } else {
                    #expect(cell.wraps && !cell.usesSingleLineMode)
                    #expect(message.maximumNumberOfLines == 0)
                    #expect(message.frame.height > 22.1)
                }
                let drawnName = message.stringValue.components(separatedBy: " · ").first ?? ""
                if name == longName {
                    #expect(drawnName.contains("…"))
                    #expect(drawnName.hasPrefix("摄") && drawnName.hasSuffix(".jpg"))
                    #expect(!drawnName.contains("�"))
                } else if width == 1280 {
                    #expect(message.stringValue == full)
                }
                for button in scene.state.buttons { #expect(button.frame.maxY < message.frame.minY) }
                if width == 1280 {
                    #expect(message.stringValue == wideText && message.frame == wideFrame)
                }
            }
            scene.state.display(.failed(kind, name), nextEnabled: true)
            let repeated = try #require(imageError446Node("state.filename", scene.state) as? NSTextField)
            #expect(repeated.stringValue == wideText && repeated.frame == wideFrame)
        }
    }
}

@Test @MainActor func imageError446ActionColorsFollowAppearanceWithoutLayout() throws {
    let scene = imageError446Scene()
    defer { scene.window.close() }
    scene.state.display(.failed(.corruptImage, "photo.jpg"), nextEnabled: true)
    let retry = try #require(scene.state.buttons.first)
    let next = try #require(scene.state.buttons.last)
    let originalFrames = scene.state.buttons.map(\.frame)
    for (appearance, fill, accent) in [(NSAppearance.Name.aqua, UInt32(0x2563eb), UInt32(0x2354c1)),
                                      (.darkAqua, UInt32(0x1d4ed8), UInt32(0x60a5fa))] {
        scene.window.appearance = NSAppearance(named: appearance)
        scene.state.viewDidChangeEffectiveAppearance()
        let background = try #require(retry.layer?.backgroundColor)
        imageError446Color(try #require(NSColor(cgColor: background)), fill)
        imageError446Color(try #require(retry.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor), 0xffffff)
        var resolvedNextInk: NSColor?
        scene.state.effectiveAppearance.performAsCurrentDrawingAppearance {
            resolvedNextInk = (next.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?.usingColorSpace(.sRGB)
        }
        imageError446Color(try #require(resolvedNextInk), accent)
        #expect(scene.state.buttons.map(\.frame) == originalFrames)
    }
}
