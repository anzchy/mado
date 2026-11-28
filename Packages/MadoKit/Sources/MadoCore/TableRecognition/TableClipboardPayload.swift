import Foundation

public enum TableRecognitionError: Error, Equatable, Sendable {
    case emptyTable
    case raggedRows
    case invalidMarkdown
}

/// Three representations of the same edited table. The caller writes HTML and
/// tab-separated text together; Markdown is available for an explicit action.
public struct TableClipboardPayload: Equatable, Sendable {
    public let html: String
    public let tabSeparated: String
    public let markdown: String

    public static func build(from table: RecognisedTable) throws -> Self {
        guard !table.rows.isEmpty, let width = table.rows.first?.count, width > 0 else {
            throw TableRecognitionError.emptyTable
        }
        guard table.rows.allSatisfy({ $0.count == width }) else {
            throw TableRecognitionError.raggedRows
        }

        let htmlRows = table.rows.enumerated().map { index, row in
            let tag = table.firstRowIsHeader && index == 0 ? "th" : "td"
            return "<tr>" + row.map { "<\(tag) \(htmlCellStyle)>\(htmlCell($0))</\(tag)>" }.joined() + "</tr>"
        }
        // UTF-8 is declared: HTML readers without a charset fall back to a legacy encoding and garble CJK.
        // `white-space: pre-wrap` keeps a cell's edge and repeated spaces visible.
        let html = "<meta charset=\"utf-8\"><table border=\"1\">" + htmlRows.joined() + "</table>"
        let tabSeparated = table.rows.map { $0.map(tsvCell).joined(separator: "\t") }.joined(separator: "\n")
        // A data-first table gets an all-empty header row. A real header that is entirely empty writes
        // `<!---->` (an empty HTML comment, rendered as nothing) in its first cell so the flag survives.
        func markdownRow(_ cells: [String]) -> String { "| " + cells.joined(separator: " | ") + " |" }
        var header = table.firstRowIsHeader ? table.rows[0].map(markdownCell) : Array(repeating: "", count: width)
        if table.firstRowIsHeader && header.allSatisfy(\.isEmpty) { header[0] = emptyHeaderCell }
        let body = table.rows.dropFirst(table.firstRowIsHeader ? 1 : 0).map { markdownRow($0.map(markdownCell)) }
        let separator = markdownRow(Array(repeating: "---", count: width))
        let markdown = ([markdownRow(header), separator] + body).joined(separator: "\n")
        return Self(html: html, tabSeparated: tabSeparated, markdown: markdown)
    }
}

extension RecognisedTable {
    public static func parseMarkdown(_ markdown: String) throws -> Self {
        let lines = markdown.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count >= 2 else { throw TableRecognitionError.invalidMarkdown }
        let header = try splitMarkdownRow(lines[0])
        let separator = try splitMarkdownRow(lines[1])
        guard !header.isEmpty, separator.count == header.count,
              separator.allSatisfy({ isSeparatorCell($0) }) else {
            throw TableRecognitionError.invalidMarkdown
        }
        // An all-empty header row means the first row is data (what `build` writes for that flag).
        let firstRowIsHeader = !header.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        let rawRows = (firstRowIsHeader ? [header] : []) + (try lines.dropFirst(2).map(splitMarkdownRow))
        guard !rawRows.isEmpty else { throw TableRecognitionError.emptyTable }
        guard rawRows.allSatisfy({ $0.count == header.count }) else {
            throw TableRecognitionError.raggedRows
        }
        let rows = rawRows.map { row in row.map { decodeMarkdownCell($0.trimmingCharacters(in: .whitespaces)) } }
        return Self(rows: rows, firstRowIsHeader: firstRowIsHeader)
    }
}

private func normalized(_ cell: String) -> String {
    cell.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
}

private func escapeHTML(_ cell: String) -> String {
    cell.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&#39;")
}

private let htmlCellStyle = "style=\"white-space: pre-wrap\""

private func htmlCell(_ cell: String) -> String {
    escapeHTML(normalized(cell)).replacingOccurrences(of: "\n", with: "<br>")
}

/// Spreadsheet-style field. A field that starts with `"` (a quoted-field reader takes it as an opening quote), or
/// has an in-cell line break or tab (bare, either would end the field), is quoted, inner quotes doubled, so it reads
/// back as one cell with its tabs (#874 fix1 WI-6). Every other field, backslashes and later quotes included, is
/// written unchanged.
private func tsvCell(_ cell: String) -> String {
    let text = normalized(cell)
    guard text.hasPrefix("\"") || text.contains("\n") || text.contains("\t") else { return text }
    return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
}

/// Markdown cell text. Every whitespace or line-break scalar the parser could trim or split on is written as
/// `&#xNNNN;` (interior U+0020 stays literal); LF becomes `<br>`; `\\ | * _ ` [ ] ~` get a backslash; markup
/// characters become HTML entities.
private func markdownCell(_ cell: String) -> String {
    let scalars = Array(normalized(cell).unicodeScalars)
    let first = scalars.firstIndex(where: { $0 != " " }) ?? scalars.count
    let last = scalars.lastIndex(where: { $0 != " " }) ?? -1
    var text = ""
    for (index, scalar) in scalars.enumerated() {
        if scalar == "\n" {
            text += "<br>"
        } else if scalar == " " && index > first && index < last {
            text += " "
        } else if markdownBackslashed.contains(scalar) {
            text += "\\" + String(scalar)
        } else if CharacterSet.whitespacesAndNewlines.contains(scalar) {
            text += "&#x" + String(scalar.value, radix: 16, uppercase: true) + ";"
        } else {
            text += escapeHTML(String(scalar))
        }
    }
    return text
}

private let markdownBackslashed: Set<Unicode.Scalar> = ["\\", "|", "*", "_", "`", "[", "]", "~"]

private func splitMarkdownRow(_ line: String) throws -> [String] {
    var body = Array(line.trimmingCharacters(in: .whitespaces))
    if body.first == "|" { body.removeFirst() }
    if body.last == "|" { body.removeLast() }
    guard !body.isEmpty else { throw TableRecognitionError.invalidMarkdown }
    var cells: [String] = []
    var current = ""
    var escaped = false
    for character in body {
        if escaped {
            current.append(character)
            escaped = false
        } else if character == "\\" {
            escaped = true
        } else if character == "|" {
            cells.append(current)
            current = ""
        } else {
            current.append(character)
        }
    }
    guard !escaped else { throw TableRecognitionError.invalidMarkdown }
    cells.append(current)
    return cells
}

/// GFM delimiter cell: one or more hyphens, with an optional colon at either edge.
private func isSeparatorCell(_ cell: String) -> Bool {
    var value = Substring(cell.trimmingCharacters(in: .whitespaces))
    if value.first == ":" { value.removeFirst() }
    if value.last == ":" { value.removeLast() }
    return !value.isEmpty && value.allSatisfy { $0 == "-" }
}

/// Inverse of `markdownCell` after `splitMarkdownRow` has removed backslash escapes. Works on scalars so a
/// combining mark after an entity cannot hide the entity's `;`.
private func decodeMarkdownCell(_ cell: String) -> String {
    let scalars = Array(cell.unicodeScalars)
    var decoded = String.UnicodeScalarView()
    var index = 0
    while index < scalars.count {
        if let (value, length) = markdownToken(in: scalars, at: index) {
            decoded.append(contentsOf: value.unicodeScalars)
            index += length
        } else {
            decoded.append(scalars[index])
            index += 1
        }
    }
    return String(decoded)
}

private let emptyHeaderCell = "<!---->"

private let markdownNamedTokens: [(token: [Unicode.Scalar], value: String)] = [
    ("<br>", "\n"), (emptyHeaderCell, ""), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
].map { (Array($0.0.unicodeScalars), $0.1) }

private func markdownToken(in scalars: [Unicode.Scalar], at start: Int) -> (String, Int)? {
    if let entry = markdownNamedTokens.first(where: { scalars[start...].starts(with: $0.token) }) {
        return (entry.value, entry.token.count)
    }
    // Numeric character reference: `&#` then decimal, or `x` and hex, then `;`.
    guard scalars[start...].starts(with: ["&", "#"]) else { return nil }
    var index = start + 2
    let hex = index < scalars.count && (scalars[index] == "x" || scalars[index] == "X")
    if hex { index += 1 }
    var digits = ""
    while index < scalars.count, scalars[index] != ";", digits.count <= 8 {
        digits.unicodeScalars.append(scalars[index])
        index += 1
    }
    guard index < scalars.count, scalars[index] == ";", digits.allSatisfy(\.isHexDigit),
          let value = UInt32(digits, radix: hex ? 16 : 10), let scalar = Unicode.Scalar(value) else {
        return nil
    }
    return (String(scalar), index + 1 - start)
}
