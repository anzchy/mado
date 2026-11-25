import MadoCore
import Testing

@Test func issue868TableModelCountsRowsAndColumns() {
    let table = RecognisedTable(rows: [["Name", "说明"], ["Sensonor", "  corrected  "]])
    #expect(table.rows[1][0] == "Sensonor")
    #expect(table.rows[1][1] == "  corrected  ")
    #expect(table.firstRowIsHeader)
    #expect(table.rowCount == 2)
    #expect(table.columnCount == 2)
    let noHeader = RecognisedTable(rows: [["A", "B"]], firstRowIsHeader: false)
    #expect(!noHeader.firstRowIsHeader)
    #expect(noHeader.rowCount == 1)
    #expect(noHeader.columnCount == 2)
}

@Test func issue868EmptyTableHasZeroCounts() {
    let table = RecognisedTable(rows: [])
    #expect(table.rowCount == 0)
    #expect(table.columnCount == 0)
}
