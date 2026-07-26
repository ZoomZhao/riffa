import Foundation
import Testing
@testable import RiffaCore

@Suite("Comparison report generation")
struct ComparisonReportTests {
    private let generator = ComparisonReportGenerator()

    @Test("HTML escapes labels and source text without external resources")
    func htmlEscaping() throws {
        let diff = TextDiffEngine().compare(
            TextDocument(text: "<img src=x onerror='bad'> & old"),
            to: TextDocument(text: "<script>alert(\"bad\")</script> & new")
        )
        let html = try generator.generate(
            text: diff,
            format: .html,
            leftLabel: "<Left & \"unsafe\">",
            rightLabel: "Right's >"
        )

        #expect(!html.contains("<script>"))
        #expect(!html.contains("<img src=x"))
        #expect(html.contains("&lt;script&gt;"))
        #expect(html.contains("&lt;img src=x onerror=&#39;bad&#39;&gt;"))
        #expect(html.contains("&lt;Left &amp; &quot;unsafe&quot;&gt;"))
        #expect(html.contains("Right&#39;s &gt;"))
        #expect(!html.contains("https://"))
        #expect(!html.contains("http://"))
    }

    @Test("Unicode text survives every report format")
    func unicodeRoundTrip() throws {
        let diff = TextDiffEngine().compare(
            TextDocument(text: "你好 👩🏽‍💻\n旧行"),
            to: TextDocument(text: "你好 👩🏽‍💻\n新行")
        )

        for format in ComparisonReportFormat.allCases {
            let output = try generator.generate(text: diff, format: format)
            #expect(output.contains("你好 👩🏽‍💻"))
            #expect(output.contains("旧行"))
            #expect(output.contains("新行"))
        }
    }

    @Test("An empty comparison has an explicit zero summary and no rows")
    func emptyComparison() throws {
        let diff = TextDiffEngine().compare(
            TextDocument(text: ""),
            to: TextDocument(text: "")
        )
        let document = generator.document(for: diff)
        let plainText = try generator.render(document, as: .plainText)
        let html = try generator.render(document, as: .html)

        #expect(document.statistics.totalCount == 0)
        #expect(document.rows.isEmpty)
        #expect(plainText.contains("total=0"))
        #expect(html.contains("Total: 0"))
        #expect(html.contains("<tbody>"))
    }

    @Test("JSON decodes to the public DTO and omits resource locators")
    func jsonDecodingAndPathPrivacy() throws {
        let left = ResourceEntry(
            locator: ResourceLocator(providerID: "local", path: "/Users/private/left/秘密.txt"),
            relativePath: "秘密.txt",
            kind: .file,
            byteCount: 12,
            modificationDate: Date(timeIntervalSinceReferenceDate: 1234)
        )
        let right = ResourceEntry(
            locator: ResourceLocator(providerID: "local", path: "/Users/private/right/秘密.txt"),
            relativePath: "秘密.txt",
            kind: .file,
            byteCount: 14,
            modificationDate: Date(timeIntervalSinceReferenceDate: 5678)
        )
        let nodes = [
            PairNode(relativePath: "秘密.txt", left: left, right: right, status: .different)
        ]

        let json = try generator.generate(folder: nodes, format: .json)
        let decoded = try JSONDecoder().decode(
            ComparisonReportDocument.self,
            from: Data(json.utf8)
        )

        #expect(decoded.kind == .folder)
        #expect(decoded.leftLabel == "Left")
        #expect(decoded.rows[0].key == "秘密.txt")
        #expect(decoded.rows[0].status == .different)
        #expect(decoded.rows[0].left?.byteCount == 12)
        #expect(!json.contains("/Users/private"))
        #expect(!json.contains("locator"))
    }

    @Test("Folder output is deterministically sorted")
    func deterministicOutput() throws {
        let first = PairNode(
            relativePath: "zeta.txt",
            left: nil,
            right: entry(path: "zeta.txt", bytes: 9),
            status: .rightOnly
        )
        let second = PairNode(
            relativePath: "alpha.txt",
            left: entry(path: "alpha.txt", bytes: 2),
            right: nil,
            status: .leftOnly
        )

        for format in ComparisonReportFormat.allCases {
            let reversed = try generator.generate(folder: [first, second], format: format)
            let ordered = try generator.generate(folder: [second, first], format: format)
            #expect(reversed == ordered)
            #expect(reversed.range(of: "alpha.txt")!.lowerBound < reversed.range(of: "zeta.txt")!.lowerBound)
        }
    }

    private func entry(path: String, bytes: Int64) -> ResourceEntry {
        ResourceEntry(
            locator: ResourceLocator(providerID: "local", path: "/not/reported/\(path)"),
            relativePath: path,
            kind: .file,
            byteCount: bytes,
            modificationDate: Date(timeIntervalSinceReferenceDate: 42)
        )
    }
}
