import AppKit
import Testing
@testable import MadoMacUI
@MainActor @Test func designMetricsAndSymbolsMatchSpecification() throws {
    let json = try registry()
    for (section, native) in [("typography", DesignMetrics.typeSizes), ("customRadii", DesignMetrics.radii)] {
        let expected = json[section] as! [String: [String: Any]]
        #expect(Set(native.keys) == Set(expected.keys))
        for (role, spec) in expected {
            #expect(native[role] == spec["referenceSize"] as? Double)
            if section == "typography" {
                #expect(DesignMetrics.font(role).pointSize == CGFloat(spec["referenceSize"] as! Double))
                let mono = DesignMetrics.font(role, monospaced: true)
                #expect(mono.pointSize == CGFloat(spec["referenceSize"] as! Double))
                #expect(mono.isFixedPitch)
            }
        }
    }
    let layout = json["layoutReferences"] as! [String: Any]
    #expect(DesignMetrics.spacing == layout["spacingPt"] as! [Double])
    #expect(DesignMetrics.icons == layout["iconPt"] as! [Double])
    #expect(DesignMetrics.hitArea == layout["iconButtonHitAreaPt"] as! [Double])
    let names = ["sidebar.left", "square.grid.2x2", "ellipsis", "chevron.left", "chevron.right", "magnifyingglass", "arrow.up.arrow.down", "info.circle", "folder", "heart", "heart.fill", "plus", "minus", "film", "xmark", "keyboard"]
    #expect(DesignSymbol.allCases.map(\.name) == names)
    for role in DesignSymbol.allCases {
        #expect(!role.label.isEmpty && role.label != role.name)
        #expect(role.image().size.width > 0)
        #expect(role.image(candidate: "mado.nonexistent.symbol").size == NSImage(systemSymbolName: DesignSymbol.fallback, accessibilityDescription: nil)!.size)
    }
}
