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
    let tokens = timeLimitCodeTokens(source)
    var declarations: [TimeLimitDeclaration] = []
    for index in tokens.indices where tokens[index] == "." {
        guard index + 1 < tokens.count, tokens[index + 1] == "timeLimit" else { continue }
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
    return declarations
}

/// A small lexer rather than a Swift parser: comments are trivia, strings are an
/// opaque token, and every other identifier/punctuation remains available to the policy.
private func timeLimitCodeTokens(_ source: String) -> [String] {
    let characters = Array(source)
    var index = 0
    var tokens: [String] = []

    func matches(_ text: String, at start: Int) -> Bool {
        let candidate = Array(text)
        return start + candidate.count <= characters.count
            && characters[start..<(start + candidate.count)].elementsEqual(candidate)
    }

    while index < characters.count {
        if characters[index].isWhitespace {
            index += 1
        } else if matches("//", at: index) {
            while index < characters.count && characters[index] != "\n" && characters[index] != "\r" {
                index += 1
            }
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
        } else {
            var quote = index
            while quote < characters.count && characters[quote] == "#" { quote += 1 }
            if quote < characters.count && characters[quote] == "\"" {
                let hashes = String(repeating: "#", count: quote - index)
                let delimiter = matches("\"\"\"", at: quote) ? "\"\"\"" : "\""
                let end = delimiter + hashes
                let escape = "\\" + hashes
                index = quote + delimiter.count
                while index < characters.count {
                    if matches(end, at: index) {
                        index += end.count
                        break
                    } else if matches(escape, at: index) {
                        // Skip the escaped character, including an escaped quote.
                        index = min(characters.count, index + escape.count + 1)
                    } else {
                        index += 1
                    }
                }
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
    return tokens
}
