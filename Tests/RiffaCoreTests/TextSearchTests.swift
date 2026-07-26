import Foundation
import Testing
@testable import RiffaCore

@Suite("Bounded text search and replacement")
struct TextSearchTests {
    @Test("Literal search treats regular-expression punctuation literally")
    func literalSpecialCharacters() throws {
        let engine = TextSearchEngine(options: .init(mode: .literal))
        let input = "cost $5 \\ path; cost $5 \\ path"
        let pattern = "$5 \\ path"

        let result = try engine.findAll(pattern: pattern, in: input)
        #expect(result.matches.count == 2)
        #expect(result.matches.map { $0.range.substring(in: input) } == [pattern, pattern])

        let replacement = "$1\\tail"
        let replaced = try engine.replaceAll(
            pattern: pattern,
            in: input,
            with: replacement
        )
        #expect(replaced.text == "cost $1\\tail; cost $1\\tail")
        #expect(replaced.replacementCount == 2)
    }

    @Test("Regular-expression replacement expands numbered capture groups")
    func captureGroups() throws {
        let engine = TextSearchEngine(options: .init(mode: .regularExpression))
        let input = "Ada Lovelace; Grace Hopper"
        let result = try engine.findAll(pattern: "([A-Z][a-z]+) ([A-Z][a-z]+)", in: input)

        #expect(result.matches.count == 2)
        #expect(result.matches[0].captures.count == 2)
        #expect(result.matches[0].captures[0]?.substring(in: input) == "Ada")
        #expect(result.matches[0].captures[1]?.substring(in: input) == "Lovelace")

        let replaced = try engine.replaceAll(
            pattern: "([A-Z][a-z]+) ([A-Z][a-z]+)",
            in: input,
            with: "$2, $1"
        )
        #expect(replaced.text == "Lovelace, Ada; Hopper, Grace")
    }

    @Test("Regex templates match Foundation numeric capture and escaping semantics")
    func captureTemplateEscaping() throws {
        let engine = TextSearchEngine(options: .init(mode: .regularExpression))

        #expect(
            try engine.replaceAll(
                pattern: "(a)(b)",
                in: "ab",
                with: #"$10|\$1|\\$2|$9"#
            ).text == #"a0|$1|\b|"#
        )
    }

    @Test("UTF-16 ranges round-trip emoji and composed Unicode")
    func unicodeRanges() throws {
        let engine = TextSearchEngine(options: .init(mode: .literal))
        let input = "A👩🏽‍💻 café 👩🏽‍💻"
        let pattern = "👩🏽‍💻"
        let result = try engine.findAll(pattern: pattern, in: input)

        #expect(result.matches.count == 2)
        #expect(result.matches[0].range.location == 1)
        #expect(result.matches[0].range.length == pattern.utf16.count)
        #expect(result.matches.allSatisfy { $0.range.range(in: input) != nil })
        #expect(result.matches.map { $0.range.substring(in: input) } == [pattern, pattern])
    }

    @Test("Case sensitivity is explicit for literal and regex modes")
    func caseSensitivity() throws {
        let sensitive = TextSearchEngine(
            options: .init(mode: .literal, caseSensitive: true)
        )
        let insensitive = TextSearchEngine(
            options: .init(mode: .regularExpression, caseSensitive: false)
        )

        #expect(try sensitive.findAll(pattern: "riffa", in: "Riffa riffa").matches.count == 1)
        #expect(try insensitive.findAll(pattern: "riffa", in: "Riffa riffa").matches.count == 2)
    }

    @Test("Zero-width and unsafe expressions fail structurally")
    func zeroWidthAndUnsafePatterns() {
        let engine = TextSearchEngine(options: .init(mode: .regularExpression))

        #expect(throws: TextSearchError.zeroWidthMatch(location: 0)) {
            try engine.findAll(pattern: "^", in: "abc")
        }
        #expect(throws: TextSearchError.zeroWidthMatch(location: 0)) {
            try engine.findAll(pattern: "(?=a)", in: "abc")
        }
        #expect(throws: TextSearchError.zeroWidthMatch(location: 1)) {
            try engine.prepare(pattern: "a|(?<=a)").contains(in: "a")
        }
        #expect(throws: TextSearchError.unsafeRegularExpression(
            reason: "nested unbounded quantifiers are not allowed"
        )) {
            try engine.findAll(pattern: "(a+)+$", in: String(repeating: "a", count: 100))
        }
    }

    @Test("Invalid regular expressions preserve a structured error")
    func invalidRegularExpression() {
        let engine = TextSearchEngine(options: .init(mode: .regularExpression))

        do {
            _ = try engine.findAll(pattern: "[unterminated", in: "text")
            Issue.record("Expected an invalid regular-expression error")
        } catch let error as TextSearchError {
            guard case let .invalidRegularExpression(reason) = error else {
                Issue.record("Unexpected text-search error: \(error)")
                return
            }
            #expect(!reason.isEmpty)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("Pattern, input, match, replacement, and output limits are enforced")
    func limits() throws {
        let limits = TextSearchLimits(
            maximumPatternUTF16Length: 3,
            maximumInputUTF16Length: 8,
            maximumMatchCount: 2,
            maximumReplacementUTF16Length: 3,
            maximumOutputUTF16Length: 8
        )
        let engine = TextSearchEngine(options: .init(mode: .literal, limits: limits))

        #expect(throws: TextSearchError.patternLimitExceeded(actual: 4, limit: 3)) {
            try engine.findAll(pattern: "long", in: "text")
        }
        #expect(throws: TextSearchError.inputLimitExceeded(actual: 9, limit: 8)) {
            try engine.findAll(pattern: "a", in: "123456789")
        }
        #expect(throws: TextSearchError.matchLimitExceeded(limit: 2)) {
            try engine.findAll(pattern: "a", in: "aaa")
        }
        #expect(throws: TextSearchError.replacementLimitExceeded(actual: 4, limit: 3)) {
            try engine.replaceAll(pattern: "a", in: "aa", with: "1234")
        }
        #expect(throws: TextSearchError.outputLimitExceeded(limit: 8)) {
            try engine.replaceAll(pattern: "a", in: "aaZZZZ", with: "123")
        }

        let captureExpansionEngine = TextSearchEngine(
            options: .init(
                mode: .regularExpression,
                limits: TextSearchLimits(
                    maximumPatternUTF16Length: 32,
                    maximumInputUTF16Length: 32,
                    maximumMatchCount: 8,
                    maximumReplacementUTF16Length: 32,
                    maximumOutputUTF16Length: 12
                )
            )
        )
        #expect(throws: TextSearchError.outputLimitExceeded(limit: 12)) {
            try captureExpansionEngine.replaceAll(
                pattern: "(a+)",
                in: "aaaaaaaa",
                with: "$1$1"
            )
        }
    }

    @Test("An empty pattern is a bounded no-op")
    func emptyPattern() throws {
        let engine = TextSearchEngine(options: .init(mode: .regularExpression))
        #expect(try engine.findAll(pattern: "", in: "abc").matches.isEmpty)
        #expect(try engine.replaceAll(pattern: "", in: "abc", with: "x").text == "abc")
    }
}
