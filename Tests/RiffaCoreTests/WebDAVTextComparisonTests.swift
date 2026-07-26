import Foundation
import Testing
@testable import RiffaCore

@Suite("Bounded WebDAV text comparison")
struct WebDAVTextComparisonTests {
    @Test("Stable snapshots are validated and compared inside every publication bound")
    func boundedComparison() async throws {
        let engine = WebDAVTextComparisonEngine(
            limits: WebDAVTextComparisonLimits(
                maximumByteCountPerDocument: 1_024,
                maximumLogicalLineCountPerDocument: 8,
                maximumLineUTF8ByteCount: 64,
                maximumLineCharacterCount: 32,
                maximumPublishedLineCount: 16
            )
        )
        let left = try await engine.validate(snapshot("alpha\r\nbeta\n", path: "left.txt"))
        let right = try await engine.validate(snapshot("alpha\ngamma\n", path: "right.txt"))
        let result = try await engine.compare(left, to: right)

        #expect(left.logicalLineCount == 2)
        #expect(right.logicalLineCount == 2)
        #expect(result.alignedLines.count == 2)
        #expect(result.statistics.unchangedLineCount == 1)
        #expect(result.statistics.modifiedLineCount == 1)
    }

    @Test("Byte, line, per-line byte, character, and publication limits fail path-free")
    func strictLimits() async throws {
        await expectComparisonError(.byteLimitExceeded) {
            try await WebDAVTextComparisonEngine(
                limits: limits(bytes: 3)
            ).validate(snapshot("four", path: "private/server/token.txt"))
        }
        await expectComparisonError(.lineCountExceeded) {
            try await WebDAVTextComparisonEngine(
                limits: limits(lines: 1)
            ).validate(snapshot("one\ntwo", path: "private/server/token.txt"))
        }
        await expectComparisonError(.lineByteLimitExceeded) {
            try await WebDAVTextComparisonEngine(
                limits: limits(lineBytes: 3)
            ).validate(snapshot("éé", path: "private/server/token.txt"))
        }
        await expectComparisonError(.lineCharacterLimitExceeded) {
            try await WebDAVTextComparisonEngine(
                limits: limits(lineCharacters: 1)
            ).validate(snapshot("ab", path: "private/server/token.txt"))
        }

        let publicationEngine = WebDAVTextComparisonEngine(
            limits: limits(publishedLines: 3)
        )
        let left = try await publicationEngine.validate(snapshot("a\nb\n", path: "left"))
        let right = try await publicationEngine.validate(snapshot("c\nd\n", path: "right"))
        await expectComparisonError(.publishedLineLimitExceeded) {
            try await publicationEngine.compare(left, to: right)
        }
    }

    @Test("Invalid comparison limits are rejected before document expansion")
    func invalidLimits() async {
        await expectComparisonError(.invalidLimits) {
            try await WebDAVTextComparisonEngine(
                limits: limits(lines: 0)
            ).validate(snapshot("content", path: "hidden"))
        }
    }

    @Test("Validation and diff workers propagate task cancellation")
    func cancellation() async throws {
        let text = Array(repeating: "line", count: 20_000).joined(separator: "\n")
        let engine = WebDAVTextComparisonEngine(
            limits: WebDAVTextComparisonLimits(
                maximumByteCountPerDocument: 1_000_000,
                maximumLogicalLineCountPerDocument: 25_000,
                maximumLineUTF8ByteCount: 64,
                maximumLineCharacterCount: 64,
                maximumPublishedLineCount: 50_000
            )
        )
        let left = try await engine.validate(snapshot(text, path: "left"))
        let right = try await engine.validate(snapshot(text + " changed", path: "right"))
        let task = Task { try await engine.compare(left, to: right) }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test("HTML reports escape content and enforce row and UTF-8 output limits")
    func boundedHTMLReport() async throws {
        let diff = TextDiffEngine().compare(
            TextDocument(text: "<left>\nsame"),
            to: TextDocument(text: "right & newer\nsame")
        )
        let report = try await WebDAVTextHTMLReportGenerator(
            limits: WebDAVTextHTMLReportLimits(
                maximumRowCount: 4,
                maximumUTF8ByteCount: 16 * 1_024
            )
        ).generate(diff, leftLabel: "Left <private>", rightLabel: "Right & safe")
        #expect(report.contains("&lt;left&gt;"))
        #expect(report.contains("Left &lt;private&gt;"))
        #expect(report.contains("Right &amp; safe"))
        #expect(!report.contains("<left>"))

        await expectReportError(.rowLimitExceeded) {
            try await WebDAVTextHTMLReportGenerator(
                limits: WebDAVTextHTMLReportLimits(
                    maximumRowCount: 1,
                    maximumUTF8ByteCount: 1_024
                )
            ).generate(diff, leftLabel: "Left", rightLabel: "Right")
        }
        await expectReportError(.outputByteLimitExceeded) {
            try await WebDAVTextHTMLReportGenerator(
                limits: WebDAVTextHTMLReportLimits(
                    maximumRowCount: 4,
                    maximumUTF8ByteCount: 64
                )
            ).generate(diff, leftLabel: "Left", rightLabel: "Right")
        }
    }

    @Test("HTML report generation propagates cancellation")
    func reportCancellation() async throws {
        let text = Array(repeating: "same", count: 8_000).joined(separator: "\n")
        let diff = TextDiffEngine().compare(TextDocument(text: text), to: TextDocument(text: text))
        let task = Task {
            try await WebDAVTextHTMLReportGenerator().generate(
                diff,
                leftLabel: "Left",
                rightLabel: "Right"
            )
        }
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    private func snapshot(_ text: String, path: String) -> WebDAVTextDocumentSnapshot {
        let data = Data(text.utf8)
        let fingerprint = DecodedTextFileFingerprint(data: data)
        return WebDAVTextDocumentSnapshot(
            relativePath: path,
            document: DecodedTextDocument(
                text: text,
                format: .utf8,
                fingerprint: fingerprint
            ),
            version: WebDAVTextDocumentVersion(
                contentLength: Int64(data.count),
                modificationDate: nil,
                etag: "\"stable\"",
                fingerprint: fingerprint
            )
        )
    }

    private func limits(
        bytes: UInt64 = 1_024,
        lines: Int = 16,
        lineBytes: Int = 128,
        lineCharacters: Int = 128,
        publishedLines: Int = 32
    ) -> WebDAVTextComparisonLimits {
        WebDAVTextComparisonLimits(
            maximumByteCountPerDocument: bytes,
            maximumLogicalLineCountPerDocument: lines,
            maximumLineUTF8ByteCount: lineBytes,
            maximumLineCharacterCount: lineCharacters,
            maximumPublishedLineCount: publishedLines
        )
    }

    private func expectComparisonError<Value: Sendable>(
        _ expected: WebDAVTextComparisonError.Code,
        operation: () async throws -> Value
    ) async {
        do {
            _ = try await operation()
            Issue.record("Expected WebDAV text comparison error \(expected)")
        } catch let error as WebDAVTextComparisonError {
            #expect(error.code == expected)
            #expect(!error.localizedDescription.contains("private/server/token.txt"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private func expectReportError(
        _ expected: WebDAVTextHTMLReportError.Code,
        operation: () async throws -> String
    ) async {
        do {
            _ = try await operation()
            Issue.record("Expected WebDAV text report error \(expected)")
        } catch let error as WebDAVTextHTMLReportError {
            #expect(error.code == expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
