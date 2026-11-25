import MadoCore
import Testing

@Test func issue868ClipboardEscapesHTMLAndPreservesEditedCells() throws {
    let table = RecognisedTable(rows: [
        ["Name", "说明"],
        ["Sensonor", "  corrected  "],
        ["<script>alert(\"x\")</script> & 'quoted' | pipe", "第一行\nsecond line"],
        ["", ""],
    ])
    let payload = try TableClipboardPayload.build(from: table)
    #expect(payload.html.hasPrefix("<table border=\"1\">"))
    #expect(payload.html.components(separatedBy: "<table").count == 2)
    #expect(payload.html.contains("&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt; &amp; &#39;quoted&#39; | pipe"))
    #expect(!payload.html.contains("<script>"))
    #expect(payload.html.contains("<th>Name</th><th>说明</th>"))
    #expect(payload.html.contains("<td>第一行<br>second line</td>"))
    #expect(payload.html.contains("<td>  corrected  </td>"))
    #expect(payload.html.contains("<td></td><td></td>"))
    #expect(payload.tabSeparated.contains("Sensonor\t  corrected  "))
    #expect(payload.markdown.contains("Sensonor"))
    #expect(!payload.markdown.contains("Sensoror"))
}

@Test func issue868ClipboardDelimitersStayInsideCells() throws {
    let table = RecognisedTable(rows: [
        ["literal \\n", "pipe | and tab\there"],
        ["line1\r\nline2", "backslash \\ and <br>"],
    ], firstRowIsHeader: false)
    let payload = try TableClipboardPayload.build(from: table)
    // TSV uses literal backslash escapes for backslash, tab and in-cell LF.
    // Thus physical LF is only a row boundary, and physical tab only a column boundary.
    #expect(payload.tabSeparated == "literal \\\\n\tpipe | and tab\\there\nline1\\nline2\tbackslash \\\\ and <br>")
    #expect(payload.tabSeparated.split(separator: "\n").count == 2)
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
