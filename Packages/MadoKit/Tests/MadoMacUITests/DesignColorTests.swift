import AppKit
import SwiftUI
import Testing
@testable import MadoMacUI

// This evaluator is deliberately test-only. It reads CSS declarations, not the Swift table.
func cssVariables(_ theme: DesignTheme) throws -> [String: String] {
    var result: [String: String] = [:]
    for name in ["globals", theme == .light ? "light" : "dark"] {
        let css = try String(contentsOf: designRepo.appendingPathComponent("design/picsee-ui-system/tokens/\(name).css"), encoding: .utf8)
        let regex = try NSRegularExpression(pattern: #"(--[\w-]+)\s*:\s*([^;]+);"#)
        let ns = css as NSString
        for match in regex.matches(in: css, range: NSRange(location: 0, length: ns.length)) {
            result[ns.substring(with: match.range(at: 1))] = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    return result
}
func evaluateCSS(_ expression: String, _ vars: [String: String]) -> [Double] {
    let s = expression.trimmingCharacters(in: .whitespacesAndNewlines)
    if s == "transparent" { return [0, 0, 0, 0] }
    if s.hasPrefix("var(") { return evaluateCSS(vars[String(s.dropFirst(4).dropLast())]!, vars) }
    if s.hasPrefix("#") {
        let h = String(s.dropFirst())
        let digits = h.count == 3 ? h.map { "\($0)\($0)" }.joined() : h
        let n = Int(digits, radix: 16)!
        return [Double((n >> 16) & 255) / 255, Double((n >> 8) & 255) / 255, Double(n & 255) / 255, 1]
    }
    if s.hasPrefix("rgba(") {
        let v = s.dropFirst(5).dropLast().split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces))! }
        return [v[0]/255, v[1]/255, v[2]/255, v[3]]
    }
    precondition(s.hasPrefix("color-mix(in srgb,"), "Unsupported CSS \(s)")
    let args = s.dropFirst("color-mix(in srgb,".count).dropLast().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    func stop(_ text: String) -> ([Double], Double?) {
        let p = text.split(separator: " ")
        return (evaluateCSS(String(p[0]), vars), p.count == 2 ? Double(p[1].dropLast())! / 100 : nil)
    }
    let (a, wa) = stop(args[0]), (b, wb) = stop(args[1])
    let x = wa ?? (1 - wb!), y = wb ?? (1 - x)
    let alpha = a[3]*x + b[3]*y
    var rgb: [Double] = []
    for i in 0..<3 {
        let weighted = a[i] * a[3] * x + b[i] * b[3] * y
        rgb.append(alpha == 0 ? 0 : weighted / alpha)
    }
    return rgb + [alpha]
}
func channels(_ c: NSColor) -> [Double] {
    let c = c.usingColorSpace(.sRGB)!
    return [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent]
}
@MainActor @Test(.timeLimit(.minutes(2))) func designColorsFollowCSSAndAppearance() throws {
    let colors = try registry()["colors"] as! [String: [String: Any]]
    #expect(Set(colors.keys) == Set(DesignColor.allCases.map(\.rawValue)))
    #expect(DesignColor.allCases.count == 22) // Includes the page-26 waiting indicator role.
    for theme in DesignTheme.allCases {
        let vars = try cssVariables(theme)
        let appearance = NSAppearance(named: theme == .light ? .aqua : .darkAqua)!
        var env = EnvironmentValues()
        env.colorScheme = theme == .light ? .light : .dark
        for role in DesignColor.allCases {
            let expected = evaluateCSS(vars[colors[role.rawValue]!["cssToken"] as! String]!, vars)
            let expressions = colors[role.rawValue]!["sourceExpressions"] as! [String: String]
            #expect(expressions[theme == .light ? "light" : "dark"] != nil)
            var actual: [Double] = []
            appearance.performAsCurrentDrawingAppearance { actual = channels(role.nsColor) }
            let swift = role.color.resolve(in: env)
            let resolved = [Double(swift.red), Double(swift.green), Double(swift.blue), Double(swift.opacity)]
            for i in 0..<4 {
                #expect(abs(role.components(theme)[i] - expected[i]) <= 1/255, "\(role) \(theme) CSS channel \(i)")
                #expect(abs(actual[i] - expected[i]) <= 1/255, "\(role) AppKit channel \(i)")
                #expect(abs(resolved[i] - actual[i]) <= 1/255, "\(role) SwiftUI channel \(i)")
            }
        }
    }
    let window = NSWindow()
    for mode in DesignAppearance.allCases {
        mode.apply(to: window)
        #expect(window.appearance?.name == (mode == .system ? nil : mode == .light ? .aqua : .darkAqua))
    }
}
