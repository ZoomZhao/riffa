import Foundation
import Testing
@testable import RiffaCore

@Suite("PDF comparison reports")
struct PDFComparisonReportTests {
    private let generator = SpecializedComparisonReportGenerator()

    @Test("PDF document contains stable summaries and complete page fields")
    func documentStructure() {
        let result = fixtureResult()
        let document = generator.document(for: result)
        let summary = Dictionary(uniqueKeysWithValues: document.summary.map { ($0.key, $0.value) })

        #expect(document.kind == .pdf)
        #expect(document.rows.map(\.key) == ["1", "2", "3"])
        #expect(summary["left.fileByteCount"] == .integer(4_096))
        #expect(summary["right.pageCount"] == .integer(2))
        #expect(summary["pages.sameCount"] == .integer(1))
        #expect(summary["pages.changedCount"] == .integer(1))
        #expect(summary["pages.leftOnlyCount"] == .integer(1))
        #expect(summary["metadata.totalCount"] == .integer(2))
        #expect(summary["metadata.differentCount"] == .integer(1))
        #expect(summary["metadata.leftOnlyCount"] == .integer(1))
        #expect(summary["hasDifferences"] == .boolean(true))

        let changedPage = document.rows[1]
        #expect(changedPage.status == "changed")
        #expect(value(in: changedPage.left, key: "dimensions.width") == .real(612))
        #expect(value(in: changedPage.right, key: "dimensions.height") == .real(612))
        #expect(value(in: changedPage.right, key: "rotationDegrees") == .integer(90))
        #expect(value(in: changedPage.left, key: "label") == .string("L<2>"))
        #expect(value(in: changedPage.right, key: "extractedText") == .string("new & line\nshared"))
        #expect(
            value(in: changedPage.details, key: "differences")
                == .string("dimensions, rotation, label, text")
        )
        #expect(value(in: changedPage.details, key: "text.sameLineCount") == .integer(1))
        #expect(value(in: changedPage.details, key: "text.changedLineCount") == .integer(3))
        #expect(value(in: changedPage.details, key: "text.inlineDifferenceCount") == .integer(1))
        #expect(value(in: changedPage.details, key: "text.lineEndingDifferenceCount") == .integer(1))

        let leftOnlyPage = document.rows[2]
        #expect(leftOnlyPage.status == "leftOnly")
        #expect(leftOnlyPage.right.isEmpty)
        #expect(value(in: leftOnlyPage.details, key: "text.changedLineCount") == .null)
    }

    @Test("Plain text HTML and JSON PDF reports are deterministic")
    func allFormatsAndStability() throws {
        let result = fixtureResult()

        for format in ComparisonReportFormat.allCases {
            let first = try generator.generate(pdf: result, format: format)
            let second = try generator.generate(pdf: result, format: format)
            #expect(first == second)
            #expect(!first.isEmpty)

            switch format {
            case .plainText:
                #expect(first.contains("Kind: pdf"))
                #expect(first.contains("detail.text.changedLineCount"))
                #expect(first.contains("left.extractedText"))
            case .html:
                #expect(first.contains("<table>"))
                #expect(first.contains("Changed text lines"))
                #expect(first.contains("Extracted text"))
            case .json:
                let decoded = try JSONDecoder().decode(
                    SpecializedComparisonReportDocument.self,
                    from: Data(first.utf8)
                )
                #expect(decoded == generator.document(for: result))
            }
        }
    }

    @Test("PDF reports omit absolute locators and raw binary metadata")
    func locatorAndDataPrivacy() throws {
        let result = fixtureResult()
        let rawMarker = "SECRET_RAW_PDF_STYLE_BYTES"

        for format in ComparisonReportFormat.allCases {
            let report = try generator.generate(
                pdf: result,
                format: format,
                leftLabel: "/Users/alice/Confidential/left.pdf",
                rightLabel: "file:///private/reviews/right.pdf"
            )
            #expect(report.contains("left.pdf"))
            #expect(report.contains("right.pdf"))
            #expect(!report.contains("/Users/alice"))
            #expect(!report.contains("/private/reviews"))
            #expect(!report.contains("file://"))
            #expect(!report.contains(rawMarker))
            #expect(!report.contains("sourceURL"))
            #expect(!report.contains("locator"))
        }
    }

    @Test("PDF HTML escapes labels page metadata and extracted text")
    func htmlEscaping() throws {
        let html = try generator.generate(
            pdf: fixtureResult(),
            format: .html,
            leftLabel: "左<script>&",
            rightLabel: "右's <side>"
        )

        #expect(html.contains("左&lt;script&gt;&amp;"))
        #expect(html.contains("右&#39;s &lt;side&gt;"))
        #expect(html.contains("L&lt;2&gt;"))
        #expect(html.contains("old &lt;line&gt;"))
        #expect(html.contains("new &amp; line"))
        #expect(!html.contains("<script>"))
        #expect(!html.contains("old <line>"))
    }

    private func value(
        in fields: [SpecializedReportField],
        key: String
    ) -> SpecializedReportValue? {
        fields.first { $0.key == key }?.value
    }

    private func fixtureResult() -> PDFComparisonResult {
        let rawMetadata = Data("SECRET_RAW_PDF_STYLE_BYTES".utf8)
        let leftMetadata = [
            MetadataField(
                key: "title",
                displayName: "Title",
                value: .string("Old <title>"),
                importance: .important
            ),
            MetadataField(
                key: "payload",
                displayName: "Payload",
                value: .data(MetadataDataSummary(data: rawMetadata)),
                importance: .informational
            )
        ]
        let rightMetadata = [
            MetadataField(
                key: "title",
                displayName: "Title",
                value: .string("New & title"),
                importance: .important
            )
        ]
        let pageOneLeft = PDFPageSnapshot(
            pageNumber: 1,
            label: "1",
            dimensions: PDFPageDimensions(width: 612, height: 792),
            rotationDegrees: 0,
            extractedText: "same"
        )
        let pageOneRight = PDFPageSnapshot(
            pageNumber: 1,
            label: "1",
            dimensions: PDFPageDimensions(width: 612, height: 792),
            rotationDegrees: 0,
            extractedText: "same"
        )
        let pageTwoLeft = PDFPageSnapshot(
            pageNumber: 2,
            label: "L<2>",
            dimensions: PDFPageDimensions(width: 612, height: 792),
            rotationDegrees: 0,
            extractedText: "old <line>\nshared"
        )
        let pageTwoRight = PDFPageSnapshot(
            pageNumber: 2,
            label: "R&2",
            dimensions: PDFPageDimensions(width: 792, height: 612),
            rotationDegrees: 90,
            extractedText: "new & line\nshared"
        )
        let pageThreeLeft = PDFPageSnapshot(
            pageNumber: 3,
            label: nil,
            dimensions: PDFPageDimensions(width: 612, height: 792),
            rotationDegrees: 0,
            extractedText: "left only"
        )

        let sameText = PDFTextComparisonResult(
            lines: [
                PDFTextLineComparison(
                    offset: 0,
                    status: .same,
                    left: PDFTextLineValue(lineNumber: 1, content: "same", ending: .none),
                    right: PDFTextLineValue(lineNumber: 1, content: "same", ending: .none),
                    inlineDifferences: [],
                    hasLineEndingDifference: false
                )
            ],
            statistics: PDFTextComparisonStatistics(
                sameLineCount: 1,
                insertedLineCount: 0,
                deletedLineCount: 0,
                modifiedLineCount: 0
            )
        )
        let changedText = PDFTextComparisonResult(
            lines: [
                PDFTextLineComparison(
                    offset: 0,
                    status: .same,
                    left: PDFTextLineValue(lineNumber: 2, content: "shared", ending: .none),
                    right: PDFTextLineValue(lineNumber: 2, content: "shared", ending: .none),
                    inlineDifferences: [],
                    hasLineEndingDifference: false
                ),
                PDFTextLineComparison(
                    offset: 1,
                    status: .modified,
                    left: PDFTextLineValue(lineNumber: 1, content: "old <line>", ending: .lf),
                    right: PDFTextLineValue(lineNumber: 1, content: "new & line", ending: .lf),
                    inlineDifferences: [
                        PDFInlineDifference(
                            status: .modified,
                            leftRange: PDFTextRange(offset: 0, length: 3),
                            rightRange: PDFTextRange(offset: 0, length: 3)
                        )
                    ],
                    hasLineEndingDifference: false
                ),
                PDFTextLineComparison(
                    offset: 2,
                    status: .inserted,
                    left: nil,
                    right: PDFTextLineValue(lineNumber: 3, content: "inserted", ending: .crlf),
                    inlineDifferences: [],
                    hasLineEndingDifference: false
                ),
                PDFTextLineComparison(
                    offset: 3,
                    status: .deleted,
                    left: PDFTextLineValue(lineNumber: 3, content: "deleted", ending: .lf),
                    right: nil,
                    inlineDifferences: [],
                    hasLineEndingDifference: true
                )
            ],
            statistics: PDFTextComparisonStatistics(
                sameLineCount: 1,
                insertedLineCount: 1,
                deletedLineCount: 1,
                modifiedLineCount: 1
            )
        )
        let pages = [
            PDFPageComparison(
                pageNumber: 2,
                status: .changed,
                differences: [.text, .dimensions, .label, .rotation],
                left: pageTwoLeft,
                right: pageTwoRight,
                textComparison: changedText
            ),
            PDFPageComparison(
                pageNumber: 3,
                status: .leftOnly,
                differences: [],
                left: pageThreeLeft,
                right: nil,
                textComparison: nil
            ),
            PDFPageComparison(
                pageNumber: 1,
                status: .same,
                differences: [],
                left: pageOneLeft,
                right: pageOneRight,
                textComparison: sameText
            )
        ]

        return PDFComparisonResult(
            leftDocument: PDFDocumentSnapshot(
                fileByteCount: 4_096,
                pageCount: 3,
                metadata: leftMetadata
            ),
            rightDocument: PDFDocumentSnapshot(
                fileByteCount: 3_072,
                pageCount: 2,
                metadata: rightMetadata
            ),
            metadataComparison: MetadataComparison().compare(
                left: leftMetadata,
                right: rightMetadata
            ),
            pages: pages,
            statistics: PDFComparisonStatistics(
                samePageCount: 1,
                changedPageCount: 1,
                leftOnlyPageCount: 1,
                rightOnlyPageCount: 0
            )
        )
    }
}
