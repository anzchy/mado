import Foundation

enum TimeLimitDeclaration: Equatable {
    case minutes(Int)
    case unrecognised

    var violatesPolicy: Bool {
        switch self {
        case .minutes(let value): value < 2
        case .unrecognised: true
        }
    }
}

/// Pure string seam for the repository's CI time-limit policy.
/// Only literal integer minutes are supported; other forms fail closed.
func scanTimeLimits(in source: String) -> [TimeLimitDeclaration] {
    let scan = timeLimitCodeTokens(source)
    let tokens = scan.tokens
    var declarations: [TimeLimitDeclaration] = []
    var propertyReadCount = 0
    for index in tokens.indices where tokens[index] == "." {
        guard index + 1 < tokens.count, tokens[index + 1] == "timeLimit" else { continue }
        guard index + 2 < tokens.count, tokens[index + 2] == "(" else {
            propertyReadCount += 1
            continue
        }
        let arguments = Array(tokens.dropFirst(index + 2).prefix(7))
        if arguments.count == 7,
           arguments[0...3] == ["(", ".", "minutes", "("],
           arguments[5...6] == [")", ")"],
           !arguments[4].isEmpty,
           arguments[4].allSatisfy({ $0.isASCII && $0.isNumber }),
           let minutes = Int(arguments[4]) {
            declarations.append(.minutes(minutes))
        } else {
            declarations.append(.unrecognised)
        }
    }
    // Count independently of tokenisation, including backticked/nonmember names.
    // Account for member reads as well as positively delimited comments and strings.
    let rawCount = timeLimitIdentifierCount(source)
    if rawCount != declarations.count + propertyReadCount + scan.ignoredCount || scan.lexicalFailure {
        declarations.append(.unrecognised)
    }
    return declarations
}

/// #673: only this exact injected-clock suite declaration may carry a one-minute limit.
/// Replace that declaration for the ordinary scanner; all remaining declarations keep the same rule.
func packageTimeLimitViolations(in source: String, fileName: String) -> [TimeLimitDeclaration] {
    guard fileName == "PrefetchResumptionTests.swift" else {
        return scanTimeLimits(in: source).filter(\.violatesPolicy)
    }
    let namedSuite = "@Suite(.timeLimit(.minutes(1))) struct PrefetchResumptionTests {"
    guard source.components(separatedBy: namedSuite).count == 2 else {
        return scanTimeLimits(in: source).filter(\.violatesPolicy)
    }
    let declarations = scanTimeLimits(in: source)
    guard declarations.filter({ $0 == .minutes(1) }).count == 1 else {
        return declarations.filter(\.violatesPolicy)
    }
    let ordinarySuite = "@Suite(.timeLimit(.minutes(2))) struct PrefetchResumptionTests {"
    let checkedSource = source.replacingOccurrences(of: namedSuite, with: ordinarySuite)
    return scanTimeLimits(in: checkedSource).filter(\.violatesPolicy)
}

private func timeLimitIdentifierCount(_ source: String) -> Int {
    let pattern = #"(?<![\p{L}\p{N}_])timeLimit(?![\p{L}\p{N}_])"#
    let expression = try! NSRegularExpression(pattern: pattern)
    return expression.numberOfMatches(in: source, range: NSRange(location: 0, length: source.utf16.count))
}

/// A small lexer rather than a Swift parser: comments are trivia, strings are an
/// opaque token, and every other identifier/punctuation remains available to the policy.
private func timeLimitCodeTokens(_ source: String) -> (tokens: [String], ignoredCount: Int, lexicalFailure: Bool) {
    let characters = Array(source)
    var index = 0
    var tokens: [String] = []
    var ignoredCount = 0
    var lexicalFailure = false

    func matches(_ text: String, at start: Int) -> Bool {
        let candidate = Array(text)
        return start + candidate.count <= characters.count
            && characters[start..<(start + candidate.count)].elementsEqual(candidate)
    }

    while index < characters.count {
        let start = index
        if characters[index].isWhitespace {
            index += 1
        } else if matches("//", at: index) {
            while index < characters.count && !characters[index].isNewline {
                index += 1
            }
            ignoredCount += timeLimitIdentifierCount(String(characters[start..<index]))
        } else if matches("/*", at: index) {
            index += 2
            var depth = 1
            while index < characters.count && depth > 0 {
                if matches("/*", at: index) {
                    depth += 1
                    index += 2
                } else if matches("*/", at: index) {
                    depth -= 1
                    index += 2
                } else {
                    index += 1
                }
            }
            lexicalFailure = lexicalFailure || depth != 0
            ignoredCount += timeLimitIdentifierCount(String(characters[start..<index]))
        } else {
            // Extended regex is outside this bounded lexer: reject its opener
            // before a quote in its body can be mistaken for a string.
            var slash = index
            while slash < characters.count && characters[slash] == "#" { slash += 1 }
            if slash > index && slash < characters.count && characters[slash] == "/" {
                lexicalFailure = true
            }
            let previous = tokens.last
            let startsAfterSpace = index > 0 && characters[index - 1].isWhitespace
                && index + 1 < characters.count && !characters[index + 1].isWhitespace
            let expressionStart = previous == nil || (startsAfterSpace && !matches("/=", at: index))
                || previous.map { ["=", "(", "[", ",", ":", "return", "{"].contains($0) } == true
            if characters[index] == "/" && expressionStart {
                // Bare regex literals cannot cross a newline. Respect escaped
                // slashes and character classes so quotes stay regex content.
                index += 1
                var closed = false
                var inClass = false
                while index < characters.count && !characters[index].isNewline {
                    let character = characters[index]
                    if character == "\\" {
                        index = min(characters.count, index + 2)
                        continue
                    }
                    if character == "[" { inClass = true }
                    if character == "]" { inClass = false }
                    index += 1
                    if character == "/" && !inClass {
                        closed = true
                        break
                    }
                }
                lexicalFailure = lexicalFailure || !closed
                ignoredCount += timeLimitIdentifierCount(String(characters[start..<index]))
                tokens.append("<regex>")
                continue
            }
            var quote = index
            while quote < characters.count && characters[quote] == "#" { quote += 1 }
            if quote < characters.count && characters[quote] == "\"" {
                let hashes = String(repeating: "#", count: quote - index)
                let delimiter = matches("\"\"\"", at: quote) ? "\"\"\"" : "\""
                let end = delimiter + hashes
                let escape = "\\" + hashes
                index = quote + delimiter.count
                var closed = false
                while index < characters.count {
                    if delimiter == "\"" && characters[index].isNewline { break }
                    if matches(end, at: index) {
                        index += end.count
                        closed = true
                        break
                    } else if matches(escape, at: index) {
                        // Skip the escaped character, including an escaped quote.
                        index = min(characters.count, index + escape.count + 1)
                    } else {
                        index += 1
                    }
                }
                lexicalFailure = lexicalFailure || !closed
                ignoredCount += timeLimitIdentifierCount(String(characters[start..<index]))
                tokens.append("<string>")
            } else if characters[index].isLetter || characters[index].isNumber || characters[index] == "_" {
                let start = index
                repeat { index += 1 } while index < characters.count
                    && (characters[index].isLetter || characters[index].isNumber || characters[index] == "_")
                tokens.append(String(characters[start..<index]))
            } else {
                tokens.append(String(characters[index]))
                index += 1
            }
        }
    }
    return (tokens, ignoredCount, lexicalFailure)
}
