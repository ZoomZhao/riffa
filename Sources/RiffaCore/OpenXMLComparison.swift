import CryptoKit
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// The logical Office package families understood by Riffa. OOXML formats are
/// macro-free; ODS is recognized from its OpenDocument package declarations.
public enum OpenXMLDocumentType: String, CaseIterable, Hashable, Codable, Sendable {
    case wordProcessingDocument = "docx"
    case spreadsheet = "xlsx"
    case presentation = "pptx"
    case openDocumentSpreadsheet = "ods"
}

/// Resource ceilings used while an in-memory Office package is indexed and parsed.
///
/// The initializer is deliberately throwing and decoding goes through the same validation,
/// so an invalid or disabled limit can never enter the comparison engine.
public struct OpenXMLComparisonLimits: Hashable, Codable, Sendable {
    private static let absoluteMaxSpreadsheetRowCount = 1_000_000
    private static let absoluteMaxSpreadsheetColumnCount = 16_384
    private static let absoluteMaxSpreadsheetCellCount = 1_000_000
    private static let absoluteMaxSpreadsheetRepeatCount = 1_000_000
    private static let absoluteMaxSpreadsheetExpandedByteCount = 128 * 1_024 * 1_024

    public let maxArchiveByteCount: Int
    public let maxPartCount: Int
    public let maxPartByteCount: Int
    public let maxTotalUncompressedByteCount: Int
    public let maxExpansionRatio: Double
    public let maxXMLPartCount: Int
    public let maxSingleXMLPartByteCount: Int
    public let maxTotalXMLByteCount: Int
    public let maxXMLNodeCount: Int
    public let maxTextCharacterCount: Int
    public let maxWorksheetOrSlideCount: Int
    public let maxLogicalItemCount: Int
    public let maxSpreadsheetRowCount: Int
    public let maxSpreadsheetColumnCount: Int
    public let maxSpreadsheetCellCount: Int
    public let maxSpreadsheetRepeatCount: Int
    public let maxSpreadsheetExpandedByteCount: Int

    public init(
        maxArchiveByteCount: Int = 256 * 1_024 * 1_024,
        maxPartCount: Int = 20_000,
        maxPartByteCount: Int = 64 * 1_024 * 1_024,
        maxTotalUncompressedByteCount: Int = 512 * 1_024 * 1_024,
        maxExpansionRatio: Double = 100,
        maxXMLPartCount: Int = 10_000,
        maxSingleXMLPartByteCount: Int = 16 * 1_024 * 1_024,
        maxTotalXMLByteCount: Int = 128 * 1_024 * 1_024,
        maxXMLNodeCount: Int = 2_000_000,
        maxTextCharacterCount: Int = 32_000_000,
        maxWorksheetOrSlideCount: Int = 4_096,
        maxLogicalItemCount: Int = 1_000_000,
        maxSpreadsheetRowCount: Int = 1_000_000,
        maxSpreadsheetColumnCount: Int = 16_384,
        maxSpreadsheetCellCount: Int = 1_000_000,
        maxSpreadsheetRepeatCount: Int = 1_000_000,
        maxSpreadsheetExpandedByteCount: Int = 128 * 1_024 * 1_024
    ) throws {
        let integers: [(String, Int)] = [
            ("maxArchiveByteCount", maxArchiveByteCount),
            ("maxPartCount", maxPartCount),
            ("maxPartByteCount", maxPartByteCount),
            ("maxTotalUncompressedByteCount", maxTotalUncompressedByteCount),
            ("maxXMLPartCount", maxXMLPartCount),
            ("maxSingleXMLPartByteCount", maxSingleXMLPartByteCount),
            ("maxTotalXMLByteCount", maxTotalXMLByteCount),
            ("maxXMLNodeCount", maxXMLNodeCount),
            ("maxTextCharacterCount", maxTextCharacterCount),
            ("maxWorksheetOrSlideCount", maxWorksheetOrSlideCount),
            ("maxLogicalItemCount", maxLogicalItemCount),
            ("maxSpreadsheetRowCount", maxSpreadsheetRowCount),
            ("maxSpreadsheetColumnCount", maxSpreadsheetColumnCount),
            ("maxSpreadsheetCellCount", maxSpreadsheetCellCount),
            ("maxSpreadsheetRepeatCount", maxSpreadsheetRepeatCount),
            ("maxSpreadsheetExpandedByteCount", maxSpreadsheetExpandedByteCount),
        ]
        guard let invalid = integers.first(where: { $0.1 <= 0 }) else {
            let spreadsheetCeilings: [(String, Int, Int)] = [
                (
                    "maxSpreadsheetRowCount",
                    maxSpreadsheetRowCount,
                    Self.absoluteMaxSpreadsheetRowCount
                ),
                (
                    "maxSpreadsheetColumnCount",
                    maxSpreadsheetColumnCount,
                    Self.absoluteMaxSpreadsheetColumnCount
                ),
                (
                    "maxSpreadsheetCellCount",
                    maxSpreadsheetCellCount,
                    Self.absoluteMaxSpreadsheetCellCount
                ),
                (
                    "maxSpreadsheetRepeatCount",
                    maxSpreadsheetRepeatCount,
                    Self.absoluteMaxSpreadsheetRepeatCount
                ),
                (
                    "maxSpreadsheetExpandedByteCount",
                    maxSpreadsheetExpandedByteCount,
                    Self.absoluteMaxSpreadsheetExpandedByteCount
                ),
            ]
            if let excessive = spreadsheetCeilings.first(where: { $0.1 > $0.2 }) {
                throw OpenXMLComparisonError(
                    code: .invalidLimits,
                    detail: "\(excessive.0) cannot exceed the hard cap of \(excessive.2)"
                )
            }
            guard maxExpansionRatio.isFinite, maxExpansionRatio >= 1 else {
                throw OpenXMLComparisonError(
                    code: .invalidLimits,
                    detail: "maxExpansionRatio must be finite and at least 1"
                )
            }
            guard maxPartByteCount <= maxTotalUncompressedByteCount else {
                throw OpenXMLComparisonError(
                    code: .invalidLimits,
                    detail: "maxPartByteCount cannot exceed maxTotalUncompressedByteCount"
                )
            }
            guard maxSingleXMLPartByteCount <= maxPartByteCount else {
                throw OpenXMLComparisonError(
                    code: .invalidLimits,
                    detail: "maxSingleXMLPartByteCount cannot exceed maxPartByteCount"
                )
            }
            guard maxSingleXMLPartByteCount <= maxTotalXMLByteCount else {
                throw OpenXMLComparisonError(
                    code: .invalidLimits,
                    detail: "maxSingleXMLPartByteCount cannot exceed maxTotalXMLByteCount"
                )
            }
            guard maxXMLPartCount <= maxPartCount else {
                throw OpenXMLComparisonError(
                    code: .invalidLimits,
                    detail: "maxXMLPartCount cannot exceed maxPartCount"
                )
            }

            self.maxArchiveByteCount = maxArchiveByteCount
            self.maxPartCount = maxPartCount
            self.maxPartByteCount = maxPartByteCount
            self.maxTotalUncompressedByteCount = maxTotalUncompressedByteCount
            self.maxExpansionRatio = maxExpansionRatio
            self.maxXMLPartCount = maxXMLPartCount
            self.maxSingleXMLPartByteCount = maxSingleXMLPartByteCount
            self.maxTotalXMLByteCount = maxTotalXMLByteCount
            self.maxXMLNodeCount = maxXMLNodeCount
            self.maxTextCharacterCount = maxTextCharacterCount
            self.maxWorksheetOrSlideCount = maxWorksheetOrSlideCount
            self.maxLogicalItemCount = maxLogicalItemCount
            self.maxSpreadsheetRowCount = maxSpreadsheetRowCount
            self.maxSpreadsheetColumnCount = maxSpreadsheetColumnCount
            self.maxSpreadsheetCellCount = maxSpreadsheetCellCount
            self.maxSpreadsheetRepeatCount = maxSpreadsheetRepeatCount
            self.maxSpreadsheetExpandedByteCount = maxSpreadsheetExpandedByteCount
            return
        }
        throw OpenXMLComparisonError(
            code: .invalidLimits,
            detail: "\(invalid.0) must be greater than zero"
        )
    }

    public static let `default`: Self = {
        // The literals above are compile-time constants whose relationships are covered by tests.
        try! Self()
    }()

    private enum CodingKeys: String, CodingKey {
        case maxArchiveByteCount
        case maxPartCount
        case maxPartByteCount
        case maxTotalUncompressedByteCount
        case maxExpansionRatio
        case maxXMLPartCount
        case maxSingleXMLPartByteCount
        case maxTotalXMLByteCount
        case maxXMLNodeCount
        case maxTextCharacterCount
        case maxWorksheetOrSlideCount
        case maxLogicalItemCount
        case maxSpreadsheetRowCount
        case maxSpreadsheetColumnCount
        case maxSpreadsheetCellCount
        case maxSpreadsheetRepeatCount
        case maxSpreadsheetExpandedByteCount
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            maxArchiveByteCount: values.decode(Int.self, forKey: .maxArchiveByteCount),
            maxPartCount: values.decode(Int.self, forKey: .maxPartCount),
            maxPartByteCount: values.decode(Int.self, forKey: .maxPartByteCount),
            maxTotalUncompressedByteCount: values.decode(Int.self, forKey: .maxTotalUncompressedByteCount),
            maxExpansionRatio: values.decode(Double.self, forKey: .maxExpansionRatio),
            maxXMLPartCount: values.decode(Int.self, forKey: .maxXMLPartCount),
            maxSingleXMLPartByteCount: values.decode(Int.self, forKey: .maxSingleXMLPartByteCount),
            maxTotalXMLByteCount: values.decode(Int.self, forKey: .maxTotalXMLByteCount),
            maxXMLNodeCount: values.decode(Int.self, forKey: .maxXMLNodeCount),
            maxTextCharacterCount: values.decode(Int.self, forKey: .maxTextCharacterCount),
            maxWorksheetOrSlideCount: values.decode(Int.self, forKey: .maxWorksheetOrSlideCount),
            maxLogicalItemCount: values.decode(Int.self, forKey: .maxLogicalItemCount),
            maxSpreadsheetRowCount: values.decodeIfPresent(
                Int.self,
                forKey: .maxSpreadsheetRowCount
            ) ?? 1_000_000,
            maxSpreadsheetColumnCount: values.decodeIfPresent(
                Int.self,
                forKey: .maxSpreadsheetColumnCount
            ) ?? 16_384,
            maxSpreadsheetCellCount: values.decodeIfPresent(
                Int.self,
                forKey: .maxSpreadsheetCellCount
            ) ?? 1_000_000,
            maxSpreadsheetRepeatCount: values.decodeIfPresent(
                Int.self,
                forKey: .maxSpreadsheetRepeatCount
            ) ?? 1_000_000,
            maxSpreadsheetExpandedByteCount: values.decodeIfPresent(
                Int.self,
                forKey: .maxSpreadsheetExpandedByteCount
            ) ?? 128 * 1_024 * 1_024
        )
    }
}

public struct OpenXMLComparisonError: Error, Hashable, Codable, Sendable, LocalizedError {
    public enum Code: String, Hashable, Codable, Sendable {
        case invalidLimits
        case archiveRejected
        case invalidPackage
        case unsupportedDocumentType
        case missingRequiredPart
        case unexpectedPartKind
        case partCountLimitExceeded
        case xmlPartCountLimitExceeded
        case xmlPartSizeLimitExceeded
        case totalXMLSizeLimitExceeded
        case xmlNodeLimitExceeded
        case textCharacterLimitExceeded
        case logicalItemLimitExceeded
        case worksheetOrSlideLimitExceeded
        case malformedXML
        case forbiddenDTD
        case invalidContentTypes
        case invalidRelationships
        case relationshipTraversal
        case danglingRelationship
        case duplicateIdentifier
        case invalidSharedStringReference
        case invalidOpenDocumentPackage
        case encryptedDocument
        case spreadsheetRowLimitExceeded
        case spreadsheetColumnLimitExceeded
        case spreadsheetCellLimitExceeded
        case spreadsheetRepeatLimitExceeded
        case spreadsheetExpansionLimitExceeded
    }

    public let code: Code
    /// A normalized path inside the package, never a local file-system path.
    public let part: String?
    public let detail: String?

    public init(code: Code, part: String? = nil, detail: String? = nil) {
        self.code = code
        self.part = part
        self.detail = detail
    }

    public var errorDescription: String? {
        var description = code.rawValue
        if let part { description += " (package part \(part))" }
        if let detail { description += ": \(detail)" }
        return description
    }
}

public struct OpenXMLCoreProperties: Hashable, Codable, Sendable {
    public let title: String?
    public let subject: String?
    public let creator: String?
    public let lastModifiedBy: String?
    public let description: String?
    public let keywords: String?
    public let category: String?
    public let created: String?
    public let modified: String?

    public init(
        title: String? = nil,
        subject: String? = nil,
        creator: String? = nil,
        lastModifiedBy: String? = nil,
        description: String? = nil,
        keywords: String? = nil,
        category: String? = nil,
        created: String? = nil,
        modified: String? = nil
    ) {
        self.title = title
        self.subject = subject
        self.creator = creator
        self.lastModifiedBy = lastModifiedBy
        self.description = description
        self.keywords = keywords
        self.category = category
        self.created = created
        self.modified = modified
    }
}

public enum OpenXMLLogicalSectionKind: String, Hashable, Codable, Sendable {
    case paragraph
    case table
    case worksheet
    case slide
}

public struct OpenXMLCellSnapshot: Hashable, Codable, Sendable {
    public let reference: String
    public let displayValue: String
    public let formula: String?
    public let valueType: String?
    public let typedValue: String?
    public let currency: String?
    public let rowSpan: Int?
    public let columnSpan: Int?

    public init(
        reference: String,
        displayValue: String,
        formula: String? = nil,
        valueType: String? = nil,
        typedValue: String? = nil,
        currency: String? = nil,
        rowSpan: Int? = nil,
        columnSpan: Int? = nil
    ) {
        self.reference = reference
        self.displayValue = displayValue
        self.formula = formula
        self.valueType = valueType
        self.typedValue = typedValue
        self.currency = currency
        self.rowSpan = rowSpan
        self.columnSpan = columnSpan
    }
}

/// A bounded logical unit extracted from a supported Office package.
///
/// Word sections use `textBlocks`, spreadsheets use `cells`, and presentations use
/// one slide section with ordered text blocks. No source XML or binary payload is retained.
public struct OpenXMLLogicalSection: Hashable, Codable, Sendable {
    public let key: String
    public let kind: OpenXMLLogicalSectionKind
    public let title: String?
    public let textBlocks: [String]
    public let cells: [OpenXMLCellSnapshot]

    public init(
        key: String,
        kind: OpenXMLLogicalSectionKind,
        title: String? = nil,
        textBlocks: [String] = [],
        cells: [OpenXMLCellSnapshot] = []
    ) {
        self.key = key
        self.kind = kind
        self.title = title
        self.textBlocks = textBlocks
        self.cells = cells
    }
}

public struct OpenXMLPartSummary: Hashable, Codable, Sendable {
    /// A normalized path inside the Office package, not a local resource path.
    public let partName: String
    public let uncompressedByteCount: Int
    public let sha256: String

    public init(partName: String, uncompressedByteCount: Int, sha256: String) {
        self.partName = partName
        self.uncompressedByteCount = uncompressedByteCount
        self.sha256 = sha256
    }
}

public struct OpenXMLDocumentSnapshot: Hashable, Codable, Sendable {
    public let documentType: OpenXMLDocumentType
    public let coreProperties: OpenXMLCoreProperties
    public let sections: [OpenXMLLogicalSection]
    public let parts: [OpenXMLPartSummary]

    public init(
        documentType: OpenXMLDocumentType,
        coreProperties: OpenXMLCoreProperties,
        sections: [OpenXMLLogicalSection],
        parts: [OpenXMLPartSummary]
    ) {
        self.documentType = documentType
        self.coreProperties = coreProperties
        self.sections = sections
        self.parts = parts
    }
}

public enum OpenXMLComparisonStatus: String, Hashable, Codable, Sendable {
    case same
    case different
    case leftOnly
    case rightOnly
}

public enum OpenXMLComparisonItemKind: String, Hashable, Codable, Sendable {
    case documentType
    case coreProperty
    case logicalSection
    case packagePart
}

/// A compact, report-safe value. Text is capped to a small preview while the SHA-256
/// covers the complete logical value.
public struct OpenXMLComparisonValue: Hashable, Codable, Sendable {
    public let itemKind: OpenXMLComparisonItemKind
    public let displayText: String?
    public let itemCount: Int
    public let byteCount: Int?
    public let sha256: String

    public init(
        itemKind: OpenXMLComparisonItemKind,
        displayText: String?,
        itemCount: Int,
        byteCount: Int? = nil,
        sha256: String
    ) {
        self.itemKind = itemKind
        self.displayText = displayText
        self.itemCount = itemCount
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

public struct OpenXMLComparisonRow: Hashable, Codable, Sendable {
    public let key: String
    public let status: OpenXMLComparisonStatus
    public let left: OpenXMLComparisonValue?
    public let right: OpenXMLComparisonValue?

    public init(
        key: String,
        status: OpenXMLComparisonStatus,
        left: OpenXMLComparisonValue?,
        right: OpenXMLComparisonValue?
    ) {
        self.key = key
        self.status = status
        self.left = left
        self.right = right
    }
}

public struct OpenXMLComparisonStatistics: Hashable, Codable, Sendable {
    public let totalCount: Int
    public let sameCount: Int
    public let differentCount: Int
    public let leftOnlyCount: Int
    public let rightOnlyCount: Int

    public init(
        totalCount: Int,
        sameCount: Int,
        differentCount: Int,
        leftOnlyCount: Int,
        rightOnlyCount: Int
    ) {
        self.totalCount = totalCount
        self.sameCount = sameCount
        self.differentCount = differentCount
        self.leftOnlyCount = leftOnlyCount
        self.rightOnlyCount = rightOnlyCount
    }
}

public struct OpenXMLComparisonResult: Hashable, Codable, Sendable {
    public let left: OpenXMLDocumentSnapshot
    public let right: OpenXMLDocumentSnapshot
    public let rows: [OpenXMLComparisonRow]
    public let statistics: OpenXMLComparisonStatistics

    public init(
        left: OpenXMLDocumentSnapshot,
        right: OpenXMLDocumentSnapshot,
        rows: [OpenXMLComparisonRow],
        statistics: OpenXMLComparisonStatistics
    ) {
        self.left = left
        self.right = right
        self.rows = rows
        self.statistics = statistics
    }

    public var hasDifferences: Bool {
        statistics.differentCount + statistics.leftOnlyCount + statistics.rightOnlyCount > 0
    }
}

public struct OpenXMLComparisonEngine: Sendable {
    public let limits: OpenXMLComparisonLimits

    public init(limits: OpenXMLComparisonLimits = .default) {
        self.limits = limits
    }

    public func snapshot(data: Data) throws -> OpenXMLDocumentSnapshot {
        do {
            if let openDocument = try OpenDocumentSpreadsheetSnapshotBuilder.snapshotIfRecognized(
                data: data,
                limits: limits
            ) {
                return openDocument
            }
            var builder = try OpenXMLPackageSnapshotBuilder(data: data, limits: limits)
            return try builder.build()
        } catch let error as OpenXMLComparisonError {
            throw error
        } catch let error as CancellationError {
            throw error
        } catch let error as ArchiveResourceError {
            throw OpenXMLComparisonError(
                code: .archiveRejected,
                part: error.path,
                detail: error.code.rawValue
            )
        } catch {
            throw OpenXMLComparisonError(code: .invalidPackage)
        }
    }

    public func compare(left: Data, right: Data) throws -> OpenXMLComparisonResult {
        compare(
            left: try snapshot(data: left),
            right: try snapshot(data: right)
        )
    }

    public func compare(
        left: OpenXMLDocumentSnapshot,
        right: OpenXMLDocumentSnapshot
    ) -> OpenXMLComparisonResult {
        var leftValues = comparisonValues(for: left)
        var rightValues = comparisonValues(for: right)
        let keys = Set(leftValues.keys).union(rightValues.keys).sorted()
        let rows = keys.map { key -> OpenXMLComparisonRow in
            let leftValue = leftValues.removeValue(forKey: key)
            let rightValue = rightValues.removeValue(forKey: key)
            let status: OpenXMLComparisonStatus
            switch (leftValue, rightValue) {
            case let (.some(lhs), .some(rhs)): status = lhs == rhs ? .same : .different
            case (.some, .none): status = .leftOnly
            case (.none, .some): status = .rightOnly
            case (.none, .none): preconditionFailure("A union key must exist on at least one side")
            }
            return OpenXMLComparisonRow(key: key, status: status, left: leftValue, right: rightValue)
        }
        let statistics = OpenXMLComparisonStatistics(
            totalCount: rows.count,
            sameCount: rows.count { $0.status == .same },
            differentCount: rows.count { $0.status == .different },
            leftOnlyCount: rows.count { $0.status == .leftOnly },
            rightOnlyCount: rows.count { $0.status == .rightOnly }
        )
        return OpenXMLComparisonResult(left: left, right: right, rows: rows, statistics: statistics)
    }

    private func comparisonValues(for snapshot: OpenXMLDocumentSnapshot) -> [String: OpenXMLComparisonValue] {
        var values: [String: OpenXMLComparisonValue] = [:]
        let type = snapshot.documentType.rawValue
        values["document.type"] = value(
            kind: .documentType,
            display: type,
            strings: [type]
        )

        let properties: [(String, String?)] = [
            ("title", snapshot.coreProperties.title),
            ("subject", snapshot.coreProperties.subject),
            ("creator", snapshot.coreProperties.creator),
            ("lastModifiedBy", snapshot.coreProperties.lastModifiedBy),
            ("description", snapshot.coreProperties.description),
            ("keywords", snapshot.coreProperties.keywords),
            ("category", snapshot.coreProperties.category),
            ("created", snapshot.coreProperties.created),
            ("modified", snapshot.coreProperties.modified),
        ]
        for (name, property) in properties where property != nil {
            values["property.\(name)"] = value(
                kind: .coreProperty,
                display: property,
                strings: [property ?? ""]
            )
        }

        for section in snapshot.sections {
            var strings = [section.kind.rawValue, section.key, section.title ?? ""]
            strings.append(contentsOf: section.textBlocks)
            for cell in section.cells {
                strings.append(cell.reference)
                strings.append(cell.displayValue)
                strings.append(cell.formula ?? "")
                strings.append(cell.valueType ?? "")
                strings.append(cell.typedValue ?? "")
                strings.append(cell.currency ?? "")
                strings.append(cell.rowSpan.map(String.init) ?? "")
                strings.append(cell.columnSpan.map(String.init) ?? "")
            }
            values["section.\(section.key)"] = value(
                kind: .logicalSection,
                display: sectionPreview(section),
                strings: strings,
                itemCount: section.cells.isEmpty ? section.textBlocks.count : section.cells.count
            )
        }

        for part in snapshot.parts {
            values["part.\(part.partName)"] = OpenXMLComparisonValue(
                itemKind: .packagePart,
                displayText: nil,
                itemCount: 1,
                byteCount: part.uncompressedByteCount,
                sha256: part.sha256
            )
        }
        return values
    }

    private func value(
        kind: OpenXMLComparisonItemKind,
        display: String?,
        strings: [String],
        itemCount: Int = 1
    ) -> OpenXMLComparisonValue {
        OpenXMLComparisonValue(
            itemKind: kind,
            displayText: display.map(boundedPreview),
            itemCount: itemCount,
            sha256: OpenXMLDigest.strings(strings)
        )
    }

    private func boundedPreview(_ value: String) -> String {
        var builder = OpenXMLPreviewBuilder(limit: 512)
        builder.append(value)
        return builder.value
    }

    private func sectionPreview(_ section: OpenXMLLogicalSection) -> String {
        var builder = OpenXMLPreviewBuilder(limit: 512)
        if section.cells.isEmpty {
            for (index, block) in section.textBlocks.enumerated() {
                if index > 0 { builder.append("\n") }
                builder.append(block)
                if builder.isFull { break }
            }
        } else {
            for (index, cell) in section.cells.prefix(8).enumerated() {
                if index > 0 { builder.append("\n") }
                builder.append(cell.reference)
                builder.append(": ")
                builder.append(cell.displayValue)
                if let formula = cell.formula {
                    builder.append(" =")
                    builder.append(formula)
                }
                if let valueType = cell.valueType {
                    builder.append(" [")
                    builder.append(valueType)
                    if let typedValue = cell.typedValue {
                        builder.append(": ")
                        builder.append(typedValue)
                    }
                    builder.append("]")
                }
                if let rowSpan = cell.rowSpan, rowSpan > 1 {
                    builder.append(" rows=")
                    builder.append(String(rowSpan))
                }
                if let columnSpan = cell.columnSpan, columnSpan > 1 {
                    builder.append(" columns=")
                    builder.append(String(columnSpan))
                }
                if builder.isFull { break }
            }
        }
        return builder.value
    }
}

/// Builds a character-bounded preview without joining or copying the complete source text.
private struct OpenXMLPreviewBuilder {
    let limit: Int
    private var output = ""
    private var characterCount = 0
    private var truncated = false

    init(limit: Int) {
        self.limit = limit
        output.reserveCapacity(limit + 1)
    }

    var isFull: Bool { truncated || characterCount >= limit }
    var value: String { output + (truncated ? "…" : "") }

    mutating func append(_ source: String) {
        guard !truncated else { return }
        for character in source {
            guard characterCount < limit else {
                truncated = true
                return
            }
            output.append(character)
            characterCount += 1
        }
    }
}

private enum OpenXMLNamespaces {
    static let contentTypes = "http://schemas.openxmlformats.org/package/2006/content-types"
    static let packageRelationships = "http://schemas.openxmlformats.org/package/2006/relationships"
    static let coreProperties = "http://schemas.openxmlformats.org/package/2006/metadata/core-properties"
    static let dc = "http://purl.org/dc/elements/1.1/"
    static let dcterms = "http://purl.org/dc/terms/"
    static let word = Set([
        "http://schemas.openxmlformats.org/wordprocessingml/2006/main",
        "http://purl.oclc.org/ooxml/wordprocessingml/main",
    ])
    static let spreadsheet = Set([
        "http://schemas.openxmlformats.org/spreadsheetml/2006/main",
        "http://purl.oclc.org/ooxml/spreadsheetml/main",
    ])
    static let presentation = Set([
        "http://schemas.openxmlformats.org/presentationml/2006/main",
        "http://purl.oclc.org/ooxml/presentationml/main",
    ])
    static let drawing = Set([
        "http://schemas.openxmlformats.org/drawingml/2006/main",
        "http://purl.oclc.org/ooxml/drawingml/main",
    ])
}

private enum OpenXMLContentType {
    static let wordMain = "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"
    static let spreadsheetMain = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"
    static let presentationMain = "application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"
}

private struct OpenXMLPackageRelationship: Hashable, Sendable {
    let identifier: String
    let type: String
    let resolvedTarget: String?
    let isExternal: Bool
}

private struct OpenXMLPackageSnapshotBuilder {
    let limits: OpenXMLComparisonLimits
    let provider: ArchiveResourceProvider
    let files: [String: ArchiveResourceEntry]
    let xmlBudget: OpenXMLXMLBudget

    init(data: Data, limits: OpenXMLComparisonLimits) throws {
        self.limits = limits
        let archiveLimits = ArchiveResourceLimits(
            maxArchiveByteCount: limits.maxArchiveByteCount,
            maxEntryCount: limits.maxPartCount,
            maxEntryUncompressedByteCount: limits.maxPartByteCount,
            maxTotalUncompressedByteCount: limits.maxTotalUncompressedByteCount,
            maxExpansionRatio: limits.maxExpansionRatio,
            maxPathByteCount: 4_096,
            maxPathDepth: 256
        )
        provider = try ArchiveResourceProvider(data: data, format: .zip, limits: archiveLimits)
        let entries = provider.list()
        let nonDirectories = entries.filter { $0.kind != .directory }
        guard nonDirectories.count <= limits.maxPartCount else {
            throw OpenXMLComparisonError(code: .partCountLimitExceeded)
        }
        if let unsupported = nonDirectories.first(where: { $0.kind != .file }) {
            throw OpenXMLComparisonError(code: .unexpectedPartKind, part: unsupported.path)
        }
        files = Dictionary(uniqueKeysWithValues: nonDirectories.map { ($0.path, $0) })

        let xmlEntries = nonDirectories.filter { Self.isXMLPart($0.path) }
        guard xmlEntries.count <= limits.maxXMLPartCount else {
            throw OpenXMLComparisonError(code: .xmlPartCountLimitExceeded)
        }
        var totalXMLBytes = 0
        for entry in xmlEntries {
            guard entry.uncompressedByteCount <= limits.maxSingleXMLPartByteCount else {
                throw OpenXMLComparisonError(code: .xmlPartSizeLimitExceeded, part: entry.path)
            }
            let (sum, overflow) = totalXMLBytes.addingReportingOverflow(entry.uncompressedByteCount)
            guard !overflow, sum <= limits.maxTotalXMLByteCount else {
                throw OpenXMLComparisonError(code: .totalXMLSizeLimitExceeded)
            }
            totalXMLBytes = sum
        }
        xmlBudget = OpenXMLXMLBudget(limits: limits)
    }

    mutating func build() throws -> OpenXMLDocumentSnapshot {
        guard files["[Content_Types].xml"] != nil, files["_rels/.rels"] != nil else {
            throw OpenXMLComparisonError(code: .invalidPackage, detail: "OPC package declarations are missing")
        }

        let contentTypes = try parseContentTypes()
        let relationships = try parseAndValidateRelationships()
        guard let rootRelationships = relationships[""] else {
            throw OpenXMLComparisonError(code: .missingRequiredPart, part: "_rels/.rels")
        }
        let officeRelations = rootRelationships.filter {
            !$0.isExternal && $0.type.hasSuffix("/officeDocument")
        }
        guard officeRelations.count == 1, let mainPart = officeRelations[0].resolvedTarget else {
            throw OpenXMLComparisonError(
                code: .invalidRelationships,
                part: "_rels/.rels",
                detail: "Exactly one internal officeDocument relationship is required"
            )
        }
        guard files[mainPart] != nil else {
            throw OpenXMLComparisonError(code: .missingRequiredPart, part: mainPart)
        }

        let documentType: OpenXMLDocumentType
        switch contentTypes.contentType(for: mainPart) {
        case OpenXMLContentType.wordMain: documentType = .wordProcessingDocument
        case OpenXMLContentType.spreadsheetMain: documentType = .spreadsheet
        case OpenXMLContentType.presentationMain: documentType = .presentation
        default:
            throw OpenXMLComparisonError(
                code: .unsupportedDocumentType,
                part: mainPart,
                detail: "The main part is not a macro-free DOCX, XLSX, or PPTX document"
            )
        }

        let properties = try coreProperties(from: rootRelationships)
        let sections: [OpenXMLLogicalSection]
        switch documentType {
        case .wordProcessingDocument:
            sections = try wordSections(mainPart: mainPart)
        case .spreadsheet:
            sections = try spreadsheetSections(
                workbookPart: mainPart,
                relationships: relationships[mainPart] ?? []
            )
        case .presentation:
            sections = try presentationSections(
                presentationPart: mainPart,
                relationships: relationships[mainPart] ?? []
            )
        case .openDocumentSpreadsheet:
            preconditionFailure("ODS snapshots are built by the OpenDocument package parser")
        }
        let parts = try partSummaries()
        return OpenXMLDocumentSnapshot(
            documentType: documentType,
            coreProperties: properties,
            sections: sections,
            parts: parts
        )
    }

    private static func isXMLPart(_ path: String) -> Bool {
        let lowered = path.lowercased()
        return lowered.hasSuffix(".xml") || lowered.hasSuffix(".rels")
    }

    private mutating func xmlData(_ path: String) throws -> Data {
        guard let entry = files[path] else {
            throw OpenXMLComparisonError(code: .missingRequiredPart, part: path)
        }
        guard Self.isXMLPart(path) else {
            throw OpenXMLComparisonError(code: .malformedXML, part: path)
        }
        guard entry.uncompressedByteCount <= limits.maxSingleXMLPartByteCount else {
            throw OpenXMLComparisonError(code: .xmlPartSizeLimitExceeded, part: path)
        }
        let data = try provider.read(path)
        guard !OpenXMLXMLSecurity.containsDocumentTypeDeclaration(data) else {
            throw OpenXMLComparisonError(code: .forbiddenDTD, part: path)
        }
        return data
    }

    private mutating func parseContentTypes() throws -> OpenXMLContentTypes {
        let path = "[Content_Types].xml"
        let delegate = OpenXMLContentTypesDelegate(budget: xmlBudget, part: path)
        try parseXML(try xmlData(path), part: path, delegate: delegate)
        return try delegate.result()
    }

    private mutating func parseAndValidateRelationships() throws -> [String: [OpenXMLPackageRelationship]] {
        var result: [String: [OpenXMLPackageRelationship]] = [:]
        let relationshipParts = files.keys.filter { $0.lowercased().hasSuffix(".rels") }.sorted()
        for relationshipPart in relationshipParts {
            let source = try OpenXMLRelationshipPath.sourcePart(for: relationshipPart)
            if !source.isEmpty, files[source] == nil {
                throw OpenXMLComparisonError(
                    code: .invalidRelationships,
                    part: relationshipPart,
                    detail: "The relationship source part is missing"
                )
            }
            let delegate = OpenXMLRelationshipsDelegate(budget: xmlBudget, part: relationshipPart)
            try parseXML(try xmlData(relationshipPart), part: relationshipPart, delegate: delegate)
            let rawRelationships = try delegate.result()
            var identifiers = Set<String>()
            var relationships: [OpenXMLPackageRelationship] = []
            relationships.reserveCapacity(rawRelationships.count)
            for relationship in rawRelationships {
                guard identifiers.insert(relationship.identifier).inserted else {
                    throw OpenXMLComparisonError(
                        code: .duplicateIdentifier,
                        part: relationshipPart,
                        detail: "Duplicate relationship identifier"
                    )
                }
                if relationship.isExternal {
                    relationships.append(OpenXMLPackageRelationship(
                        identifier: relationship.identifier,
                        type: relationship.type,
                        resolvedTarget: nil,
                        isExternal: true
                    ))
                    continue
                }
                let target = try OpenXMLRelationshipPath.resolve(
                    relationship.target,
                    relativeTo: source,
                    relationshipPart: relationshipPart
                )
                guard files[target] != nil else {
                    throw OpenXMLComparisonError(code: .danglingRelationship, part: target)
                }
                relationships.append(OpenXMLPackageRelationship(
                    identifier: relationship.identifier,
                    type: relationship.type,
                    resolvedTarget: target,
                    isExternal: false
                ))
            }
            result[source] = relationships
        }
        return result
    }

    private mutating func coreProperties(
        from rootRelationships: [OpenXMLPackageRelationship]
    ) throws -> OpenXMLCoreProperties {
        let candidates = rootRelationships.filter {
            !$0.isExternal && $0.type.hasSuffix("/metadata/core-properties")
        }
        guard candidates.count <= 1 else {
            throw OpenXMLComparisonError(
                code: .invalidRelationships,
                part: "_rels/.rels",
                detail: "Multiple core-properties relationships are not supported"
            )
        }
        guard let part = candidates.first?.resolvedTarget else { return OpenXMLCoreProperties() }
        let delegate = OpenXMLCorePropertiesDelegate(budget: xmlBudget, part: part)
        try parseXML(try xmlData(part), part: part, delegate: delegate)
        return delegate.result()
    }

    private mutating func wordSections(mainPart: String) throws -> [OpenXMLLogicalSection] {
        let delegate = OpenXMLWordDocumentDelegate(budget: xmlBudget, part: mainPart)
        try parseXML(try xmlData(mainPart), part: mainPart, delegate: delegate)
        return delegate.sections
    }

    private mutating func spreadsheetSections(
        workbookPart: String,
        relationships: [OpenXMLPackageRelationship]
    ) throws -> [OpenXMLLogicalSection] {
        let workbookDelegate = OpenXMLWorkbookDelegate(
            budget: xmlBudget,
            part: workbookPart,
            maxSheetCount: limits.maxWorksheetOrSlideCount
        )
        try parseXML(try xmlData(workbookPart), part: workbookPart, delegate: workbookDelegate)
        let sheets = workbookDelegate.sheets
        guard sheets.count <= limits.maxWorksheetOrSlideCount else {
            throw OpenXMLComparisonError(code: .worksheetOrSlideLimitExceeded, part: workbookPart)
        }
        let relationshipMap = Dictionary(uniqueKeysWithValues: relationships.map { ($0.identifier, $0) })

        var sharedStrings: [String] = []
        let sharedCandidates = relationships.filter {
            !$0.isExternal && $0.type.hasSuffix("/sharedStrings")
        }
        guard sharedCandidates.count <= 1 else {
            throw OpenXMLComparisonError(code: .invalidRelationships, part: workbookPart)
        }
        if let sharedPart = sharedCandidates.first?.resolvedTarget {
            let delegate = OpenXMLSharedStringsDelegate(budget: xmlBudget, part: sharedPart)
            try parseXML(try xmlData(sharedPart), part: sharedPart, delegate: delegate)
            sharedStrings = delegate.strings
        }

        var sections: [OpenXMLLogicalSection] = []
        sections.reserveCapacity(sheets.count)
        for (index, sheet) in sheets.enumerated() {
            guard let relationship = relationshipMap[sheet.relationshipID],
                  !relationship.isExternal,
                  relationship.type.hasSuffix("/worksheet"),
                  let target = relationship.resolvedTarget else {
                throw OpenXMLComparisonError(
                    code: .invalidRelationships,
                    part: workbookPart,
                    detail: "A worksheet relationship is missing or has the wrong type"
                )
            }
            let delegate = OpenXMLWorksheetDelegate(
                budget: xmlBudget,
                part: target,
                sharedStrings: sharedStrings
            )
            try parseXML(try xmlData(target), part: target, delegate: delegate)
            sections.append(OpenXMLLogicalSection(
                key: "worksheet.\(index + 1)",
                kind: .worksheet,
                title: sheet.name,
                cells: try delegate.result()
            ))
        }
        return sections
    }

    private mutating func presentationSections(
        presentationPart: String,
        relationships: [OpenXMLPackageRelationship]
    ) throws -> [OpenXMLLogicalSection] {
        let presentationDelegate = OpenXMLPresentationDelegate(
            budget: xmlBudget,
            part: presentationPart,
            maxSlideCount: limits.maxWorksheetOrSlideCount
        )
        try parseXML(try xmlData(presentationPart), part: presentationPart, delegate: presentationDelegate)
        let slideIDs = presentationDelegate.slideRelationshipIDs
        guard slideIDs.count <= limits.maxWorksheetOrSlideCount else {
            throw OpenXMLComparisonError(code: .worksheetOrSlideLimitExceeded, part: presentationPart)
        }
        let relationshipMap = Dictionary(uniqueKeysWithValues: relationships.map { ($0.identifier, $0) })
        var sections: [OpenXMLLogicalSection] = []
        sections.reserveCapacity(slideIDs.count)
        for (index, relationshipID) in slideIDs.enumerated() {
            guard let relationship = relationshipMap[relationshipID],
                  !relationship.isExternal,
                  relationship.type.hasSuffix("/slide"),
                  let target = relationship.resolvedTarget else {
                throw OpenXMLComparisonError(
                    code: .invalidRelationships,
                    part: presentationPart,
                    detail: "A slide relationship is missing or has the wrong type"
                )
            }
            let delegate = OpenXMLSlideDelegate(budget: xmlBudget, part: target)
            try parseXML(try xmlData(target), part: target, delegate: delegate)
            let textBlocks = delegate.textBlocks
            sections.append(OpenXMLLogicalSection(
                key: "slide.\(index + 1)",
                kind: .slide,
                title: textBlocks.first,
                textBlocks: textBlocks
            ))
        }
        return sections
    }

    private func partSummaries() throws -> [OpenXMLPartSummary] {
        try files.values.sorted { $0.path < $1.path }.map { entry in
            let data = try provider.read(entry.path)
            return OpenXMLPartSummary(
                partName: entry.path,
                uncompressedByteCount: data.count,
                sha256: OpenXMLDigest.data(data)
            )
        }
    }

    private func parseXML(
        _ data: Data,
        part: String,
        delegate: OpenXMLBoundedDelegate
    ) throws {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        #if canImport(FoundationXML)
        parser.externalEntityResolvingPolicy = .never
        #endif
        parser.delegate = delegate
        let parsed = parser.parse()
        if let error = delegate.failure { throw error }
        guard parsed else {
            throw OpenXMLComparisonError(code: .malformedXML, part: part)
        }
        try delegate.validateComplete()
    }
}

private struct OpenXMLContentTypes {
    let overrides: [String: String]
    let defaults: [String: String]

    func contentType(for part: String) -> String? {
        overrides[part] ?? defaults[(part as NSString).pathExtension.lowercased()]
    }
}

private final class OpenXMLXMLBudget {
    private let limits: OpenXMLComparisonLimits
    private var nodeCount = 0
    private var textCharacterCount = 0
    private var logicalItemCount = 0

    init(limits: OpenXMLComparisonLimits) {
        self.limits = limits
    }

    func consumeNode(part: String) throws {
        let (next, overflow) = nodeCount.addingReportingOverflow(1)
        guard !overflow, next <= limits.maxXMLNodeCount else {
            throw OpenXMLComparisonError(code: .xmlNodeLimitExceeded, part: part)
        }
        nodeCount = next
    }

    func consumeText(_ text: String, part: String) throws {
        let (next, overflow) = textCharacterCount.addingReportingOverflow(text.count)
        guard !overflow, next <= limits.maxTextCharacterCount else {
            throw OpenXMLComparisonError(code: .textCharacterLimitExceeded, part: part)
        }
        textCharacterCount = next
    }

    func consumeLogicalItem(part: String) throws {
        let (next, overflow) = logicalItemCount.addingReportingOverflow(1)
        guard !overflow, next <= limits.maxLogicalItemCount else {
            throw OpenXMLComparisonError(code: .logicalItemLimitExceeded, part: part)
        }
        logicalItemCount = next
    }
}

private enum OpenXMLXMLSecurity {
    static func containsDocumentTypeDeclaration(_ data: Data) -> Bool {
        // Removing NUL also exposes ASCII declarations in UTF-16LE/BE input. XML names
        // are ASCII, so a case-insensitive byte scan is sufficient and deliberately
        // conservative (a declaration-like sequence in a comment is rejected too).
        let normalized = data.compactMap { byte -> UInt8? in
            guard byte != 0 else { return nil }
            if byte >= 0x61, byte <= 0x7a { return byte - 0x20 }
            return byte
        }
        return normalized.containsSubsequence(Array("<!DOCTYPE".utf8))
            || normalized.containsSubsequence(Array("<!ENTITY".utf8))
    }
}

private extension Array where Element == UInt8 {
    func containsSubsequence(_ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, count >= needle.count else { return false }
        for start in 0...(count - needle.count) {
            if self[start..<(start + needle.count)].elementsEqual(needle) { return true }
        }
        return false
    }
}

private class OpenXMLBoundedDelegate: NSObject, XMLParserDelegate {
    let budget: OpenXMLXMLBudget
    let part: String
    let expectedRoot: String
    let expectedRootNamespaces: Set<String>
    private(set) var failure: OpenXMLComparisonError?
    private var depth = 0
    private var rootSeen = false

    init(
        budget: OpenXMLXMLBudget,
        part: String,
        expectedRoot: String,
        expectedRootNamespaces: Set<String>
    ) {
        self.budget = budget
        self.part = part
        self.expectedRoot = expectedRoot
        self.expectedRootNamespaces = expectedRootNamespaces
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard failure == nil else { parser.abortParsing(); return }
        do {
            try budget.consumeNode(part: part)
            depth += 1
            if depth == 1 {
                guard !rootSeen,
                      elementName == expectedRoot,
                      namespaceURI.map(expectedRootNamespaces.contains) == true else {
                    throw OpenXMLComparisonError(
                        code: .malformedXML,
                        part: part,
                        detail: "Unexpected XML root element or namespace"
                    )
                }
                rootSeen = true
            }
            try startElement(
                elementName,
                namespaceURI: namespaceURI,
                qualifiedName: qName,
                attributes: attributeDict
            )
        } catch let error as OpenXMLComparisonError {
            fail(error, parser: parser)
        } catch {
            fail(OpenXMLComparisonError(code: .malformedXML, part: part), parser: parser)
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard failure == nil else { return }
        do {
            try endElement(elementName, namespaceURI: namespaceURI, qualifiedName: qName)
            depth -= 1
            guard depth >= 0 else {
                throw OpenXMLComparisonError(code: .malformedXML, part: part)
            }
        } catch let error as OpenXMLComparisonError {
            fail(error, parser: parser)
        } catch {
            fail(OpenXMLComparisonError(code: .malformedXML, part: part), parser: parser)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard failure == nil else { return }
        do {
            try budget.consumeText(string, part: part)
            try characters(string)
        } catch let error as OpenXMLComparisonError {
            fail(error, parser: parser)
        } catch {
            fail(OpenXMLComparisonError(code: .malformedXML, part: part), parser: parser)
        }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let text = String(data: CDATABlock, encoding: .utf8) else {
            fail(OpenXMLComparisonError(code: .malformedXML, part: part), parser: parser)
            return
        }
        self.parser(parser, foundCharacters: text)
    }

    func parser(
        _ parser: XMLParser,
        foundExternalEntityDeclarationWithName name: String,
        publicID: String?,
        systemID: String?
    ) {
        fail(OpenXMLComparisonError(code: .forbiddenDTD, part: part), parser: parser)
    }

    func parser(
        _ parser: XMLParser,
        resolveExternalEntityName name: String,
        systemID: String?
    ) -> Data? {
        fail(OpenXMLComparisonError(code: .forbiddenDTD, part: part), parser: parser)
        return nil
    }

    func startElement(
        _ name: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) throws {}

    func endElement(_ name: String, namespaceURI: String?, qualifiedName: String?) throws {}
    func characters(_ string: String) throws {}

    func validateComplete() throws {
        if let failure { throw failure }
        guard rootSeen, depth == 0 else {
            throw OpenXMLComparisonError(code: .malformedXML, part: part)
        }
    }

    func consumeLogicalItem() throws {
        try budget.consumeLogicalItem(part: part)
    }

    private func fail(_ error: OpenXMLComparisonError, parser: XMLParser) {
        guard failure == nil else { return }
        failure = error
        parser.abortParsing()
    }
}

private final class OpenXMLContentTypesDelegate: OpenXMLBoundedDelegate {
    private var overrides: [String: String] = [:]
    private var defaults: [String: String] = [:]

    init(budget: OpenXMLXMLBudget, part: String) {
        super.init(
            budget: budget,
            part: part,
            expectedRoot: "Types",
            expectedRootNamespaces: [OpenXMLNamespaces.contentTypes]
        )
    }

    override func startElement(
        _ name: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) throws {
        guard namespaceURI == OpenXMLNamespaces.contentTypes else { return }
        switch name {
        case "Override":
            guard let rawPart = attributes.xmlValue("PartName"),
                  let contentType = attributes.xmlValue("ContentType"),
                  rawPart.hasPrefix("/") else {
                throw OpenXMLComparisonError(code: .invalidContentTypes, part: part)
            }
            let normalized = try OpenXMLRelationshipPath.resolve(
                rawPart,
                relativeTo: "",
                relationshipPart: part
            )
            guard overrides[normalized] == nil else {
                throw OpenXMLComparisonError(code: .invalidContentTypes, part: part)
            }
            overrides[normalized] = contentType
        case "Default":
            guard let rawExtension = attributes.xmlValue("Extension"),
                  let contentType = attributes.xmlValue("ContentType"),
                  !rawExtension.isEmpty,
                  !rawExtension.contains("/") else {
                throw OpenXMLComparisonError(code: .invalidContentTypes, part: part)
            }
            let ext = rawExtension.lowercased()
            guard defaults[ext] == nil else {
                throw OpenXMLComparisonError(code: .invalidContentTypes, part: part)
            }
            defaults[ext] = contentType
        default: break
        }
    }

    func result() throws -> OpenXMLContentTypes {
        guard !overrides.isEmpty || !defaults.isEmpty else {
            throw OpenXMLComparisonError(code: .invalidContentTypes, part: part)
        }
        return OpenXMLContentTypes(overrides: overrides, defaults: defaults)
    }
}

private struct OpenXMLRawRelationship {
    let identifier: String
    let type: String
    let target: String
    let isExternal: Bool
}

private final class OpenXMLRelationshipsDelegate: OpenXMLBoundedDelegate {
    private var relationships: [OpenXMLRawRelationship] = []

    init(budget: OpenXMLXMLBudget, part: String) {
        super.init(
            budget: budget,
            part: part,
            expectedRoot: "Relationships",
            expectedRootNamespaces: [OpenXMLNamespaces.packageRelationships]
        )
    }

    override func startElement(
        _ name: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) throws {
        guard namespaceURI == OpenXMLNamespaces.packageRelationships,
              name == "Relationship" else { return }
        guard let identifier = attributes.xmlValue("Id"), !identifier.isEmpty,
              let type = attributes.xmlValue("Type"), !type.isEmpty,
              let target = attributes.xmlValue("Target"), !target.isEmpty else {
            throw OpenXMLComparisonError(code: .invalidRelationships, part: part)
        }
        let targetMode = attributes.xmlValue("TargetMode")?.lowercased()
        guard targetMode == nil || targetMode == "internal" || targetMode == "external" else {
            throw OpenXMLComparisonError(code: .invalidRelationships, part: part)
        }
        try consumeLogicalItem()
        relationships.append(OpenXMLRawRelationship(
            identifier: identifier,
            type: type,
            target: target,
            isExternal: targetMode == "external"
        ))
    }

    func result() throws -> [OpenXMLRawRelationship] { relationships }
}

private final class OpenXMLCorePropertiesDelegate: OpenXMLBoundedDelegate {
    private var currentField: String?
    private var currentValue = ""
    private var values: [String: String] = [:]

    init(budget: OpenXMLXMLBudget, part: String) {
        super.init(
            budget: budget,
            part: part,
            expectedRoot: "coreProperties",
            expectedRootNamespaces: [OpenXMLNamespaces.coreProperties]
        )
    }

    override func startElement(
        _ name: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) throws {
        let expectedNamespace: String? = switch name {
        case "title", "subject", "creator", "description": OpenXMLNamespaces.dc
        case "created", "modified": OpenXMLNamespaces.dcterms
        case "lastModifiedBy", "keywords", "category": OpenXMLNamespaces.coreProperties
        default: nil
        }
        if let expectedNamespace, namespaceURI == expectedNamespace {
            currentField = name
            currentValue = ""
        }
    }

    override func characters(_ string: String) throws {
        if currentField != nil { currentValue += string }
    }

    override func endElement(_ name: String, namespaceURI: String?, qualifiedName: String?) throws {
        guard currentField == name else { return }
        if values[name] == nil { values[name] = currentValue }
        currentField = nil
        currentValue = ""
    }

    func result() -> OpenXMLCoreProperties {
        OpenXMLCoreProperties(
            title: values["title"],
            subject: values["subject"],
            creator: values["creator"],
            lastModifiedBy: values["lastModifiedBy"],
            description: values["description"],
            keywords: values["keywords"],
            category: values["category"],
            created: values["created"],
            modified: values["modified"]
        )
    }
}

private final class OpenXMLWordDocumentDelegate: OpenXMLBoundedDelegate {
    private(set) var sections: [OpenXMLLogicalSection] = []
    private var paragraphText: String?
    private var paragraphIsInTable = false
    private var collectingText = false
    private var tableDepth = 0
    private var tableRows: [[String]] = []
    private var currentRow: [String]?
    private var currentCellParagraphs: [String]?
    private var paragraphIndex = 0
    private var tableIndex = 0

    init(budget: OpenXMLXMLBudget, part: String) {
        super.init(
            budget: budget,
            part: part,
            expectedRoot: "document",
            expectedRootNamespaces: OpenXMLNamespaces.word
        )
    }

    override func startElement(
        _ name: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) throws {
        guard namespaceURI.map(OpenXMLNamespaces.word.contains) == true else { return }
        switch name {
        case "tbl":
            tableDepth += 1
            if tableDepth == 1 { tableRows = [] }
        case "tr" where tableDepth == 1:
            currentRow = []
        case "tc" where tableDepth == 1:
            currentCellParagraphs = []
        case "p" where paragraphText == nil:
            paragraphText = ""
            paragraphIsInTable = tableDepth > 0
        case "t" where paragraphText != nil:
            collectingText = true
        case "tab" where paragraphText != nil:
            paragraphText? += "\t"
        case "br" where paragraphText != nil,
             "cr" where paragraphText != nil:
            paragraphText? += "\n"
        default: break
        }
    }

    override func characters(_ string: String) throws {
        if collectingText { paragraphText? += string }
    }

    override func endElement(_ name: String, namespaceURI: String?, qualifiedName: String?) throws {
        guard namespaceURI.map(OpenXMLNamespaces.word.contains) == true else { return }
        switch name {
        case "t": collectingText = false
        case "p":
            guard let text = paragraphText else { return }
            try consumeLogicalItem()
            if paragraphIsInTable {
                currentCellParagraphs?.append(text)
            } else {
                paragraphIndex += 1
                sections.append(OpenXMLLogicalSection(
                    key: "paragraph.\(paragraphIndex)",
                    kind: .paragraph,
                    textBlocks: [text]
                ))
            }
            paragraphText = nil
            paragraphIsInTable = false
        case "tc" where tableDepth == 1:
            currentRow?.append(currentCellParagraphs?.joined(separator: "\n") ?? "")
            currentCellParagraphs = nil
        case "tr" where tableDepth == 1:
            if let currentRow { tableRows.append(currentRow) }
            self.currentRow = nil
        case "tbl":
            if tableDepth == 1 {
                try consumeLogicalItem()
                tableIndex += 1
                sections.append(OpenXMLLogicalSection(
                    key: "table.\(tableIndex)",
                    kind: .table,
                    textBlocks: tableRows.map { $0.joined(separator: "\t") }
                ))
                tableRows = []
            }
            tableDepth -= 1
        default: break
        }
    }
}

private struct OpenXMLWorkbookSheet {
    let name: String
    let relationshipID: String
}

private final class OpenXMLWorkbookDelegate: OpenXMLBoundedDelegate {
    private(set) var sheets: [OpenXMLWorkbookSheet] = []
    private let maxSheetCount: Int

    init(budget: OpenXMLXMLBudget, part: String, maxSheetCount: Int) {
        self.maxSheetCount = maxSheetCount
        super.init(
            budget: budget,
            part: part,
            expectedRoot: "workbook",
            expectedRootNamespaces: OpenXMLNamespaces.spreadsheet
        )
    }

    override func startElement(
        _ name: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) throws {
        guard namespaceURI.map(OpenXMLNamespaces.spreadsheet.contains) == true, name == "sheet",
              let sheetName = attributes.xmlValue("name"),
              let relationshipID = attributes.xmlNamespacedValue("id"),
              !sheetName.isEmpty, !relationshipID.isEmpty else { return }
        guard sheets.count < maxSheetCount else {
            throw OpenXMLComparisonError(code: .worksheetOrSlideLimitExceeded, part: part)
        }
        try consumeLogicalItem()
        sheets.append(OpenXMLWorkbookSheet(name: sheetName, relationshipID: relationshipID))
    }
}

private final class OpenXMLSharedStringsDelegate: OpenXMLBoundedDelegate {
    private(set) var strings: [String] = []
    private var current: String?
    private var collectingText = false

    init(budget: OpenXMLXMLBudget, part: String) {
        super.init(
            budget: budget,
            part: part,
            expectedRoot: "sst",
            expectedRootNamespaces: OpenXMLNamespaces.spreadsheet
        )
    }

    override func startElement(
        _ name: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) throws {
        guard namespaceURI.map(OpenXMLNamespaces.spreadsheet.contains) == true else { return }
        if name == "si" { current = "" }
        if name == "t", current != nil { collectingText = true }
    }

    override func characters(_ string: String) throws {
        if collectingText { current? += string }
    }

    override func endElement(_ name: String, namespaceURI: String?, qualifiedName: String?) throws {
        guard namespaceURI.map(OpenXMLNamespaces.spreadsheet.contains) == true else { return }
        if name == "t" { collectingText = false }
        if name == "si", let current {
            try consumeLogicalItem()
            strings.append(current)
            self.current = nil
        }
    }
}

private final class OpenXMLWorksheetDelegate: OpenXMLBoundedDelegate {
    private let sharedStrings: [String]
    private var cells: [OpenXMLCellSnapshot] = []
    private var reference: String?
    private var cellType: String?
    private var formula: String?
    private var rawValue: String?
    private var inlineText: String?
    private var collecting: String?

    init(budget: OpenXMLXMLBudget, part: String, sharedStrings: [String]) {
        self.sharedStrings = sharedStrings
        super.init(
            budget: budget,
            part: part,
            expectedRoot: "worksheet",
            expectedRootNamespaces: OpenXMLNamespaces.spreadsheet
        )
    }

    override func startElement(
        _ name: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) throws {
        guard namespaceURI.map(OpenXMLNamespaces.spreadsheet.contains) == true else { return }
        switch name {
        case "c":
            reference = attributes.xmlValue("r") ?? "cell.\(cells.count + 1)"
            cellType = attributes.xmlValue("t")
            formula = nil
            rawValue = nil
            inlineText = nil
        case "f" where reference != nil: collecting = "formula"
        case "v" where reference != nil: collecting = "value"
        case "t" where reference != nil && cellType == "inlineStr": collecting = "inline"
        default: break
        }
    }

    override func characters(_ string: String) throws {
        switch collecting {
        case "formula": formula = (formula ?? "") + string
        case "value": rawValue = (rawValue ?? "") + string
        case "inline": inlineText = (inlineText ?? "") + string
        default: break
        }
    }

    override func endElement(_ name: String, namespaceURI: String?, qualifiedName: String?) throws {
        guard namespaceURI.map(OpenXMLNamespaces.spreadsheet.contains) == true else { return }
        if name == "f" || name == "v" || name == "t" { collecting = nil }
        guard name == "c", let reference else { return }
        let displayValue: String
        switch cellType {
        case "s":
            guard let rawValue,
                  let index = Int(rawValue),
                  index >= 0,
                  index < sharedStrings.count else {
                throw OpenXMLComparisonError(code: .invalidSharedStringReference, part: part)
            }
            displayValue = sharedStrings[index]
        case "inlineStr": displayValue = inlineText ?? ""
        case "b": displayValue = rawValue == "1" ? "TRUE" : "FALSE"
        default: displayValue = rawValue ?? ""
        }
        try consumeLogicalItem()
        cells.append(OpenXMLCellSnapshot(
            reference: reference,
            displayValue: displayValue,
            formula: formula
        ))
        self.reference = nil
        cellType = nil
        formula = nil
        rawValue = nil
        inlineText = nil
    }

    func result() throws -> [OpenXMLCellSnapshot] {
        var references = Set<String>()
        for cell in cells where !references.insert(cell.reference).inserted {
            throw OpenXMLComparisonError(
                code: .duplicateIdentifier,
                part: part,
                detail: "Duplicate cell reference"
            )
        }
        return cells
    }
}

private final class OpenXMLPresentationDelegate: OpenXMLBoundedDelegate {
    private(set) var slideRelationshipIDs: [String] = []
    private let maxSlideCount: Int

    init(budget: OpenXMLXMLBudget, part: String, maxSlideCount: Int) {
        self.maxSlideCount = maxSlideCount
        super.init(
            budget: budget,
            part: part,
            expectedRoot: "presentation",
            expectedRootNamespaces: OpenXMLNamespaces.presentation
        )
    }

    override func startElement(
        _ name: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) throws {
        guard namespaceURI.map(OpenXMLNamespaces.presentation.contains) == true,
              name == "sldId",
              let relationshipID = attributes.xmlNamespacedValue("id"),
              !relationshipID.isEmpty else { return }
        guard slideRelationshipIDs.count < maxSlideCount else {
            throw OpenXMLComparisonError(code: .worksheetOrSlideLimitExceeded, part: part)
        }
        try consumeLogicalItem()
        slideRelationshipIDs.append(relationshipID)
    }
}

private final class OpenXMLSlideDelegate: OpenXMLBoundedDelegate {
    private(set) var textBlocks: [String] = []
    private var currentText: String?

    init(budget: OpenXMLXMLBudget, part: String) {
        super.init(
            budget: budget,
            part: part,
            expectedRoot: "sld",
            expectedRootNamespaces: OpenXMLNamespaces.presentation
        )
    }

    override func startElement(
        _ name: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) throws {
        if name == "t", namespaceURI.map(OpenXMLNamespaces.drawing.contains) == true {
            currentText = ""
        }
    }

    override func characters(_ string: String) throws {
        if currentText != nil { currentText? += string }
    }

    override func endElement(_ name: String, namespaceURI: String?, qualifiedName: String?) throws {
        if name == "t",
           namespaceURI.map(OpenXMLNamespaces.drawing.contains) == true,
           let currentText {
            try consumeLogicalItem()
            textBlocks.append(currentText)
            self.currentText = nil
        }
    }
}

private enum OpenXMLRelationshipPath {
    static func sourcePart(for relationshipPart: String) throws -> String {
        if relationshipPart == "_rels/.rels" { return "" }
        guard relationshipPart.hasSuffix(".rels"),
              let marker = relationshipPart.range(of: "/_rels/", options: .backwards) else {
            throw OpenXMLComparisonError(code: .invalidRelationships, part: relationshipPart)
        }
        let directory = String(relationshipPart[..<marker.lowerBound])
        let filename = String(relationshipPart[marker.upperBound...].dropLast(".rels".count))
        guard !filename.isEmpty else {
            throw OpenXMLComparisonError(code: .invalidRelationships, part: relationshipPart)
        }
        return directory.isEmpty ? filename : "\(directory)/\(filename)"
    }

    static func resolve(
        _ rawTarget: String,
        relativeTo sourcePart: String,
        relationshipPart: String
    ) throws -> String {
        guard !rawTarget.contains("\\"),
              !rawTarget.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw OpenXMLComparisonError(code: .relationshipTraversal, part: relationshipPart)
        }
        let withoutFragment = rawTarget.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let withoutQuery = withoutFragment.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
        guard let decoded = String(withoutQuery).removingPercentEncoding, !decoded.isEmpty,
              !decoded.contains("\\"),
              !decoded.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw OpenXMLComparisonError(code: .relationshipTraversal, part: relationshipPart)
        }

        var components: [String]
        if decoded.hasPrefix("/") {
            components = []
        } else {
            components = sourcePart.split(separator: "/").dropLast().map(String.init)
        }
        for rawComponent in decoded.split(separator: "/", omittingEmptySubsequences: false) {
            let component = String(rawComponent)
            if component.isEmpty || component == "." { continue }
            if component == ".." {
                guard !components.isEmpty else {
                    throw OpenXMLComparisonError(code: .relationshipTraversal, part: relationshipPart)
                }
                components.removeLast()
                continue
            }
            guard !component.contains(":"), component.utf8.count <= 4_096 else {
                throw OpenXMLComparisonError(code: .relationshipTraversal, part: relationshipPart)
            }
            components.append(component.precomposedStringWithCanonicalMapping)
        }
        guard !components.isEmpty, components.count <= 256 else {
            throw OpenXMLComparisonError(code: .relationshipTraversal, part: relationshipPart)
        }
        return components.joined(separator: "/")
    }
}

private extension Dictionary where Key == String, Value == String {
    func xmlValue(_ localName: String) -> String? {
        self[localName] ?? first(where: { key, _ in
            key.split(separator: ":").last.map(String.init) == localName
                || key.split(separator: ":").last.map(String.init)?.lowercased() == localName.lowercased()
        })?.value
    }

    func xmlNamespacedValue(_ localName: String) -> String? {
        first(where: { key, _ in
            let components = key.split(separator: ":")
            return components.count > 1
                && components.last.map(String.init)?.lowercased() == localName.lowercased()
        })?.value
    }
}

private enum OpenXMLDigest {
    static func data(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    static func strings(_ strings: [String]) -> String {
        var hasher = SHA256()
        for string in strings {
            let bytes = Data(string.utf8)
            var count = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &count) { hasher.update(bufferPointer: $0) }
            hasher.update(data: bytes)
        }
        return hex(hasher.finalize())
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
