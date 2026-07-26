import Foundation
import Testing
@testable import RiffaCore

@Suite("Bounded delimited-text serialization")
struct DelimitedTextSerializerTests {
    @Test("RFC 4180 quoting and custom line endings are deterministic")
    func quoting() throws {
        let rows = [
            ["id", "note", "quote", "multiline", "empty"],
            ["1", "left|right", "say \"hi\"", "line 1\r\nline 2", ""]
        ]
        let serializer = DelimitedTextSerializer(
            delimiter: "|",
            lineEnding: .lineFeed
        )

        let output = try serializer.serialize(rows: rows)

        #expect(output == "id|note|quote|multiline|empty\n1|\"left|right\"|\"say \"\"hi\"\"\"|\"line 1\r\nline 2\"|")
        #expect(output.utf8.count <= serializer.limits.maximumOutputUTF8ByteCount)
    }

    @Test("Serialized fields round-trip through the parser")
    func roundTrip() throws {
        let rows = [
            ["plain", "comma,inside", "say \"hello\"", ""],
            ["跨平台", "line 1\nline 2", "carriage\rreturn", "tail"]
        ]
        let serializer = DelimitedTextSerializer(
            delimiter: ",",
            lineEnding: .carriageReturnLineFeed
        )
        let output = try serializer.serialize(rows: rows)
        let parsed = DelimitedTextParser().parse(output)

        #expect(parsed.diagnostics.isEmpty)
        #expect(parsed.rows.map { $0.fields.map(\.value) } == rows)
        #expect(output.contains("\r\n"))
    }

    @Test("Single empty fields survive first, middle, and final records")
    func emptyFieldRoundTrip() throws {
        let rows = [[""], ["value"], [""]]
        let output = try DelimitedTextSerializer(
            lineEnding: .lineFeed
        ).serialize(rows: rows)
        let parsed = DelimitedTextParser().parse(output)

        #expect(output == "\"\"\nvalue\n\"\"")
        #expect(parsed.rows.map { $0.fields.map(\.value) } == rows)
        #expect(throws: DelimitedTextSerializationError.self) {
            _ = try DelimitedTextSerializer().serialize(rows: [[]])
        }
    }

    @Test("Each supported record ending is emitted exactly")
    func lineEndings() throws {
        let rows = [["a"], ["b"]]

        #expect(try DelimitedTextSerializer(lineEnding: .lineFeed).serialize(rows: rows) == "a\nb")
        #expect(try DelimitedTextSerializer(lineEnding: .carriageReturn).serialize(rows: rows) == "a\rb")
        #expect(try DelimitedTextSerializer(lineEnding: .carriageReturnLineFeed).serialize(rows: rows) == "a\r\nb")
    }

    @Test("Final LF, CRLF, CR, and no terminator round-trip exactly")
    func finalRecordTerminatorRoundTrip() throws {
        let cases: [(String, DelimitedTextLineEnding, Bool)] = [
            ("a,b\n", .lineFeed, true),
            ("a,b\r\n", .carriageReturnLineFeed, true),
            ("a,b\r", .carriageReturn, true),
            ("a,b", .lineFeed, false)
        ]

        for (source, lineEnding, terminatesLastRecord) in cases {
            let parsed = DelimitedTextParser().parse(source)
            let rows = parsed.rows.map { $0.fields.map(\.value) }
            let output = try DelimitedTextSerializer(
                lineEnding: lineEnding,
                terminatesLastRecord: terminatesLastRecord
            ).serialize(rows: rows)

            #expect(parsed.diagnostics.isEmpty)
            #expect(output == source)
        }
    }

    @Test("A final record terminator consumes output budget")
    func finalRecordTerminatorBudget() throws {
        let exact = DelimitedTextSerializer(
            lineEnding: .carriageReturnLineFeed,
            terminatesLastRecord: true,
            limits: try .init(maximumOutputUTF8ByteCount: 3)
        )
        #expect(try exact.serialize(rows: [["a"]]) == "a\r\n")

        try expectError(
            .outputUTF8ByteLimitExceeded,
            serializer: DelimitedTextSerializer(
                lineEnding: .carriageReturnLineFeed,
                terminatesLastRecord: true,
                limits: try .init(maximumOutputUTF8ByteCount: 2)
            ),
            rows: [["a"]]
        )
    }

    @Test("Non-positive limits and invalid delimiters fail before output")
    func invalidConfiguration() throws {
        let invalidLimits: [() throws -> DelimitedTextSerializationLimits] = [
            { try .init(maximumRowCount: 0) },
            { try .init(maximumFieldCountPerRow: 0) },
            { try .init(maximumTotalFieldCount: 0) },
            { try .init(maximumFieldUTF8ByteCount: 0) },
            { try .init(maximumOutputUTF8ByteCount: 0) }
        ]

        for makeLimits in invalidLimits {
            #expect(throws: DelimitedTextSerializationError.self) {
                _ = try makeLimits()
            }
        }

        do {
            _ = try DelimitedTextSerializer(delimiter: "\"").serialize(rows: [["a"]])
            Issue.record("Expected an invalid delimiter")
        } catch let error as DelimitedTextSerializationError {
            #expect(error.code == .invalidDelimiter)
        }
    }

    @Test("Every structural and UTF-8 budget is strict")
    func budgets() throws {
        try expectError(
            .rowLimitExceeded,
            serializer: DelimitedTextSerializer(
                limits: try .init(maximumRowCount: 1)
            ),
            rows: [["a"], ["b"]]
        )
        try expectError(
            .fieldCountPerRowExceeded,
            serializer: DelimitedTextSerializer(
                limits: try .init(maximumFieldCountPerRow: 1)
            ),
            rows: [["a", "b"]]
        )
        try expectError(
            .totalFieldLimitExceeded,
            serializer: DelimitedTextSerializer(
                limits: try .init(maximumTotalFieldCount: 2)
            ),
            rows: [["a", "b"], ["c"]]
        )
        try expectError(
            .fieldUTF8ByteLimitExceeded,
            serializer: DelimitedTextSerializer(
                limits: try .init(maximumFieldUTF8ByteCount: 3)
            ),
            rows: [["🙂"]]
        )
        try expectError(
            .outputUTF8ByteLimitExceeded,
            serializer: DelimitedTextSerializer(
                limits: try .init(maximumOutputUTF8ByteCount: 4)
            ),
            rows: [["a,b"]]
        )

        let exact = DelimitedTextSerializer(
            limits: try .init(
                maximumRowCount: 1,
                maximumFieldCountPerRow: 1,
                maximumTotalFieldCount: 1,
                maximumFieldUTF8ByteCount: 3,
                maximumOutputUTF8ByteCount: 3
            )
        )
        #expect(try exact.serialize(rows: [["abc"]]) == "abc")
    }

    @Test("Serializer configuration and path-free errors are Codable")
    func codable() throws {
        let serializer = DelimitedTextSerializer(
            delimiter: "🧩",
            lineEnding: .carriageReturn,
            terminatesLastRecord: true,
            limits: try .init(maximumRowCount: 7)
        )
        let encoded = try JSONEncoder().encode(serializer)
        #expect(try JSONDecoder().decode(DelimitedTextSerializer.self, from: encoded) == serializer)

        let legacyConfiguration = Data(
            """
            {"delimiter":",","lineEnding":"\\n","limits":{"maximumFieldCountPerRow":1,"maximumFieldUTF8ByteCount":1,"maximumOutputUTF8ByteCount":1,"maximumRowCount":1,"maximumTotalFieldCount":1}}
            """.utf8
        )
        let legacySerializer = try JSONDecoder().decode(
            DelimitedTextSerializer.self,
            from: legacyConfiguration
        )
        #expect(legacySerializer.terminatesLastRecord == false)

        let error = DelimitedTextSerializationError(
            code: .fieldUTF8ByteLimitExceeded,
            rowIndex: 2,
            fieldIndex: 3,
            actualValue: 9,
            limit: 8
        )
        let errorData = try JSONEncoder().encode(error)
        #expect(try JSONDecoder().decode(DelimitedTextSerializationError.self, from: errorData) == error)
        #expect(!String(decoding: errorData, as: UTF8.self).contains("/"))

        let invalidDelimiter = Data(
            """
            {"delimiter":"ab","lineEnding":"\\n","limits":{"maximumFieldCountPerRow":1,"maximumFieldUTF8ByteCount":1,"maximumOutputUTF8ByteCount":1,"maximumRowCount":1,"maximumTotalFieldCount":1}}
            """.utf8
        )
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(DelimitedTextSerializer.self, from: invalidDelimiter)
        }

        let invalidLimits = Data(
            """
            {"maximumFieldCountPerRow":1,"maximumFieldUTF8ByteCount":1,"maximumOutputUTF8ByteCount":1,"maximumRowCount":0,"maximumTotalFieldCount":1}
            """.utf8
        )
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(
                DelimitedTextSerializationLimits.self,
                from: invalidLimits
            )
        }

        let invalidParsingLimits = Data(
            """
            {"maximumCharacterCount":1,"maximumDiagnosticCount":1,"maximumFieldCountPerRow":1,"maximumFieldUTF8ByteCount":1,"maximumInputUTF8ByteCount":1,"maximumRowCount":0,"maximumTotalFieldCount":1}
            """.utf8
        )
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(
                DelimitedTextParsingLimits.self,
                from: invalidParsingLimits
            )
        }
    }

    @Test("Public serializer models satisfy strict Sendable constraints")
    func sendable() {
        func requireSendable<T: Sendable>(_: T.Type) {}

        requireSendable(DelimitedTextLineEnding.self)
        requireSendable(DelimitedTextSerializationLimits.self)
        requireSendable(DelimitedTextSerializationError.self)
        requireSendable(DelimitedTextSerializer.self)
        requireSendable(DelimitedTextParsingLimits.self)
        requireSendable(DelimitedTextParsingError.self)
    }

    private func expectError(
        _ code: DelimitedTextSerializationError.Code,
        serializer: DelimitedTextSerializer,
        rows: [[String]]
    ) throws {
        do {
            _ = try serializer.serialize(rows: rows)
            Issue.record("Expected \(code.rawValue)")
        } catch let error as DelimitedTextSerializationError {
            #expect(error.code == code)
            #expect(error.errorDescription != nil)
        }
    }
}

@Suite("Bounded delimited-text parsing")
struct BoundedDelimitedTextParsingTests {
    @Test("Bounded overload preserves legacy quoted-field behavior")
    func compatibleOutput() throws {
        let source = "id,note\n1,\"a,b\"\n2,\"say \"\"hi\"\"\""
        let parser = DelimitedTextParser()
        let legacy = parser.parse(source)
        let bounded = try parser.parse(source, limits: .standard)

        #expect(bounded == legacy)
    }

    @Test("Parser preflight enforces input, character, row, field, and total budgets")
    func budgets() throws {
        try expectError(
            .inputUTF8ByteLimitExceeded,
            text: "abcd",
            limits: try .init(maximumInputUTF8ByteCount: 3)
        )
        try expectError(
            .characterLimitExceeded,
            text: "abcd",
            limits: try .init(maximumCharacterCount: 3)
        )
        try expectError(
            .rowLimitExceeded,
            text: "a\nb",
            limits: try .init(maximumRowCount: 1)
        )
        try expectError(
            .fieldCountPerRowExceeded,
            text: "a,b",
            limits: try .init(maximumFieldCountPerRow: 1)
        )
        try expectError(
            .totalFieldLimitExceeded,
            text: "a,b\nc",
            limits: try .init(maximumTotalFieldCount: 2)
        )
        try expectError(
            .fieldUTF8ByteLimitExceeded,
            text: "🙂",
            limits: try .init(maximumFieldUTF8ByteCount: 3)
        )
    }

    @Test("Quoted delimiters do not consume structural field budget")
    func quotedDelimiterBudget() throws {
        let result = try DelimitedTextParser().parse(
            "\"a,b,c\"",
            limits: try .init(maximumFieldCountPerRow: 1, maximumTotalFieldCount: 1)
        )
        #expect(result.rows.map { $0.fields.map(\.value) } == [["a,b,c"]])
    }

    @Test("Malformed-input diagnostics are bounded before parser allocation")
    func diagnosticBudget() throws {
        try expectError(
            .diagnosticLimitExceeded,
            text: "a\"b\"c",
            limits: try .init(maximumDiagnosticCount: 1)
        )
    }

    @Test("Non-positive parser limits fail explicitly")
    func invalidLimits() {
        #expect(throws: DelimitedTextParsingError.self) {
            _ = try DelimitedTextParsingLimits(maximumRowCount: 0)
        }
    }

    private func expectError(
        _ code: DelimitedTextParsingError.Code,
        text: String,
        limits: DelimitedTextParsingLimits
    ) throws {
        do {
            _ = try DelimitedTextParser().parse(text, limits: limits)
            Issue.record("Expected \(code.rawValue)")
        } catch let error as DelimitedTextParsingError {
            #expect(error.code == code)
            #expect(error.errorDescription != nil)
        }
    }
}

@Suite("Table edit candidate validation")
struct TableDraftValidatorTests {
    @Test("Key edits that would create duplicates are rejected before commit")
    func duplicateKeyMutation() throws {
        let validator = TableDraftValidator(
            alignment: .keyColumns([0]),
            ignoreCase: true,
            ignoreWhitespace: true
        )

        #expect(throws: TableDraftValidationError.self) {
            try validator.validate(rows: [[" A ", "one"], ["a", "two"]])
        }
        do {
            try validator.validate(rows: [["A", "one"], ["A", "two"]])
            Issue.record("Expected duplicate key rejection")
        } catch let error as TableDraftValidationError {
            #expect(error.code == .duplicateKey)
            #expect(error.rowIndex == 1)
            #expect(error.fieldIndex == 0)
        }
    }

    @Test("Missing key columns and invalid key configuration are rejected")
    func invalidKeys() throws {
        do {
            try TableDraftValidator(alignment: .keyColumns([1])).validate(rows: [["only"]])
            Issue.record("Expected missing key column")
        } catch let error as TableDraftValidationError {
            #expect(error.code == .missingKeyColumn)
            #expect(error.rowIndex == 0)
            #expect(error.fieldIndex == 1)
        }

        do {
            try TableDraftValidator(alignment: .keyColumns([0, 0])).validate(rows: [["a"]])
            Issue.record("Expected invalid key configuration")
        } catch let error as TableDraftValidationError {
            #expect(error.code == .invalidKeyColumns)
        }
    }

    @Test("Valid candidate rows pass structural and composite-key validation")
    func validCandidate() throws {
        let limits = try DelimitedTextSerializationLimits(
            maximumRowCount: 2,
            maximumFieldCountPerRow: 2,
            maximumTotalFieldCount: 4,
            maximumFieldUTF8ByteCount: 8,
            maximumOutputUTF8ByteCount: 32
        )
        let validator = TableDraftValidator(
            limits: limits,
            alignment: .keyColumns([0])
        )

        try validator.validate(rows: [["a", "one"], ["b", "two"]])
    }
}
