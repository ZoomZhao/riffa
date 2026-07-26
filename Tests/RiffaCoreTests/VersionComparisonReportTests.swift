import Foundation
import Testing
@testable import RiffaCore

@Suite("Version comparison reports")
struct VersionComparisonReportTests {
    private let generator = SpecializedComparisonReportGenerator()

    @Test("Version report rows and summaries use stable comparison order")
    func documentStructure() {
        let result = fixtureResult()
        let document = generator.document(for: result)
        let summary = Dictionary(uniqueKeysWithValues: document.summary.map { ($0.key, $0.value) })

        #expect(document.kind == .version)
        #expect(document.rows.map(\.key) == VersionComparisonField.allCases.map(\.rawValue))
        #expect(document.rows.first?.key == "displayName")
        #expect(document.rows.first?.status == "different")
        #expect(document.rows.first?.left.first?.value == .string("Old<script>.app"))
        #expect(summary["totalFieldCount"] == .integer(Int64(VersionComparisonField.allCases.count)))
        #expect(summary["differentFieldCount"] == .integer(6))
        #expect(summary["hasDifferences"] == .boolean(true))
    }

    @Test("Plain HTML and JSON version reports are deterministic")
    func stableFormats() throws {
        let result = fixtureResult()
        for format in ComparisonReportFormat.allCases {
            let first = try generator.generate(version: result, format: format)
            let second = try generator.generate(version: result, format: format)
            #expect(first == second)
            #expect(!first.isEmpty)
            switch format {
            case .plainText:
                #expect(first.contains("Kind: version"))
                #expect(first.contains("Main binary SHA-256"))
                #expect(first.contains("arm64, x86_64"))
            case .html:
                #expect(first.contains("<table>"))
                #expect(first.contains("Signature status"))
            case .json:
                let decoded = try JSONDecoder().decode(
                    SpecializedComparisonReportDocument.self,
                    from: Data(first.utf8)
                )
                #expect(decoded == generator.document(for: result))
            }
        }
    }

    @Test("Version report labels remove absolute paths and file URLs")
    func locatorPrivacy() throws {
        for format in ComparisonReportFormat.allCases {
            let report = try generator.generate(
                version: fixtureResult(),
                format: format,
                leftLabel: "/Users/alice/Secret/Old<script>.app",
                rightLabel: "file:///private/review/New%26.app"
            )
            #expect(report.contains("Old"))
            #expect(report.contains("New"))
            #expect(!report.contains("/Users/alice"))
            #expect(!report.contains("/private/review"))
            #expect(!report.contains("file://"))
            #expect(!report.contains("sourceURL"))
            #expect(!report.contains("locator"))
        }
    }

    @Test("Version HTML escapes labels and every snapshot-derived value")
    func htmlEscaping() throws {
        let html = try generator.generate(
            version: fixtureResult(),
            format: .html,
            leftLabel: "左<script>&",
            rightLabel: "右's <side>"
        )

        #expect(html.contains("左&lt;script&gt;&amp;"))
        #expect(html.contains("右&#39;s &lt;side&gt;"))
        #expect(html.contains("Old&lt;script&gt;.app"))
        #expect(html.contains("TEAM&lt;OLD&gt;"))
        #expect(!html.contains("<script>"))
        #expect(!html.contains("TEAM<OLD>"))
    }

    private func fixtureResult() -> VersionComparisonResult {
        let left = VersionResourceSnapshot(
            displayName: "Old<script>.app",
            kind: .applicationBundle,
            bundleIdentifier: "dev.riffa.old&demo",
            shortVersionString: "1.0",
            bundleVersion: "10",
            packageType: "APPL",
            minimumSystemVersion: "14.0",
            architectures: [
                VersionArchitecture(
                    cpuType: 0x0100_000C,
                    cpuSubtype: 0,
                    displayName: "arm64"
                ),
                VersionArchitecture(
                    cpuType: 0x0100_0007,
                    cpuSubtype: 3,
                    displayName: "x86_64"
                )
            ],
            fileByteCount: 4_096,
            sha256: "aaaa",
            codeSignature: VersionCodeSignature(
                status: .valid,
                teamIdentifier: "TEAM<OLD>",
                signingIdentifier: "dev.riffa.old&demo"
            )
        )
        let right = VersionResourceSnapshot(
            displayName: "New&.app",
            kind: .applicationBundle,
            bundleIdentifier: "dev.riffa.new",
            shortVersionString: "2.0",
            bundleVersion: "10",
            packageType: "APPL",
            minimumSystemVersion: "14.0",
            architectures: [
                VersionArchitecture(
                    cpuType: 0x0100_000C,
                    cpuSubtype: 0,
                    displayName: "arm64"
                ),
                VersionArchitecture(
                    cpuType: 0x0100_0007,
                    cpuSubtype: 3,
                    displayName: "x86_64"
                )
            ],
            fileByteCount: 4_096,
            sha256: "bbbb",
            codeSignature: VersionCodeSignature(
                status: .valid,
                teamIdentifier: "TEAM<NEW>",
                signingIdentifier: "dev.riffa.new"
            )
        )
        return VersionComparisonEngine().compare(left: left, right: right)
    }
}
