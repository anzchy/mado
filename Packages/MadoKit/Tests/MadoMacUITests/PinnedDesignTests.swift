import Foundation
import Testing
import CryptoKit

@Test func pinnedDesignGridRulesFollowViewport() throws {
    let page = try PinnedDesign.page("grid-light")
    #expect(try page.edges(".grid-bottom-bar", "padding", viewport: 1280).right == 12)
    #expect(try page.edges(".grid-bottom-bar", "padding", viewport: 480).right == 7)
    #expect(try page.length(".grid-toolbar-tools", "gap", viewport: 1280) == 6)
    #expect(try page.length(".grid-toolbar-tools", "gap", viewport: 800) == 2)
}

@Test func pinnedDesignAppliesLonghandsInCascadeOrder() throws {
    let grid = try PinnedDesign.page("grid-light")
    #expect(try grid.edges(".toolbar", "padding", viewport: 700) == .init(top: 0, right: 8, bottom: 0, left: 8))
    #expect(throws: PinnedDesign.Error.self) { try grid.edges(".sidebar", "padding", viewport: 700) }
    let inspector = try PinnedDesign.page("viewer-inspector")
    #expect(throws: PinnedDesign.Error.self) { try inspector.edges(".inspector", "padding", viewport: 700) }
}

@Test func pinnedDesignAppliesDeclarationsInSameRuleOrder() throws {
    let page = try fixturePage(".a{padding-left:4px;padding:10px}.b{padding:10px;padding-left:4px}")
    #expect(try page.edges(".a", "padding", viewport: 800).left == 10)
    #expect(try page.edges(".b", "padding", viewport: 800).left == 4)
}

@Test func pinnedDesignRejectsContextualOverride() throws {
    let page = try PinnedDesign.page("grid-light")
    #expect(throws: PinnedDesign.Error.self) {
        try page.color(".titlebar-middle", "color", viewport: 1280)
    }
}

@Test func pinnedDesignUsesDarkTokensForDirectQueries() throws {
    let page = try PinnedDesign.page("grid-dark")
    #expect(try page.color(":root", "--color-accent", viewport: 1280).red == 96.0 / 255)
}

@Test func pinnedDesignRejectsUnresolvedMathOperands() throws {
    let page = try PinnedDesign.page("grid-light")
    for expression in ["min(10px,unsupported,20px)", "max(10px,unsupported,20px)", "clamp(10px,unsupported,20px)"] {
        #expect(throws: PinnedDesign.Error.self) { try page.lengthValue(expression, viewport: 800) }
    }
}

@Test func pinnedDesignResolvesUnitlessLineHeightAsLength() throws {
    let page = try PinnedDesign.page("search-empty")
    #expect(abs(try page.length(".empty-state p", "line-height", viewport: 1280) - 22.1) < 0.0001)
}

private func fixturePage(_ css: String) throws -> PinnedDesign {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let states = temporary.appendingPathComponent("design/prototypes/picsee-browser/states")
    try FileManager.default.createDirectory(at: states, withIntermediateDirectories: true)
    let html = "<html><style>\(css)</style></html>"
    let hash = SHA256.hash(data: Data(html.utf8)).map { String(format: "%02x", $0) }.joined()
    try Data(html.utf8).write(to: states.appendingPathComponent("fixture.html"))
    let manifest = "{\"states\":[{\"name\":\"fixture\",\"file\":\"fixture.html\",\"sha256\":\"\(hash)\"}]}"
    try Data(manifest.utf8).write(to: states.appendingPathComponent("manifest.json"))
    let source = temporary.appendingPathComponent("Packages/MadoKit/Tests/MadoMacUITests/Test.swift")
    return try PinnedDesign.page("fixture", source: source.path)
}

@Test func pinnedDesignColorMixUsesCSSWeights() throws {
    let page = try fixturePage(".a{color:color-mix(in srgb, black, white)} .b{color:color-mix(in srgb, black 20%, white 20%)} .c{color:color-mix(in srgb, black 20%, transparent 20%)} .d{color:color-mix(in srgb, black 80%, white 80%)} .e{color:color-mix(in srgb, black 20%, white)}")
    #expect(try page.color(".a", "color", viewport: 800).red == 0.5)
    #expect(try page.color(".b", "color", viewport: 800).red == 0.5)
    #expect(try page.color(".b", "color", viewport: 800).alpha == 0.4)
    #expect(try page.color(".c", "color", viewport: 800).alpha == 0.2)
    #expect(try page.color(".d", "color", viewport: 800).red == 0.5)
    #expect(try page.color(".d", "color", viewport: 800).alpha == 1)
    #expect(try page.color(".e", "color", viewport: 800).red == 0.8)
}

@Test func pinnedDesignPropagatesBrokenLineHeightToken() throws {
    let page = try fixturePage(".a{font-size:12px;font-weight:500;line-height:var(--missing)}")
    #expect(throws: PinnedDesign.Error.self) { try page.font(".a", viewport: 800) }
}

@Test func pinnedDesignRejectsUnsupportedAtRules() throws {
    for conditional in ["@media (prefers-reduced-motion:reduce){.a{gap:9px}}", "@supports (display:grid){.a{gap:9px}}", "@layer example{.a{gap:9px}}"] {
        let page = try fixturePage(".a{gap:2px}" + conditional)
        #expect(throws: PinnedDesign.Error.self) { try page.length(".a", "gap", viewport: 800) }
    }
}

@Test func issue168RejectsCommaSeparatedMediaLists() throws {
    let page = try fixturePage(".a{gap:2px}@media (min-width:1000px), (max-width:400px){.a{gap:9px}}")
    for viewport in [300.0, 1200.0] {
        do {
            _ = try page.length(".a", "gap", viewport: viewport)
            Issue.record("Expected unsupported media list at \(viewport)pt")
        } catch let error as PinnedDesign.Error {
            for part in ["fixture", "selector '.a'", "property 'gap'", "at \(viewport)pt", "unsupported @media"] {
                #expect(error.description.contains(part), "Missing \(part): \(error)")
            }
        }
    }
}

@Test func issue168RejectsSameElementQualifiers() throws {
    for qualified in [".x.state", ".x[attr]", ".x:not(.hidden)", ".x:last-child", ".parent .x:not(.hidden)"] {
        let page = try fixturePage(".x{gap:2px}\(qualified){gap:9px}")
        do {
            _ = try page.length(".x", "gap", viewport: 800)
            Issue.record("Expected ambiguity from \(qualified)")
        } catch let error as PinnedDesign.Error {
            for part in ["fixture", "selector '.x'", "property 'gap'", "at 800.0pt", "ambiguous", qualified] {
                #expect(error.description.contains(part), "Missing \(part): \(error)")
            }
        }
    }
}

@Test func issue168RejectsPrefixOrderQualifiersWithoutMatchingClassPrefixes() throws {
    for qualified in [".state.a", "button.a", ":not(.hidden).a"] {
        let page = try fixturePage(".a{gap:2px}\(qualified){gap:9px}")
        do {
            _ = try page.length(".a", "gap", viewport: 800)
            Issue.record("Expected ambiguity from \(qualified)")
        } catch let error as PinnedDesign.Error {
            for part in ["fixture", "selector '.a'", "property 'gap'", "at 800.0pt", "ambiguous", qualified] {
                #expect(error.description.contains(part), "Missing \(part): \(error)")
            }
        }
    }
    let distinct = try fixturePage(".a{gap:2px}.ab{gap:9px}")
    #expect(try distinct.length(".a", "gap", viewport: 800) == 2)
}

@Test func issue168RejectsPinnedWorkspaceQualifiedRule() throws {
    let page = try PinnedDesign.page("grid-light")
    do {
        _ = try page.raw(".workspace", "grid-template-columns", viewport: 1280)
        Issue.record("Expected qualified workspace rule to be ambiguous")
    } catch let error as PinnedDesign.Error {
        for part in ["grid-light", "selector '.workspace'", "property 'grid-template-columns'", "at 1280.0pt", "ambiguous", ".workspace:not(.sidebar-hidden)"] {
            #expect(error.description.contains(part), "Missing \(part): \(error)")
        }
    }
}

@Test func issue168AllowsTransientStateQualifiers() throws {
    for qualified in [":hover", ":focus", ":focus-visible", ":focus-within", ":active", ":disabled"] {
        let page = try fixturePage(".x{gap:2px}.x\(qualified){gap:9px}")
        #expect(try page.length(".x", "gap", viewport: 800) == 2)
    }
}

@Test func issue168RejectsMalformedCSSTailsOnLoad() throws {
    let cases = [
        (".a{gap:2px}}", "stray closing brace"),
        (".a{gap:2px} trailing text", "trailing CSS text"),
        ("@import url(other.css); .a{gap:2px}", "blockless at-statement"),
        ("@charset \"utf-8\"; .a{gap:2px}", "blockless at-statement")
    ]
    for (css, reason) in cases {
        do {
            _ = try fixturePage(css)
            Issue.record("Expected CSS load failure: \(css)")
        } catch let error as PinnedDesign.Error {
            #expect(error.description.contains("fixture"), "Missing page: \(error)")
            #expect(error.description.contains(reason), "Missing \(reason): \(error)")
        }
    }
}

@Test func pinnedDesignTypographyAndColorsComeFromPages() throws {
    let empty = try PinnedDesign.page("search-empty")
    let heading = try empty.font(".empty-state h2", viewport: 1280)
    #expect(heading.size == 16)
    #expect(heading.weight == 500)
    // #317: the Bottom Bar has no top rule and is --color-bg at 80% in each appearance.
    for name in ["grid-light", "grid-dark"] {
        let page = try PinnedDesign.page(name)
        #expect(try page.raw(".grid-bottom-bar", "border-top", viewport: 1280) == "0", "\(name)")
        let fill = try page.color(".grid-bottom-bar", "background", viewport: 1280)
        let background = try page.color(":root", "--color-bg", viewport: 1280)
        #expect(abs(fill.alpha - background.alpha * 0.8) < 1e-9, "\(name)")
        #expect(abs(fill.red - background.red) < 1e-9 && abs(fill.green - background.green) < 1e-9
            && abs(fill.blue - background.blue) < 1e-9, "\(name)")
    }
    let light = try PinnedDesign.page("grid-light").color(":root", "--color-bg", viewport: 1280)
    let dark = try PinnedDesign.page("grid-dark").color(":root", "--color-bg", viewport: 1280)
    #expect(light != dark)
}

@Test func pinnedDesignReportsMissingRules() throws {
    let page = try PinnedDesign.page("viewer-inspector")
    #expect(throws: PinnedDesign.Error.self) {
        try page.length(".missing-selector", "gap", viewport: 1280)
    }
}

@Test func pinnedDesignExpressionsAndFailureExplainTheSource() throws {
    let page = try PinnedDesign.page("grid-light")
    #expect(try page.length(".thumbnail-wrap", "height", viewport: 1280) == 188.16)
    #expect(try page.length(".thumbnail-wrap", "height", viewport: 480) == 150)
    #expect(try page.length("body.tauri-macos", "--traffic-lights-clearance", viewport: 1280) == 62)
    let highlight = try page.color(":root", "--color-highlight", viewport: 1280)
    #expect(highlight.alpha == 0.65)
    do {
        try page.assertLength(99, ".grid-toolbar-tools", "gap", viewport: 800)
        Issue.record("Expected a CSS comparison failure")
    } catch let error as PinnedDesign.Error {
        #expect(error.description.contains(".grid-toolbar-tools gap at 800.0pt"))
        #expect(error.description.contains("expected 2.0pt"))
        #expect(error.description.contains("actual 99.0pt"))
    }
}

@Test func pinnedDesignRejectsChangedPageHash() throws {
    let source = URL(fileURLWithPath: #filePath)
    let root = source.deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let original = root.appendingPathComponent("design/prototypes/picsee-browser/states")
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let states = temporary.appendingPathComponent("design/prototypes/picsee-browser/states")
    try FileManager.default.createDirectory(at: states, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    try FileManager.default.copyItem(at: original.appendingPathComponent("manifest.json"),
                                     to: states.appendingPathComponent("manifest.json"))
    try Data("<style>.grid-bottom-bar{padding:99px}</style>".utf8)
        .write(to: states.appendingPathComponent("grid-light.html"))
    let fakeSource = temporary.appendingPathComponent("Packages/MadoKit/Tests/MadoMacUITests/Test.swift")
    do {
        _ = try PinnedDesign.page("grid-light", source: fakeSource.path)
        Issue.record("Expected SHA256 mismatch")
    } catch let error as PinnedDesign.Error {
        #expect(error.description.contains("SHA256 mismatch"))
        #expect(error.description.contains("grid-light.html"))
    }
}

@Test func pinnedDesignLineHeightAndMinNeedExplicitBasis() throws {
    let page = try PinnedDesign.page("search-empty")
    #expect(abs(try page.lineHeight(".empty-state p", viewport: 1280) - 22.1) < 0.0001)
    #expect(try page.lengthValue("min(145px,100%)", viewport: 800, percentageBase: 120) == 120)
    #expect(throws: PinnedDesign.Error.self) {
        try page.lengthValue("min(145px,100%)", viewport: 800)
    }
}

@Test func i315PinnedReaderReadsWallTokens() throws {
    let light = try PinnedDesign.page("first-launch")
    let dark = try PinnedDesign.page("first-launch", appearance: "dark")
    #expect(try light.childCount(tag: "img", inClass: "tiles") == 60)
    #expect(try PinnedDesign.seconds(light.rootToken("--motion-duration-fast")) == 0.15)
    #expect(try PinnedDesign.seconds(light.rootToken("--motion-duration-fast", media: "prefers-reduced-motion:reduce")) == 0)
    #expect(try PinnedDesign.seconds("0.35s") == 0.35)
    #expect(throws: PinnedDesign.Error.self) { try light.raw(":root", "--motion-duration-fast", viewport: 960) }
    #expect(try light.rotationDegrees(".wall .tiles") == -9)
    #expect(try light.translateY(".wall .tiles>:nth-child(2n)") == 110)
    #expect(try light.gridColumns(".wall .tiles") == 6)
    let lightShadow = try light.boxShadowLayers(":root", "--shadow-soft", viewport: 960)
    #expect(lightShadow.count == 2)
    if lightShadow.count == 2 {
        #expect([lightShadow[0].x, lightShadow[0].y, lightShadow[0].blur, lightShadow[0].spread] == [0, 0, 0, 0.5])
        #expect([lightShadow[1].x, lightShadow[1].y, lightShadow[1].blur, lightShadow[1].spread] == [0, 8, 24, 0])
        #expect(abs(lightShadow[0].color.alpha - 0.12) < 0.001 && abs(lightShadow[1].color.alpha - 0.08) < 0.001)
        #expect(abs(lightShadow[1].color.red - 0x1a / 255.0) < 0.001)
    }
    let darkShadow = try dark.boxShadowLayers(":root", "--shadow-soft", viewport: 960)
    #expect(darkShadow.count == 2)
    if darkShadow.count == 2 {
        #expect(abs(darkShadow[0].color.alpha - 0.16) < 0.001)
        #expect(darkShadow[1].color.red == 0 && darkShadow[1].color.green == 0 && darkShadow[1].color.blue == 0)
        #expect(abs(darkShadow[1].color.alpha - 0.45) < 0.001)
    }
    let scrim = try light.radialGradient(".wall::after", viewport: 960)
    #expect([scrim.radiusX, scrim.radiusY, scrim.centreX, scrim.centreY] == [42, 38, 50, 50])
    #expect(scrim.stops.map(\.location) == [0, 0.45, 1])
    #expect(zip(scrim.stops.map(\.color.alpha), [1, 0.8, 0.25]).allSatisfy { abs($0 - $1) < 0.001 })
    let border = try light.border(".drop-outline")
    #expect(border.width == 1.5 && border.style == "dashed")
    #expect(try light.raw(".wall img", "object-fit", viewport: 960) == "cover")
}

@Test func i316PinnedReaderReadsDrift() throws {
    let page = try PinnedDesign.page("first-launch")
    let animation = try page.animation(".wall .tiles")
    #expect(animation.name == "home-wall-drift" && animation.duration == 60, "the reduced-motion rule must not win")
    #expect(try page.reducedMotionAnimation(".wall .tiles") == "none")
    let frames = try page.keyframes("home-wall-drift")
    #expect([frames.from.x, frames.from.y, frames.to.x, frames.to.y] == [0, 0, 0, -362])
    #expect(throws: PinnedDesign.Error.self) { try page.keyframes("no-such-keyframes") }
    #expect(throws: PinnedDesign.Error.self) { try page.animation(".drop-outline") }
    #expect(throws: PinnedDesign.Error.self) { try page.reducedMotionAnimation(".drop-outline") }
}
