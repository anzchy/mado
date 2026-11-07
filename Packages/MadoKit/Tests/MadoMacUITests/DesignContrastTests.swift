import Foundation
import Testing
@testable import MadoMacUI

func composite(_ fg: [Double], on bg: [Double]) -> [Double] {
    (0..<3).map { fg[$0]*fg[3] + bg[$0]*(1-fg[3]) } + [1]
}
func contrast(_ a: [Double], _ b: [Double]) -> Double {
    func luminance(_ rgb: [Double]) -> Double {
        let v = rgb.prefix(3).map { $0 <= 0.04045 ? $0/12.92 : pow(($0+0.055)/1.055, 2.4) }
        return v[0]*0.2126 + v[1]*0.7152 + v[2]*0.0722
    }
    let x = luminance(a), y = luminance(b)
    return (max(x,y)+0.05)/(min(x,y)+0.05)
}
@Test func designContrastReport() {
    #expect(abs(contrast([0,0,0,1], [1,1,1,1])-21) < 0.00001)
    let pairs: [(String, DesignColor, DesignColor?, Double)] = [
        ("Default text / canvas", .textPrimary, nil, 4.5),
        ("Secondary/status text / canvas", .textSecondary, nil, 4.5),
        ("Folder count / hover", .textSecondary, .hoverBackground, 4.5),
        ("Folder count / selected", .textSecondary, .selectionFill, 4.5),
        ("Icon / canvas", .textPrimary, nil, 3),
        ("Folder/icon text / hover", .textPrimary, .hoverBackground, 4.5),
        ("Icon graphic / hover", .textPrimary, .hoverBackground, 3),
        ("Icon text / pressed,selected", .textPrimary, .selectionFill, 4.5),
        ("Icon graphic / pressed,selected", .textPrimary, .selectionFill, 3),
        ("Folder/filter text / selected", .selectionText, .selectionFill, 4.5),
        ("Filename text / selected", .textPrimary, .selectionFill, 4.5),
        ("Thumbnail graphic / sidebar", .textPrimary, .sidebarBackground, 3),
        ("Selection frame / sidebar", .accent, .sidebarBackground, 3),
        ("Selection frame / canvas", .accent, nil, 3),
        ("Shortcut text / hover", .textPrimary, .hoverBackground, 4.5),
        ("Shortcut boundary / hover", .divider, .hoverBackground, 3),
        ("Focus / canvas", .focusRing, nil, 3),
        ("Focus / hover", .focusRing, .hoverBackground, 3),
        ("Focus / selected", .focusRing, .selectionFill, 3),
        ("Focus / input", .focusRing, .inputBackground, 3),
        ("Error text / canvas", .errorText, nil, 4.5)
    ]
    for theme in DesignTheme.allCases {
        let canvas = DesignColor.canvasBackground.components(theme)
        for (label, foreground, background, target) in pairs {
            let bg = background.map { composite($0.components(theme), on: canvas) } ?? canvas
            let ratio = contrast(composite(foreground.components(theme), on: bg), bg)
            #expect(ratio.isFinite && ratio >= 1)
            print("CONTRAST | \(theme) | \(label) | \(String(format: "%.2f", ratio)) | \(target) | \(ratio >= target ? "PASS" : "MISS") |")
        }
    }
}
