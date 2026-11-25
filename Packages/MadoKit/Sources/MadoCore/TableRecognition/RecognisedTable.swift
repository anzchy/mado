/// Cell text is kept verbatim. A table may be edited by replacing `rows`.
public struct RecognisedTable: Equatable, Sendable {
    public var rows: [[String]]
    public var firstRowIsHeader: Bool

    public init(rows: [[String]], firstRowIsHeader: Bool = true) {
        self.rows = rows
        self.firstRowIsHeader = firstRowIsHeader
    }

    public var rowCount: Int { rows.count }
    public var columnCount: Int { rows.first?.count ?? 0 }
}
