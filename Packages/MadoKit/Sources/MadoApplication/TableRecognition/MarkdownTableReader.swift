import Foundation

/// Reads the one Markdown table in a model's reply (#869 AC-5). Fences and prose around it are ignored; pipe rows
/// after a break, or a header with no rows, are not a whole table. `\|` is a
/// literal pipe and `<br>` (any case, `<br/>`, `<br />`) a line break inside a cell. Whether rows carry outer
/// pipes is read from the separator line, the one row whose cells can never be empty.
enum MarkdownTableReader {
    enum Outcome: Equatable { case rows([[String]]), noTable, incomplete }

    static func read(_ text: String) -> Outcome {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let start = lines.indices.dropLast().first(where: { hasPipe(lines[$0]) && isSeparator(lines[$0 + 1]) })
        else { return .noTable }
        let separator = lines[start + 1]
        let leading = separator.hasPrefix("|"), trailing = endsWithPipe(separator)
        let header = cells(lines[start], leading: leading, trailing: trailing)
        guard cells(separator, leading: leading, trailing: trailing).count == header.count else { return .incomplete }
        var rows = [header]
        var end = lines.endIndex
        for index in (start + 2)..<lines.endIndex {
            guard hasPipe(lines[index]) else { end = index; break }
            let row = cells(lines[index], leading: leading, trailing: trailing)
            guard row.count == header.count else { return .incomplete }
            rows.append(row)
        }
        // A blank or prose line with more pipe rows after it broke the table: what was read is not all of it.
        if lines[end...].contains(where: hasPipe) { return .incomplete }
        // A header alone carries no cells to paste.
        return rows.count > 1 ? .rows(rows) : .noTable
    }

    private static func hasPipe(_ line: String) -> Bool { split(line).count > 1 }

    private static func endsWithPipe(_ line: String) -> Bool { line.hasSuffix("|") && !line.hasSuffix("\\|") }

    /// `|---|:--|--:|`, with or without outer pipes; needs at least one pipe so a rule line (`---`) is not one.
    private static func isSeparator(_ line: String) -> Bool {
        guard hasPipe(line) else { return false }
        let parts = cells(line, leading: line.hasPrefix("|"), trailing: endsWithPipe(line))
        return !parts.isEmpty && parts.allSatisfy { part in
            var body = Substring(part)
            if body.hasPrefix(":") { body.removeFirst() }
            if body.hasSuffix(":") { body.removeLast() }
            return !body.isEmpty && body.allSatisfy { $0 == "-" }
        }
    }

    /// Splits on unescaped pipes; `\|` stays in the cell as `|`.
    private static func split(_ line: String) -> [String] {
        var parts = [""]
        var escaped = false
        for character in line {
            if escaped {
                parts[parts.count - 1].append(character == "|" ? "|" : "\\\(character)")
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                parts.append("")
            } else {
                parts[parts.count - 1].append(character)
            }
        }
        if escaped { parts[parts.count - 1].append("\\") }
        return parts
    }

    private static func cells(_ line: String, leading: Bool, trailing: Bool) -> [String] {
        var parts = split(line)
        if leading, line.hasPrefix("|"), parts.count > 1 { parts.removeFirst() }
        if trailing, endsWithPipe(line), parts.count > 1 { parts.removeLast() }
        return parts.map { part in
            part.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        }
    }
}
