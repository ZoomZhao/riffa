import Foundation
import Testing
@testable import RiffaApp

@Suite("Text compare presentation")
struct TextSyntaxHighlightingTests {
    @Test("Language detection follows each file name independently")
    func languageDetectionByFileName() {
        #expect(TextSyntaxLanguage.detect(fileName: "Left.swift") == .swift)
        #expect(TextSyntaxLanguage.detect(fileName: "right.tsx") == .javascript)
        #expect(TextSyntaxLanguage.detect(fileName: "Dockerfile") == .shell)
        #expect(TextSyntaxLanguage.detect(fileName: "README") == .markdown)
        #expect(TextSyntaxLanguage.detect(fileName: "notes.txt") == nil)
        #expect(TextSyntaxLanguage.detect(fileName: nil) == nil)
    }

    @Test("Swift highlighting classifies common syntax without changing text")
    func swiftTokenClassification() {
        let source = """
        struct Widget {
            let count = 42 // sample
            let title = "hello"
        }
        """
        let value = source as NSString
        let tokens = TextSyntaxHighlighter.tokens(in: source, language: .swift)
        let classified = tokens.map { (value.substring(with: $0.range), $0.kind) }

        #expect(classified.contains { $0 == ("struct", .keyword) })
        #expect(classified.contains { $0 == ("Widget", .type) })
        #expect(classified.contains { $0 == ("42", .number) })
        #expect(classified.contains { $0 == ("// sample", .comment) })
        #expect(classified.contains { $0 == ("\"hello\"", .string) })
    }

    @Test("Highlighting is disabled above the bounded input limit")
    func highlightingLimit() {
        let oversized = String(
            repeating: "x",
            count: TextSyntaxHighlighter.maximumUTF16Length + 1
        )

        #expect(TextSyntaxHighlighter.tokens(in: oversized, language: .swift).isEmpty)
    }

    @Test("Compared panes fill wide viewports and stay usable in narrow windows")
    func responsivePaneWidths() {
        #expect(TextComparePaneLayout.paneWidth(for: 1_201) == 600)
        #expect(
            TextComparePaneLayout.paneWidth(for: 400)
                == TextComparePaneLayout.minimumPaneWidth
        )
    }
}
