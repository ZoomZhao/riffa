import Foundation

/// A stable, self-contained representation supported by the report renderer.
public enum ComparisonReportFormat: String, CaseIterable, Codable, Sendable {
    case plainText
    case html
    case json
}

public enum ComparisonReportKind: String, Codable, Sendable {
    case text
    case folder
}

public enum ComparisonReportStatus: String, Codable, Sendable {
    case unchanged
    case modified
    case inserted
    case deleted
    case same
    case different
    case leftOnly
    case rightOnly
    case typeMismatch
    case error
}

/// Counts are explicit rather than dictionary-backed so the schema and output
/// remain predictable as report formats evolve.
public struct ComparisonReportStatistics: Equatable, Codable, Sendable {
    public let totalCount: Int
    public let unchangedCount: Int
    public let modifiedCount: Int
    public let insertedCount: Int
    public let deletedCount: Int
    public let sameCount: Int
    public let differentCount: Int
    public let leftOnlyCount: Int
    public let rightOnlyCount: Int
    public let typeMismatchCount: Int
    public let errorCount: Int

    public init(
        totalCount: Int,
        unchangedCount: Int = 0,
        modifiedCount: Int = 0,
        insertedCount: Int = 0,
        deletedCount: Int = 0,
        sameCount: Int = 0,
        differentCount: Int = 0,
        leftOnlyCount: Int = 0,
        rightOnlyCount: Int = 0,
        typeMismatchCount: Int = 0,
        errorCount: Int = 0
    ) {
        self.totalCount = totalCount
        self.unchangedCount = unchangedCount
        self.modifiedCount = modifiedCount
        self.insertedCount = insertedCount
        self.deletedCount = deletedCount
        self.sameCount = sameCount
        self.differentCount = differentCount
        self.leftOnlyCount = leftOnlyCount
        self.rightOnlyCount = rightOnlyCount
        self.typeMismatchCount = typeMismatchCount
        self.errorCount = errorCount
    }
}

/// The data shown for one side of a report row. Source locators are
/// deliberately absent, preventing accidental disclosure of absolute paths.
public struct ComparisonReportValue: Equatable, Codable, Sendable {
    public let lineNumber: Int?
    public let text: String?
    public let lineEnding: String?
    public let resourceKind: String?
    public let byteCount: Int64?
    public let modificationDate: Date?

    public init(
        lineNumber: Int? = nil,
        text: String? = nil,
        lineEnding: String? = nil,
        resourceKind: String? = nil,
        byteCount: Int64? = nil,
        modificationDate: Date? = nil
    ) {
        self.lineNumber = lineNumber
        self.text = text
        self.lineEnding = lineEnding
        self.resourceKind = resourceKind
        self.byteCount = byteCount
        self.modificationDate = modificationDate
    }
}

public struct ComparisonReportRow: Equatable, Codable, Sendable {
    /// One-based aligned row number for text, or a relative path for folders.
    public let key: String
    public let status: ComparisonReportStatus
    public let left: ComparisonReportValue?
    public let right: ComparisonReportValue?

    public init(
        key: String,
        status: ComparisonReportStatus,
        left: ComparisonReportValue?,
        right: ComparisonReportValue?
    ) {
        self.key = key
        self.status = status
        self.left = left
        self.right = right
    }
}

/// Codable DTO used as the single source for plain-text, HTML, and JSON output.
public struct ComparisonReportDocument: Equatable, Codable, Sendable {
    public let schemaVersion: Int
    public let kind: ComparisonReportKind
    public let leftLabel: String
    public let rightLabel: String
    public let statistics: ComparisonReportStatistics
    public let rows: [ComparisonReportRow]

    public init(
        schemaVersion: Int = 1,
        kind: ComparisonReportKind,
        leftLabel: String,
        rightLabel: String,
        statistics: ComparisonReportStatistics,
        rows: [ComparisonReportRow]
    ) {
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.leftLabel = leftLabel
        self.rightLabel = rightLabel
        self.statistics = statistics
        self.rows = rows
    }
}

/// Builds privacy-conscious comparison reports with deterministic ordering and
/// no timestamps, random identifiers, or external HTML resources.
public struct ComparisonReportGenerator: Sendable {
    public init() {}

    public func document(
        for result: TextDiffResult,
        leftLabel: String = "Left",
        rightLabel: String = "Right"
    ) -> ComparisonReportDocument {
        let rows = result.alignedLines.map { line in
            ComparisonReportRow(
                key: String(line.offset + 1),
                status: reportStatus(for: line.kind),
                left: line.left.map(textValue(for:)),
                right: line.right.map(textValue(for:))
            )
        }

        return ComparisonReportDocument(
            kind: .text,
            leftLabel: leftLabel,
            rightLabel: rightLabel,
            statistics: ComparisonReportStatistics(
                totalCount: rows.count,
                unchangedCount: result.statistics.unchangedLineCount,
                modifiedCount: result.statistics.modifiedLineCount,
                insertedCount: result.statistics.insertedLineCount,
                deletedCount: result.statistics.deletedLineCount
            ),
            rows: rows
        )
    }

    public func document(
        for nodes: [PairNode],
        leftLabel: String = "Left",
        rightLabel: String = "Right"
    ) -> ComparisonReportDocument {
        let orderedNodes = nodes.sorted { lhs, rhs in
            if lhs.relativePath != rhs.relativePath {
                return lhs.relativePath < rhs.relativePath
            }
            return lhs.status.rawValue < rhs.status.rawValue
        }

        let rows = orderedNodes.map { node in
            ComparisonReportRow(
                key: node.relativePath,
                status: reportStatus(for: node.status),
                left: node.left.map(resourceValue(for:)),
                right: node.right.map(resourceValue(for:))
            )
        }

        return ComparisonReportDocument(
            kind: .folder,
            leftLabel: leftLabel,
            rightLabel: rightLabel,
            statistics: folderStatistics(for: orderedNodes),
            rows: rows
        )
    }

    public func generate(
        text result: TextDiffResult,
        format: ComparisonReportFormat,
        leftLabel: String = "Left",
        rightLabel: String = "Right"
    ) throws -> String {
        try render(
            document(for: result, leftLabel: leftLabel, rightLabel: rightLabel),
            as: format
        )
    }

    public func generate(
        folder nodes: [PairNode],
        format: ComparisonReportFormat,
        leftLabel: String = "Left",
        rightLabel: String = "Right"
    ) throws -> String {
        try render(
            document(for: nodes, leftLabel: leftLabel, rightLabel: rightLabel),
            as: format
        )
    }

    public func render(
        _ document: ComparisonReportDocument,
        as format: ComparisonReportFormat
    ) throws -> String {
        switch format {
        case .plainText:
            plainText(for: document)
        case .html:
            html(for: document)
        case .json:
            try json(for: document)
        }
    }

    private func textValue(for value: DiffLineValue) -> ComparisonReportValue {
        ComparisonReportValue(
            lineNumber: value.lineNumber,
            text: value.line.content,
            lineEnding: displayName(for: value.line.ending)
        )
    }

    private func resourceValue(for entry: ResourceEntry) -> ComparisonReportValue {
        ComparisonReportValue(
            resourceKind: entry.kind.rawValue,
            byteCount: entry.byteCount,
            modificationDate: entry.modificationDate
        )
    }

    private func reportStatus(for kind: DiffLineKind) -> ComparisonReportStatus {
        switch kind {
        case .unchanged: .unchanged
        case .modified: .modified
        case .inserted: .inserted
        case .deleted: .deleted
        }
    }

    private func reportStatus(for status: PairNode.Status) -> ComparisonReportStatus {
        switch status {
        case .same: .same
        case .different: .different
        case .leftOnly: .leftOnly
        case .rightOnly: .rightOnly
        case .typeMismatch: .typeMismatch
        case .error: .error
        }
    }

    private func displayName(for ending: TextLineEnding) -> String {
        switch ending {
        case .none: "none"
        case .lf: "LF"
        case .crlf: "CRLF"
        case .cr: "CR"
        }
    }

    private func folderStatistics(for nodes: [PairNode]) -> ComparisonReportStatistics {
        var same = 0
        var different = 0
        var leftOnly = 0
        var rightOnly = 0
        var typeMismatch = 0
        var error = 0

        for node in nodes {
            switch node.status {
            case .same: same += 1
            case .different: different += 1
            case .leftOnly: leftOnly += 1
            case .rightOnly: rightOnly += 1
            case .typeMismatch: typeMismatch += 1
            case .error: error += 1
            }
        }

        return ComparisonReportStatistics(
            totalCount: nodes.count,
            sameCount: same,
            differentCount: different,
            leftOnlyCount: leftOnly,
            rightOnlyCount: rightOnly,
            typeMismatchCount: typeMismatch,
            errorCount: error
        )
    }

    private func plainText(for document: ComparisonReportDocument) -> String {
        var lines = [
            "Riffa Comparison Report",
            "Schema: \(document.schemaVersion)",
            "Kind: \(document.kind.rawValue)",
            "Left: \(plainField(document.leftLabel))",
            "Right: \(plainField(document.rightLabel))",
            "Statistics: \(statisticsText(document.statistics))",
            "Rows:"
        ]

        for row in document.rows {
            lines.append(
                [
                    plainField(row.key),
                    row.status.rawValue,
                    plainValue(row.left),
                    plainValue(row.right)
                ].joined(separator: "\t")
            )
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private func plainValue(_ value: ComparisonReportValue?) -> String {
        guard let value else { return "—" }

        var fields: [String] = []
        if let lineNumber = value.lineNumber { fields.append("line=\(lineNumber)") }
        if let text = value.text { fields.append("text=\(plainField(text))") }
        if let lineEnding = value.lineEnding { fields.append("ending=\(lineEnding)") }
        if let resourceKind = value.resourceKind { fields.append("kind=\(resourceKind)") }
        if let byteCount = value.byteCount { fields.append("bytes=\(byteCount)") }
        if let modificationDate = value.modificationDate {
            fields.append("modified=\(dateText(modificationDate))")
        }
        return fields.joined(separator: ";")
    }

    private func plainField(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private func statisticsText(_ statistics: ComparisonReportStatistics) -> String {
        [
            "total=\(statistics.totalCount)",
            "unchanged=\(statistics.unchangedCount)",
            "modified=\(statistics.modifiedCount)",
            "inserted=\(statistics.insertedCount)",
            "deleted=\(statistics.deletedCount)",
            "same=\(statistics.sameCount)",
            "different=\(statistics.differentCount)",
            "leftOnly=\(statistics.leftOnlyCount)",
            "rightOnly=\(statistics.rightOnlyCount)",
            "typeMismatch=\(statistics.typeMismatchCount)",
            "error=\(statistics.errorCount)"
        ].joined(separator: " ")
    }

    private func html(for document: ComparisonReportDocument) -> String {
        let rows = document.rows.map { row in
            """
              <tr class="status-\(row.status.rawValue)">
                <td>\(htmlEscape(row.key))</td>
                <td><span class="status">\(htmlEscape(row.status.rawValue))</span></td>
                <td>\(htmlValue(row.left))</td>
                <td>\(htmlValue(row.right))</td>
              </tr>
            """
        }.joined(separator: "\n")

        return """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Riffa Comparison Report</title>
          <style>
            :root { color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, sans-serif; }
            body { margin: 2rem auto; max-width: 1100px; padding: 0 1rem; background: Canvas; color: CanvasText; }
            h1 { margin-bottom: .25rem; } .labels { color: GrayText; margin-top: 0; }
            .summary { display: flex; flex-wrap: wrap; gap: .5rem; margin: 1.25rem 0; }
            .metric, .status { border: 1px solid color-mix(in srgb, CanvasText 18%, transparent); border-radius: 999px; padding: .2rem .55rem; }
            table { border-collapse: collapse; width: 100%; table-layout: fixed; }
            th, td { border-bottom: 1px solid color-mix(in srgb, CanvasText 14%, transparent); padding: .55rem; text-align: left; vertical-align: top; overflow-wrap: anywhere; }
            th { position: sticky; top: 0; background: Canvas; }
            td:nth-child(1) { width: 18%; } td:nth-child(2) { width: 12%; }
            .status-modified, .status-different, .status-typeMismatch { background: color-mix(in srgb, orange 12%, transparent); }
            .status-inserted, .status-rightOnly { background: color-mix(in srgb, seagreen 12%, transparent); }
            .status-deleted, .status-leftOnly, .status-error { background: color-mix(in srgb, crimson 11%, transparent); }
            code { white-space: pre-wrap; font-family: ui-monospace, SFMono-Regular, monospace; }
          </style>
        </head>
        <body>
          <h1>Riffa Comparison Report</h1>
          <p class="labels">\(htmlEscape(document.kind.rawValue)) · \(htmlEscape(document.leftLabel)) ↔ \(htmlEscape(document.rightLabel))</p>
          <section class="summary" aria-label="Statistics">\(statisticsHTML(document.statistics))</section>
          <table>
            <thead><tr><th>Row / path</th><th>Status</th><th>\(htmlEscape(document.leftLabel))</th><th>\(htmlEscape(document.rightLabel))</th></tr></thead>
            <tbody>
        \(rows)
            </tbody>
          </table>
        </body>
        </html>
        """ + "\n"
    }

    private func htmlValue(_ value: ComparisonReportValue?) -> String {
        guard let value else { return "<span aria-label=\"not present\">—</span>" }
        var fields: [String] = []
        if let lineNumber = value.lineNumber { fields.append("line \(lineNumber)") }
        if let text = value.text { fields.append("<code>\(htmlEscape(text))</code>") }
        if let lineEnding = value.lineEnding { fields.append("ending \(htmlEscape(lineEnding))") }
        if let resourceKind = value.resourceKind { fields.append(htmlEscape(resourceKind)) }
        if let byteCount = value.byteCount { fields.append("\(byteCount) bytes") }
        if let modificationDate = value.modificationDate {
            fields.append(htmlEscape(dateText(modificationDate)))
        }
        return fields.joined(separator: "<br>")
    }

    private func statisticsHTML(_ statistics: ComparisonReportStatistics) -> String {
        let values: [(String, Int)] = [
            ("Total", statistics.totalCount),
            ("Unchanged", statistics.unchangedCount),
            ("Modified", statistics.modifiedCount),
            ("Inserted", statistics.insertedCount),
            ("Deleted", statistics.deletedCount),
            ("Same", statistics.sameCount),
            ("Different", statistics.differentCount),
            ("Left only", statistics.leftOnlyCount),
            ("Right only", statistics.rightOnlyCount),
            ("Type mismatch", statistics.typeMismatchCount),
            ("Errors", statistics.errorCount)
        ]
        return values.map { label, value in
            "<span class=\"metric\">\(label): \(value)</span>"
        }.joined(separator: " ")
    }

    private func htmlEscape(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.utf8.count)
        for character in value {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            default: result.append(character)
            }
        }
        return result
    }

    private func json(for document: ComparisonReportDocument) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        guard let output = String(data: data, encoding: .utf8) else {
            throw ComparisonReportEncodingError.invalidUTF8
        }
        return output + "\n"
    }

    private func dateText(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}

public enum ComparisonReportEncodingError: Error, Sendable {
    case invalidUTF8
}
