import AppKit
import Foundation
import SwiftUI

enum TextSyntaxLanguage: String, Equatable, Sendable {
    case swift
    case cFamily
    case javascript
    case python
    case ruby
    case shell
    case markup
    case styleSheet
    case json
    case yaml
    case markdown
    case sql

    static func detect(fileName: String?) -> TextSyntaxLanguage? {
        guard let fileName, !fileName.isEmpty else { return nil }
        let lowercasedName = fileName.lowercased()
        let pathExtension = URL(fileURLWithPath: lowercasedName).pathExtension

        switch lowercasedName {
        case "dockerfile", "makefile", ".bashrc", ".zshrc", ".profile":
            return .shell
        case "gemfile", "rakefile":
            return .ruby
        case "readme", "changelog", "license":
            return .markdown
        default:
            break
        }

        return switch pathExtension {
        case "swift": .swift
        case "c", "h", "cc", "cpp", "cxx", "hh", "hpp", "hxx", "m", "mm",
             "java", "kt", "kts", "cs", "go", "rs":
            .cFamily
        case "js", "jsx", "mjs", "cjs", "ts", "tsx":
            .javascript
        case "py", "pyw":
            .python
        case "rb":
            .ruby
        case "sh", "bash", "zsh", "fish":
            .shell
        case "html", "htm", "xml", "svg", "plist":
            .markup
        case "css", "scss", "sass", "less":
            .styleSheet
        case "json", "jsonc":
            .json
        case "yaml", "yml":
            .yaml
        case "md", "markdown", "mdown":
            .markdown
        case "sql":
            .sql
        default:
            nil
        }
    }

    static func detect(url: URL?) -> TextSyntaxLanguage? {
        detect(fileName: url?.lastPathComponent)
    }
}

enum TextSyntaxTokenKind: Equatable, Sendable {
    case keyword
    case string
    case comment
    case number
    case type
    case attribute
}

struct TextSyntaxToken: Equatable, Sendable {
    let range: NSRange
    let kind: TextSyntaxTokenKind
}

enum TextSyntaxHighlighter {
    static let maximumUTF16Length = 1_000_000
    static let maximumTokenCount = 100_000

    static func tokens(
        in text: String,
        language: TextSyntaxLanguage?
    ) -> [TextSyntaxToken] {
        guard let language else { return [] }
        let characters = Array(text.utf16)
        guard !characters.isEmpty,
              characters.count <= maximumUTF16Length
        else { return [] }

        let rules = Rules(language: language)
        var tokens: [TextSyntaxToken] = []
        tokens.reserveCapacity(min(1_024, max(16, characters.count / 24)))
        var index = 0
        var insideMarkupTag = false

        while index < characters.count, tokens.count < maximumTokenCount {
            if let marker = rules.blockCommentStart,
               hasPrefix(characters, marker, at: index) {
                let end = blockCommentEnd(
                    in: characters,
                    from: index + marker.count,
                    closing: rules.blockCommentEnd ?? []
                )
                tokens.append(
                    TextSyntaxToken(
                        range: NSRange(location: index, length: end - index),
                        kind: .comment
                    )
                )
                index = end
                continue
            }

            if let marker = rules.lineComment,
               hasPrefix(characters, marker, at: index) {
                let end = lineEnd(in: characters, from: index)
                tokens.append(
                    TextSyntaxToken(
                        range: NSRange(location: index, length: end - index),
                        kind: .comment
                    )
                )
                index = end
                continue
            }

            let character = characters[index]
            if rules.quoteCharacters.contains(character) {
                let end = quotedEnd(
                    in: characters,
                    from: index,
                    quote: character
                )
                tokens.append(
                    TextSyntaxToken(
                        range: NSRange(location: index, length: end - index),
                        kind: .string
                    )
                )
                index = end
                continue
            }

            if language == .markup {
                if character == CharacterCode.lessThan {
                    insideMarkupTag = true
                    index += 1
                    if index < characters.count,
                       characters[index] == CharacterCode.slash {
                        index += 1
                    }
                    continue
                }
                if character == CharacterCode.greaterThan {
                    insideMarkupTag = false
                    index += 1
                    continue
                }
            }

            if language == .markdown,
               character == CharacterCode.numberSign,
               isLinePrefix(in: characters, at: index) {
                var end = index
                while end < characters.count,
                      characters[end] == CharacterCode.numberSign {
                    end += 1
                }
                tokens.append(
                    TextSyntaxToken(
                        range: NSRange(location: index, length: end - index),
                        kind: .keyword
                    )
                )
                index = end
                continue
            }

            if isASCIIDigit(character) {
                let end = numberEnd(in: characters, from: index)
                tokens.append(
                    TextSyntaxToken(
                        range: NSRange(location: index, length: end - index),
                        kind: .number
                    )
                )
                index = end
                continue
            }

            if isIdentifierStart(character) {
                let end = identifierEnd(in: characters, from: index)
                let word = String(decoding: characters[index..<end], as: UTF16.self)
                let lowercasedWord = word.lowercased()
                let kind: TextSyntaxTokenKind?
                if rules.keywords.contains(lowercasedWord) {
                    kind = .keyword
                } else if insideMarkupTag
                            || isKey(in: characters, after: end, language: language)
                            || character == CharacterCode.dollar {
                    kind = .attribute
                } else if isASCIIUppercase(character) {
                    kind = .type
                } else {
                    kind = nil
                }
                if let kind {
                    tokens.append(
                        TextSyntaxToken(
                            range: NSRange(location: index, length: end - index),
                            kind: kind
                        )
                    )
                }
                index = end
                continue
            }

            index += 1
        }

        return tokens
    }

    private static func hasPrefix(
        _ characters: [UInt16],
        _ prefix: [UInt16],
        at index: Int
    ) -> Bool {
        guard !prefix.isEmpty, index + prefix.count <= characters.count else {
            return false
        }
        for offset in prefix.indices where characters[index + offset] != prefix[offset] {
            return false
        }
        return true
    }

    private static func blockCommentEnd(
        in characters: [UInt16],
        from start: Int,
        closing: [UInt16]
    ) -> Int {
        guard !closing.isEmpty else {
            return lineEnd(in: characters, from: start)
        }
        var index = start
        while index < characters.count {
            if hasPrefix(characters, closing, at: index) {
                return index + closing.count
            }
            index += 1
        }
        return characters.count
    }

    private static func lineEnd(in characters: [UInt16], from start: Int) -> Int {
        var index = start
        while index < characters.count,
              characters[index] != CharacterCode.lineFeed,
              characters[index] != CharacterCode.carriageReturn {
            index += 1
        }
        return index
    }

    private static func quotedEnd(
        in characters: [UInt16],
        from start: Int,
        quote: UInt16
    ) -> Int {
        var index = start + 1
        while index < characters.count {
            if characters[index] == CharacterCode.backslash {
                index = min(characters.count, index + 2)
            } else if characters[index] == quote {
                return index + 1
            } else {
                index += 1
            }
        }
        return characters.count
    }

    private static func numberEnd(in characters: [UInt16], from start: Int) -> Int {
        var index = start + 1
        while index < characters.count {
            let character = characters[index]
            guard isASCIIDigit(character)
                    || isASCIIHexLetter(character)
                    || character == CharacterCode.period
                    || character == CharacterCode.underscore
            else { break }
            index += 1
        }
        return index
    }

    private static func identifierEnd(in characters: [UInt16], from start: Int) -> Int {
        var index = start + 1
        while index < characters.count, isIdentifierBody(characters[index]) {
            index += 1
        }
        return index
    }

    private static func isLinePrefix(in characters: [UInt16], at index: Int) -> Bool {
        guard index > 0 else { return true }
        var cursor = index - 1
        while true {
            let character = characters[cursor]
            if character == CharacterCode.lineFeed
                || character == CharacterCode.carriageReturn {
                return true
            }
            if character != CharacterCode.space
                && character != CharacterCode.tab {
                return false
            }
            guard cursor > 0 else { return true }
            cursor -= 1
        }
    }

    private static func isKey(
        in characters: [UInt16],
        after end: Int,
        language: TextSyntaxLanguage
    ) -> Bool {
        guard language == .yaml || language == .styleSheet else { return false }
        var index = end
        while index < characters.count,
              (
                  characters[index] == CharacterCode.space
                      || characters[index] == CharacterCode.tab
              ) {
            index += 1
        }
        return index < characters.count
            && characters[index] == CharacterCode.colon
    }

    private static func isIdentifierStart(_ character: UInt16) -> Bool {
        isASCIILetter(character)
            || character == CharacterCode.underscore
            || character == CharacterCode.dollar
    }

    private static func isIdentifierBody(_ character: UInt16) -> Bool {
        isIdentifierStart(character) || isASCIIDigit(character)
    }

    private static func isASCIILetter(_ character: UInt16) -> Bool {
        (CharacterCode.uppercaseA...CharacterCode.uppercaseZ).contains(character)
            || (CharacterCode.lowercaseA...CharacterCode.lowercaseZ).contains(character)
    }

    private static func isASCIIUppercase(_ character: UInt16) -> Bool {
        (CharacterCode.uppercaseA...CharacterCode.uppercaseZ).contains(character)
    }

    private static func isASCIIHexLetter(_ character: UInt16) -> Bool {
        (CharacterCode.lowercaseA...CharacterCode.lowercaseF).contains(character)
            || (CharacterCode.uppercaseA...CharacterCode.uppercaseF).contains(character)
    }

    private static func isASCIIDigit(_ character: UInt16) -> Bool {
        (CharacterCode.zero...CharacterCode.nine).contains(character)
    }

    private struct Rules {
        let keywords: Set<String>
        let lineComment: [UInt16]?
        let blockCommentStart: [UInt16]?
        let blockCommentEnd: [UInt16]?
        let quoteCharacters: Set<UInt16>

        init(language: TextSyntaxLanguage) {
            keywords = languageKeywords(language)
            switch language {
            case .swift, .cFamily, .javascript:
                lineComment = Array("//".utf16)
                blockCommentStart = Array("/*".utf16)
                blockCommentEnd = Array("*/".utf16)
            case .styleSheet:
                lineComment = nil
                blockCommentStart = Array("/*".utf16)
                blockCommentEnd = Array("*/".utf16)
            case .python, .ruby, .shell, .yaml:
                lineComment = Array("#".utf16)
                blockCommentStart = nil
                blockCommentEnd = nil
            case .sql:
                lineComment = Array("--".utf16)
                blockCommentStart = Array("/*".utf16)
                blockCommentEnd = Array("*/".utf16)
            case .markup, .markdown:
                lineComment = nil
                blockCommentStart = Array("<!--".utf16)
                blockCommentEnd = Array("-->".utf16)
            case .json:
                lineComment = nil
                blockCommentStart = nil
                blockCommentEnd = nil
            }

            var quotes: Set<UInt16> = [
                CharacterCode.doubleQuote,
                CharacterCode.singleQuote,
            ]
            if language == .javascript
                || language == .shell
                || language == .markdown {
                quotes.insert(CharacterCode.backtick)
            }
            quoteCharacters = quotes
        }
    }

    private static func languageKeywords(_ language: TextSyntaxLanguage) -> Set<String> {
        switch language {
        case .swift:
            [
                "actor", "any", "associatedtype", "async", "await", "break",
                "case", "catch", "class", "continue", "default", "defer", "deinit",
                "do", "else", "enum", "extension", "fallthrough", "false", "fileprivate",
                "for", "func", "guard", "if", "import", "in", "init", "inout",
                "internal", "is", "isolated", "let", "nil", "nonisolated", "open",
                "private", "protocol", "public", "repeat", "return", "self", "some",
                "static", "struct", "subscript", "super", "switch", "throw", "throws",
                "true", "try", "typealias", "var", "where", "while",
            ]
        case .cFamily:
            [
                "abstract", "as", "async", "auto", "await", "bool", "break", "byte",
                "case", "catch", "char", "class", "const", "continue", "default",
                "defer", "do", "double", "else", "enum", "extends", "extern", "false",
                "final", "float", "for", "func", "goto", "if", "implements", "import",
                "include", "inline", "int", "interface", "let", "long", "namespace",
                "new", "nil", "null", "package", "private", "protected", "public",
                "register", "return", "short", "signed", "sizeof", "static", "struct",
                "super", "switch", "template", "this", "throw", "throws", "trait",
                "true", "try", "typedef", "typename", "union", "unsafe", "unsigned",
                "using", "var", "virtual", "void", "volatile", "where", "while",
            ]
        case .javascript:
            [
                "async", "await", "break", "case", "catch", "class", "const",
                "continue", "debugger", "default", "delete", "do", "else", "export",
                "extends", "false", "finally", "for", "from", "function", "get", "if",
                "implements", "import", "in", "instanceof", "interface", "let", "new",
                "null", "of", "package", "private", "protected", "public", "return",
                "set", "static", "super", "switch", "this", "throw", "true", "try",
                "type", "typeof", "undefined", "var", "void", "while", "with", "yield",
            ]
        case .python:
            [
                "and", "as", "assert", "async", "await", "break", "case", "class",
                "continue", "def", "del", "elif", "else", "except", "false", "finally",
                "for", "from", "global", "if", "import", "in", "is", "lambda", "match",
                "none", "nonlocal", "not", "or", "pass", "raise", "return", "true",
                "try", "while", "with", "yield",
            ]
        case .ruby:
            [
                "alias", "and", "begin", "break", "case", "class", "def", "defined",
                "do", "else", "elsif", "end", "ensure", "false", "for", "if", "in",
                "module", "next", "nil", "not", "or", "redo", "rescue", "retry",
                "return", "self", "super", "then", "true", "undef", "unless", "until",
                "when", "while", "yield",
            ]
        case .shell:
            [
                "case", "do", "done", "elif", "else", "esac", "export", "false", "fi",
                "for", "function", "if", "in", "local", "readonly", "return", "select",
                "set", "shift", "then", "true", "typeset", "until", "while",
            ]
        case .styleSheet:
            ["and", "from", "important", "media", "not", "only", "supports", "to", "var"]
        case .json:
            ["false", "null", "true"]
        case .yaml:
            ["false", "null", "true", "yes", "no", "on", "off"]
        case .sql:
            [
                "alter", "and", "as", "asc", "begin", "between", "by", "case",
                "commit", "create", "delete", "desc", "distinct", "drop", "else", "end",
                "exists", "false", "from", "full", "group", "having", "in", "index",
                "inner", "insert", "into", "is", "join", "left", "like", "limit", "not",
                "null", "on", "or", "order", "outer", "primary", "references", "right",
                "rollback", "select", "set", "table", "then", "true", "union", "unique",
                "update", "values", "when", "where", "with",
            ]
        case .markup, .markdown:
            []
        }
    }

    private enum CharacterCode {
        static let tab: UInt16 = 9
        static let lineFeed: UInt16 = 10
        static let carriageReturn: UInt16 = 13
        static let space: UInt16 = 32
        static let doubleQuote: UInt16 = 34
        static let numberSign: UInt16 = 35
        static let dollar: UInt16 = 36
        static let singleQuote: UInt16 = 39
        static let period: UInt16 = 46
        static let slash: UInt16 = 47
        static let zero: UInt16 = 48
        static let nine: UInt16 = 57
        static let colon: UInt16 = 58
        static let lessThan: UInt16 = 60
        static let greaterThan: UInt16 = 62
        static let uppercaseA: UInt16 = 65
        static let uppercaseF: UInt16 = 70
        static let uppercaseZ: UInt16 = 90
        static let backslash: UInt16 = 92
        static let underscore: UInt16 = 95
        static let backtick: UInt16 = 96
        static let lowercaseA: UInt16 = 97
        static let lowercaseF: UInt16 = 102
        static let lowercaseZ: UInt16 = 122
    }
}

struct TextSyntaxHighlightedLine: View {
    let text: String
    let language: TextSyntaxLanguage?
    @Environment(\.riffaTheme) private var theme

    var body: some View {
        highlightedText
    }

    private var highlightedText: Text {
        let value = text as NSString
        let tokens = TextSyntaxHighlighter.tokens(in: text, language: language)
        guard !tokens.isEmpty else {
            return Text(verbatim: text).foregroundColor(theme.ink)
        }

        var result = Text(verbatim: "")
        var location = 0
        for token in tokens {
            guard token.range.location >= location,
                  NSMaxRange(token.range) <= value.length
            else { continue }
            if token.range.location > location {
                result = result + Text(
                    verbatim: value.substring(
                        with: NSRange(
                            location: location,
                            length: token.range.location - location
                        )
                    )
                )
                .foregroundColor(theme.ink)
            }
            result = result + Text(verbatim: value.substring(with: token.range))
                .foregroundColor(color(for: token.kind))
            location = NSMaxRange(token.range)
        }
        if location < value.length {
            result = result + Text(
                verbatim: value.substring(
                    with: NSRange(location: location, length: value.length - location)
                )
            )
            .foregroundColor(theme.ink)
        }
        return result
    }

    private func color(for kind: TextSyntaxTokenKind) -> Color {
        switch kind {
        case .keyword: theme.accentHover
        case .string: theme.success
        case .comment: theme.inkTertiary
        case .number: theme.warning
        case .type: theme.secure
        case .attribute: theme.accent
        }
    }
}

extension RiffaTheme {
    func nsSyntaxColor(for kind: TextSyntaxTokenKind) -> NSColor {
        switch kind {
        case .keyword: NSColor(accentHover)
        case .string: NSColor(success)
        case .comment: NSColor(inkTertiary)
        case .number: NSColor(warning)
        case .type: NSColor(secure)
        case .attribute: NSColor(accent)
        }
    }
}
