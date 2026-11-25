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
            return "<tr>" + row.map { "<\(tag)>\(htmlCell($0))</\(tag)>" }.joined() + "</tr>"
        }
        let html = "<table border=\"1\">" + htmlRows.joined() + "</table>"
        let tabSeparated = table.rows.map { $0.map(tsvCell).joined(separator: "\t") }.joined(separator: "\n")
        let renderedRows = table.rows.map { "| " + $0.map(markdownCell).joined(separator: " | ") + " |" }
        let separator = "| " + Array(repeating: "---", count: width).joined(separator: " | ") + " |"
        let prefix = table.firstRowIsHeader ? "" : "<!-- mado:first-row-is-data -->\n"
        let markdown = prefix + ([renderedRows[0], separator] + renderedRows.dropFirst()).joined(separator: "\n")
        return Self(html: html, tabSeparated: tabSeparated, markdown: markdown)
    }
}

extension RecognisedTable {
    public static func parseMarkdown(_ markdown: String) throws -> Self {
        var lines = markdown.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let marker = "<!-- mado:first-row-is-data -->"
        let firstRowIsHeader = lines.first != marker
        if !firstRowIsHeader { lines.removeFirst() }
        guard lines.count >= 2 else { throw TableRecognitionError.invalidMarkdown }
        let header = try splitMarkdownRow(lines[0])
        let separator = try splitMarkdownRow(lines[1])
        guard !header.isEmpty, separator.count == header.count,
              separator.allSatisfy({ isSeparatorCell($0) }) else {
            throw TableRecognitionError.invalidMarkdown
        }
        let rows = try ([header] + lines.dropFirst(2).map(splitMarkdownRow)).map { row in
            row.map { decodeMarkdownCell($0.trimmingCharacters(in: .whitespaces)) }
        }
        guard rows.allSatisfy({ $0.count == header.count }) else {
            throw TableRecognitionError.raggedRows
        }
        return Self(rows: rows, firstRowIsHeader: firstRowIsHeader)
    }
}
import Foundation


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

private func htmlCell(_ cell: String) -> String {
    escapeHTML(normalized(cell)).replacingOccurrences(of: "\n", with: "<br>")
}

private func tsvCell(_ cell: String) -> String {
    normalized(cell).replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\t", with: "\\t")
        .replacingOccurrences(of: "\n", with: "\\n")
}

private func markdownCell(_ cell: String) -> String {
    let chars = Array(normalized(cell))
    let first = chars.firstIndex(where: { $0 != " " }) ?? chars.count
    let last = chars.lastIndex(where: { $0 != " " }) ?? -1
    return chars.enumerated().map { index, character in
        if character == " " && (index < first || index > last) { return "&#32;" }
        if character == "\t" { return "&#9;" }
        if character == "\n" { return "<br>" }
        if character == "\\" { return "\\\\" }
        if character == "|" { return "\\|" }
        return escapeHTML(String(character))
    }.joined()
}

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

private func isSeparatorCell(_ cell: String) -> Bool {
    let value = cell.trimmingCharacters(in: .whitespaces)
    let hyphens = value.filter { $0 == "-" }.count
    return hyphens >= 3 && value.allSatisfy { $0 == "-" || $0 == ":" }
}

private func decodeMarkdownCell(_ cell: String) -> String {
    cell.replacingOccurrences(of: "<br>", with: "\n")
        .replacingOccurrences(of: "&#32;", with: " ")
        .replacingOccurrences(of: "&#9;", with: "\t")
        .replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&quot;", with: "\"")
        .replacingOccurrences(of: "&#39;", with: "'")
        .replacingOccurrences(of: "&amp;", with: "&")
}
