import Foundation
import Testing
@testable import RiffaCore

@Suite("Office package specialized reports")
struct OpenXMLComparisonReportTests {
    private let generator = SpecializedComparisonReportGenerator()

    @Test("Plain, HTML, and JSON reports are deterministic, portable, and contain no raw package bytes")
    func formatsPrivacyAndDeterminism() throws {
        let result = comparisonResult()
        for format in ComparisonReportFormat.allCases {
            let first = try generator.generate(
                openXML: result,
                format: format,
                leftLabel: "/Users/private/Documents/左<报告>.docx",
                rightLabel: "file:///Users/private/Documents/right%26book.ods"
            )
            let second = try generator.generate(
                openXML: result,
                format: format,
                leftLabel: "/Users/private/Documents/左<报告>.docx",
                rightLabel: "file:///Users/private/Documents/right%26book.ods"
            )
            #expect(first == second)
            #expect(first.contains("openXML"))
            #expect(first.contains("docx"))
            #expect(first.contains("ods"))
            #expect(!first.contains("/Users/private"))
            #expect(!first.contains("file://"))
            #expect(!first.contains("RAW_ARCHIVE_BYTES_MUST_NOT_APPEAR"))
        }
    }

    @Test("HTML escapes labels, keys, and extracted text previews")
    func htmlEscaping() throws {
        let html = try generator.generate(
            openXML: comparisonResult(),
            format: .html,
            leftLabel: "左<报告>.docx",
            rightLabel: "右&表格.ods"
        )

        #expect(html.contains("左&lt;报告&gt;.docx"))
        #expect(html.contains("右&amp;表格.ods"))
        #expect(html.contains("&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt;"))
        #expect(!html.contains("<script>"))
    }

    @Test("JSON round-trips through the stable specialized report DTO")
    func jsonRoundTrip() throws {
        let result = comparisonResult()
        let document = generator.document(
            for: result,
            leftLabel: "/Users/private/left.docx",
            rightLabel: "/Users/private/right.ods"
        )
        #expect(document.kind == .openXML)
        #expect(document.leftLabel == "left.docx")
        #expect(document.rightLabel == "right.ods")

        let json = try generator.render(document, as: .json)
        let decoded = try JSONDecoder().decode(
            SpecializedComparisonReportDocument.self,
            from: Data(json.utf8)
        )
        #expect(decoded == document)
        #expect(json.utf8.count < 100_000)
    }

    @Test("Report DTO remains strict Sendable")
    func sendableReport() async {
        let document = generator.document(for: comparisonResult())
        requireOpenXMLReportSendable(document)
        let copied = await Task.detached { @Sendable in document }.value
        #expect(copied == document)
    }

    private func comparisonResult() -> OpenXMLComparisonResult {
        let left = OpenXMLDocumentSnapshot(
            documentType: .wordProcessingDocument,
            coreProperties: OpenXMLCoreProperties(
                title: "季度 <script>alert('x')</script>",
                creator: "左 & 作者",
                modified: "2026-07-19T01:00:00Z"
            ),
            sections: [
                OpenXMLLogicalSection(
                    key: "paragraph.1",
                    kind: .paragraph,
                    textBlocks: ["<script>alert('x')</script>"]
                )
            ],
            parts: [
                OpenXMLPartSummary(
                    partName: "word/document.xml",
                    uncompressedByteCount: 123,
                    sha256: String(repeating: "a", count: 64)
                )
            ]
        )
        let right = OpenXMLDocumentSnapshot(
            documentType: .openDocumentSpreadsheet,
            coreProperties: OpenXMLCoreProperties(
                title: "季度 & workbook",
                creator: "右作者",
                modified: "2026-07-19T02:00:00Z"
            ),
            sections: [
                OpenXMLLogicalSection(
                    key: "worksheet.1",
                    kind: .worksheet,
                    title: "Sheet <1>",
                    cells: [
                        OpenXMLCellSnapshot(
                            reference: "A1",
                            displayValue: "new",
                            formula: "of:=1+1",
                            valueType: "float",
                            typedValue: "2",
                            rowSpan: 2,
                            columnSpan: 3
                        )
                    ]
                )
            ],
            parts: [
                OpenXMLPartSummary(
                    partName: "content.xml",
                    uncompressedByteCount: 456,
                    sha256: String(repeating: "b", count: 64)
                )
            ]
        )
        return OpenXMLComparisonEngine().compare(left: left, right: right)
    }
}

private func requireOpenXMLReportSendable<T: Sendable>(_ value: T) {}
