import Testing
@testable import RiffaCore

@Suite("Delimited table parsing")
struct DelimitedTableParsingTests {
    @Test("Basic fields, empty fields, and trailing record endings are stable")
    func basicRecords() {
        let result = DelimitedTextParser().parse("a,b,\r\n1,,3\n")

        #expect(result.diagnostics.isEmpty)
        #expect(result.rows.count == 2)
        #expect(result.rows.map { $0.fields.map(\.value) } == [
            ["a", "b", ""],
            ["1", "", "3"]
        ])
        #expect(result.rows[0].fields.map(\.columnIndex) == [0, 1, 2])
        #expect(result.rows[0].fields.map(\.location.column) == [1, 3, 5])
        #expect(result.rows[1].location == TableSourceLocation(offset: 5, line: 2, column: 1))
    }

    @Test("Quoted delimiters, escaped quotes, and embedded line endings are preserved")
    func quotedFields() {
        let source = "id,name\r\n1,\"Ada, Jr.\"\n2,\"line 1\r\nline 2\"\r3,\"say \"\"hi\"\"\""
        let result = DelimitedTextParser().parse(source)

        #expect(result.diagnostics.isEmpty)
        #expect(result.rows.count == 4)
        #expect(result.rows[1].fields[1].value == "Ada, Jr.")
        #expect(result.rows[2].fields[1].value == "line 1\r\nline 2")
        #expect(result.rows[3].fields[1].value == "say \"hi\"")
        #expect(result.rows.map(\.location.line) == [1, 2, 3, 5])
        #expect(result.rows[2].fields[1].location.line == 3)
        #expect(result.rows[2].fields[1].location.column == 3)
    }

    @Test("CR, LF, and CRLF each terminate exactly one record")
    func mixedRecordEndings() {
        let result = DelimitedTextParser().parse("a\rb\r\nc\nd")

        #expect(result.diagnostics.isEmpty)
        #expect(result.rows.map { $0.fields[0].value } == ["a", "b", "c", "d"])
        #expect(result.rows.map(\.location.line) == [1, 2, 3, 4])
        #expect(result.rows.map(\.location.column) == [1, 1, 1, 1])
    }

    @Test("A custom delimiter still honors quoted content")
    func customDelimiter() {
        let result = DelimitedTextParser(delimiter: "\t").parse(
            "id\tnote\n1\t\"contains\ttab\"\n2\t\"two\nlines\""
        )

        #expect(result.diagnostics.isEmpty)
        #expect(result.delimiter == "\t")
        #expect(result.rows.map { $0.fields.map(\.value) } == [
            ["id", "note"],
            ["1", "contains\ttab"],
            ["2", "two\nlines"]
        ])
    }

    @Test("Malformed quoting is diagnosed at source positions without dropping text")
    func malformedQuoting() {
        let result = DelimitedTextParser().parse("ab\"c,\"ok\"x\n\"unterminated")

        #expect(result.rows.map { $0.fields.map(\.value) } == [
            ["ab\"c", "okx"],
            ["unterminated"]
        ])
        #expect(result.diagnostics.map(\.code) == [
            .unexpectedQuote,
            .unexpectedCharacterAfterClosingQuote,
            .unterminatedQuotedField
        ])
        #expect(result.diagnostics.map(\.location.line) == [1, 1, 2])
        #expect(result.diagnostics.map(\.location.column) == [3, 10, 1])
        #expect(result.diagnostics.map(\.recordIndex) == [0, 0, 1])
        #expect(result.diagnostics.map(\.fieldIndex) == [0, 1, 0])
    }

    @Test("Empty input differs from physical blank records")
    func emptyAndBlankRecords() {
        let empty = DelimitedTextParser().parse("")
        let oneBlank = DelimitedTextParser().parse("\n")
        let twoBlank = DelimitedTextParser().parse("\r\n\n")

        #expect(empty.rows.isEmpty)
        #expect(oneBlank.rows.map { $0.fields.map(\.value) } == [[""]])
        #expect(twoBlank.rows.map { $0.fields.map(\.value) } == [[""], [""]])
    }

    @Test("A quote or newline cannot be configured as the delimiter")
    func invalidDelimiter() {
        let result = DelimitedTextParser(delimiter: "\"").parse("a\"b")

        #expect(result.rows.isEmpty)
        #expect(result.diagnostics.count == 1)
        #expect(result.diagnostics[0].code == .invalidDelimiter)
        #expect(result.diagnostics[0].location.line == 1)
        #expect(result.diagnostics[0].location.column == 1)
    }
}

@Suite("Table comparison")
struct TableComparisonTests {
    @Test("Row-number alignment reports row and cell statuses")
    func rowNumberAlignment() {
        let options = TableComparisonOptions(ignoredColumns: [2])
        let result = TableComparisonEngine(options: options).compare(
            leftText: "1,A,old\n2,B,left\n3,C,last\n",
            rightText: "1,A,new\n2,b,right\n"
        )

        #expect(result.rows.map(\.status) == [.same, .modified, .leftOnly])
        #expect(result.rows[0].cells.map(\.status) == [.same, .same, .ignored])
        #expect(result.rows[1].cells.map(\.status) == [.same, .modified, .ignored])
        #expect(result.rows[2].cells.map(\.status) == [.leftOnly, .leftOnly, .ignored])
        #expect(result.statistics.sameRowCount == 1)
        #expect(result.statistics.modifiedRowCount == 1)
        #expect(result.statistics.leftOnlyRowCount == 1)
        #expect(result.statistics.totalRowCount == 3)
        #expect(result.hasDifferences)
    }

    @Test("Case and all whitespace can be ignored independently")
    func comparisonNormalization() {
        let strict = TableComparisonEngine().compare(
            leftText: "\"A b\",One\n",
            rightText: "ab,one\n"
        )
        let relaxed = TableComparisonEngine(
            options: TableComparisonOptions(ignoreCase: true, ignoreWhitespace: true)
        ).compare(
            leftText: "\"A b\",One\n",
            rightText: "ab,one\n"
        )

        #expect(strict.rows.map(\.status) == [.modified])
        #expect(relaxed.rows.map(\.status) == [.same])
        #expect(relaxed.rows[0].cells.map(\.status) == [.same, .same])
    }

    @Test("Variable-width records expose missing cells")
    func variableWidthRows() {
        let result = TableComparisonEngine().compare(
            leftText: "1,a,b\n",
            rightText: "1,a\n"
        )

        #expect(result.rows.map(\.status) == [.modified])
        #expect(result.rows[0].cells.map(\.status) == [.same, .same, .leftOnly])
        #expect(result.rows[0].cells[2].left?.value == "b")
        #expect(result.rows[0].cells[2].right == nil)
    }

    @Test("Composite keys align in stable left-first order")
    func compositeKeyAlignment() {
        let options = TableComparisonOptions(
            alignment: .keyColumns([0, 1]),
            ignoreCase: true
        )
        let result = TableComparisonEngine(options: options).compare(
            leftText: "eu,2,L-two\nus,1,L-one\neu,3,L-three\n",
            rightText: "US,1,R-one\nap,9,R-nine\nEU,2,L-two\n"
        )

        #expect(result.rows.map(\.status) == [.same, .modified, .leftOnly, .rightOnly])
        #expect(result.rows.map(\.keyValues) == [
            ["eu", "2"],
            ["us", "1"],
            ["eu", "3"],
            ["ap", "9"]
        ])
        #expect(result.rows.map { $0.left?.index } == [0, 1, 2, nil])
        #expect(result.rows.map { $0.right?.index } == [2, 0, nil, 1])
        #expect(result.rows[1].cells.map(\.status) == [.same, .same, .modified])
    }

    @Test("Duplicate composite keys are explicit and every physical row survives")
    func duplicateKeys() {
        let options = TableComparisonOptions(alignment: .keyColumns([0, 1]))
        let result = TableComparisonEngine(options: options).compare(
            leftText: "x,1,L1\nx,1,L2\ny,2,LY\n",
            rightText: "x,1,R1\ny,2,LY\nx,1,R2\n"
        )

        #expect(result.rows.map(\.status) == [
            .duplicateKey,
            .duplicateKey,
            .same,
            .duplicateKey,
            .duplicateKey
        ])
        #expect(result.statistics.duplicateKeyRowCount == 4)
        #expect(result.diagnostics.map(\.code) == [.duplicateKey, .duplicateKey])
        #expect(result.diagnostics.map(\.side) == [.left, .right])

        let representedLeftRows = result.rows.compactMap { $0.left?.index }.sorted()
        let representedRightRows = result.rows.compactMap { $0.right?.index }.sorted()
        #expect(representedLeftRows == [0, 1, 2])
        #expect(representedRightRows == [0, 1, 2])
    }

    @Test("A key duplicated on one side prevents arbitrary pairing on both sides")
    func oneSidedDuplicateKey() {
        let options = TableComparisonOptions(alignment: .keyColumns([0, 1]))
        let result = TableComparisonEngine(options: options).compare(
            leftText: "k,1,left-a\nk,1,left-b\n",
            rightText: "k,1,right\n"
        )

        #expect(result.rows.map(\.status) == [.duplicateKey, .duplicateKey, .duplicateKey])
        #expect(result.rows.compactMap { $0.left?.index }.sorted() == [0, 1])
        #expect(result.rows.compactMap { $0.right?.index } == [0])
        #expect(result.diagnostics.map(\.code) == [.duplicateKey])
        #expect(result.diagnostics.map(\.side) == [.left])
    }

    @Test("Composite key matching honors case and whitespace options")
    func normalizedCompositeKeys() {
        let options = TableComparisonOptions(
            alignment: .keyColumns([0, 1]),
            ignoreCase: true,
            ignoreWhitespace: true
        )
        let result = TableComparisonEngine(options: options).compare(
            leftText: " A ,0 1,left\n",
            rightText: "a,01,right\n"
        )

        #expect(result.rows.map(\.status) == [.modified])
        #expect(result.rows[0].left?.index == 0)
        #expect(result.rows[0].right?.index == 0)
        #expect(result.rows[0].cells.map(\.status) == [.same, .same, .modified])
    }

    @Test("Missing key columns produce error rows instead of discarding records")
    func missingKeyColumns() {
        let options = TableComparisonOptions(alignment: .keyColumns([0, 1]))
        let result = TableComparisonEngine(options: options).compare(
            leftText: "a\nb,2\n",
            rightText: "b,2\n"
        )

        #expect(result.rows.map(\.status) == [.error, .same])
        #expect(result.rows[0].left?.index == 0)
        #expect(result.rows[1].left?.index == 1)
        #expect(result.rows[1].right?.index == 0)
        #expect(result.diagnostics.count == 1)
        #expect(result.diagnostics[0].code == .missingKeyColumn)
        #expect(result.diagnostics[0].side == .left)
        #expect(result.diagnostics[0].recordIndex == 0)
        #expect(result.diagnostics[0].fieldIndex == 1)
        #expect(result.statistics.errorRowCount == 1)
    }

    @Test("Parser diagnostics become visible error rows while parsed data remains comparable")
    func parserErrorsRemainVisible() {
        let result = TableComparisonEngine().compare(
            leftText: "a\"b,c\n",
            rightText: "\"a\"\"b\",c\n"
        )

        #expect(result.rows.map(\.status) == [.error, .same])
        #expect(result.rows[0].diagnostics.map(\.code) == [.unexpectedQuote])
        #expect(result.rows[0].left?.fields[0].value == "a\"b")
        #expect(result.rows[1].left?.fields[0].value == "a\"b")
        #expect(result.diagnostics.map(\.side) == [.left])
        #expect(result.statistics.errorRowCount == 1)
        #expect(result.statistics.sameRowCount == 1)
    }

    @Test("Invalid comparison configuration returns explicit errors")
    func invalidConfiguration() {
        let options = TableComparisonOptions(
            alignment: .keyColumns([]),
            ignoredColumns: [-1]
        )
        let result = TableComparisonEngine(options: options).compare(
            leftText: "a\n",
            rightText: "a\n"
        )

        #expect(result.rows.map(\.status) == [.error, .error])
        #expect(result.diagnostics.map(\.code) == [
            .invalidConfiguration,
            .invalidConfiguration
        ])
        #expect(result.statistics.errorRowCount == 2)
    }

    @Test("Public table models satisfy strict Sendable constraints")
    func sendableModels() {
        func requireSendable<T: Sendable>(_: T.Type) {}

        requireSendable(TableSourceLocation.self)
        requireSendable(TableDiagnostic.self)
        requireSendable(TableField.self)
        requireSendable(TableRow.self)
        requireSendable(ParsedTable.self)
        requireSendable(DelimitedTextParser.self)
        requireSendable(TableComparisonOptions.self)
        requireSendable(TableCellComparison.self)
        requireSendable(TableComparisonRow.self)
        requireSendable(TableComparisonResult.self)
        requireSendable(TableComparisonEngine.self)
    }
}
