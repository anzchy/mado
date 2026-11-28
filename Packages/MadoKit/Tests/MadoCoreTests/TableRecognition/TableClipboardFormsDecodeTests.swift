import MadoCore
import Testing

/// AC-3: the three clipboard forms carry identical cell text for the same edited table. Each form is decoded
/// back to cells (HTML by a test-only extraction, tab-separated text by an RFC 4180-style quoted-field reader,
/// Markdown by `parseMarkdown`) and compared with the model. Tabs inside cells have their own test below.
@Test func issue868AllThreeFormsDecodeBackToTheSameEditedCells() throws {
    let edited = [
        ["名称 Name", "说明", "Emoji"],
        ["Sensonor", "  corrected  ", "👨‍👩‍👧 family"],
        ["第一行\nsecond line", "", "🇨🇳 flag"],
        ["<script>&'\"|</script>", "2*3*4 _x_ `c` [l] ~s~", "\u{3000}全角 x\u{00A0}"],
        ["C:\\Temp \\n", "say \"hi\"\nbye", "a\u{2028}b"],
    ]
    for flag in [true, false] {
        let table = RecognisedTable(rows: edited, firstRowIsHeader: flag)
        let payload = try TableClipboardPayload.build(from: table)

        let html = htmlCells(payload.html)
        #expect(html.rows == edited)
        #expect(html.headerTagged == [flag, false, false, false, false])
        #expect(tabSeparatedCells(payload.tabSeparated) == edited)
        #expect(try RecognisedTable.parseMarkdown(payload.markdown) == table)
    }
}

/// AC-3 for quote and line-break edges: a cell that starts with `"`, a cell that is only `"` followed by another
/// column (which must not be swallowed), a `"` inside a cell, LF, CRLF and empty cells. CRLF is normalised to LF
/// in every form, so the expected cells differ from the input only there.
@Test func issue868AllThreeFormsKeepQuoteLeadingAndLineBreakCells() throws {
    let edited = [
        ["\"quoted\" & x", "\"", "after quote"],
        ["mid \"q\" end", "", "\""],
        ["\n", "a\r\nb", "\"\"\n\""],
        ["", "\"x", "last"],
    ]
    var expected = edited
    expected[2][1] = "a\nb"
    for flag in [true, false] {
        let table = RecognisedTable(rows: edited, firstRowIsHeader: flag)
        let payload = try TableClipboardPayload.build(from: table)

        #expect(htmlCells(payload.html).rows == expected)
        #expect(tabSeparatedCells(payload.tabSeparated) == expected)
        let markdown = try RecognisedTable.parseMarkdown(payload.markdown)
        #expect(markdown == RecognisedTable(rows: expected, firstRowIsHeader: flag))
    }
}

/// Test-only extraction of `<tr>` rows and `<th>`/`<td>` cell text, undoing the builder's escaping.
private func htmlCells(_ html: String) -> (rows: [[String]], headerTagged: [Bool]) {
    let rowPattern = /<tr>(.*?)<\/tr>/.dotMatchesNewlines()
    let cellPattern = /<(th|td)[^>]*>(.*?)<\/(?:th|td)>/.dotMatchesNewlines()
    var rows: [[String]] = []
    var headerTagged: [Bool] = []
    for row in html.matches(of: rowPattern) {
        let cells = row.output.1.matches(of: cellPattern)
        headerTagged.append(cells.allSatisfy { $0.output.1 == "th" })
        rows.append(cells.map { match in
            String(match.output.2)
                .replacingOccurrences(of: "<br>", with: "\n")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&amp;", with: "&")
        })
    }
    return (rows, headerTagged)
}

/// #874 fix1 WI-6 (audit i874-r1 gpt M1): a tab inside a cell survives the tab-separated form. Its field is quoted
/// (inner quotes doubled), so a spreadsheet's paste reads the same cells and columns back, tabs included.
@Test func issue874Fix1TabsInsideCellsSurviveTheTabSeparatedForm() throws {
    let edited = [
        ["名称\tName", "\tleading", "trailing\t"],
        ["a\tb\tc", "say \"hi\"\tthere", "\"\t\""],
        ["\t", "", "line\nbreak\tand tab"],
    ]
    let table = RecognisedTable(rows: edited)
    let payload = try TableClipboardPayload.build(from: table)
    let cells = tabSeparatedCells(payload.tabSeparated)
    #expect(cells == edited)
    #expect(cells.allSatisfy { $0.count == 3 }, "no tab splits a column")
    #expect(htmlCells(payload.html).rows == edited)
    #expect(try RecognisedTable.parseMarkdown(payload.markdown) == table)
}

/// Test-only reader for what a spreadsheet does on paste, matching Python's `csv` reader with a tab delimiter
/// and standard quoting: tab ends a field, LF ends a row, a field that starts with `"` runs to the closing quote
/// with `""` meaning one quote (text after the closing quote is kept), and a `"` later in a field is literal.
private func tabSeparatedCells(_ text: String) -> [[String]] {
    var rows: [[String]] = []
    var row: [String] = []
    var field = ""
    var quoted = false
    var atFieldStart = true
    var characters = Array(text.unicodeScalars)[...]
    while let scalar = characters.popFirst() {
        if quoted {
            if scalar == "\"" {
                if characters.first == "\"" {
                    field.unicodeScalars.append(characters.removeFirst())
                } else {
                    quoted = false
                }
            } else {
                field.unicodeScalars.append(scalar)
            }
        } else if scalar == "\"" && atFieldStart {
            quoted = true
            atFieldStart = false
        } else if scalar == "\t" || scalar == "\n" {
            row.append(field)
            field = ""
            atFieldStart = true
            if scalar == "\n" {
                rows.append(row)
                row = []
            }
        } else {
            field.unicodeScalars.append(scalar)
            atFieldStart = false
        }
    }
    row.append(field)
    rows.append(row)
    return rows
}
