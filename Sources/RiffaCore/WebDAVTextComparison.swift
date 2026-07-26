import Foundation

/// Strict limits for turning stable WebDAV text snapshots into an in-memory diff.
///
/// These limits are intentionally separate from the transport byte limit. A
/// small, newline-dense response can otherwise expand into millions of Swift
/// values while it is split, aligned, displayed, and reported.
public struct WebDAVTextComparisonLimits: Hashable, Codable, Sendable {
    public let maximumByteCountPerDocument: UInt64
    public let maximumLogicalLineCountPerDocument: Int
    public let maximumLineUTF8ByteCount: Int
    public let maximumLineCharacterCount: Int
    public let maximumPublishedLineCount: Int

    public init(
        maximumByteCountPerDocument: UInt64 = 8 * 1_024 * 1_024,
        maximumLogicalLineCountPerDocument: Int = 100_000,
        maximumLineUTF8ByteCount: Int = 256 * 1_024,
        maximumLineCharacterCount: Int = 128 * 1_024,
        maximumPublishedLineCount: Int = 200_000
    ) {
        self.maximumByteCountPerDocument = maximumByteCountPerDocument
        self.maximumLogicalLineCountPerDocument = maximumLogicalLineCountPerDocument
        self.maximumLineUTF8ByteCount = maximumLineUTF8ByteCount
        self.maximumLineCharacterCount = maximumLineCharacterCount
        self.maximumPublishedLineCount = maximumPublishedLineCount
    }

    public static let `default` = Self()
}

public struct WebDAVTextComparisonError: Error, Hashable, Codable, Sendable, LocalizedError {
    public enum Code: String, Hashable, Codable, Sendable {
        case invalidLimits
        case byteLimitExceeded
        case lineCountExceeded
        case lineByteLimitExceeded
        case lineCharacterLimitExceeded
        case publishedLineLimitExceeded
    }

    public let code: Code
    public let attempted: UInt64?
    public let limit: UInt64?

    public init(code: Code, attempted: UInt64? = nil, limit: UInt64? = nil) {
        self.code = code
        self.attempted = attempted
        self.limit = limit
    }

    public var errorDescription: String? {
        switch code {
        case .invalidLimits:
            "The WebDAV text comparison limits are invalid."
        case .byteLimitExceeded:
            "A WebDAV text document exceeds the comparison byte limit."
        case .lineCountExceeded:
            "A WebDAV text document exceeds the logical line limit."
        case .lineByteLimitExceeded:
            "A WebDAV text document contains a line that exceeds the UTF-8 byte limit."
        case .lineCharacterLimitExceeded:
            "A WebDAV text document contains a line that exceeds the character limit."
        case .publishedLineLimitExceeded:
            "The WebDAV text comparison exceeds the published line limit."
        }
    }
}

/// A snapshot that has passed all expansion-sensitive validation.
public struct ValidatedWebDAVTextDocument: Sendable {
    public let snapshot: WebDAVTextDocumentSnapshot
    public let logicalLineCount: Int

    fileprivate init(snapshot: WebDAVTextDocumentSnapshot, logicalLineCount: Int) {
        self.snapshot = snapshot
        self.logicalLineCount = logicalLineCount
    }
}

/// Validates and compares stable WebDAV text without inheriting transport-scale
/// allocation limits. The async entry points run away from actor executors and
/// check cooperative cancellation throughout their bounded scans.
public struct WebDAVTextComparisonEngine: Sendable {
    public let limits: WebDAVTextComparisonLimits

    public init(limits: WebDAVTextComparisonLimits = .default) {
        self.limits = limits
    }

    public var documentLimits: DecodedTextDocumentLimits {
        DecodedTextDocumentLimits(maximumByteCount: limits.maximumByteCountPerDocument)
    }

    public func validate(
        _ snapshot: WebDAVTextDocumentSnapshot
    ) async throws -> ValidatedWebDAVTextDocument {
        try validateLimits()
        try Task.checkCancellation()
        let byteCount = snapshot.version.fingerprint.byteCount
        guard byteCount <= limits.maximumByteCountPerDocument else {
            throw WebDAVTextComparisonError(
                code: .byteLimitExceeded,
                attempted: byteCount,
                limit: limits.maximumByteCountPerDocument
            )
        }

        let lineCount = try scan(snapshot.document.text)
        try Task.checkCancellation()
        return ValidatedWebDAVTextDocument(
            snapshot: snapshot,
            logicalLineCount: lineCount
        )
    }

    public func compare(
        _ left: ValidatedWebDAVTextDocument,
        to right: ValidatedWebDAVTextDocument
    ) async throws -> TextDiffResult {
        try validateLimits()
        try Task.checkCancellation()

        let potentialPublishedCount = left.logicalLineCount.addingReportingOverflow(
            right.logicalLineCount
        )
        guard !potentialPublishedCount.overflow,
              potentialPublishedCount.partialValue <= limits.maximumPublishedLineCount else {
            throw WebDAVTextComparisonError(
                code: .publishedLineLimitExceeded,
                attempted: potentialPublishedCount.overflow
                    ? nil
                    : UInt64(potentialPublishedCount.partialValue),
                limit: UInt64(limits.maximumPublishedLineCount)
            )
        }

        let leftDocument = TextDocument(text: left.snapshot.document.text)
        try Task.checkCancellation()
        let rightDocument = TextDocument(text: right.snapshot.document.text)
        try Task.checkCancellation()
        let result = try TextDiffEngine().compareCancellable(leftDocument, to: rightDocument)
        try Task.checkCancellation()
        guard result.alignedLines.count <= limits.maximumPublishedLineCount else {
            throw WebDAVTextComparisonError(
                code: .publishedLineLimitExceeded,
                attempted: UInt64(result.alignedLines.count),
                limit: UInt64(limits.maximumPublishedLineCount)
            )
        }
        return result
    }

    private func validateLimits() throws {
        guard limits.maximumByteCountPerDocument > 0,
              limits.maximumByteCountPerDocument <= UInt64(Int.max),
              limits.maximumLogicalLineCountPerDocument > 0,
              limits.maximumLineUTF8ByteCount > 0,
              limits.maximumLineCharacterCount > 0,
              limits.maximumPublishedLineCount > 0 else {
            throw WebDAVTextComparisonError(code: .invalidLimits)
        }
    }

    private func scan(_ text: String) throws -> Int {
        guard !text.isEmpty else { return 0 }

        var lineCount = 0
        var lineByteCount = 0
        var lineCharacterCount = 0
        var hasUnterminatedContent = false
        var inspectedCharacterCount = 0

        for character in text {
            if inspectedCharacterCount & 0x3FF == 0 {
                try Task.checkCancellation()
            }
            inspectedCharacterCount += 1

            if character == "\n" || character == "\r" || character == "\r\n" {
                lineCount += 1
                try enforceLineCount(lineCount)
                lineByteCount = 0
                lineCharacterCount = 0
                hasUnterminatedContent = false
                continue
            }

            let byteAttempt = lineByteCount.addingReportingOverflow(
                String(character).utf8.count
            )
            guard !byteAttempt.overflow,
                  byteAttempt.partialValue <= limits.maximumLineUTF8ByteCount else {
                throw WebDAVTextComparisonError(
                    code: .lineByteLimitExceeded,
                    attempted: byteAttempt.overflow ? nil : UInt64(byteAttempt.partialValue),
                    limit: UInt64(limits.maximumLineUTF8ByteCount)
                )
            }
            lineByteCount = byteAttempt.partialValue

            let characterAttempt = lineCharacterCount.addingReportingOverflow(1)
            guard !characterAttempt.overflow,
                  characterAttempt.partialValue <= limits.maximumLineCharacterCount else {
                throw WebDAVTextComparisonError(
                    code: .lineCharacterLimitExceeded,
                    attempted: characterAttempt.overflow
                        ? nil
                        : UInt64(characterAttempt.partialValue),
                    limit: UInt64(limits.maximumLineCharacterCount)
                )
            }
            lineCharacterCount = characterAttempt.partialValue
            hasUnterminatedContent = true
        }

        if hasUnterminatedContent {
            lineCount += 1
            try enforceLineCount(lineCount)
        }
        return lineCount
    }

    private func enforceLineCount(_ count: Int) throws {
        guard count <= limits.maximumLogicalLineCountPerDocument else {
            throw WebDAVTextComparisonError(
                code: .lineCountExceeded,
                attempted: UInt64(count),
                limit: UInt64(limits.maximumLogicalLineCountPerDocument)
            )
        }
    }
}

public struct WebDAVTextHTMLReportLimits: Hashable, Codable, Sendable {
    public let maximumRowCount: Int
    public let maximumUTF8ByteCount: Int

    public init(
        maximumRowCount: Int = 200_000,
        maximumUTF8ByteCount: Int = 16 * 1_024 * 1_024
    ) {
        self.maximumRowCount = maximumRowCount
        self.maximumUTF8ByteCount = maximumUTF8ByteCount
    }

    public static let `default` = Self()
}

public struct WebDAVTextHTMLReportError: Error, Hashable, Codable, Sendable, LocalizedError {
    public enum Code: String, Hashable, Codable, Sendable {
        case invalidLimits
        case rowLimitExceeded
        case outputByteLimitExceeded
    }

    public let code: Code
    public let attempted: Int?
    public let limit: Int?

    public init(code: Code, attempted: Int? = nil, limit: Int? = nil) {
        self.code = code
        self.attempted = attempted
        self.limit = limit
    }

    public var errorDescription: String? {
        switch code {
        case .invalidLimits:
            "The WebDAV text report limits are invalid."
        case .rowLimitExceeded:
            "The WebDAV text report exceeds the row limit."
        case .outputByteLimitExceeded:
            "The WebDAV text report exceeds the UTF-8 output limit."
        }
    }
}

/// Produces a self-contained, escaped HTML report with strict publication
/// bounds. It deliberately accepts no server URL or authentication value.
public struct WebDAVTextHTMLReportGenerator: Sendable {
    public let limits: WebDAVTextHTMLReportLimits

    public init(limits: WebDAVTextHTMLReportLimits = .default) {
        self.limits = limits
    }

    public func generate(
        _ result: TextDiffResult,
        leftLabel: String,
        rightLabel: String
    ) async throws -> String {
        guard limits.maximumRowCount > 0, limits.maximumUTF8ByteCount > 0 else {
            throw WebDAVTextHTMLReportError(code: .invalidLimits)
        }
        guard result.alignedLines.count <= limits.maximumRowCount else {
            throw WebDAVTextHTMLReportError(
                code: .rowLimitExceeded,
                attempted: result.alignedLines.count,
                limit: limits.maximumRowCount
            )
        }

        var output = BoundedWebDAVHTMLBuilder(limit: limits.maximumUTF8ByteCount)
        try output.append("<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">")
        try output.append("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">")
        try output.append("<title>Riffa WebDAV Text Comparison</title><style>")
        try output.append("body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;margin:2rem}table{border-collapse:collapse;width:100%;table-layout:fixed}th,td{border-bottom:1px solid #8885;padding:.45rem;text-align:left;vertical-align:top;overflow-wrap:anywhere}code{white-space:pre-wrap;font-family:ui-monospace,SFMono-Regular,monospace}.modified{background:#f90a}.inserted{background:#080a}.deleted{background:#d00a}</style></head><body>")
        try output.append("<h1>Riffa WebDAV Text Comparison</h1><p>")
        try output.appendEscaped(leftLabel)
        try output.append(" ↔ ")
        try output.appendEscaped(rightLabel)
        try output.append("</p><table><thead><tr><th>Status</th><th>")
        try output.appendEscaped(leftLabel)
        try output.append("</th><th>")
        try output.appendEscaped(rightLabel)
        try output.append("</th></tr></thead><tbody>\n")

        for (offset, line) in result.alignedLines.enumerated() {
            if offset & 0xFF == 0 {
                try Task.checkCancellation()
            }
            try output.append("<tr class=\"")
            try output.append(Self.statusName(line.kind))
            try output.append("\"><td>")
            try output.append(Self.statusName(line.kind))
            try output.append("</td><td>")
            try output.appendLine(line.left)
            try output.append("</td><td>")
            try output.appendLine(line.right)
            try output.append("</td></tr>\n")
        }
        try Task.checkCancellation()
        try output.append("</tbody></table></body></html>\n")
        return output.value
    }

    private static func statusName(_ kind: DiffLineKind) -> String {
        switch kind {
        case .unchanged: "unchanged"
        case .inserted: "inserted"
        case .deleted: "deleted"
        case .modified: "modified"
        }
    }
}

private struct BoundedWebDAVHTMLBuilder {
    private(set) var value = ""
    private var byteCount = 0
    private let limit: Int

    init(limit: Int) {
        self.limit = limit
        value.reserveCapacity(min(limit, 64 * 1_024))
    }

    mutating func append(_ text: String) throws {
        let attempt = byteCount.addingReportingOverflow(text.utf8.count)
        guard !attempt.overflow, attempt.partialValue <= limit else {
            throw WebDAVTextHTMLReportError(
                code: .outputByteLimitExceeded,
                attempted: attempt.overflow ? nil : attempt.partialValue,
                limit: limit
            )
        }
        value.append(text)
        byteCount = attempt.partialValue
    }

    mutating func appendEscaped(_ text: String) throws {
        for (offset, character) in text.enumerated() {
            if offset & 0x3FF == 0 {
                try Task.checkCancellation()
            }
            switch character {
            case "&": try append("&amp;")
            case "<": try append("&lt;")
            case ">": try append("&gt;")
            case "\"": try append("&quot;")
            case "'": try append("&#39;")
            default: try append(String(character))
            }
        }
    }

    mutating func appendLine(_ line: DiffLineValue?) throws {
        guard let line else {
            try append("<span aria-label=\"not present\">—</span>")
            return
        }
        try append("<span>line ")
        try append(String(line.lineNumber))
        try append("</span><br><code>")
        try appendEscaped(line.line.content)
        try append("</code>")
    }
}
