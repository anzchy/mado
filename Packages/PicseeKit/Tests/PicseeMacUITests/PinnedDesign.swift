import Foundation
import CryptoKit

/// Reads values from a SHA-pinned HTML state. Test support only; this is a deliberately small CSS reader.
struct PinnedDesign {
    struct Error: Swift.Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = "Pinned design: \(description)" }
    }
    struct Edges: Equatable { let top: Double; let right: Double; let bottom: Double; let left: Double }
    struct Font: Equatable { let size: Double; let weight: Int; let lineHeight: Double? }
    struct Color: Equatable { let red: Double; let green: Double; let blue: Double; let alpha: Double }
    private struct Rule { let selector: String; let declarations: [String: String]; let declarationOrder: [(String, String)]; let min: Double?; let max: Double?; let unsupported: String? }
    private let name: String
    private let rules: [Rule]
    private let appearance: String
    private let html: String

    static func page(_ name: String, source: String? = nil, appearance: String? = nil) throws -> Self {
        let tests = URL(fileURLWithPath: source ?? #filePath).deletingLastPathComponent()
        let root = tests.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let directory = root.appendingPathComponent("design/prototypes/picsee-browser/states")
        let manifestData = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        let catalog = try JSONDecoder().decode(Catalog.self, from: manifestData)
        guard let entry = catalog.states.first(where: { $0.name == name }),
              !entry.file.contains("/"), !entry.file.contains("..") else {
            throw Error("unknown page '\(name)' in manifest.json")
        }
        let data = try Data(contentsOf: directory.appendingPathComponent(entry.file))
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == entry.sha256 else {
            throw Error("\(entry.file) SHA256 mismatch: manifest expected \(entry.sha256), actual \(actual). Re-pin the design deliberately.")
        }
        guard let html = String(data: data, encoding: .utf8) else { throw Error("\(entry.file) is not UTF-8") }
        var styles = matches("(?s)<style\\b[^>]*>(.*?)</style>", in: html).compactMap { $0.first }
        guard !styles.isEmpty else { throw Error("\(entry.file) has no inline CSS") }
        if name == "b4-first-launch" {
            let tokenDirectory = directory.appendingPathComponent("_ds/picsee-ui-system/tokens")
            for (file, expected) in [
                ("light.css", "20bf9c01c80c1a863b94097778990431a958bc9dbf517aa82fb3f54d67a867d7"),
                ("dark.css", "71f5ceec615b7f9cad6684d086d01aaa62e9ab49faa7efe5021bea2a2a5d3b58")
            ] {
                let bytes = try Data(contentsOf: tokenDirectory.appendingPathComponent(file))
                let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                guard digest == expected, let css = String(data: bytes, encoding: .utf8) else {
                    throw Error("\(file) differs from the whitespace-normalized 9234b14 token stylesheet")
                }
                styles.insert(css, at: 0)
            }
        }
        var rules: [Rule] = []
        for style in styles {
            do {
                try parse(style, min: nil, max: nil, unsupported: nil, into: &rules)
            } catch let error as Error {
                throw Error("\(name) CSS load: \(error.description)")
            }
        }
        let resolvedAppearance = appearance ?? (html.contains("class=\"theme-dark\"") ? "dark" : "light")
        return Self(name: name, rules: rules, appearance: resolvedAppearance, html: html)
    }

    func declaration(_ selector: String, _ property: String, viewport: Double) throws -> String {
        guard let value = try matchingRules(selector, property, viewport: viewport)
            .last(where: { $0.declarations[property] != nil })?.declarations[property] else {
            throw Error("\(name) selector '\(selector)' property '\(property)' at \(viewport)pt: no declaration")
        }
        return value
    }

    func exactDeclaration(_ selector: String, _ property: String) throws -> String {
        guard let value = rules.last(where: { $0.selector == selector && $0.declarations[property] != nil })?
            .declarations[property] else {
            throw Error("\(name) selector '\(selector)' property '\(property)': no exact declaration")
        }
        return value
    }

    func raw(_ selector: String, _ property: String, viewport: Double) throws -> String {
        let candidates = try matchingRules(selector, property, viewport: viewport)
        let themeValue = selector == ":root" && property.hasPrefix("--")
            ? try matchingRules(appearance == "dark" ? ".theme-dark" : ".theme-light", property, viewport: viewport)
                .last(where: { $0.declarations[property] != nil })?.declarations[property]
            : nil
        guard let value = themeValue ?? candidates.last(where: { $0.declarations[property] != nil })?.declarations[property] else {
            throw Error("\(name) selector '\(selector)' property '\(property)' at \(viewport)pt: no matching declaration")
        }
        return try resolveVars(value, viewport: viewport, context: "\(selector) \(property)", tokenSelector: selector)
    }

    func length(_ selector: String, _ property: String, viewport: Double, percentageBase: Double? = nil) throws -> Double {
        let value = try raw(selector, property, viewport: viewport)
        if property == "line-height", Double(value) != nil {
            return try lineHeight(selector, viewport: viewport)
        }
        guard let result = evaluate(value, viewport: viewport, percentageBase: percentageBase) else {
            throw Error("\(name) \(selector) \(property) at \(viewport)pt: expected length, got '\(value)'")
        }
        return result
    }

    func lineHeight(_ selector: String, viewport: Double) throws -> Double {
        let size = try length(selector, "font-size", viewport: viewport)
        let value = try raw(selector, "line-height", viewport: viewport)
        guard let number = evaluate(value, viewport: viewport) else {
            throw Error("\(name) \(selector) line-height at \(viewport)pt: unresolved '\(value)'")
        }
        return value.hasSuffix("px") ? number : size * number
    }

    func lengthValue(_ expression: String, viewport: Double, percentageBase: Double? = nil) throws -> Double {
        // A bare token reference such as `var(--radius-control)` resolves against :root first.
        let expression = expression.contains("var(")
            ? try resolveVars(expression, viewport: viewport, context: "length expression", tokenSelector: ":root") : expression
        guard let number = evaluate(expression, viewport: viewport, percentageBase: percentageBase) else {
            throw Error("\(name) length expression at \(viewport)pt: expected a resolvable length, got '\(expression)'")
        }
        return number
    }

    func edges(_ selector: String, _ property: String, viewport: Double) throws -> Edges {
        let candidates = try matchingRules(selector, property, viewport: viewport, sideProperties: true)
        var sides: [String?] = [nil, nil, nil, nil]
        for rule in candidates {
            for (key, value) in rule.declarationOrder {
                if key == property {
                    let parts = Self.splitWhitespace(value)
                    guard (1...4).contains(parts.count) else {
                        throw Error("\(name) \(selector) \(property) at \(viewport)pt: expected 1–4 sides, got '\(value)'")
                    }
                    sides = [parts[0], parts.count > 1 ? parts[1] : parts[0],
                             parts.count > 2 ? parts[2] : parts[0],
                             parts.count > 3 ? parts[3] : parts.count > 1 ? parts[1] : parts[0]]
                }
                for (index, side) in ["top", "right", "bottom", "left"].enumerated()
                    where key == "\(property)-\(side)" {
                    sides[index] = value
                }
            }
        }
        guard sides.allSatisfy({ $0 != nil }) else {
            throw Error("\(name) \(selector) \(property) at \(viewport)pt: no complete side declaration")
        }
        let parts = try sides.map { try resolveVars($0!, viewport: viewport, context: "\(selector) \(property)", tokenSelector: selector) }
        let value = parts.joined(separator: " ")
        let numbers = try parts.map { part -> Double in
            guard let number = evaluate(part, viewport: viewport) else {
                throw Error("\(name) \(selector) \(property) at \(viewport)pt: unresolved side '\(part)' in '\(value)'")
            }
            return number
        }
        return Edges(top: numbers[0], right: numbers[1], bottom: numbers[2], left: numbers[3])
    }

    func font(_ selector: String, viewport: Double) throws -> Font {
        let size = try length(selector, "font-size", viewport: viewport)
        let weightText = try raw(selector, "font-weight", viewport: viewport)
        guard let weight = Int(weightText) else {
            throw Error("\(name) \(selector) font-weight at \(viewport)pt: expected numeric weight, got '\(weightText)'")
        }
        let lineHeight: Double?
        do {
            let rawLine = try raw(selector, "line-height", viewport: viewport)
            if let points = evaluate(rawLine, viewport: viewport) {
                lineHeight = rawLine.hasSuffix("px") ? points : points * size
            } else {
                throw Error("\(name) \(selector) line-height at \(viewport)pt: unresolved '\(rawLine)'")
            }
        } catch let error as Error where error.description.contains("no matching declaration") {
            lineHeight = nil
        }
        return Font(size: size, weight: weight, lineHeight: lineHeight)
    }

    func color(_ selector: String, _ property: String, viewport: Double) throws -> Color {
        let value = try raw(selector, property, viewport: viewport)
        let colorText = property.hasPrefix("border") ? String(value.components(separatedBy: " solid ").last ?? value) : value
        guard let parsed = parseColor(colorText) else {
            throw Error("\(name) \(selector) \(property) at \(viewport)pt: expected sRGB color, got '\(value)'")
        }
        return parsed
    }

    func assertLength(_ actual: Double, _ selector: String, _ property: String, viewport: Double,
                      tolerance: Double = 0.01) throws {
        let expected = try length(selector, property, viewport: viewport)
        guard abs(actual - expected) <= tolerance else {
            throw Error("\(name) \(selector) \(property) at \(viewport)pt: expected \(expected)pt from CSS, actual \(actual)pt (tolerance \(tolerance)pt)")
        }
    }

    func assertEdges(_ actual: Edges, _ selector: String, _ property: String, viewport: Double,
                     tolerance: Double = 0.01) throws {
        let expected = try edges(selector, property, viewport: viewport)
        let differences = [abs(actual.top - expected.top), abs(actual.right - expected.right),
                           abs(actual.bottom - expected.bottom), abs(actual.left - expected.left)]
        guard differences.allSatisfy({ $0 <= tolerance }) else {
            throw Error("\(name) \(selector) \(property) at \(viewport)pt: expected \(expected)pt from CSS, actual \(actual)pt")
        }
    }

    func assertFont(_ actual: Font, _ selector: String, viewport: Double, tolerance: Double = 0.01) throws {
        let expected = try font(selector, viewport: viewport)
        guard abs(actual.size - expected.size) <= tolerance, actual.weight == expected.weight,
              (actual.lineHeight == nil && expected.lineHeight == nil ||
               actual.lineHeight != nil && expected.lineHeight != nil &&
               abs(actual.lineHeight! - expected.lineHeight!) <= tolerance) else {
            throw Error("\(name) \(selector) font at \(viewport)pt: expected \(expected) from CSS, actual \(actual)")
        }
    }

    func assertColor(_ actual: Color, _ selector: String, _ property: String, viewport: Double,
                     tolerance: Double = 1.0 / 255) throws {
        let expected = try color(selector, property, viewport: viewport)
        let differences = [abs(actual.red - expected.red), abs(actual.green - expected.green),
                           abs(actual.blue - expected.blue), abs(actual.alpha - expected.alpha)]
        guard differences.allSatisfy({ $0 <= tolerance }) else {
            throw Error("\(name) \(selector) \(property) at \(viewport)pt: expected \(expected) sRGB from CSS, actual \(actual) sRGB")
        }
    }

    private func resolveVars(_ text: String, viewport: Double, context: String, tokenSelector: String, depth: Int = 0) throws -> String {
        guard depth < 20 else { throw Error("\(name) \(context) at \(viewport)pt: cyclic var() in '\(text)'") }
        var result = text
        while let range = result.range(of: "var(") {
            guard let close = result[range.upperBound...].firstIndex(of: ")") else {
                throw Error("\(name) \(context) at \(viewport)pt: unterminated var() in '\(text)'")
            }
            let token = String(result[range.upperBound..<close])
            let selectors = tokenSelector == ":root"
                ? [appearance == "dark" ? ".theme-dark" : ".theme-light", ":root"]
                : [tokenSelector, appearance == "dark" ? ".theme-dark" : ".theme-light", ":root"]
            var found: String?
            for selector in selectors {
                found = try rawToken(selector, token, viewport: viewport)
                if found != nil { break }
            }
            guard let found else { throw Error("\(name) \(context) at \(viewport)pt: missing token \(token) in '\(text)'") }
            result.replaceSubrange(range.lowerBound...close, with: try resolveVars(found, viewport: viewport, context: context, tokenSelector: tokenSelector, depth: depth + 1))
        }
        return result
    }

    private func rawToken(_ selector: String, _ token: String, viewport: Double) throws -> String? {
        try matchingRules(selector, token, viewport: viewport)
            .last(where: { $0.declarations[token] != nil })?.declarations[token]
    }

    /// Exact-selector queries fail when a contextual rule could override the same property.
    /// This reader does not infer the pinned DOM's full selector matching or specificity.
    private func matchingRules(_ selector: String, _ property: String, viewport: Double,
                               sideProperties: Bool = false) throws -> [Rule] {
        let properties = [property] + (sideProperties ? ["top", "right", "bottom", "left"].map { "\(property)-\($0)" } : [])
        let active = rules.filter { ($0.min == nil || viewport >= $0.min!) && ($0.max == nil || viewport <= $0.max!) }
        for rule in active.reversed() where properties.contains(where: { rule.declarations[$0] != nil }) {
            let contextual = rule.selector != selector && [" ", ">", "+", "~"].contains {
                rule.selector.hasSuffix($0 + selector)
            }
            let qualifier = Self.sameElementQualifier(in: rule.selector, after: selector)
            let ambiguous = contextual || qualifier != nil
            if let unsupported = rule.unsupported, rule.selector == selector || ambiguous {
                throw Error("\(name) selector '\(selector)' property '\(property)' at \(viewport)pt: unsupported \(unsupported)")
            }
            if ambiguous {
                throw Error("\(name) selector '\(selector)' property '\(property)' at \(viewport)pt: ambiguous contextual rule '\(rule.selector)'")
            }
        }
        return active.filter { $0.selector == selector && $0.unsupported == nil }
    }

    private static func sameElementQualifier(in ruleSelector: String, after selector: String) -> String? {
        let chars = Array(ruleSelector)
        let query = Array(selector)
        guard !query.isEmpty, query.count <= chars.count else { return nil }
        var compoundStart = 0
        var depth = 0
        for (index, char) in chars.enumerated() {
            if char == "(" || char == "[" { depth += 1 }
            if char == ")" || char == "]" { depth -= 1 }
            if depth == 0 && (char.isWhitespace || ">+~,".contains(char)) { compoundStart = index + 1 }
        }
        depth = 0
        for index in compoundStart..<chars.count {
            let char = chars[index]
            if depth == 0, index + query.count <= chars.count,
               Array(chars[index..<(index + query.count)]) == query {
                let end = index + query.count
                guard end == chars.count || ".#[:".contains(chars[end]) else { continue }
                let qualifier = String(chars[compoundStart..<index] + chars[end...])
                if qualifier.isEmpty { return nil }
                if qualifier.range(of: "^:(hover|focus[\\w-]*|active|disabled)$", options: .regularExpression) != nil {
                    return nil
                }
                return qualifier
            }
            if char == "(" || char == "[" { depth += 1 }
            if char == ")" || char == "]" { depth -= 1 }
        }
        return nil
    }

    private struct Catalog: Decodable {
        let states: [Entry]
        struct Entry: Decodable { let name: String; let file: String; let sha256: String }
    }

    private static func parse(_ css: String, min: Double?, max: Double?, unsupported: String?, into rules: inout [Rule]) throws {
        let clean = css.replacingOccurrences(of: "(?s)/\\*.*?\\*/", with: "", options: .regularExpression)
        let chars = Array(clean)
        var i = 0
        while i < chars.count {
            while i < chars.count && chars[i].isWhitespace { i += 1 }
            guard i < chars.count else { break }
            if chars[i] == "}" { throw Error("stray closing brace") }
            let start = i
            while i < chars.count && chars[i] != "{" { i += 1 }
            guard i < chars.count else {
                let tail = String(chars[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if tail.hasPrefix("@"), tail.contains(";") { throw Error("blockless at-statement '\(tail)'") }
                throw Error("trailing CSS text '\(tail)'")
            }
            let header = String(chars[start..<i]).trimmingCharacters(in: .whitespacesAndNewlines)
            if header.hasPrefix("@"), header.contains(";") {
                throw Error("blockless at-statement in '\(header)'")
            }
            i += 1
            let bodyStart = i
            var depth = 1
            while i < chars.count && depth > 0 {
                if chars[i] == "{" { depth += 1 }
                if chars[i] == "}" { depth -= 1 }
                i += 1
            }
            guard depth == 0 else { throw Error("unbalanced CSS block after '\(header)'") }
            let body = String(chars[bodyStart..<(i - 1)])
            if header.hasPrefix("@media") {
                let maxWidth = matches("max-width\\s*:\\s*([0-9.]+)px", in: header).first?.first.flatMap(Double.init)
                let minWidth = matches("min-width\\s*:\\s*([0-9.]+)px", in: header).first?.first.flatMap(Double.init)
                let widthOnly = header.range(of: "^@media\\s*(\\(\\s*(min|max)-width\\s*:\\s*[0-9.]+px\\s*\\)\\s*(and\\s*)?)+$", options: .regularExpression) != nil
                try parse(body, min: widthOnly ? minWidth ?? min : min, max: widthOnly ? maxWidth ?? max : max,
                          unsupported: widthOnly ? unsupported : header, into: &rules)
            } else if header.hasPrefix("@") && !header.hasPrefix("@keyframes") && !header.hasPrefix("@font-face") {
                try parse(body, min: min, max: max, unsupported: header, into: &rules)
            } else if !header.hasPrefix("@") {
                var declarations: [String: String] = [:]
                var declarationOrder: [(String, String)] = []
                for declaration in split(body, separator: ";") {
                    guard let colon = declaration.firstIndex(of: ":") else { continue }
                    let key = declaration[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
                    let value = declaration[declaration.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
                    declarations[key] = value
                    declarationOrder.append((key, value))
                }
                for selector in split(header, separator: ",") {
                    rules.append(Rule(selector: selector.trimmingCharacters(in: .whitespacesAndNewlines),
                                      declarations: declarations, declarationOrder: declarationOrder, min: min, max: max,
                                      unsupported: unsupported))
                }
            }
        }
    }

    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            (1..<match.numberOfRanges).compactMap { index in
                let range = match.range(at: index)
                return range.location == NSNotFound ? nil : ns.substring(with: range)
            }
        }
    }

    private static func split(_ input: String, separator: Character) -> [String] {
        var result: [String] = []; var depth = 0; var start = input.startIndex
        for index in input.indices {
            if input[index] == "(" { depth += 1 }
            if input[index] == ")" { depth -= 1 }
            if input[index] == separator && depth == 0 {
                result.append(String(input[start..<index]))
                start = input.index(after: index)
            }
        }
        result.append(String(input[start...]))
        return result
    }

    private static func splitWhitespace(_ input: String) -> [String] {
        var result: [String] = []; var depth = 0; var current = ""
        for char in input {
            if char == "(" { depth += 1 }
            if char == ")" { depth -= 1 }
            if char.isWhitespace && depth == 0 {
                if !current.isEmpty { result.append(current); current = "" }
            } else { current.append(char) }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private func evaluate(_ expression: String, viewport: Double, percentageBase: Double? = nil) -> Double? {
        let value = expression.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("clamp("), value.hasSuffix(")") {
            let parts = Self.split(String(value.dropFirst(6).dropLast()), separator: ",")
            guard parts.count == 3, let low = evaluate(parts[0], viewport: viewport, percentageBase: percentageBase),
                  let preferred = evaluate(parts[1], viewport: viewport, percentageBase: percentageBase), let high = evaluate(parts[2], viewport: viewport, percentageBase: percentageBase) else { return nil }
            return Swift.min(Swift.max(preferred, low), high)
        }
        if (value.hasPrefix("min(") || value.hasPrefix("max(")), value.hasSuffix(")") {
            let numbers = Self.split(String(value.dropFirst(4).dropLast()), separator: ",").map {
                evaluate($0, viewport: viewport, percentageBase: percentageBase)
            }
            guard numbers.count >= 2, numbers.allSatisfy({ $0 != nil }) else { return nil }
            return value.hasPrefix("min(") ? numbers.compactMap { $0 }.min() : numbers.compactMap { $0 }.max()
        }
        if value.hasPrefix("calc("), value.hasSuffix(")") {
            let body = String(value.dropFirst(5).dropLast())
            for op in [" + ", " - "] {
                if let range = body.range(of: op), let left = evaluate(String(body[..<range.lowerBound]), viewport: viewport, percentageBase: percentageBase),
                   let right = evaluate(String(body[range.upperBound...]), viewport: viewport, percentageBase: percentageBase) {
                    return op == " + " ? left + right : left - right
                }
            }
            return evaluate(body, viewport: viewport, percentageBase: percentageBase)
        }
        if value.hasSuffix("%"), let base = percentageBase, let n = Double(value.dropLast()) { return n * base / 100 }
        if value.hasSuffix("vw"), let n = Double(value.dropLast(2)) { return n * viewport / 100 }
        if value.hasSuffix("px"), let n = Double(value.dropLast(2)) { return n }
        return Double(value)
    }

    private func parseColor(_ text: String) -> Color? {
        let value = text.trimmingCharacters(in: .whitespaces)
        if value == "transparent" { return Color(red: 0, green: 0, blue: 0, alpha: 0) }
        if value == "black" { return Color(red: 0, green: 0, blue: 0, alpha: 1) }
        if value == "white" { return Color(red: 1, green: 1, blue: 1, alpha: 1) }
        if value.hasPrefix("#") {
            let hex = String(value.dropFirst())
            let expanded = hex.count == 3 ? hex.map { "\($0)\($0)" }.joined() : hex
            guard expanded.count == 6, let number = Int(expanded, radix: 16) else { return nil }
            return Color(red: Double((number >> 16) & 255) / 255,
                         green: Double((number >> 8) & 255) / 255,
                         blue: Double(number & 255) / 255, alpha: 1)
        }
        if value.hasPrefix("rgba("), value.hasSuffix(")") {
            let parts = Self.split(String(value.dropFirst(5).dropLast()), separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 4 else { return nil }
            return Color(red: parts[0] / 255, green: parts[1] / 255, blue: parts[2] / 255, alpha: parts[3])
        }
        if value.hasPrefix("color-mix(in srgb,"), value.hasSuffix(")") {
            let body = String(value.dropFirst("color-mix(in srgb,".count).dropLast())
            let parts = Self.split(body, separator: ",")
            guard parts.count == 2 else { return nil }
            func component(_ string: String) -> (Color, Double?)? {
                let bits = Self.splitWhitespace(string.trimmingCharacters(in: .whitespaces))
                guard bits.count >= 1 else { return nil }
                let percent = bits.last?.hasSuffix("%") == true ? Double(bits.last!.dropLast()).map { $0 / 100 } : nil
                let colorString = percent == nil ? string.trimmingCharacters(in: .whitespaces) : bits.dropLast().joined(separator: " ")
                guard let color = parseColor(colorString) else { return nil }
                return (color, percent)
            }
            guard let (a, firstWeight) = component(parts[0]), let (b, secondWeight) = component(parts[1]) else { return nil }
            guard [firstWeight, secondWeight].allSatisfy({ $0 == nil || (0...1).contains($0!) }) else { return nil }
            var wa = firstWeight ?? (secondWeight == nil ? 0.5 : 1 - secondWeight!)
            var wb = secondWeight ?? (firstWeight == nil ? 0.5 : 1 - firstWeight!)
            let total = wa + wb
            guard total > 0 else { return nil }
            let alphaMultiplier = Swift.min(total, 1.0)
            wa /= total; wb /= total
            let alpha = (a.alpha * wa + b.alpha * wb) * alphaMultiplier
            guard alpha > 0 else { return Color(red: 0, green: 0, blue: 0, alpha: 0) }
            let mixedAlpha = a.alpha * wa + b.alpha * wb
            return Color(red: (a.red * a.alpha * wa + b.red * b.alpha * wb) / mixedAlpha,
                         green: (a.green * a.alpha * wa + b.green * b.alpha * wb) / mixedAlpha,
                         blue: (a.blue * a.alpha * wa + b.blue * b.alpha * wb) / mixedAlpha, alpha: alpha)
        }
        return nil
    }
}

extension PinnedDesign {
    /// `:root` token outside every unsupported-media rule, or only inside the rule whose header contains `media`.
    func rootToken(_ token: String, media: String? = nil) throws -> String {
        let rule = rules.last { rule in
            guard rule.selector == ":root", rule.declarations[token] != nil else { return false }
            guard let media else { return rule.unsupported == nil }
            return rule.unsupported?.replacingOccurrences(of: " ", with: "").contains(media) == true
        }
        guard let value = rule?.declarations[token] else {
            throw Error("\(name) :root \(token) media \(media ?? "none"): no declaration")
        }
        return try resolveVars(value, viewport: 960, context: ":root \(token)", tokenSelector: ":root")
    }

    static func seconds(_ value: String) throws -> Double {
        let text = value.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix("ms"), let n = Double(text.dropLast(2)) { return n / 1000 }
        if text.hasSuffix("s"), let n = Double(text.dropLast()) { return n }
        throw Error("expected a CSS time, got '\(value)'")
    }

    func boxShadowLayers(_ selector: String, _ property: String = "box-shadow", viewport: Double) throws
        -> [(x: Double, y: Double, blur: Double, spread: Double, color: Color)] {
        let value = try raw(selector, property, viewport: viewport)
        return try Self.split(value, separator: ",").map { layer in
            let parts = Self.splitWhitespace(layer.trimmingCharacters(in: .whitespaces))
            let lengths = parts.prefix { evaluate($0, viewport: viewport) != nil }.compactMap { evaluate($0, viewport: viewport) }
            guard (2...4).contains(lengths.count),
                  let color = parseColor(parts.dropFirst(lengths.count).joined(separator: " ")) else {
                throw Error("\(name) \(selector) \(property): unparsed shadow layer '\(layer)'")
            }
            return (lengths[0], lengths[1], lengths.count > 2 ? lengths[2] : 0, lengths.count > 3 ? lengths[3] : 0, color)
        }
    }

    func radialGradient(_ selector: String, viewport: Double) throws
        -> (radiusX: Double, radiusY: Double, centreX: Double, centreY: Double, stops: [(color: Color, location: Double)]) {
        let value = try raw(selector, "background", viewport: viewport)
        guard value.hasPrefix("radial-gradient("), value.hasSuffix(")") else {
            throw Error("\(name) \(selector) background is not a radial gradient: \(value)")
        }
        let parts = Self.split(String(value.dropFirst("radial-gradient(".count).dropLast()), separator: ",")
        guard let shape = Self.matches(#"^\s*ellipse ([\d.]+)% ([\d.]+)% at ([\d.]+)% ([\d.]+)%\s*$"#, in: parts[0]).first,
              shape.count == 4, let rx = Double(shape[0]), let ry = Double(shape[1]),
              let cx = Double(shape[2]), let cy = Double(shape[3]) else {
            throw Error("\(name) \(selector) radial gradient shape unparsed: \(parts[0])")
        }
        let stops = try parts.dropFirst().map { stop -> (color: Color, location: Double) in
            let bits = Self.splitWhitespace(stop.trimmingCharacters(in: .whitespaces))
            guard let last = bits.last, last.hasSuffix("%"), let percent = Double(last.dropLast()),
                  let color = parseColor(bits.dropLast().joined(separator: " ")) else {
                throw Error("\(name) \(selector) radial gradient stop unparsed: \(stop)")
            }
            return (color, percent / 100)
        }
        return (rx, ry, cx, cy, stops)
    }

    private func transformNumber(_ selector: String, _ pattern: String) throws -> Double {
        let value = try exactDeclaration(selector, "transform")
        guard let text = Self.matches(pattern, in: value).first?.first, let number = Double(text) else {
            throw Error("\(name) \(selector) transform '\(value)' does not match \(pattern)")
        }
        return number
    }

    func rotationDegrees(_ selector: String) throws -> Double { try transformNumber(selector, #"rotate\((-?[\d.]+)deg\)"#) }
    func translateY(_ selector: String) throws -> Double { try transformNumber(selector, #"translateY\((-?[\d.]+)px\)"#) }

    func gridColumns(_ selector: String) throws -> Int {
        let value = try exactDeclaration(selector, "grid-template-columns")
        guard let text = Self.matches(#"^repeat\((\d+),\s*1fr\)$"#, in: value).first?.first, let count = Int(text) else {
            throw Error("\(name) \(selector) grid-template-columns '\(value)' is not repeat(n,1fr)")
        }
        return count
    }

    func border(_ selector: String) throws -> (width: Double, style: String) {
        let value = try exactDeclaration(selector, "border")
        let parts = Self.splitWhitespace(value)
        guard parts.count >= 2, let width = evaluate(parts[0], viewport: 960) else {
            throw Error("\(name) \(selector) border '\(value)' unparsed")
        }
        return (width, parts[1])
    }

    func childCount(tag: String, inClass: String) throws -> Int {
        let blocks = Self.matches("(?s)<div class=\"\(inClass)\"[^>]*>(.*?)</div>", in: html)
        guard blocks.count == 1, let body = blocks.first?.first else {
            throw Error("\(name) expected one <div class=\"\(inClass)\">, found \(blocks.count)")
        }
        return body.components(separatedBy: "<\(tag)").count - 1
    }

    /// The `animation` shorthand outside every media rule, as `name duration timing iterations direction`.
    func animation(_ selector: String) throws
        -> (name: String, duration: Double, timing: String, iterations: String, direction: String) {
        guard let value = rules.last(where: { $0.selector == selector && $0.unsupported == nil })?
            .declarations["animation"] else {
            throw Error("\(name) \(selector) animation: no declaration outside media rules")
        }
        let parts = Self.splitWhitespace(value)
        guard parts.count == 5, let duration = try? Self.seconds(parts[1]) else {
            throw Error("\(name) \(selector) animation '\(value)' is not 'name duration timing iterations direction'")
        }
        return (parts[0], duration, parts[2], parts[3], parts[4])
    }

    /// The `animation` declared for `selector` inside `@media (prefers-reduced-motion:reduce)`.
    func reducedMotionAnimation(_ selector: String) throws -> String {
        guard let value = rules.last(where: {
            $0.selector == selector
                && $0.unsupported?.replacingOccurrences(of: " ", with: "").contains("prefers-reduced-motion:reduce") == true
        })?.declarations["animation"] else {
            throw Error("\(name) \(selector) animation: no prefers-reduced-motion rule")
        }
        return value
    }

    /// `@keyframes name { from { translate: x y } to { translate: x y } }`. The CSS parser skips keyframes; read the HTML.
    func keyframes(_ keyframesName: String) throws -> (from: (x: Double, y: Double), to: (x: Double, y: Double)) {
        let number = #"(-?[\d.]+)(?:px)?"#
        let pattern = #"@keyframes\s+"# + NSRegularExpression.escapedPattern(for: keyframesName)
            + #"\s*\{\s*from\s*\{\s*translate:\s*"# + number + #"\s+"# + number
            + #"\s*;?\s*\}\s*to\s*\{\s*translate:\s*"# + number + #"\s+"# + number + #"\s*;?\s*\}\s*\}"#
        let found = Self.matches(pattern, in: html)
        let values = found.first?.compactMap(Double.init) ?? []
        guard found.count == 1, values.count == 4 else {
            throw Error("\(name) @keyframes \(keyframesName): expected one from/to translate block, found \(found.count)")
        }
        return ((values[0], values[1]), (values[2], values[3]))
    }
}
