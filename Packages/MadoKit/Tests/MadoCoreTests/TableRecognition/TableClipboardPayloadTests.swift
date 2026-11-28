import MadoCore
import Testing

@Test func issue868HTMLDeclaresUTF8EscapesCellsAndKeepsEdgeSpacesWithPreWrap() throws {
    let table = RecognisedTable(rows: [
        ["Name", "说明"],
        ["Sensonor", "  corrected  "],
        ["<script>alert(\"x\")</script> & 'quoted' | pipe", "第一行\nsecond line"],
        ["", ""],
    ])
    let payload = try TableClipboardPayload.build(from: table)
    let preWrap = "style=\"white-space: pre-wrap\""
    // UTF-8 is declared so HTML readers do not fall back to a legacy encoding for CJK; every cell is
    // `white-space: pre-wrap` so edge spaces stay visible.
    #expect(payload.html.hasPrefix("<meta charset=\"utf-8\"><table border=\"1\">"))
    #expect(payload.html.hasSuffix("</table>"))
    #expect(payload.html.components(separatedBy: "<table").count == 2)
    #expect(payload.html.contains("&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt; &amp; &#39;quoted&#39; | pipe"))
    #expect(!payload.html.contains("<script>"))
    #expect(payload.html.contains("<tr><th \(preWrap)>Name</th><th \(preWrap)>说明</th></tr>"))
    #expect(payload.html.contains("<td \(preWrap)>第一行<br>second line</td>"))
    #expect(payload.html.contains("<td \(preWrap)>  corrected  </td>"))
    #expect(payload.html.contains("<td \(preWrap)></td><td \(preWrap)></td>"))
    #expect(payload.tabSeparated.contains("Sensonor\t  corrected  "))
    #expect(payload.markdown.contains("Sensonor"))
    #expect(!payload.markdown.contains("Sensoror"))
}

@Test func issue868TSVQuotesQuoteLeadingLineBreakAndTabFieldsAndKeepsBackslashes() throws {
    let table = RecognisedTable(rows: [
        ["literal \\n", "pipe | and tab\there"],
        ["line1\r\nline2", "backslash \\ and <br>"],
        ["say \"hi\"\nbye", "C:\\Temp \"bare\""],
        ["\"quoted\" & x", "second"],
        ["\"", "after"],
        ["mid \"q\" end", ""],
        ["\n", "a\r\nb"],
    ], firstRowIsHeader: false)
    let payload = try TableClipboardPayload.build(from: table)
    // Spreadsheet paste: a field that starts with `"`, has an in-cell line break or a tab is quoted RFC 4180 style
    // (inner quotes doubled); every other field stays bare, since a `"` after the first character is literal.
    // A backslash is never escaped, a tab inside a cell is kept in its quoted field (#874 fix1 WI-6), and CRLF
    // becomes LF.
    #expect(payload.tabSeparated == [
        "literal \\n\t\"pipe | and tab\there\"",
        "\"line1\nline2\"\tbackslash \\ and <br>",
        "\"say \"\"hi\"\"\nbye\"\tC:\\Temp \"bare\"",
        "\"\"\"quoted\"\" & x\"\tsecond",
        "\"\"\"\"\tafter",
        "mid \"q\" end\t",
        "\"\n\"\t\"a\nb\"",
    ].joined(separator: "\n"))
    #expect(payload.html.contains("line1<br>line2"))
    #expect(payload.markdown.contains("pipe \\| and tab"))
    #expect(payload.markdown.contains("line1<br>line2"))
    #expect(payload.markdown.contains("&lt;br&gt;"))
    #expect(!payload.html.contains("<br></td><td>backslash"))
}

@Test func issue868MarkdownRoundTripsTextAndHeaderFlag() throws {
    for flag in [true, false] {
        let original = RecognisedTable(rows: [
            ["  ", "A|B", ""],
            ["Sensonor", "\"quoted\" & <tag>", "first\nsecond"],
            ["\\n", " leading ", "尾部 "],
        ], firstRowIsHeader: flag)
        let markdown = try TableClipboardPayload.build(from: original).markdown
        let parsed = try RecognisedTable.parseMarkdown(markdown)
        #expect(parsed == original)
        #expect(markdown.contains("| --- | --- | --- |"))
    }
}

@Test func issue868MarkdownRejectsRaggedAndMissingTables() throws {
    #expect(throws: TableRecognitionError.raggedRows) {
        try RecognisedTable.parseMarkdown("| A | B |\n| --- | --- |\n| one |")
    }
    #expect(throws: TableRecognitionError.invalidMarkdown) {
        try RecognisedTable.parseMarkdown("not a table")
    }
    #expect(throws: TableRecognitionError.emptyTable) {
        try TableClipboardPayload.build(from: RecognisedTable(rows: []))
    }
    #expect(throws: TableRecognitionError.raggedRows) {
        try TableClipboardPayload.build(from: RecognisedTable(rows: [["A", "B"], ["only one"]]))
    }
}

@Test func issue868MarkdownSeparatorMustBeValidAndMayBeAligned() throws {
    #expect(throws: TableRecognitionError.invalidMarkdown) {
        try RecognisedTable.parseMarkdown("| A | B |\n| --- | nope |\n| one | two |")
    }
    let aligned = try RecognisedTable.parseMarkdown("| A | B |\n| :--- | ---: |\n| one | two |")
    #expect(aligned.rows == [["A", "B"], ["one", "two"]])
}

@Test func issue868MarkdownEntityEncodesUnicodeSpacesAndBreaksAndBackslashEscapesActiveCharacters() throws {
    // Every whitespace or line-break scalar the parser could trim or split on is written as `&#xNNNN;`
    // (interior U+0020 stays literal); Markdown-active `* _ ` [ ] ~` get a backslash, which the parser drops.
    let cells = [
        "\u{3000}中文", "x\u{00A0}", "a\u{2028}b", "a\u{2029}b", "a\u{0B}b", "a\u{85}b",
        " edge ", "2*3*4 _x_ `code` [link](u) ~s~", "tab\there",
    ]
    let original = RecognisedTable(rows: [cells, Array(cells.reversed())])
    let markdown = try TableClipboardPayload.build(from: original).markdown
    #expect(try RecognisedTable.parseMarkdown(markdown) == original)
    #expect(markdown.components(separatedBy: .newlines).count == 3)
    #expect(markdown.contains("| &#x3000;中文 | x&#xA0; | a&#x2028;b | a&#x2029;b | a&#xB;b | a&#x85;b |"))
    #expect(markdown.contains("| &#x20;edge&#x20; | 2\\*3\\*4 \\_x\\_ \\`code\\` \\[link\\](u) \\~s\\~ | tab&#x9;here |"))
}

@Test func issue868MarkdownParserDecodesCharacterReferencesAndLeavesMalformedOnesLiteral() throws {
    let parsed = try RecognisedTable.parseMarkdown(
        "| &#65;&#X42;&#x63; | &#xZZ; &#+41; &#; &#x110000; &#12 |\n| --- | --- |\n| &amp;lt; | a&#x301; |"
    )
    #expect(parsed.rows == [["ABc", "&#xZZ; &#+41; &#; &#x110000; &#12"], ["&lt;", "a\u{301}"]])
}

@Test func issue868MarkdownDataFirstTableWritesEmptyHeaderRowAndEmptyRealHeaderUsesEmptyComment() throws {
    // firstRowIsHeader == false: an all-empty header row, the separator, then every row; no private marker.
    let dataFirst = RecognisedTable(rows: [["A", "B"], ["1", "2"]], firstRowIsHeader: false)
    let dataMarkdown = try TableClipboardPayload.build(from: dataFirst).markdown
    #expect(dataMarkdown == "|  |  |\n| --- | --- |\n| A | B |\n| 1 | 2 |")
    #expect(try RecognisedTable.parseMarkdown(dataMarkdown) == dataFirst)
    // A real header row that is entirely empty writes `<!---->` (renders empty) in its first cell.
    let emptyHeader = RecognisedTable(rows: [["", ""], ["1", "2"]])
    let headerMarkdown = try TableClipboardPayload.build(from: emptyHeader).markdown
    #expect(headerMarkdown == "| <!----> |  |\n| --- | --- |\n| 1 | 2 |")
    #expect(try RecognisedTable.parseMarkdown(headerMarkdown) == emptyHeader)
    // Markdown from elsewhere: an all-empty header reads as data-first; with no data rows it is an empty table.
    #expect(try RecognisedTable.parseMarkdown("| | |\n| --- | --- |\n| x | y |")
        == RecognisedTable(rows: [["x", "y"]], firstRowIsHeader: false))
    #expect(throws: TableRecognitionError.emptyTable) {
        try RecognisedTable.parseMarkdown("| | |\n| --- | --- |")
    }
}

@Test func issue868MarkdownSeparatorFollowsGFMOneOrMoreHyphensWithOptionalEdgeColons() throws {
    for separator in ["| - | - |", "|:-:|:-:|", "|:--|--:|", "| :---: | ---- |", "|-|-|"] {
        let parsed = try RecognisedTable.parseMarkdown("| A | B |\n\(separator)\n| one | two |")
        #expect(parsed.rows == [["A", "B"], ["one", "two"]])
    }
    for separator in ["| :-:--- | --- |", "| : | --- |", "| -:- | --- |", "| --- | ::-- |", "| -- - | --- |"] {
        #expect(throws: TableRecognitionError.invalidMarkdown) {
            try RecognisedTable.parseMarkdown("| A | B |\n\(separator)\n| one | two |")
        }
    }
}

@Test func issue868MarkdownRoundTripsCombiningMarksNextToEscapesEntitiesAndEdges() throws {
    let original = RecognisedTable(rows: [
        ["\u{301}lead", "\\\u{301}", "|\u{301}", " \u{301}"],
        ["&\u{301}", "x \u{301}", "*\u{301}*", "\u{3000}\u{301}"],
    ])
    let markdown = try TableClipboardPayload.build(from: original).markdown
    #expect(try RecognisedTable.parseMarkdown(markdown) == original)
}
