import Foundation
import Testing
@testable import RiffaCore

@Suite("Archive specialized reports")
struct ArchiveComparisonReportTests {
    private let generator = SpecializedComparisonReportGenerator()

    @Test("Plain, HTML, and JSON reports are deterministic, portable, and byte-free")
    func formatsPrivacyAndDeterminism() throws {
        let result = try comparisonResult()
        for format in ComparisonReportFormat.allCases {
            let first = try generator.generate(
                archive: result,
                format: format,
                leftLabel: "/Users/private/左<archive>.zip",
                rightLabel: "file:///Users/private/right%26archive.tar"
            )
            let second = try generator.generate(
                archive: result,
                format: format,
                leftLabel: "/Users/private/左<archive>.zip",
                rightLabel: "file:///Users/private/right%26archive.tar"
            )

            #expect(first == second)
            #expect(first.contains("archive"))
            #expect(first.contains("资料"))
            #expect(first.contains(String(repeating: "a", count: 64)))
            #expect(!first.contains("/Users/private"))
            #expect(!first.contains("file://"))
            #expect(!first.contains("RAW_ARCHIVE_BYTES_MUST_NOT_APPEAR"))
        }
    }

    @Test("HTML escapes archive paths, link destinations, and portable labels")
    func htmlEscaping() throws {
        let html = try generator.generate(
            archive: comparisonResult(),
            format: .html,
            leftLabel: "左<archive>.zip",
            rightLabel: "右&archive.tar"
        )

        #expect(html.contains("左&lt;archive&gt;.zip"))
        #expect(html.contains("右&amp;archive.tar"))
        #expect(html.contains("资料/&lt;script&gt;.txt"))
        #expect(html.contains("target&lt;&amp;&gt;"))
        #expect(!html.contains("<script>"))
    }

    @Test("JSON round-trips through the stable specialized report DTO")
    func jsonRoundTrip() throws {
        let document = generator.document(
            for: try comparisonResult(),
            leftLabel: "/private/left.zip",
            rightLabel: "/private/right.tar"
        )

        #expect(document.kind == .archive)
        #expect(document.leftLabel == "left.zip")
        #expect(document.rightLabel == "right.tar")
        let json = try generator.render(document, as: .json)
        let decoded = try JSONDecoder().decode(
            SpecializedComparisonReportDocument.self,
            from: Data(json.utf8)
        )
        #expect(decoded == document)
        #expect(json.utf8.count < 100_000)
    }

    @Test("Report detail rows obey the validated comparison entry ceiling")
    func reportRowLimit() throws {
        let options = try ArchiveComparisonOptions(
            limits: ArchiveComparisonLimits(maxComparedEntryCount: 1),
            compareContent: false
        )
        let summary = entry(kind: .file, byteCount: 1, digest: nil)
        let rows = ["c", "a", "b"].map {
            ArchiveComparisonRow(
                path: $0,
                status: .same,
                left: summary,
                right: summary
            )
        }
        let result = ArchiveComparisonResult(
            leftFormat: .zip,
            rightFormat: .tar,
            options: options,
            rows: rows,
            statistics: ArchiveComparisonStatistics(
                totalCount: 3,
                sameCount: 3,
                differentCount: 0,
                leftOnlyCount: 0,
                rightOnlyCount: 0,
                hashedFileCount: 0,
                readAndHashedByteCount: 0
            )
        )

        let document = generator.document(for: result)
        #expect(document.rows.count == 1)
        #expect(document.rows.first?.key == "c")
        #expect(document.summary.contains { field in
            field.key == "publishedRowCount" && field.value == .integer(1)
        })
    }

    @Test("Archive report documents remain strictly Sendable")
    func sendableReport() async throws {
        let document = generator.document(for: try comparisonResult())
        requireArchiveReportSendable(document)
        let copied = await Task.detached { @Sendable in document }.value
        #expect(copied == document)
    }

    private func comparisonResult() throws -> ArchiveComparisonResult {
        let options = try ArchiveComparisonOptions(
            compareModificationDate: true,
            comparePermissions: true
        )
        let fileLeft = entry(
            kind: .file,
            byteCount: 12,
            digest: String(repeating: "a", count: 64)
        )
        let fileRight = entry(
            kind: .file,
            byteCount: 12,
            digest: String(repeating: "b", count: 64)
        )
        let linkLeft = ArchiveComparisonEntrySummary(
            kind: .symbolicLink,
            uncompressedByteCount: 0,
            compressedByteCount: 0,
            compression: .none,
            symbolicLinkDestination: "target<&>"
        )
        let linkRight = ArchiveComparisonEntrySummary(
            kind: .symbolicLink,
            uncompressedByteCount: 0,
            compressedByteCount: 0,
            compression: .none,
            symbolicLinkDestination: "other"
        )
        let rows = [
            ArchiveComparisonRow(
                path: "资料/<script>.txt",
                status: .different,
                left: fileLeft,
                right: fileRight,
                differenceFields: [.content]
            ),
            ArchiveComparisonRow(
                path: "latest",
                status: .different,
                left: linkLeft,
                right: linkRight,
                differenceFields: [.symbolicLinkDestination]
            ),
        ]
        return ArchiveComparisonResult(
            leftFormat: .zip,
            rightFormat: .tar,
            options: options,
            rows: rows,
            statistics: ArchiveComparisonStatistics(
                totalCount: 2,
                sameCount: 0,
                differentCount: 2,
                leftOnlyCount: 0,
                rightOnlyCount: 0,
                hashedFileCount: 2,
                readAndHashedByteCount: 24
            )
        )
    }

    private func entry(
        kind: ArchiveResourceEntry.Kind,
        byteCount: Int,
        digest: String?
    ) -> ArchiveComparisonEntrySummary {
        ArchiveComparisonEntrySummary(
            kind: kind,
            uncompressedByteCount: byteCount,
            compressedByteCount: byteCount,
            compression: .none,
            modificationDate: Date(timeIntervalSince1970: 1_000),
            permissions: 0o644,
            contentSHA256: digest
        )
    }
}

private func requireArchiveReportSendable<T: Sendable>(_ value: T) {}
