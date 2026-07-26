import Foundation

/// A one-based source position plus a zero-based extended-grapheme offset.
public struct TableSourceLocation: Hashable, Sendable {
    public let offset: Int
    public let line: Int
    public let column: Int

    public init(offset: Int, line: Int, column: Int) {
        self.offset = offset
        self.line = line
        self.column = column
    }
}

public enum TableDiagnosticCode: String, Hashable, Sendable {
    case invalidDelimiter
    case unexpectedQuote
    case unexpectedCharacterAfterClosingQuote
    case unterminatedQuotedField
    case invalidConfiguration
    case missingKeyColumn
    case duplicateKey
}

public enum TableSide: String, Hashable, Sendable {
    case left
    case right
}

/// A parser or comparison diagnostic. Record and field indices are zero-based;
/// source line and column are one-based.
public struct TableDiagnostic: Hashable, Sendable {
    public let code: TableDiagnosticCode
    public let message: String
    public let location: TableSourceLocation
    public let recordIndex: Int?
    public let fieldIndex: Int?
    public let side: TableSide?

    public init(
        code: TableDiagnosticCode,
        message: String,
        location: TableSourceLocation,
        recordIndex: Int? = nil,
        fieldIndex: Int? = nil,
        side: TableSide? = nil
    ) {
        self.code = code
        self.message = message
        self.location = location
        self.recordIndex = recordIndex
        self.fieldIndex = fieldIndex
        self.side = side
    }

    fileprivate func attributed(to side: TableSide) -> TableDiagnostic {
        TableDiagnostic(
            code: code,
            message: message,
            location: location,
            recordIndex: recordIndex,
            fieldIndex: fieldIndex,
            side: side
        )
    }
}

public struct TableField: Hashable, Sendable {
    public let value: String
    public let columnIndex: Int
    public let location: TableSourceLocation

    public init(value: String, columnIndex: Int, location: TableSourceLocation) {
        self.value = value
        self.columnIndex = columnIndex
        self.location = location
    }
}

public struct TableRow: Identifiable, Hashable, Sendable {
    public let index: Int
    public let fields: [TableField]
    public let location: TableSourceLocation

    public init(index: Int, fields: [TableField], location: TableSourceLocation) {
        self.index = index
        self.fields = fields
        self.location = location
    }

    public var id: Int { index }

    public subscript(column columnIndex: Int) -> TableField? {
        guard fields.indices.contains(columnIndex) else { return nil }
        return fields[columnIndex]
    }
}

public struct ParsedTable: Hashable, Sendable {
    public let rows: [TableRow]
    public let diagnostics: [TableDiagnostic]
    public let delimiter: Character

    public init(
        rows: [TableRow],
        diagnostics: [TableDiagnostic],
        delimiter: Character
    ) {
        self.rows = rows
        self.diagnostics = diagnostics
        self.delimiter = delimiter
    }

    public var hasErrors: Bool { !diagnostics.isEmpty }
}

public enum DelimitedTextLineEnding: String, CaseIterable, Hashable, Codable, Sendable {
    case lineFeed = "\n"
    case carriageReturnLineFeed = "\r\n"
    case carriageReturn = "\r"

    public var text: String { rawValue }
}

public struct DelimitedTextSerializationLimits: Hashable, Codable, Sendable {
    public static let defaultMaximumRowCount = 250_000
    public static let defaultMaximumFieldCountPerRow = 4_096
    public static let defaultMaximumTotalFieldCount = 4_000_000
    public static let defaultMaximumFieldUTF8ByteCount = 4 * 1_024 * 1_024
    public static let defaultMaximumOutputUTF8ByteCount = 32 * 1_024 * 1_024

    public let maximumRowCount: Int
    public let maximumFieldCountPerRow: Int
    public let maximumTotalFieldCount: Int
    public let maximumFieldUTF8ByteCount: Int
    public let maximumOutputUTF8ByteCount: Int

    public static let standard = Self(
        uncheckedMaximumRowCount: Self.defaultMaximumRowCount,
        maximumFieldCountPerRow: Self.defaultMaximumFieldCountPerRow,
        maximumTotalFieldCount: Self.defaultMaximumTotalFieldCount,
        maximumFieldUTF8ByteCount: Self.defaultMaximumFieldUTF8ByteCount,
        maximumOutputUTF8ByteCount: Self.defaultMaximumOutputUTF8ByteCount
    )

    private enum CodingKeys: String, CodingKey {
        case maximumRowCount
        case maximumFieldCountPerRow
        case maximumTotalFieldCount
        case maximumFieldUTF8ByteCount
        case maximumOutputUTF8ByteCount
    }

    public init(
        maximumRowCount: Int = Self.defaultMaximumRowCount,
        maximumFieldCountPerRow: Int = Self.defaultMaximumFieldCountPerRow,
        maximumTotalFieldCount: Int = Self.defaultMaximumTotalFieldCount,
        maximumFieldUTF8ByteCount: Int = Self.defaultMaximumFieldUTF8ByteCount,
        maximumOutputUTF8ByteCount: Int = Self.defaultMaximumOutputUTF8ByteCount
    ) throws {
        guard maximumRowCount > 0,
              maximumFieldCountPerRow > 0,
              maximumTotalFieldCount > 0,
              maximumFieldUTF8ByteCount > 0,
              maximumOutputUTF8ByteCount > 0
        else {
            throw DelimitedTextSerializationError(code: .invalidLimits)
        }
        self.init(
            uncheckedMaximumRowCount: maximumRowCount,
            maximumFieldCountPerRow: maximumFieldCountPerRow,
            maximumTotalFieldCount: maximumTotalFieldCount,
            maximumFieldUTF8ByteCount: maximumFieldUTF8ByteCount,
            maximumOutputUTF8ByteCount: maximumOutputUTF8ByteCount
        )
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                maximumRowCount: container.decode(Int.self, forKey: .maximumRowCount),
                maximumFieldCountPerRow: container.decode(Int.self, forKey: .maximumFieldCountPerRow),
                maximumTotalFieldCount: container.decode(Int.self, forKey: .maximumTotalFieldCount),
                maximumFieldUTF8ByteCount: container.decode(Int.self, forKey: .maximumFieldUTF8ByteCount),
                maximumOutputUTF8ByteCount: container.decode(Int.self, forKey: .maximumOutputUTF8ByteCount)
            )
        } catch let error as DelimitedTextSerializationError {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: error.localizedDescription,
                    underlyingError: error
                )
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(maximumRowCount, forKey: .maximumRowCount)
        try container.encode(maximumFieldCountPerRow, forKey: .maximumFieldCountPerRow)
        try container.encode(maximumTotalFieldCount, forKey: .maximumTotalFieldCount)
        try container.encode(maximumFieldUTF8ByteCount, forKey: .maximumFieldUTF8ByteCount)
        try container.encode(maximumOutputUTF8ByteCount, forKey: .maximumOutputUTF8ByteCount)
    }

    private init(
        uncheckedMaximumRowCount maximumRowCount: Int,
        maximumFieldCountPerRow: Int,
        maximumTotalFieldCount: Int,
        maximumFieldUTF8ByteCount: Int,
        maximumOutputUTF8ByteCount: Int
    ) {
        self.maximumRowCount = maximumRowCount
        self.maximumFieldCountPerRow = maximumFieldCountPerRow
        self.maximumTotalFieldCount = maximumTotalFieldCount
        self.maximumFieldUTF8ByteCount = maximumFieldUTF8ByteCount
        self.maximumOutputUTF8ByteCount = maximumOutputUTF8ByteCount
    }
}

public struct DelimitedTextSerializationError: Error, Hashable, Codable, Sendable, LocalizedError {
    public enum Code: String, Hashable, Codable, Sendable {
        case invalidLimits
        case invalidDelimiter
        case emptyRow
        case rowLimitExceeded
        case fieldCountPerRowExceeded
        case totalFieldLimitExceeded
        case fieldUTF8ByteLimitExceeded
        case outputUTF8ByteLimitExceeded
        case arithmeticOverflow
    }

    public let code: Code
    public let rowIndex: Int?
    public let fieldIndex: Int?
    public let actualValue: Int?
    public let limit: Int?

    public init(
        code: Code,
        rowIndex: Int? = nil,
        fieldIndex: Int? = nil,
        actualValue: Int? = nil,
        limit: Int? = nil
    ) {
        self.code = code
        self.rowIndex = rowIndex
        self.fieldIndex = fieldIndex
        self.actualValue = actualValue
        self.limit = limit
    }

    public var errorDescription: String? {
        switch code {
        case .invalidLimits:
            "Delimited-text serialization limits must all be greater than zero."
        case .invalidDelimiter:
            "The delimiter cannot be a quote or line-ending character."
        case .emptyRow:
            "A delimited-text row must contain at least one field."
        case .rowLimitExceeded:
            "The table contains more rows than the serialization limit."
        case .fieldCountPerRowExceeded:
            "A table row contains more fields than the serialization limit."
        case .totalFieldLimitExceeded:
            "The table contains more total fields than the serialization limit."
        case .fieldUTF8ByteLimitExceeded:
            "A table field exceeds the serialization UTF-8 byte limit."
        case .outputUTF8ByteLimitExceeded:
            "The serialized table exceeds the output UTF-8 byte limit."
        case .arithmeticOverflow:
            "Delimited-text serialization size arithmetic overflowed."
        }
    }
}

/// A bounded RFC 4180-style serializer. Fields containing a delimiter, quote,
/// CR, or LF are quoted and embedded quotes are doubled.
public struct DelimitedTextSerializer: Hashable, Codable, Sendable {
    public let delimiter: Character
    public let lineEnding: DelimitedTextLineEnding
    /// Whether the serialized final record is followed by `lineEnding`.
    /// This is opt-in so existing callers retain their previous output.
    public let terminatesLastRecord: Bool
    public let limits: DelimitedTextSerializationLimits

    private enum CodingKeys: String, CodingKey {
        case delimiter
        case lineEnding
        case terminatesLastRecord
        case limits
    }

    public init(
        delimiter: Character = ",",
        lineEnding: DelimitedTextLineEnding = .carriageReturnLineFeed,
        terminatesLastRecord: Bool = false,
        limits: DelimitedTextSerializationLimits = .standard
    ) {
        self.delimiter = delimiter
        self.lineEnding = lineEnding
        self.terminatesLastRecord = terminatesLastRecord
        self.limits = limits
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let delimiterString = try container.decode(String.self, forKey: .delimiter)
        guard delimiterString.count == 1, let delimiter = delimiterString.first else {
            throw DecodingError.dataCorruptedError(
                forKey: .delimiter,
                in: container,
                debugDescription: "A delimiter must contain exactly one extended grapheme cluster."
            )
        }
        self.delimiter = delimiter
        lineEnding = try container.decode(DelimitedTextLineEnding.self, forKey: .lineEnding)
        terminatesLastRecord = try container.decodeIfPresent(
            Bool.self,
            forKey: .terminatesLastRecord
        ) ?? false
        limits = try container.decode(DelimitedTextSerializationLimits.self, forKey: .limits)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(String(delimiter), forKey: .delimiter)
        try container.encode(lineEnding, forKey: .lineEnding)
        try container.encode(terminatesLastRecord, forKey: .terminatesLastRecord)
        try container.encode(limits, forKey: .limits)
    }

    public func serialize(rows: [[String]]) throws -> String {
        try validateConfiguration()
        guard rows.count <= limits.maximumRowCount else {
            throw DelimitedTextSerializationError(
                code: .rowLimitExceeded,
                actualValue: rows.count,
                limit: limits.maximumRowCount
            )
        }

        var output = ""
        output.reserveCapacity(min(limits.maximumOutputUTF8ByteCount, 64 * 1_024))
        var outputByteCount = 0
        var totalFieldCount = 0
        let delimiterText = String(delimiter)
        let delimiterByteCount = delimiterText.utf8.count
        let lineEndingByteCount = lineEnding.text.utf8.count

        func adding(_ left: Int, _ right: Int) throws -> Int {
            let (result, overflow) = left.addingReportingOverflow(right)
            guard !overflow else {
                throw DelimitedTextSerializationError(code: .arithmeticOverflow)
            }
            return result
        }

        func reserveOutputBytes(
            _ byteCount: Int,
            rowIndex: Int? = nil,
            fieldIndex: Int? = nil
        ) throws {
            let attempted = try adding(outputByteCount, byteCount)
            guard attempted <= limits.maximumOutputUTF8ByteCount else {
                throw DelimitedTextSerializationError(
                    code: .outputUTF8ByteLimitExceeded,
                    rowIndex: rowIndex,
                    fieldIndex: fieldIndex,
                    actualValue: attempted,
                    limit: limits.maximumOutputUTF8ByteCount
                )
            }
            outputByteCount = attempted
        }

        for (rowIndex, row) in rows.enumerated() {
            guard !row.isEmpty else {
                throw DelimitedTextSerializationError(
                    code: .emptyRow,
                    rowIndex: rowIndex
                )
            }
            guard row.count <= limits.maximumFieldCountPerRow else {
                throw DelimitedTextSerializationError(
                    code: .fieldCountPerRowExceeded,
                    rowIndex: rowIndex,
                    actualValue: row.count,
                    limit: limits.maximumFieldCountPerRow
                )
            }
            totalFieldCount = try adding(totalFieldCount, row.count)
            guard totalFieldCount <= limits.maximumTotalFieldCount else {
                throw DelimitedTextSerializationError(
                    code: .totalFieldLimitExceeded,
                    rowIndex: rowIndex,
                    actualValue: totalFieldCount,
                    limit: limits.maximumTotalFieldCount
                )
            }

            if rowIndex > 0 {
                try reserveOutputBytes(lineEndingByteCount, rowIndex: rowIndex)
                output += lineEnding.text
            }

            for (fieldIndex, field) in row.enumerated() {
                if fieldIndex > 0 {
                    try reserveOutputBytes(
                        delimiterByteCount,
                        rowIndex: rowIndex,
                        fieldIndex: fieldIndex
                    )
                    output += delimiterText
                }

                let fieldByteCount = field.utf8.count
                guard fieldByteCount <= limits.maximumFieldUTF8ByteCount else {
                    throw DelimitedTextSerializationError(
                        code: .fieldUTF8ByteLimitExceeded,
                        rowIndex: rowIndex,
                        fieldIndex: fieldIndex,
                        actualValue: fieldByteCount,
                        limit: limits.maximumFieldUTF8ByteCount
                    )
                }

                let needsQuotes = (row.count == 1 && field.isEmpty)
                    || field.contains(delimiter)
                    || field.contains("\"")
                    || field.contains("\r")
                    || field.contains("\n")
                    || field.contains("\r\n")
                if needsQuotes {
                    let quoteCount = field.reduce(into: 0) { count, character in
                        if character == "\"" { count += 1 }
                    }
                    let quotedByteCount = try adding(try adding(fieldByteCount, quoteCount), 2)
                    try reserveOutputBytes(
                        quotedByteCount,
                        rowIndex: rowIndex,
                        fieldIndex: fieldIndex
                    )
                    output.append("\"")
                    output += field.replacingOccurrences(of: "\"", with: "\"\"")
                    output.append("\"")
                } else {
                    try reserveOutputBytes(
                        fieldByteCount,
                        rowIndex: rowIndex,
                        fieldIndex: fieldIndex
                    )
                    output += field
                }
            }
        }

        if terminatesLastRecord, !rows.isEmpty {
            try reserveOutputBytes(
                lineEndingByteCount,
                rowIndex: rows.count - 1
            )
            output += lineEnding.text
        }

        return output
    }

    private func validateConfiguration() throws {
        guard limits.maximumRowCount > 0,
              limits.maximumFieldCountPerRow > 0,
              limits.maximumTotalFieldCount > 0,
              limits.maximumFieldUTF8ByteCount > 0,
              limits.maximumOutputUTF8ByteCount > 0
        else {
            throw DelimitedTextSerializationError(code: .invalidLimits)
        }
        guard delimiter != "\"",
              delimiter != "\r",
              delimiter != "\n",
              delimiter != "\r\n"
        else {
            throw DelimitedTextSerializationError(code: .invalidDelimiter)
        }
    }
}

public struct DelimitedTextParsingLimits: Hashable, Codable, Sendable {
    public static let defaultMaximumInputUTF8ByteCount = 32 * 1_024 * 1_024
    public static let defaultMaximumCharacterCount = 8 * 1_024 * 1_024
    public static let defaultMaximumRowCount = 250_000
    public static let defaultMaximumFieldCountPerRow = 4_096
    public static let defaultMaximumTotalFieldCount = 4_000_000
    public static let defaultMaximumFieldUTF8ByteCount = 4 * 1_024 * 1_024
    public static let defaultMaximumDiagnosticCount = 10_000

    public let maximumInputUTF8ByteCount: Int
    public let maximumCharacterCount: Int
    public let maximumRowCount: Int
    public let maximumFieldCountPerRow: Int
    public let maximumTotalFieldCount: Int
    public let maximumFieldUTF8ByteCount: Int
    public let maximumDiagnosticCount: Int

    public static let standard = Self(
        uncheckedMaximumInputUTF8ByteCount: Self.defaultMaximumInputUTF8ByteCount,
        maximumCharacterCount: Self.defaultMaximumCharacterCount,
        maximumRowCount: Self.defaultMaximumRowCount,
        maximumFieldCountPerRow: Self.defaultMaximumFieldCountPerRow,
        maximumTotalFieldCount: Self.defaultMaximumTotalFieldCount,
        maximumFieldUTF8ByteCount: Self.defaultMaximumFieldUTF8ByteCount,
        maximumDiagnosticCount: Self.defaultMaximumDiagnosticCount
    )

    private enum CodingKeys: String, CodingKey {
        case maximumInputUTF8ByteCount
        case maximumCharacterCount
        case maximumRowCount
        case maximumFieldCountPerRow
        case maximumTotalFieldCount
        case maximumFieldUTF8ByteCount
        case maximumDiagnosticCount
    }

    public init(
        maximumInputUTF8ByteCount: Int = Self.defaultMaximumInputUTF8ByteCount,
        maximumCharacterCount: Int = Self.defaultMaximumCharacterCount,
        maximumRowCount: Int = Self.defaultMaximumRowCount,
        maximumFieldCountPerRow: Int = Self.defaultMaximumFieldCountPerRow,
        maximumTotalFieldCount: Int = Self.defaultMaximumTotalFieldCount,
        maximumFieldUTF8ByteCount: Int = Self.defaultMaximumFieldUTF8ByteCount,
        maximumDiagnosticCount: Int = Self.defaultMaximumDiagnosticCount
    ) throws {
        guard maximumInputUTF8ByteCount > 0,
              maximumCharacterCount > 0,
              maximumRowCount > 0,
              maximumFieldCountPerRow > 0,
              maximumTotalFieldCount > 0,
              maximumFieldUTF8ByteCount > 0,
              maximumDiagnosticCount > 0
        else {
            throw DelimitedTextParsingError(code: .invalidLimits)
        }
        self.init(
            uncheckedMaximumInputUTF8ByteCount: maximumInputUTF8ByteCount,
            maximumCharacterCount: maximumCharacterCount,
            maximumRowCount: maximumRowCount,
            maximumFieldCountPerRow: maximumFieldCountPerRow,
            maximumTotalFieldCount: maximumTotalFieldCount,
            maximumFieldUTF8ByteCount: maximumFieldUTF8ByteCount,
            maximumDiagnosticCount: maximumDiagnosticCount
        )
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                maximumInputUTF8ByteCount: container.decode(Int.self, forKey: .maximumInputUTF8ByteCount),
                maximumCharacterCount: container.decode(Int.self, forKey: .maximumCharacterCount),
                maximumRowCount: container.decode(Int.self, forKey: .maximumRowCount),
                maximumFieldCountPerRow: container.decode(Int.self, forKey: .maximumFieldCountPerRow),
                maximumTotalFieldCount: container.decode(Int.self, forKey: .maximumTotalFieldCount),
                maximumFieldUTF8ByteCount: container.decode(Int.self, forKey: .maximumFieldUTF8ByteCount),
                maximumDiagnosticCount: container.decode(Int.self, forKey: .maximumDiagnosticCount)
            )
        } catch let error as DelimitedTextParsingError {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: error.localizedDescription,
                    underlyingError: error
                )
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(maximumInputUTF8ByteCount, forKey: .maximumInputUTF8ByteCount)
        try container.encode(maximumCharacterCount, forKey: .maximumCharacterCount)
        try container.encode(maximumRowCount, forKey: .maximumRowCount)
        try container.encode(maximumFieldCountPerRow, forKey: .maximumFieldCountPerRow)
        try container.encode(maximumTotalFieldCount, forKey: .maximumTotalFieldCount)
        try container.encode(maximumFieldUTF8ByteCount, forKey: .maximumFieldUTF8ByteCount)
        try container.encode(maximumDiagnosticCount, forKey: .maximumDiagnosticCount)
    }

    private init(
        uncheckedMaximumInputUTF8ByteCount maximumInputUTF8ByteCount: Int,
        maximumCharacterCount: Int,
        maximumRowCount: Int,
        maximumFieldCountPerRow: Int,
        maximumTotalFieldCount: Int,
        maximumFieldUTF8ByteCount: Int,
        maximumDiagnosticCount: Int
    ) {
        self.maximumInputUTF8ByteCount = maximumInputUTF8ByteCount
        self.maximumCharacterCount = maximumCharacterCount
        self.maximumRowCount = maximumRowCount
        self.maximumFieldCountPerRow = maximumFieldCountPerRow
        self.maximumTotalFieldCount = maximumTotalFieldCount
        self.maximumFieldUTF8ByteCount = maximumFieldUTF8ByteCount
        self.maximumDiagnosticCount = maximumDiagnosticCount
    }
}

public struct DelimitedTextParsingError: Error, Hashable, Codable, Sendable, LocalizedError {
    public enum Code: String, Hashable, Codable, Sendable {
        case invalidLimits
        case inputUTF8ByteLimitExceeded
        case characterLimitExceeded
        case rowLimitExceeded
        case fieldCountPerRowExceeded
        case totalFieldLimitExceeded
        case fieldUTF8ByteLimitExceeded
        case diagnosticLimitExceeded
        case arithmeticOverflow
    }

    public let code: Code
    public let rowIndex: Int?
    public let fieldIndex: Int?
    public let actualValue: Int?
    public let limit: Int?

    public init(
        code: Code,
        rowIndex: Int? = nil,
        fieldIndex: Int? = nil,
        actualValue: Int? = nil,
        limit: Int? = nil
    ) {
        self.code = code
        self.rowIndex = rowIndex
        self.fieldIndex = fieldIndex
        self.actualValue = actualValue
        self.limit = limit
    }

    public var errorDescription: String? {
        switch code {
        case .invalidLimits:
            "Delimited-text parsing limits must all be greater than zero."
        case .inputUTF8ByteLimitExceeded:
            "The delimited text exceeds the input UTF-8 byte limit."
        case .characterLimitExceeded:
            "The delimited text exceeds the character limit."
        case .rowLimitExceeded:
            "The delimited text exceeds the row limit."
        case .fieldCountPerRowExceeded:
            "A delimited-text row exceeds the field-count limit."
        case .totalFieldLimitExceeded:
            "The delimited text exceeds the total-field limit."
        case .fieldUTF8ByteLimitExceeded:
            "A delimited-text field exceeds the UTF-8 byte limit."
        case .diagnosticLimitExceeded:
            "The malformed delimited text exceeds the diagnostic limit."
        case .arithmeticOverflow:
            "Delimited-text parsing size arithmetic overflowed."
        }
    }
}

/// A loss-preserving RFC 4180-style parser. It accepts CR, LF, and CRLF
/// records, retains line endings inside quoted fields, and reports malformed
/// quoting while keeping every character that can be represented in a field.
public struct DelimitedTextParser: Sendable {
    public let delimiter: Character

    public init(delimiter: Character = ",") {
        self.delimiter = delimiter
    }

    /// Bounded parsing that preserves the legacy parser's diagnostics and
    /// output while rejecting oversized inputs before row/field arrays are
    /// allocated.
    public func parse(
        _ text: String,
        limits: DelimitedTextParsingLimits
    ) throws -> ParsedTable {
        try preflight(text, limits: limits)
        return parse(text)
    }

    public func parse(_ text: String) -> ParsedTable {
        let origin = TableSourceLocation(offset: 0, line: 1, column: 1)
        guard delimiter != "\"",
              delimiter != "\r",
              delimiter != "\n",
              delimiter != "\r\n"
        else {
            return ParsedTable(
                rows: [],
                diagnostics: [
                    TableDiagnostic(
                        code: .invalidDelimiter,
                        message: "The delimiter cannot be a quote or line-ending character.",
                        location: origin,
                        recordIndex: 0,
                        fieldIndex: 0
                    )
                ],
                delimiter: delimiter
            )
        }

        let characters = Array(text)
        guard !characters.isEmpty else {
            return ParsedTable(rows: [], diagnostics: [], delimiter: delimiter)
        }

        enum State {
            case fieldStart
            case unquoted
            case quoted
            case afterClosingQuote
        }

        var rows: [TableRow] = []
        var diagnostics: [TableDiagnostic] = []
        var currentFields: [TableField] = []
        var fieldValue = ""
        var state = State.fieldStart
        var cursor = 0
        var line = 1
        var column = 1
        var offset = 0
        var rowStart = origin
        var fieldStart = origin
        var recordPending = false

        func location() -> TableSourceLocation {
            TableSourceLocation(offset: offset, line: line, column: column)
        }

        func appendDiagnostic(
            _ code: TableDiagnosticCode,
            _ message: String,
            at diagnosticLocation: TableSourceLocation
        ) {
            diagnostics.append(
                TableDiagnostic(
                    code: code,
                    message: message,
                    location: diagnosticLocation,
                    recordIndex: rows.count,
                    fieldIndex: currentFields.count
                )
            )
        }

        func finishField() {
            currentFields.append(
                TableField(
                    value: fieldValue,
                    columnIndex: currentFields.count,
                    location: fieldStart
                )
            )
            fieldValue = ""
            state = .fieldStart
        }

        func finishRecord() {
            finishField()
            rows.append(TableRow(index: rows.count, fields: currentFields, location: rowStart))
            currentFields = []
            recordPending = false
        }

        func consumeCharacter() {
            cursor += 1
            offset += 1
            column += 1
        }

        func consumeNewline() -> String {
            let newline: String
            if characters[cursor] == "\r\n" {
                newline = "\r\n"
                cursor += 1
                offset += 1
            } else if characters[cursor] == "\r",
               cursor + 1 < characters.count,
               characters[cursor + 1] == "\n"
            {
                newline = "\r\n"
                cursor += 2
                offset += 2
            } else {
                newline = String(characters[cursor])
                cursor += 1
                offset += 1
            }
            line += 1
            column = 1
            return newline
        }

        while cursor < characters.count {
            let character = characters[cursor]
            let currentLocation = location()
            let isNewline = character == "\r" || character == "\n" || character == "\r\n"

            switch state {
            case .fieldStart:
                if character == delimiter {
                    recordPending = true
                    finishField()
                    consumeCharacter()
                    fieldStart = location()
                } else if isNewline {
                    finishRecord()
                    _ = consumeNewline()
                    rowStart = location()
                    fieldStart = rowStart
                } else if character == "\"" {
                    recordPending = true
                    state = .quoted
                    consumeCharacter()
                } else {
                    recordPending = true
                    fieldValue.append(character)
                    state = .unquoted
                    consumeCharacter()
                }

            case .unquoted:
                if character == delimiter {
                    finishField()
                    consumeCharacter()
                    fieldStart = location()
                } else if isNewline {
                    finishRecord()
                    _ = consumeNewline()
                    rowStart = location()
                    fieldStart = rowStart
                } else {
                    if character == "\"" {
                        appendDiagnostic(
                            .unexpectedQuote,
                            "A quote may only open a field at the start of that field.",
                            at: currentLocation
                        )
                    }
                    fieldValue.append(character)
                    consumeCharacter()
                }

            case .quoted:
                if character == "\"" {
                    if cursor + 1 < characters.count, characters[cursor + 1] == "\"" {
                        fieldValue.append("\"")
                        consumeCharacter()
                        consumeCharacter()
                    } else {
                        state = .afterClosingQuote
                        consumeCharacter()
                    }
                } else if isNewline {
                    fieldValue += consumeNewline()
                } else {
                    fieldValue.append(character)
                    consumeCharacter()
                }

            case .afterClosingQuote:
                if character == delimiter {
                    finishField()
                    consumeCharacter()
                    fieldStart = location()
                } else if isNewline {
                    finishRecord()
                    _ = consumeNewline()
                    rowStart = location()
                    fieldStart = rowStart
                } else {
                    appendDiagnostic(
                        .unexpectedCharacterAfterClosingQuote,
                        "Only a delimiter or line ending may follow a closing quote.",
                        at: currentLocation
                    )
                    fieldValue.append(character)
                    state = .unquoted
                    consumeCharacter()
                }
            }
        }

        if state == .quoted {
            appendDiagnostic(
                .unterminatedQuotedField,
                "The quoted field reaches the end of input without a closing quote.",
                at: fieldStart
            )
        }

        if recordPending {
            finishRecord()
        }

        return ParsedTable(rows: rows, diagnostics: diagnostics, delimiter: delimiter)
    }

    private func preflight(
        _ text: String,
        limits: DelimitedTextParsingLimits
    ) throws {
        guard limits.maximumInputUTF8ByteCount > 0,
              limits.maximumCharacterCount > 0,
              limits.maximumRowCount > 0,
              limits.maximumFieldCountPerRow > 0,
              limits.maximumTotalFieldCount > 0,
              limits.maximumFieldUTF8ByteCount > 0,
              limits.maximumDiagnosticCount > 0
        else {
            throw DelimitedTextParsingError(code: .invalidLimits)
        }

        let inputByteCount = text.utf8.count
        guard inputByteCount <= limits.maximumInputUTF8ByteCount else {
            throw DelimitedTextParsingError(
                code: .inputUTF8ByteLimitExceeded,
                actualValue: inputByteCount,
                limit: limits.maximumInputUTF8ByteCount
            )
        }
        let characterCount = text.count
        guard characterCount <= limits.maximumCharacterCount else {
            throw DelimitedTextParsingError(
                code: .characterLimitExceeded,
                actualValue: characterCount,
                limit: limits.maximumCharacterCount
            )
        }

        // Invalid delimiters are represented by the legacy parser's explicit
        // diagnostic rather than by a new throwing behavior.
        guard delimiter != "\"",
              delimiter != "\r",
              delimiter != "\n",
              delimiter != "\r\n"
        else { return }
        guard !text.isEmpty else { return }

        enum State {
            case fieldStart
            case unquoted
            case quoted
            case afterClosingQuote
        }

        var state = State.fieldStart
        var rowCount = 0
        var fieldsInRow = 0
        var totalFieldCount = 0
        var fieldByteCount = 0
        var diagnosticCount = 0
        var recordPending = false

        func checkedAdd(_ left: Int, _ right: Int) throws -> Int {
            let (result, overflow) = left.addingReportingOverflow(right)
            guard !overflow else {
                throw DelimitedTextParsingError(code: .arithmeticOverflow)
            }
            return result
        }

        func appendFieldBytes(_ byteCount: Int) throws {
            let attempted = try checkedAdd(fieldByteCount, byteCount)
            guard attempted <= limits.maximumFieldUTF8ByteCount else {
                throw DelimitedTextParsingError(
                    code: .fieldUTF8ByteLimitExceeded,
                    rowIndex: rowCount,
                    fieldIndex: fieldsInRow,
                    actualValue: attempted,
                    limit: limits.maximumFieldUTF8ByteCount
                )
            }
            fieldByteCount = attempted
        }

        func appendDiagnostic() throws {
            diagnosticCount = try checkedAdd(diagnosticCount, 1)
            guard diagnosticCount <= limits.maximumDiagnosticCount else {
                throw DelimitedTextParsingError(
                    code: .diagnosticLimitExceeded,
                    rowIndex: rowCount,
                    fieldIndex: fieldsInRow,
                    actualValue: diagnosticCount,
                    limit: limits.maximumDiagnosticCount
                )
            }
        }

        func finishField() throws {
            fieldsInRow = try checkedAdd(fieldsInRow, 1)
            guard fieldsInRow <= limits.maximumFieldCountPerRow else {
                throw DelimitedTextParsingError(
                    code: .fieldCountPerRowExceeded,
                    rowIndex: rowCount,
                    actualValue: fieldsInRow,
                    limit: limits.maximumFieldCountPerRow
                )
            }
            totalFieldCount = try checkedAdd(totalFieldCount, 1)
            guard totalFieldCount <= limits.maximumTotalFieldCount else {
                throw DelimitedTextParsingError(
                    code: .totalFieldLimitExceeded,
                    rowIndex: rowCount,
                    actualValue: totalFieldCount,
                    limit: limits.maximumTotalFieldCount
                )
            }
            fieldByteCount = 0
            state = .fieldStart
        }

        func finishRecord() throws {
            try finishField()
            rowCount = try checkedAdd(rowCount, 1)
            guard rowCount <= limits.maximumRowCount else {
                throw DelimitedTextParsingError(
                    code: .rowLimitExceeded,
                    actualValue: rowCount,
                    limit: limits.maximumRowCount
                )
            }
            fieldsInRow = 0
            recordPending = false
        }

        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let nextIndex = text.index(after: index)
            let isNewline = character == "\r"
                || character == "\n"
                || character == "\r\n"

            switch state {
            case .fieldStart:
                if character == delimiter {
                    recordPending = true
                    try finishField()
                } else if isNewline {
                    try finishRecord()
                } else if character == "\"" {
                    recordPending = true
                    state = .quoted
                } else {
                    recordPending = true
                    try appendFieldBytes(character.utf8.count)
                    state = .unquoted
                }

            case .unquoted:
                if character == delimiter {
                    try finishField()
                } else if isNewline {
                    try finishRecord()
                } else {
                    if character == "\"" { try appendDiagnostic() }
                    try appendFieldBytes(character.utf8.count)
                }

            case .quoted:
                if character == "\"" {
                    if nextIndex < text.endIndex, text[nextIndex] == "\"" {
                        try appendFieldBytes(1)
                        index = text.index(after: nextIndex)
                        continue
                    }
                    state = .afterClosingQuote
                } else {
                    try appendFieldBytes(character.utf8.count)
                }

            case .afterClosingQuote:
                if character == delimiter {
                    try finishField()
                } else if isNewline {
                    try finishRecord()
                } else {
                    try appendDiagnostic()
                    try appendFieldBytes(character.utf8.count)
                    state = .unquoted
                }
            }
            index = nextIndex
        }

        if state == .quoted { try appendDiagnostic() }
        if recordPending { try finishRecord() }
    }
}

public enum TableRowAlignment: Hashable, Sendable {
    case rowNumber
    case keyColumns([Int])
}

public struct TableComparisonOptions: Hashable, Sendable {
    public var alignment: TableRowAlignment
    public var ignoredColumns: Set<Int>
    public var ignoreCase: Bool
    public var ignoreWhitespace: Bool

    public init(
        alignment: TableRowAlignment = .rowNumber,
        ignoredColumns: Set<Int> = [],
        ignoreCase: Bool = false,
        ignoreWhitespace: Bool = false
    ) {
        self.alignment = alignment
        self.ignoredColumns = ignoredColumns
        self.ignoreCase = ignoreCase
        self.ignoreWhitespace = ignoreWhitespace
    }
}

public struct TableDraftValidationError: Error, Hashable, Codable, Sendable, LocalizedError {
    public enum Code: String, Hashable, Codable, Sendable {
        case rowLimitExceeded
        case emptyRow
        case fieldCountPerRowExceeded
        case totalFieldLimitExceeded
        case fieldUTF8ByteLimitExceeded
        case invalidKeyColumns
        case missingKeyColumn
        case duplicateKey
        case arithmeticOverflow
    }

    public let code: Code
    public let rowIndex: Int?
    public let fieldIndex: Int?
    public let actualValue: Int?
    public let limit: Int?

    public init(
        code: Code,
        rowIndex: Int? = nil,
        fieldIndex: Int? = nil,
        actualValue: Int? = nil,
        limit: Int? = nil
    ) {
        self.code = code
        self.rowIndex = rowIndex
        self.fieldIndex = fieldIndex
        self.actualValue = actualValue
        self.limit = limit
    }

    public var errorDescription: String? {
        switch code {
        case .rowLimitExceeded:
            "The edited table exceeds the row limit."
        case .emptyRow:
            "Each edited row must contain at least one field."
        case .fieldCountPerRowExceeded:
            "An edited row exceeds the per-row field limit."
        case .totalFieldLimitExceeded:
            "The edited table exceeds the total-field limit."
        case .fieldUTF8ByteLimitExceeded:
            "An edited field exceeds the UTF-8 byte limit."
        case .invalidKeyColumns:
            "Key columns must be unique non-negative indices."
        case .missingKeyColumn:
            "An edited row does not contain every configured key column."
        case .duplicateKey:
            "The edit would create a duplicate composite key."
        case .arithmeticOverflow:
            "Edited-table size arithmetic overflowed."
        }
    }
}

/// Validates a candidate in-memory table before an editor commits it. This is
/// deliberately independent of source paths and rejects key mutations that
/// would leave the UI in an ambiguous duplicate-key state.
public struct TableDraftValidator: Hashable, Sendable {
    public let limits: DelimitedTextSerializationLimits
    public let alignment: TableRowAlignment
    public let ignoreCase: Bool
    public let ignoreWhitespace: Bool

    public init(
        limits: DelimitedTextSerializationLimits = .standard,
        alignment: TableRowAlignment = .rowNumber,
        ignoreCase: Bool = false,
        ignoreWhitespace: Bool = false
    ) {
        self.limits = limits
        self.alignment = alignment
        self.ignoreCase = ignoreCase
        self.ignoreWhitespace = ignoreWhitespace
    }

    public func validate(rows: [[String]]) throws {
        guard rows.count <= limits.maximumRowCount else {
            throw TableDraftValidationError(
                code: .rowLimitExceeded,
                actualValue: rows.count,
                limit: limits.maximumRowCount
            )
        }

        var totalFields = 0
        for (rowIndex, row) in rows.enumerated() {
            guard !row.isEmpty else {
                throw TableDraftValidationError(code: .emptyRow, rowIndex: rowIndex)
            }
            guard row.count <= limits.maximumFieldCountPerRow else {
                throw TableDraftValidationError(
                    code: .fieldCountPerRowExceeded,
                    rowIndex: rowIndex,
                    actualValue: row.count,
                    limit: limits.maximumFieldCountPerRow
                )
            }
            let (attemptedTotal, overflow) = totalFields.addingReportingOverflow(row.count)
            guard !overflow else {
                throw TableDraftValidationError(code: .arithmeticOverflow, rowIndex: rowIndex)
            }
            guard attemptedTotal <= limits.maximumTotalFieldCount else {
                throw TableDraftValidationError(
                    code: .totalFieldLimitExceeded,
                    rowIndex: rowIndex,
                    actualValue: attemptedTotal,
                    limit: limits.maximumTotalFieldCount
                )
            }
            totalFields = attemptedTotal

            if let fieldIndex = row.firstIndex(where: {
                $0.utf8.count > limits.maximumFieldUTF8ByteCount
            }) {
                throw TableDraftValidationError(
                    code: .fieldUTF8ByteLimitExceeded,
                    rowIndex: rowIndex,
                    fieldIndex: fieldIndex,
                    actualValue: row[fieldIndex].utf8.count,
                    limit: limits.maximumFieldUTF8ByteCount
                )
            }
        }

        guard case let .keyColumns(columns) = alignment else { return }
        guard !columns.isEmpty,
              columns.allSatisfy({ $0 >= 0 }),
              Set(columns).count == columns.count else {
            throw TableDraftValidationError(code: .invalidKeyColumns)
        }

        var seenKeys: Set<[String]> = []
        for (rowIndex, row) in rows.enumerated() {
            guard let missingColumn = columns.first(where: { !row.indices.contains($0) }) else {
                let key = columns.map { normalize(row[$0]) }
                guard seenKeys.insert(key).inserted else {
                    throw TableDraftValidationError(
                        code: .duplicateKey,
                        rowIndex: rowIndex,
                        fieldIndex: columns.first
                    )
                }
                continue
            }
            throw TableDraftValidationError(
                code: .missingKeyColumn,
                rowIndex: rowIndex,
                fieldIndex: missingColumn
            )
        }
    }

    private func normalize(_ value: String) -> String {
        var normalized = value
        if ignoreWhitespace { normalized.removeAll(where: \.isWhitespace) }
        if ignoreCase { normalized = normalized.lowercased() }
        return normalized
    }
}

public enum TableCellStatus: String, Hashable, Sendable {
    case same
    case modified
    case leftOnly
    case rightOnly
    case ignored
}

public struct TableCellComparison: Identifiable, Hashable, Sendable {
    public let columnIndex: Int
    public let left: TableField?
    public let right: TableField?
    public let status: TableCellStatus

    public init(
        columnIndex: Int,
        left: TableField?,
        right: TableField?,
        status: TableCellStatus
    ) {
        self.columnIndex = columnIndex
        self.left = left
        self.right = right
        self.status = status
    }

    public var id: Int { columnIndex }
}

public enum TableRowStatus: String, Hashable, Sendable {
    case same
    case modified
    case leftOnly
    case rightOnly
    case duplicateKey
    case error
}

public struct TableComparisonRow: Identifiable, Hashable, Sendable {
    public let offset: Int
    public let status: TableRowStatus
    public let keyValues: [String]?
    public let left: TableRow?
    public let right: TableRow?
    public let cells: [TableCellComparison]
    public let diagnostics: [TableDiagnostic]

    public init(
        offset: Int,
        status: TableRowStatus,
        keyValues: [String]? = nil,
        left: TableRow?,
        right: TableRow?,
        cells: [TableCellComparison],
        diagnostics: [TableDiagnostic] = []
    ) {
        self.offset = offset
        self.status = status
        self.keyValues = keyValues
        self.left = left
        self.right = right
        self.cells = cells
        self.diagnostics = diagnostics
    }

    public var id: Int { offset }
}

public struct TableComparisonStatistics: Hashable, Sendable {
    public let sameRowCount: Int
    public let modifiedRowCount: Int
    public let leftOnlyRowCount: Int
    public let rightOnlyRowCount: Int
    public let duplicateKeyRowCount: Int
    public let errorRowCount: Int

    public init(
        sameRowCount: Int,
        modifiedRowCount: Int,
        leftOnlyRowCount: Int,
        rightOnlyRowCount: Int,
        duplicateKeyRowCount: Int,
        errorRowCount: Int
    ) {
        self.sameRowCount = sameRowCount
        self.modifiedRowCount = modifiedRowCount
        self.leftOnlyRowCount = leftOnlyRowCount
        self.rightOnlyRowCount = rightOnlyRowCount
        self.duplicateKeyRowCount = duplicateKeyRowCount
        self.errorRowCount = errorRowCount
    }

    public var totalRowCount: Int {
        sameRowCount
            + modifiedRowCount
            + leftOnlyRowCount
            + rightOnlyRowCount
            + duplicateKeyRowCount
            + errorRowCount
    }

    public var differenceRowCount: Int {
        modifiedRowCount
            + leftOnlyRowCount
            + rightOnlyRowCount
            + duplicateKeyRowCount
            + errorRowCount
    }

    fileprivate init(rows: [TableComparisonRow]) {
        var same = 0
        var modified = 0
        var leftOnly = 0
        var rightOnly = 0
        var duplicateKey = 0
        var error = 0

        for row in rows {
            switch row.status {
            case .same: same += 1
            case .modified: modified += 1
            case .leftOnly: leftOnly += 1
            case .rightOnly: rightOnly += 1
            case .duplicateKey: duplicateKey += 1
            case .error: error += 1
            }
        }

        self.init(
            sameRowCount: same,
            modifiedRowCount: modified,
            leftOnlyRowCount: leftOnly,
            rightOnlyRowCount: rightOnly,
            duplicateKeyRowCount: duplicateKey,
            errorRowCount: error
        )
    }
}

public struct TableComparisonResult: Hashable, Sendable {
    public let rows: [TableComparisonRow]
    public let diagnostics: [TableDiagnostic]
    public let statistics: TableComparisonStatistics

    public init(rows: [TableComparisonRow], diagnostics: [TableDiagnostic]) {
        self.rows = rows
        self.diagnostics = diagnostics
        statistics = TableComparisonStatistics(rows: rows)
    }

    public var hasDifferences: Bool { statistics.differenceRowCount > 0 }
}

/// Compares parsed delimited tables either by physical record position or by
/// a normalized composite key. Duplicate keys are never paired arbitrarily.
public struct TableComparisonEngine: Sendable {
    public let options: TableComparisonOptions

    public init(options: TableComparisonOptions = .init()) {
        self.options = options
    }

    public func compare(
        leftText: String,
        rightText: String,
        delimiter: Character = ","
    ) -> TableComparisonResult {
        let parser = DelimitedTextParser(delimiter: delimiter)
        return compare(left: parser.parse(leftText), right: parser.parse(rightText))
    }

    public func compare(
        leftText: String,
        rightText: String,
        delimiter: Character = ",",
        parsingLimits: DelimitedTextParsingLimits
    ) throws -> TableComparisonResult {
        let parser = DelimitedTextParser(delimiter: delimiter)
        return compare(
            left: try parser.parse(leftText, limits: parsingLimits),
            right: try parser.parse(rightText, limits: parsingLimits)
        )
    }

    public func compare(left: ParsedTable, right: ParsedTable) -> TableComparisonResult {
        var diagnostics = left.diagnostics.map { $0.attributed(to: .left) }
        diagnostics += right.diagnostics.map { $0.attributed(to: .right) }

        var payloads = parserErrorPayloads(for: left, side: .left)
        payloads += parserErrorPayloads(for: right, side: .right)

        let configurationDiagnostics = validateOptions()
        diagnostics += configurationDiagnostics
        if !configurationDiagnostics.isEmpty {
            payloads += configurationDiagnostics.map {
                RowPayload(
                    status: .error,
                    keyValues: nil,
                    left: nil,
                    right: nil,
                    cells: [],
                    diagnostics: [$0]
                )
            }
            return makeResult(payloads: payloads, diagnostics: diagnostics)
        }

        switch options.alignment {
        case .rowNumber:
            payloads += compareByRowNumber(left: left.rows, right: right.rows)
        case let .keyColumns(columns):
            let keyedResult = compareByKey(
                left: left.rows,
                right: right.rows,
                columns: columns
            )
            payloads += keyedResult.payloads
            diagnostics += keyedResult.diagnostics
        }

        return makeResult(payloads: payloads, diagnostics: diagnostics)
    }

    private func validateOptions() -> [TableDiagnostic] {
        let origin = TableSourceLocation(offset: 0, line: 1, column: 1)
        var diagnostics: [TableDiagnostic] = []

        if let invalidIgnoredColumn = options.ignoredColumns.sorted().first(where: { $0 < 0 }) {
            diagnostics.append(
                TableDiagnostic(
                    code: .invalidConfiguration,
                    message: "Ignored column indices must be non-negative; found \(invalidIgnoredColumn).",
                    location: origin,
                    fieldIndex: invalidIgnoredColumn
                )
            )
        }

        if case let .keyColumns(columns) = options.alignment {
            if columns.isEmpty {
                diagnostics.append(
                    TableDiagnostic(
                        code: .invalidConfiguration,
                        message: "Key alignment requires at least one key column.",
                        location: origin
                    )
                )
            }
            if let invalidColumn = columns.first(where: { $0 < 0 }) {
                diagnostics.append(
                    TableDiagnostic(
                        code: .invalidConfiguration,
                        message: "Key column indices must be non-negative; found \(invalidColumn).",
                        location: origin,
                        fieldIndex: invalidColumn
                    )
                )
            }
            if Set(columns).count != columns.count {
                diagnostics.append(
                    TableDiagnostic(
                        code: .invalidConfiguration,
                        message: "Each key column may appear only once.",
                        location: origin
                    )
                )
            }
        }

        return diagnostics
    }

    private func parserErrorPayloads(
        for table: ParsedTable,
        side: TableSide
    ) -> [RowPayload] {
        table.diagnostics.map { original in
            let diagnostic = original.attributed(to: side)
            let row = original.recordIndex.flatMap { index in
                table.rows.indices.contains(index) ? table.rows[index] : nil
            }
            return RowPayload(
                status: .error,
                keyValues: nil,
                left: side == .left ? row : nil,
                right: side == .right ? row : nil,
                cells: compareCells(
                    left: side == .left ? row : nil,
                    right: side == .right ? row : nil
                ),
                diagnostics: [diagnostic]
            )
        }
    }

    private func compareByRowNumber(
        left: [TableRow],
        right: [TableRow]
    ) -> [RowPayload] {
        let rowCount = max(left.count, right.count)
        return (0..<rowCount).map { index in
            let leftRow = left.indices.contains(index) ? left[index] : nil
            let rightRow = right.indices.contains(index) ? right[index] : nil
            return comparisonPayload(left: leftRow, right: rightRow, keyValues: nil)
        }
    }

    private func compareByKey(
        left: [TableRow],
        right: [TableRow],
        columns: [Int]
    ) -> KeyComparisonOutput {
        let leftEntries = makeKeyedRows(left, columns: columns, side: .left)
        let rightEntries = makeKeyedRows(right, columns: columns, side: .right)

        let leftCounts = keyCounts(leftEntries)
        let rightCounts = keyCounts(rightEntries)
        let duplicateKeys = Set(
            leftCounts.compactMap { $0.value > 1 ? $0.key : nil }
                + rightCounts.compactMap { $0.value > 1 ? $0.key : nil }
        )

        let leftDuplicateDiagnostics = duplicateDiagnostics(
            entries: leftEntries,
            counts: leftCounts,
            side: .left,
            columns: columns
        )
        let rightDuplicateDiagnostics = duplicateDiagnostics(
            entries: rightEntries,
            counts: rightCounts,
            side: .right,
            columns: columns
        )
        let duplicateDiagnosticsByKey = Dictionary(
            grouping: leftDuplicateDiagnostics + rightDuplicateDiagnostics,
            by: { $0.key }
        ).mapValues { $0.map(\.diagnostic) }

        var diagnostics = leftEntries.compactMap(\.diagnostic)
        diagnostics += rightEntries.compactMap(\.diagnostic)
        diagnostics += leftDuplicateDiagnostics.map(\.diagnostic)
        diagnostics += rightDuplicateDiagnostics.map(\.diagnostic)

        let uniqueRight = Dictionary(
            uniqueKeysWithValues: rightEntries.compactMap { entry -> (CompositeKey, KeyedRow)? in
                guard let key = entry.key,
                      !duplicateKeys.contains(key),
                      entry.diagnostic == nil
                else { return nil }
                return (key, entry)
            }
        )

        var consumedRightRows: Set<Int> = []
        var payloads: [RowPayload] = []

        for entry in leftEntries {
            if let diagnostic = entry.diagnostic {
                payloads.append(
                    RowPayload(
                        status: .error,
                        keyValues: nil,
                        left: entry.row,
                        right: nil,
                        cells: compareCells(left: entry.row, right: nil),
                        diagnostics: [diagnostic]
                    )
                )
                continue
            }

            guard let key = entry.key else { continue }
            if duplicateKeys.contains(key) {
                payloads.append(
                    RowPayload(
                        status: .duplicateKey,
                        keyValues: entry.displayKey,
                        left: entry.row,
                        right: nil,
                        cells: compareCells(left: entry.row, right: nil),
                        diagnostics: duplicateDiagnosticsByKey[key, default: []]
                    )
                )
            } else if let match = uniqueRight[key] {
                consumedRightRows.insert(match.row.index)
                payloads.append(
                    comparisonPayload(
                        left: entry.row,
                        right: match.row,
                        keyValues: entry.displayKey
                    )
                )
            } else {
                payloads.append(
                    comparisonPayload(left: entry.row, right: nil, keyValues: entry.displayKey)
                )
            }
        }

        for entry in rightEntries {
            if let diagnostic = entry.diagnostic {
                payloads.append(
                    RowPayload(
                        status: .error,
                        keyValues: nil,
                        left: nil,
                        right: entry.row,
                        cells: compareCells(left: nil, right: entry.row),
                        diagnostics: [diagnostic]
                    )
                )
                continue
            }

            guard let key = entry.key else { continue }
            if duplicateKeys.contains(key) {
                payloads.append(
                    RowPayload(
                        status: .duplicateKey,
                        keyValues: entry.displayKey,
                        left: nil,
                        right: entry.row,
                        cells: compareCells(left: nil, right: entry.row),
                        diagnostics: duplicateDiagnosticsByKey[key, default: []]
                    )
                )
            } else if !consumedRightRows.contains(entry.row.index) {
                payloads.append(
                    comparisonPayload(left: nil, right: entry.row, keyValues: entry.displayKey)
                )
            }
        }

        return KeyComparisonOutput(payloads: payloads, diagnostics: diagnostics)
    }

    private func makeKeyedRows(
        _ rows: [TableRow],
        columns: [Int],
        side: TableSide
    ) -> [KeyedRow] {
        rows.map { row in
            guard let missingColumn = columns.first(where: { row[column: $0] == nil }) else {
                let displayKey = columns.compactMap { row[column: $0]?.value }
                return KeyedRow(
                    row: row,
                    key: CompositeKey(values: displayKey.map(normalize)),
                    displayKey: displayKey,
                    diagnostic: nil
                )
            }

            let diagnostic = TableDiagnostic(
                code: .missingKeyColumn,
                message: "Record \(row.index + 1) has no key column \(missingColumn + 1).",
                location: row.location,
                recordIndex: row.index,
                fieldIndex: missingColumn,
                side: side
            )
            return KeyedRow(row: row, key: nil, displayKey: [], diagnostic: diagnostic)
        }
    }

    private func keyCounts(_ entries: [KeyedRow]) -> [CompositeKey: Int] {
        entries.reduce(into: [:]) { counts, entry in
            if let key = entry.key, entry.diagnostic == nil {
                counts[key, default: 0] += 1
            }
        }
    }

    private func duplicateDiagnostics(
        entries: [KeyedRow],
        counts: [CompositeKey: Int],
        side: TableSide,
        columns: [Int]
    ) -> [KeyDiagnostic] {
        var seen: Set<CompositeKey> = []
        var result: [KeyDiagnostic] = []

        for entry in entries {
            guard let key = entry.key,
                  counts[key, default: 0] > 1,
                  seen.insert(key).inserted
            else { continue }

            let firstKeyColumn = columns[0]
            let diagnostic = TableDiagnostic(
                code: .duplicateKey,
                message: "The composite key \(describe(entry.displayKey)) occurs \(counts[key, default: 0]) times on the \(side.rawValue) side.",
                location: entry.row[column: firstKeyColumn]?.location ?? entry.row.location,
                recordIndex: entry.row.index,
                fieldIndex: firstKeyColumn,
                side: side
            )
            result.append(KeyDiagnostic(key: key, diagnostic: diagnostic))
        }

        return result
    }

    private func comparisonPayload(
        left: TableRow?,
        right: TableRow?,
        keyValues: [String]?
    ) -> RowPayload {
        let cells = compareCells(left: left, right: right)
        let status: TableRowStatus
        switch (left, right) {
        case (.some, nil):
            status = .leftOnly
        case (nil, .some):
            status = .rightOnly
        case (.some, .some):
            status = cells.contains { cell in
                cell.status != .same && cell.status != .ignored
            } ? .modified : .same
        case (nil, nil):
            status = .error
        }

        return RowPayload(
            status: status,
            keyValues: keyValues,
            left: left,
            right: right,
            cells: cells,
            diagnostics: []
        )
    }

    private func compareCells(
        left: TableRow?,
        right: TableRow?
    ) -> [TableCellComparison] {
        let columnCount = max(left?.fields.count ?? 0, right?.fields.count ?? 0)
        return (0..<columnCount).map { columnIndex in
            let leftField = left?[column: columnIndex]
            let rightField = right?[column: columnIndex]
            let status: TableCellStatus

            if options.ignoredColumns.contains(columnIndex) {
                status = .ignored
            } else {
                switch (leftField, rightField) {
                case let (leftField?, rightField?):
                    status = normalize(leftField.value) == normalize(rightField.value)
                        ? .same
                        : .modified
                case (.some, nil):
                    status = .leftOnly
                case (nil, .some):
                    status = .rightOnly
                case (nil, nil):
                    status = .same
                }
            }

            return TableCellComparison(
                columnIndex: columnIndex,
                left: leftField,
                right: rightField,
                status: status
            )
        }
    }

    private func normalize(_ value: String) -> String {
        var normalized = value
        if options.ignoreWhitespace {
            normalized.removeAll(where: \.isWhitespace)
        }
        if options.ignoreCase {
            normalized = normalized.lowercased()
        }
        return normalized
    }

    private func describe(_ values: [String]) -> String {
        values.map { value in
            let escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }.joined(separator: ", ")
    }

    private func makeResult(
        payloads: [RowPayload],
        diagnostics: [TableDiagnostic]
    ) -> TableComparisonResult {
        let rows = payloads.enumerated().map { offset, payload in
            TableComparisonRow(
                offset: offset,
                status: payload.status,
                keyValues: payload.keyValues,
                left: payload.left,
                right: payload.right,
                cells: payload.cells,
                diagnostics: payload.diagnostics
            )
        }
        return TableComparisonResult(rows: rows, diagnostics: diagnostics)
    }
}

private struct CompositeKey: Hashable {
    let values: [String]
}

private struct KeyedRow {
    let row: TableRow
    let key: CompositeKey?
    let displayKey: [String]
    let diagnostic: TableDiagnostic?
}

private struct KeyDiagnostic {
    let key: CompositeKey
    let diagnostic: TableDiagnostic
}

private struct RowPayload {
    let status: TableRowStatus
    let keyValues: [String]?
    let left: TableRow?
    let right: TableRow?
    let cells: [TableCellComparison]
    let diagnostics: [TableDiagnostic]
}

private struct KeyComparisonOutput {
    let payloads: [RowPayload]
    let diagnostics: [TableDiagnostic]
}
