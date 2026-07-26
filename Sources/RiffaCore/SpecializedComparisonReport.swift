import Foundation

public enum SpecializedComparisonReportKind: String, CaseIterable, Codable, Sendable {
    case archive
    case hexadecimal
    case image
    case table
    case metadata
    case pdf
    case version
    case openXML
}

/// Typed scalar used by the stable specialized-report DTO. It deliberately has
/// no raw Data, URL, or resource-locator case.
public enum SpecializedReportValue: Equatable, Codable, Sendable {
    case string(String)
    case integer(Int64)
    case real(Double)
    case decimal(Decimal)
    case boolean(Bool)
    case date(Date)
    case null

    private enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    private enum Kind: String, Codable {
        case string
        case integer
        case real
        case decimal
        case boolean
        case date
        case null
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .string: self = .string(try container.decode(String.self, forKey: .value))
        case .integer: self = .integer(try container.decode(Int64.self, forKey: .value))
        case .real: self = .real(try container.decode(Double.self, forKey: .value))
        case .decimal: self = .decimal(try container.decode(Decimal.self, forKey: .value))
        case .boolean: self = .boolean(try container.decode(Bool.self, forKey: .value))
        case .date: self = .date(try container.decode(Date.self, forKey: .value))
        case .null: self = .null
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .string(value):
            try container.encode(Kind.string, forKey: .type)
            try container.encode(value, forKey: .value)
        case let .integer(value):
            try container.encode(Kind.integer, forKey: .type)
            try container.encode(value, forKey: .value)
        case let .real(value):
            try container.encode(Kind.real, forKey: .type)
            try container.encode(value, forKey: .value)
        case let .decimal(value):
            try container.encode(Kind.decimal, forKey: .type)
            try container.encode(value, forKey: .value)
        case let .boolean(value):
            try container.encode(Kind.boolean, forKey: .type)
            try container.encode(value, forKey: .value)
        case let .date(value):
            try container.encode(Kind.date, forKey: .type)
            try container.encode(value, forKey: .value)
        case .null:
            try container.encode(Kind.null, forKey: .type)
        }
    }
}

public struct SpecializedReportField: Equatable, Codable, Sendable {
    public let key: String
    public let label: String
    public let value: SpecializedReportValue

    public init(key: String, label: String, value: SpecializedReportValue) {
        self.key = key
        self.label = label
        self.value = value
    }
}

public struct SpecializedReportRow: Equatable, Codable, Sendable {
    public let key: String
    public let status: String
    public let left: [SpecializedReportField]
    public let right: [SpecializedReportField]
    public let details: [SpecializedReportField]

    public init(
        key: String,
        status: String,
        left: [SpecializedReportField] = [],
        right: [SpecializedReportField] = [],
        details: [SpecializedReportField] = []
    ) {
        self.key = key
        self.status = status
        self.left = left
        self.right = right
        self.details = details
    }
}

/// Codable source of truth for all specialized report renderers. Ordered
/// arrays, rather than dictionaries, make both presentation and JSON stable.
public struct SpecializedComparisonReportDocument: Equatable, Codable, Sendable {
    public let schemaVersion: Int
    public let kind: SpecializedComparisonReportKind
    public let leftLabel: String
    public let rightLabel: String
    public let summary: [SpecializedReportField]
    public let rows: [SpecializedReportRow]

    public init(
        schemaVersion: Int = 1,
        kind: SpecializedComparisonReportKind,
        leftLabel: String,
        rightLabel: String,
        summary: [SpecializedReportField],
        rows: [SpecializedReportRow]
    ) {
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.leftLabel = leftLabel
        self.rightLabel = rightLabel
        self.summary = summary
        self.rows = rows
    }
}

public struct SpecializedComparisonReportGenerator: Sendable {
    public init() {}

    public func document(
        for result: HexComparisonResult,
        leftLabel: String = "Left",
        rightLabel: String = "Right"
    ) -> SpecializedComparisonReportDocument {
        let rows = result.differences.sorted { $0.startOffset < $1.startOffset }.map { difference in
            SpecializedReportRow(
                key: String(format: "0x%08X", difference.startOffset),
                status: "different",
                details: [
                    integerField("startOffset", "Start offset", difference.startOffset),
                    integerField("leftCount", "Left byte count", difference.leftCount),
                    integerField("rightCount", "Right byte count", difference.rightCount),
                    integerField("span", "Compared span", difference.comparedCount)
                ]
            )
        }

        return SpecializedComparisonReportDocument(
            kind: .hexadecimal,
            leftLabel: portableLocalLabel(leftLabel),
            rightLabel: portableLocalLabel(rightLabel),
            summary: [
                integerField("leftByteCount", "Left bytes", result.leftByteCount),
                integerField("rightByteCount", "Right bytes", result.rightByteCount),
                integerField(
                    "differingBytePositionCount",
                    "Differing positions",
                    result.differingBytePositionCount
                ),
                integerField("differenceRangeCount", "Difference ranges", rows.count)
            ],
            rows: rows
        )
    }

    /// Produces a bounded report from a streamed local comparison. Only the
    /// published range prefix becomes detail rows; aggregate counts remain
    /// exact even when adversarial input creates more ranges than can safely
    /// be retained in memory.
    public func document(
        for result: LocalHexComparisonSummary,
        leftLabel: String = "Left",
        rightLabel: String = "Right"
    ) -> SpecializedComparisonReportDocument {
        let rows = result.publishedDifferenceRanges.map { difference in
            SpecializedReportRow(
                key: String(format: "0x%016llX", difference.startOffset),
                status: "different",
                details: [
                    uint64Field("startOffset", "Start offset", difference.startOffset),
                    uint64Field("leftCount", "Left byte count", difference.leftCount),
                    uint64Field("rightCount", "Right byte count", difference.rightCount),
                    uint64Field("span", "Compared span", difference.comparedCount)
                ]
            )
        }

        return SpecializedComparisonReportDocument(
            kind: .hexadecimal,
            leftLabel: portableLocalLabel(leftLabel),
            rightLabel: portableLocalLabel(rightLabel),
            summary: [
                uint64Field("leftByteCount", "Left bytes", result.leftByteCount),
                uint64Field("rightByteCount", "Right bytes", result.rightByteCount),
                uint64Field(
                    "differingBytePositionCount",
                    "Differing positions",
                    result.differingBytePositionCount
                ),
                uint64Field(
                    "differenceRangeCount",
                    "Difference ranges",
                    result.differenceRangeCount
                ),
                integerField(
                    "publishedDifferenceRangeCount",
                    "Published difference ranges",
                    result.publishedDifferenceRanges.count
                ),
                SpecializedReportField(
                    key: "differenceRangesTruncated",
                    label: "Difference ranges truncated",
                    value: .boolean(result.differenceRangesTruncated)
                )
            ],
            rows: rows
        )
    }

    public func document(
        for result: ImageComparisonResult,
        leftLabel: String = "Left",
        rightLabel: String = "Right"
    ) -> SpecializedComparisonReportDocument {
        var summary: [SpecializedReportField] = [
            stringField("dimensionStatus", "Dimension status", result.dimensionStatus.rawValue),
            integerField("comparedPixelCount", "Compared pixels", result.comparedPixelCount),
            integerField("mismatchedPixelCount", "Mismatched pixels", result.mismatchedPixelCount),
            realField("mismatchRatio", "Mismatch ratio", result.mismatchRatio),
            integerField(
                "maximumChannelDifference",
                "Maximum channel difference",
                Int(result.maximumChannelDifference)
            ),
            realField(
                "averageChannelDifference",
                "Average channel difference",
                result.averageChannelDifference
            ),
            integerField("mask.originX", "Mask origin X", result.mismatchMask.originX),
            integerField("mask.originY", "Mask origin Y", result.mismatchMask.originY),
            integerField("mask.width", "Mask width", result.mismatchMask.width),
            integerField("mask.height", "Mask height", result.mismatchMask.height),
            integerField(
                "mask.sampleCount",
                "Mask sample count",
                result.mismatchMask.values.count
            ),
            integerField(
                "mask.nonzeroCount",
                "Mask nonzero count",
                result.mismatchedPixelCount
            )
        ]
        appendBounds(result.overlapBounds, prefix: "overlap", label: "Overlap", to: &summary)
        appendBounds(result.mismatchBounds, prefix: "mismatch", label: "Mismatch", to: &summary)

        // The potentially enormous mismatchMask.values array is intentionally
        // excluded; dimensions, counts, and bounds are sufficient for a report.
        return SpecializedComparisonReportDocument(
            kind: .image,
            leftLabel: leftLabel,
            rightLabel: rightLabel,
            summary: summary,
            rows: []
        )
    }

    public func document(
        for result: TableComparisonResult,
        leftLabel: String = "Left",
        rightLabel: String = "Right"
    ) -> SpecializedComparisonReportDocument {
        let rows = result.rows.sorted { $0.offset < $1.offset }.map { row in
            var details = row.cells.sorted { $0.columnIndex < $1.columnIndex }.map { cell in
                stringField(
                    "column.\(cell.columnIndex).status",
                    "Column \(cell.columnIndex) status",
                    cell.status.rawValue
                )
            }
            let diagnostics = row.diagnostics.sorted(by: diagnosticSort)
            for (index, diagnostic) in diagnostics.enumerated() {
                details.append(
                    stringField(
                        "diagnostic.\(index)",
                        "Diagnostic \(index + 1)",
                        diagnosticText(diagnostic)
                    )
                )
            }

            return SpecializedReportRow(
                key: row.keyValues?.joined(separator: " | ") ?? String(row.offset + 1),
                status: row.status.rawValue,
                left: tableFields(row.left),
                right: tableFields(row.right),
                details: details
            )
        }

        var summary: [SpecializedReportField] = [
            integerField("totalRowCount", "Total rows", result.statistics.totalRowCount),
            integerField("sameRowCount", "Same rows", result.statistics.sameRowCount),
            integerField("modifiedRowCount", "Modified rows", result.statistics.modifiedRowCount),
            integerField("leftOnlyRowCount", "Left-only rows", result.statistics.leftOnlyRowCount),
            integerField("rightOnlyRowCount", "Right-only rows", result.statistics.rightOnlyRowCount),
            integerField(
                "duplicateKeyRowCount",
                "Duplicate-key rows",
                result.statistics.duplicateKeyRowCount
            ),
            integerField("errorRowCount", "Error rows", result.statistics.errorRowCount),
            integerField("diagnosticCount", "Diagnostics", result.diagnostics.count)
        ]
        for (index, diagnostic) in result.diagnostics.sorted(by: diagnosticSort).enumerated() {
            summary.append(
                stringField(
                    "diagnostic.\(index)",
                    "Diagnostic \(index + 1)",
                    diagnosticText(diagnostic)
                )
            )
        }

        return SpecializedComparisonReportDocument(
            kind: .table,
            leftLabel: leftLabel,
            rightLabel: rightLabel,
            summary: summary,
            rows: rows
        )
    }

    public func document(
        for result: MetadataComparisonResult,
        leftLabel: String = "Left",
        rightLabel: String = "Right"
    ) -> SpecializedComparisonReportDocument {
        let rows = result.rows.sorted { lhs, rhs in
            if lhs.key != rhs.key { return lhs.key < rhs.key }
            return lhs.occurrenceIndex < rhs.occurrenceIndex
        }.map { row in
            SpecializedReportRow(
                key: "\(row.key)#\(row.occurrenceIndex)",
                status: row.status.rawValue,
                left: metadataFields(row.left),
                right: metadataFields(row.right),
                details: [
                    stringField("displayName", "Display name", row.displayName),
                    stringField("importance", "Importance", row.importance.rawValue),
                    integerField("occurrenceIndex", "Occurrence", row.occurrenceIndex)
                ]
            )
        }

        return SpecializedComparisonReportDocument(
            kind: .metadata,
            leftLabel: leftLabel,
            rightLabel: rightLabel,
            summary: [
                integerField("totalCount", "Total fields", result.statistics.totalCount),
                integerField("sameCount", "Same fields", result.statistics.sameCount),
                integerField("differentCount", "Different fields", result.statistics.differentCount),
                integerField("leftOnlyCount", "Left-only fields", result.statistics.leftOnlyCount),
                integerField("rightOnlyCount", "Right-only fields", result.statistics.rightOnlyCount)
            ],
            rows: rows
        )
    }

    /// Local file-system metadata reuses the typed metadata report schema. The
    /// snapshots themselves intentionally contain no absolute resource paths or
    /// raw extended-attribute values.
    public func document(
        for result: LocalMetadataComparisonResult,
        leftLabel: String = "Left",
        rightLabel: String = "Right"
    ) -> SpecializedComparisonReportDocument {
        document(
            for: result.comparison,
            leftLabel: leftLabel,
            rightLabel: rightLabel
        )
    }

    public func document(
        for result: VersionComparisonResult,
        leftLabel: String = "Left",
        rightLabel: String = "Right"
    ) -> SpecializedComparisonReportDocument {
        let order = Dictionary(
            uniqueKeysWithValues: VersionComparisonField.allCases.enumerated().map {
                ($0.element, $0.offset)
            }
        )
        let rows = result.fields.enumerated().sorted { lhs, rhs in
            let leftRank = order[lhs.element.field] ?? Int.max
            let rightRank = order[rhs.element.field] ?? Int.max
            return leftRank == rightRank ? lhs.offset < rhs.offset : leftRank < rightRank
        }.map { _, field in
            SpecializedReportRow(
                key: field.field.rawValue,
                status: field.status.rawValue,
                left: [versionField(field.left, field: field.field)],
                right: [versionField(field.right, field: field.field)]
            )
        }

        return SpecializedComparisonReportDocument(
            kind: .version,
            leftLabel: portableLocalLabel(leftLabel),
            rightLabel: portableLocalLabel(rightLabel),
            summary: [
                integerField(
                    "totalFieldCount",
                    "Compared fields",
                    result.statistics.totalFieldCount
                ),
                integerField(
                    "sameFieldCount",
                    "Same fields",
                    result.statistics.sameFieldCount
                ),
                integerField(
                    "differentFieldCount",
                    "Different fields",
                    result.statistics.differentFieldCount
                ),
                SpecializedReportField(
                    key: "hasDifferences",
                    label: "Has differences",
                    value: .boolean(result.hasDifferences)
                )
            ],
            rows: rows
        )
    }

    public func document(
        for result: OpenXMLComparisonResult,
        leftLabel: String = "Left",
        rightLabel: String = "Right"
    ) -> SpecializedComparisonReportDocument {
        let rows = result.rows.sorted { $0.key < $1.key }.map { row in
            SpecializedReportRow(
                key: row.key,
                status: row.status.rawValue,
                left: openXMLFields(row.left),
                right: openXMLFields(row.right)
            )
        }

        return SpecializedComparisonReportDocument(
            kind: .openXML,
            leftLabel: portableLocalLabel(leftLabel),
            rightLabel: portableLocalLabel(rightLabel),
            summary: [
                stringField("left.documentType", "Left document type", result.left.documentType.rawValue),
                stringField("right.documentType", "Right document type", result.right.documentType.rawValue),
                integerField("left.sectionCount", "Left logical sections", result.left.sections.count),
                integerField("right.sectionCount", "Right logical sections", result.right.sections.count),
                integerField("left.partCount", "Left package parts", result.left.parts.count),
                integerField("right.partCount", "Right package parts", result.right.parts.count),
                integerField("totalCount", "Compared items", result.statistics.totalCount),
                integerField("sameCount", "Same items", result.statistics.sameCount),
                integerField("differentCount", "Different items", result.statistics.differentCount),
                integerField("leftOnlyCount", "Left-only items", result.statistics.leftOnlyCount),
                integerField("rightOnlyCount", "Right-only items", result.statistics.rightOnlyCount),
                SpecializedReportField(
                    key: "hasDifferences",
                    label: "Has differences",
                    value: .boolean(result.hasDifferences)
                )
            ],
            rows: rows
        )
    }

    /// Produces a report whose detail rows can never exceed the comparison's validated
    /// entry ceiling. Archive bytes and external resource locators are not representable
    /// in this DTO.
    public func document(
        for result: ArchiveComparisonResult,
        leftLabel: String = "Left",
        rightLabel: String = "Right"
    ) -> SpecializedComparisonReportDocument {
        let publishedRows = result.rows
            .prefix(result.options.limits.maxComparedEntryCount)
            .sorted { $0.path < $1.path }
            .map { row in
                SpecializedReportRow(
                    key: row.path,
                    status: row.status.rawValue,
                    left: archiveFields(row.left),
                    right: archiveFields(row.right),
                    details: row.differenceFields.isEmpty ? [] : [
                        stringField(
                            "differenceFields",
                            "Differences",
                            row.differenceFields.map(\.rawValue).joined(separator: ", ")
                        )
                    ]
                )
            }

        return SpecializedComparisonReportDocument(
            kind: .archive,
            leftLabel: portableLocalLabel(leftLabel),
            rightLabel: portableLocalLabel(rightLabel),
            summary: [
                stringField("left.format", "Left archive format", result.leftFormat.rawValue),
                stringField("right.format", "Right archive format", result.rightFormat.rawValue),
                integerField("totalCount", "Compared entries", result.statistics.totalCount),
                integerField("publishedRowCount", "Published rows", publishedRows.count),
                integerField("sameCount", "Same entries", result.statistics.sameCount),
                integerField("differentCount", "Different entries", result.statistics.differentCount),
                integerField("leftOnlyCount", "Left-only entries", result.statistics.leftOnlyCount),
                integerField("rightOnlyCount", "Right-only entries", result.statistics.rightOnlyCount),
                integerField("hashedFileCount", "Hashed files", result.statistics.hashedFileCount),
                integerField(
                    "readAndHashedByteCount",
                    "Read and hashed bytes",
                    result.statistics.readAndHashedByteCount
                ),
                SpecializedReportField(
                    key: "compareContent",
                    label: "Compare content",
                    value: .boolean(result.options.compareContent)
                ),
                SpecializedReportField(
                    key: "compareModificationDate",
                    label: "Compare modification dates",
                    value: .boolean(result.options.compareModificationDate)
                ),
                SpecializedReportField(
                    key: "comparePermissions",
                    label: "Compare permissions",
                    value: .boolean(result.options.comparePermissions)
                ),
                SpecializedReportField(
                    key: "compareCompression",
                    label: "Compare compression",
                    value: .boolean(result.options.compareCompression)
                ),
                SpecializedReportField(
                    key: "hasDifferences",
                    label: "Has differences",
                    value: .boolean(result.hasDifferences)
                )
            ],
            rows: publishedRows
        )
    }

    public func document(
        for result: PDFComparisonResult,
        leftLabel: String = "Left",
        rightLabel: String = "Right"
    ) -> SpecializedComparisonReportDocument {
        let rows = result.pages.enumerated().sorted { left, right in
            if left.element.pageNumber != right.element.pageNumber {
                return left.element.pageNumber < right.element.pageNumber
            }
            return left.offset < right.offset
        }.map { _, page in
            SpecializedReportRow(
                key: String(page.pageNumber),
                status: page.status.rawValue,
                left: pdfPageFields(page.left),
                right: pdfPageFields(page.right),
                details: pdfPageDetails(page)
            )
        }
        let metadata = result.metadataComparison.statistics

        return SpecializedComparisonReportDocument(
            kind: .pdf,
            leftLabel: portablePDFLabel(leftLabel),
            rightLabel: portablePDFLabel(rightLabel),
            summary: [
                integerField("left.fileByteCount", "Left document bytes", result.leftDocument.fileByteCount),
                integerField("right.fileByteCount", "Right document bytes", result.rightDocument.fileByteCount),
                integerField("left.pageCount", "Left document pages", result.leftDocument.pageCount),
                integerField("right.pageCount", "Right document pages", result.rightDocument.pageCount),
                integerField("left.metadataFieldCount", "Left metadata fields", result.leftDocument.metadata.count),
                integerField("right.metadataFieldCount", "Right metadata fields", result.rightDocument.metadata.count),
                integerField("pages.totalCount", "Compared page slots", rows.count),
                integerField("pages.sameCount", "Same pages", result.statistics.samePageCount),
                integerField("pages.changedCount", "Changed pages", result.statistics.changedPageCount),
                integerField("pages.leftOnlyCount", "Left-only pages", result.statistics.leftOnlyPageCount),
                integerField("pages.rightOnlyCount", "Right-only pages", result.statistics.rightOnlyPageCount),
                integerField("pages.differentCount", "Different pages", result.statistics.differentPageCount),
                integerField("metadata.totalCount", "Compared metadata fields", metadata.totalCount),
                integerField("metadata.sameCount", "Same metadata fields", metadata.sameCount),
                integerField("metadata.differentCount", "Different metadata fields", metadata.differentCount),
                integerField("metadata.leftOnlyCount", "Left-only metadata fields", metadata.leftOnlyCount),
                integerField("metadata.rightOnlyCount", "Right-only metadata fields", metadata.rightOnlyCount),
                SpecializedReportField(
                    key: "hasDifferences",
                    label: "Has differences",
                    value: .boolean(result.hasDifferences)
                )
            ],
            rows: rows
        )
    }

    public func generate(
        hex result: HexComparisonResult,
        format: ComparisonReportFormat,
        leftLabel: String = "Left",
        rightLabel: String = "Right"
    ) throws -> String {
        try render(document(for: result, leftLabel: leftLabel, rightLabel: rightLabel), as: format)
    }

    public func generate(
        hex result: LocalHexComparisonSummary,
        format: ComparisonReportFormat,
        leftLabel: String = "Left",
        rightLabel: String = "Right"
    ) throws -> String {
        try render(document(for: result, leftLabel: leftLabel, rightLabel: rightLabel), as: format)
    }

    public func generate(
        image result: ImageComparisonResult,
        format: ComparisonReportFormat,
        leftLabel: String = "Left",
        rightLabel: String = "Right"
    ) throws -> String {
        try render(document(for: result, leftLabel: leftLabel, rightLabel: rightLabel), as: format)
    }

    public func generate(
        table result: TableComparisonResult,
        format: ComparisonReportFormat,
        leftLabel: String = "Left",
        rightLabel: String = "Right"
    ) throws -> String {
        try render(document(for: result, leftLabel: leftLabel, rightLabel: rightLabel), as: format)
    }

    public func generate(
        metadata result: MetadataComparisonResult,
        format: ComparisonReportFormat,
        leftLabel: String = "Left",
        rightLabel: String = "Right"
    ) throws -> String {
        try render(document(for: result, leftLabel: leftLabel, rightLabel: rightLabel), as: format)
    }

    public func generate(
        metadata result: LocalMetadataComparisonResult,
        format: ComparisonReportFormat,
        leftLabel: String = "Left",
        rightLabel: String = "Right"
    ) throws -> String {
        try render(document(for: result, leftLabel: leftLabel, rightLabel: rightLabel), as: format)
    }

    public func generate(
        version result: VersionComparisonResult,
        format: ComparisonReportFormat,
        leftLabel: String = "Left",
        rightLabel: String = "Right"
    ) throws -> String {
        try render(document(for: result, leftLabel: leftLabel, rightLabel: rightLabel), as: format)
    }

    public func generate(
        openXML result: OpenXMLComparisonResult,
        format: ComparisonReportFormat,
        leftLabel: String = "Left",
        rightLabel: String = "Right"
    ) throws -> String {
        try render(document(for: result, leftLabel: leftLabel, rightLabel: rightLabel), as: format)
    }

    public func generate(
        archive result: ArchiveComparisonResult,
        format: ComparisonReportFormat,
        leftLabel: String = "Left",
        rightLabel: String = "Right"
    ) throws -> String {
        try render(document(for: result, leftLabel: leftLabel, rightLabel: rightLabel), as: format)
    }

    public func generate(
        pdf result: PDFComparisonResult,
        format: ComparisonReportFormat,
        leftLabel: String = "Left",
        rightLabel: String = "Right"
    ) throws -> String {
        try render(document(for: result, leftLabel: leftLabel, rightLabel: rightLabel), as: format)
    }

    public func render(
        _ document: SpecializedComparisonReportDocument,
        as format: ComparisonReportFormat
    ) throws -> String {
        switch format {
        case .plainText: plainText(document)
        case .html: html(document)
        case .json: try json(document)
        }
    }

    private func plainText(_ document: SpecializedComparisonReportDocument) -> String {
        var lines = [
            "Riffa Specialized Comparison Report",
            "Schema: \(document.schemaVersion)",
            "Kind: \(document.kind.rawValue)",
            "Left: \(plainEscape(document.leftLabel))",
            "Right: \(plainEscape(document.rightLabel))",
            "Summary:"
        ]
        lines += document.summary.map { field in
            "\(plainEscape(field.key))\t\(plainEscape(field.label))\t\(plainEscape(valueText(field.value)))"
        }
        lines.append("Rows:")
        for row in document.rows {
            lines.append("\(plainEscape(row.key))\t\(plainEscape(row.status))")
            lines += plainFields(row.left, prefix: "left")
            lines += plainFields(row.right, prefix: "right")
            lines += plainFields(row.details, prefix: "detail")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func plainFields(_ fields: [SpecializedReportField], prefix: String) -> [String] {
        fields.map { field in
            "  \(prefix).\(plainEscape(field.key))\t\(plainEscape(field.label))\t\(plainEscape(valueText(field.value)))"
        }
    }

    private func html(_ document: SpecializedComparisonReportDocument) -> String {
        let summary = document.summary.map { field in
            "<div class=\"metric\"><dt>\(htmlEscape(field.label))</dt><dd>\(htmlEscape(valueText(field.value)))</dd></div>"
        }.joined(separator: "\n")
        let rows: String
        if document.rows.isEmpty {
            rows = "<tr><td colspan=\"5\" class=\"empty\">No detail rows</td></tr>"
        } else {
            rows = document.rows.map { row in
                """
                <tr>
                  <td>\(htmlEscape(row.key))</td>
                  <td><span class="status">\(htmlEscape(row.status))</span></td>
                  <td>\(htmlFields(row.left))</td>
                  <td>\(htmlFields(row.right))</td>
                  <td>\(htmlFields(row.details))</td>
                </tr>
                """
            }.joined(separator: "\n")
        }

        return """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Riffa Specialized Comparison Report</title>
          <style>
            :root { color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, sans-serif; }
            body { max-width: 1200px; margin: 2rem auto; padding: 0 1rem; background: Canvas; color: CanvasText; }
            .labels, .empty { color: GrayText; } .summary { display: flex; flex-wrap: wrap; gap: .5rem; margin: 1rem 0; }
            .metric { border: 1px solid color-mix(in srgb, CanvasText 18%, transparent); border-radius: .6rem; padding: .45rem .65rem; }
            dt { font-size: .75rem; color: GrayText; } dd { margin: .15rem 0 0; font-variant-numeric: tabular-nums; }
            table { width: 100%; border-collapse: collapse; table-layout: fixed; }
            th, td { padding: .55rem; border-bottom: 1px solid color-mix(in srgb, CanvasText 14%, transparent); text-align: left; vertical-align: top; overflow-wrap: anywhere; }
            th { background: Canvas; position: sticky; top: 0; } ul { margin: 0; padding-left: 1.1rem; }
            .status { border: 1px solid color-mix(in srgb, CanvasText 20%, transparent); border-radius: 999px; padding: .15rem .45rem; }
          </style>
        </head>
        <body>
          <h1>Riffa Specialized Comparison Report</h1>
          <p class="labels">\(htmlEscape(document.kind.rawValue)) · \(htmlEscape(document.leftLabel)) ↔ \(htmlEscape(document.rightLabel))</p>
          <dl class="summary">\(summary)</dl>
          <table>
            <thead><tr><th>Key</th><th>Status</th><th>\(htmlEscape(document.leftLabel))</th><th>\(htmlEscape(document.rightLabel))</th><th>Details</th></tr></thead>
            <tbody>\(rows)</tbody>
          </table>
        </body>
        </html>
        """ + "\n"
    }

    private func htmlFields(_ fields: [SpecializedReportField]) -> String {
        guard !fields.isEmpty else { return "—" }
        return "<ul>" + fields.map { field in
            "<li><strong>\(htmlEscape(field.label)):</strong> \(htmlEscape(valueText(field.value)))</li>"
        }.joined() + "</ul>"
    }

    private func json(_ document: SpecializedComparisonReportDocument) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ComparisonReportEncodingError.invalidUTF8
        }
        return text + "\n"
    }

    private func tableFields(_ row: TableRow?) -> [SpecializedReportField] {
        guard let row else { return [] }
        return row.fields.sorted { $0.columnIndex < $1.columnIndex }.map { field in
            stringField("column.\(field.columnIndex)", "Column \(field.columnIndex)", field.value)
        }
    }

    private func archiveFields(
        _ entry: ArchiveComparisonEntrySummary?
    ) -> [SpecializedReportField] {
        guard let entry else { return [] }
        var fields = [
            stringField("kind", "Kind", entry.kind.rawValue),
            integerField("uncompressedByteCount", "Uncompressed bytes", entry.uncompressedByteCount),
            integerField("compressedByteCount", "Stored bytes", entry.compressedByteCount),
            stringField("compression", "Compression", entry.compression.rawValue),
        ]
        if let modificationDate = entry.modificationDate {
            fields.append(SpecializedReportField(
                key: "modificationDate",
                label: "Modification date",
                value: .date(modificationDate)
            ))
        }
        if let permissions = entry.permissions {
            fields.append(integerField("permissions", "Permissions", Int(permissions)))
        }
        if let destination = entry.symbolicLinkDestination {
            fields.append(stringField(
                "symbolicLinkDestination",
                "Symbolic-link destination",
                destination
            ))
        }
        if let digest = entry.contentSHA256 {
            fields.append(stringField("contentSHA256", "Content SHA-256", digest))
        }
        return fields
    }

    private func metadataFields(_ field: MetadataField?) -> [SpecializedReportField] {
        guard let field else { return [] }
        var output = [
            stringField("displayName", "Display name", field.displayName),
            stringField("importance", "Importance", field.importance.rawValue)
        ]
        switch field.value {
        case let .string(value):
            output.append(stringField("value", "Value", value))
        case let .integer(value):
            output.append(SpecializedReportField(key: "value", label: "Value", value: .integer(value)))
        case let .decimal(value):
            output.append(SpecializedReportField(key: "value", label: "Value", value: .decimal(value)))
        case let .boolean(value):
            output.append(SpecializedReportField(key: "value", label: "Value", value: .boolean(value)))
        case let .date(value):
            output.append(SpecializedReportField(key: "value", label: "Value", value: .date(value)))
        case let .data(summary):
            output.append(integerField("value.byteCount", "Data byte count", summary.byteCount))
            output.append(stringField("value.sha256", "Data SHA-256", summary.sha256))
        case .null:
            output.append(SpecializedReportField(key: "value", label: "Value", value: .null))
        }
        return output
    }

    private func versionField(
        _ value: VersionComparisonValue,
        field: VersionComparisonField
    ) -> SpecializedReportField {
        let reportValue: SpecializedReportValue = switch value {
        case let .string(value): .string(value)
        case let .integer(value): .integer(value)
        case let .strings(values): .string(values.joined(separator: ", "))
        case .null: .null
        }
        return SpecializedReportField(
            key: "value",
            label: versionFieldLabel(field),
            value: reportValue
        )
    }

    private func openXMLFields(_ value: OpenXMLComparisonValue?) -> [SpecializedReportField] {
        guard let value else { return [] }
        var fields = [
            stringField("itemKind", "Item kind", value.itemKind.rawValue),
            integerField("itemCount", "Logical item count", value.itemCount),
            stringField("sha256", "SHA-256", value.sha256)
        ]
        fields.append(SpecializedReportField(
            key: "displayText",
            label: "Text preview",
            value: value.displayText.map(SpecializedReportValue.string) ?? .null
        ))
        fields.append(SpecializedReportField(
            key: "byteCount",
            label: "Uncompressed bytes",
            value: value.byteCount.map { .integer(Int64($0)) } ?? .null
        ))
        return fields
    }

    private func versionFieldLabel(_ field: VersionComparisonField) -> String {
        switch field {
        case .displayName: "Display name"
        case .kind: "Resource kind"
        case .bundleIdentifier: "Bundle identifier"
        case .shortVersionString: "Short version"
        case .bundleVersion: "Bundle version"
        case .packageType: "Package type"
        case .minimumSystemVersion: "Minimum system version"
        case .architectures: "Architectures"
        case .fileByteCount: "Main binary bytes"
        case .sha256: "Main binary SHA-256"
        case .signatureStatus: "Signature status"
        case .signingTeamIdentifier: "Signing team identifier"
        case .signingIdentifier: "Signing identifier"
        case .signatureDiagnosticCode: "Signature diagnostic code"
        }
    }

    private func pdfPageFields(_ page: PDFPageSnapshot?) -> [SpecializedReportField] {
        guard let page else { return [] }
        return [
            integerField("pageNumber", "Page number", page.pageNumber),
            realField("dimensions.width", "Width", page.dimensions.width),
            realField("dimensions.height", "Height", page.dimensions.height),
            integerField("rotationDegrees", "Rotation degrees", page.rotationDegrees),
            SpecializedReportField(
                key: "label",
                label: "Page label",
                value: page.label.map(SpecializedReportValue.string) ?? .null
            ),
            integerField("extractedTextCharacterCount", "Extracted text characters", page.extractedText.count),
            stringField("extractedText", "Extracted text", page.extractedText)
        ]
    }

    private func pdfPageDetails(_ page: PDFPageComparison) -> [SpecializedReportField] {
        let differences = page.differences.enumerated().sorted { left, right in
            let leftRank = pdfDifferenceRank(left.element)
            let rightRank = pdfDifferenceRank(right.element)
            return leftRank == rightRank ? left.offset < right.offset : leftRank < rightRank
        }.map(\.element.rawValue)
        var fields: [SpecializedReportField] = [
            stringField("differences", "Differences", differences.joined(separator: ", "))
        ]

        guard let text = page.textComparison else {
            for (key, label) in pdfTextStatisticFields {
                fields.append(SpecializedReportField(key: key, label: label, value: .null))
            }
            return fields
        }

        let inlineDifferenceCount = text.lines.reduce(into: 0) { count, line in
            count += line.inlineDifferences.count
        }
        let lineEndingDifferenceCount = text.lines.count { $0.hasLineEndingDifference }
        let values = [
            text.statistics.sameLineCount,
            text.statistics.insertedLineCount,
            text.statistics.deletedLineCount,
            text.statistics.modifiedLineCount,
            text.statistics.changedLineCount,
            inlineDifferenceCount,
            lineEndingDifferenceCount
        ]
        for ((key, label), value) in zip(pdfTextStatisticFields, values) {
            fields.append(integerField(key, label, value))
        }
        return fields
    }

    private var pdfTextStatisticFields: [(String, String)] {
        [
            ("text.sameLineCount", "Same text lines"),
            ("text.insertedLineCount", "Inserted text lines"),
            ("text.deletedLineCount", "Deleted text lines"),
            ("text.modifiedLineCount", "Modified text lines"),
            ("text.changedLineCount", "Changed text lines"),
            ("text.inlineDifferenceCount", "Inline text differences"),
            ("text.lineEndingDifferenceCount", "Line-ending differences")
        ]
    }

    private func pdfDifferenceRank(_ difference: PDFPageDifferenceKind) -> Int {
        switch difference {
        case .dimensions: 0
        case .rotation: 1
        case .label: 2
        case .text: 3
        }
    }

    /// PDF callers commonly pass selected file paths as labels. Keep useful
    /// filenames while preventing an exported report from disclosing a local
    /// directory or a file URL.
    private func portablePDFLabel(_ label: String) -> String {
        portableLocalLabel(label)
    }

    private func portableLocalLabel(_ label: String) -> String {
        if label.hasPrefix("/"), !label.isEmpty {
            return URL(fileURLWithPath: label).lastPathComponent
        }
        if label.lowercased().hasPrefix("file://") {
            let encodedPath = String(label.dropFirst("file://".count))
            let path = encodedPath.removingPercentEncoding ?? encodedPath
            return URL(fileURLWithPath: path).lastPathComponent
        }
        if let url = URL(string: label), url.isFileURL {
            return url.lastPathComponent
        }
        return label
    }

    private func diagnosticSort(_ left: TableDiagnostic, _ right: TableDiagnostic) -> Bool {
        if left.location.offset != right.location.offset {
            return left.location.offset < right.location.offset
        }
        if left.code.rawValue != right.code.rawValue {
            return left.code.rawValue < right.code.rawValue
        }
        return left.message < right.message
    }

    private func diagnosticText(_ diagnostic: TableDiagnostic) -> String {
        "\(diagnostic.code.rawValue) at \(diagnostic.location.line):\(diagnostic.location.column): \(diagnostic.message)"
    }

    private func appendBounds(
        _ bounds: PixelBounds?,
        prefix: String,
        label: String,
        to fields: inout [SpecializedReportField]
    ) {
        guard let bounds else {
            fields.append(SpecializedReportField(key: "\(prefix).bounds", label: "\(label) bounds", value: .null))
            return
        }
        fields.append(integerField("\(prefix).x", "\(label) X", bounds.x))
        fields.append(integerField("\(prefix).y", "\(label) Y", bounds.y))
        fields.append(integerField("\(prefix).width", "\(label) width", bounds.width))
        fields.append(integerField("\(prefix).height", "\(label) height", bounds.height))
    }

    private func integerField(_ key: String, _ label: String, _ value: Int) -> SpecializedReportField {
        SpecializedReportField(key: key, label: label, value: .integer(Int64(value)))
    }

    private func uint64Field(_ key: String, _ label: String, _ value: UInt64) -> SpecializedReportField {
        // LocalHexComparisonLimits constrains file extents to Int64.max, so
        // streamed counts and offsets remain exactly representable in the
        // report DTO's signed integer scalar.
        SpecializedReportField(key: key, label: label, value: .integer(Int64(value)))
    }

    private func realField(_ key: String, _ label: String, _ value: Double) -> SpecializedReportField {
        SpecializedReportField(key: key, label: label, value: .real(value))
    }

    private func stringField(_ key: String, _ label: String, _ value: String) -> SpecializedReportField {
        SpecializedReportField(key: key, label: label, value: .string(value))
    }

    private func valueText(_ value: SpecializedReportValue) -> String {
        switch value {
        case let .string(value): value
        case let .integer(value): String(value)
        case let .real(value): String(format: "%.12g", locale: Locale(identifier: "en_US_POSIX"), value)
        case let .decimal(value): NSDecimalNumber(decimal: value).stringValue
        case let .boolean(value): value ? "true" : "false"
        case let .date(value): dateText(value)
        case .null: "null"
        }
    }

    private func dateText(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private func plainEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private func htmlEscape(_ value: String) -> String {
        var output = ""
        output.reserveCapacity(value.utf8.count)
        for character in value {
            switch character {
            case "&": output += "&amp;"
            case "<": output += "&lt;"
            case ">": output += "&gt;"
            case "\"": output += "&quot;"
            case "'": output += "&#39;"
            default: output.append(character)
            }
        }
        return output
    }
}
