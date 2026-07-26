import Foundation

/// The interpretation applied to a text-search pattern.
public enum TextSearchMode: String, Codable, CaseIterable, Sendable {
    case literal
    case regularExpression
}

/// Resource ceilings for an individual search or replacement operation.
///
/// All character limits use UTF-16 code units because that is the coordinate
/// system used by Foundation's regular-expression engine and by `NSRange`.
public struct TextSearchLimits: Equatable, Sendable {
    public var maximumPatternUTF16Length: Int
    public var maximumInputUTF16Length: Int
    public var maximumMatchCount: Int
    public var maximumReplacementUTF16Length: Int
    public var maximumOutputUTF16Length: Int

    public init(
        maximumPatternUTF16Length: Int = 4_096,
        maximumInputUTF16Length: Int = 8 * 1_024 * 1_024,
        maximumMatchCount: Int = 100_000,
        maximumReplacementUTF16Length: Int = 1 * 1_024 * 1_024,
        maximumOutputUTF16Length: Int = 32 * 1_024 * 1_024
    ) {
        self.maximumPatternUTF16Length = maximumPatternUTF16Length
        self.maximumInputUTF16Length = maximumInputUTF16Length
        self.maximumMatchCount = maximumMatchCount
        self.maximumReplacementUTF16Length = maximumReplacementUTF16Length
        self.maximumOutputUTF16Length = maximumOutputUTF16Length
    }
}

public struct TextSearchOptions: Equatable, Sendable {
    public var mode: TextSearchMode
    public var caseSensitive: Bool
    public var limits: TextSearchLimits

    public init(
        mode: TextSearchMode = .literal,
        caseSensitive: Bool = true,
        limits: TextSearchLimits = .init()
    ) {
        self.mode = mode
        self.caseSensitive = caseSensitive
        self.limits = limits
    }
}

/// A range expressed in UTF-16 code units.
///
/// This representation round-trips Foundation regular-expression ranges and
/// can be converted safely to native `String.Index` values with `range(in:)`.
public struct TextSearchRange: Equatable, Hashable, Sendable {
    public let location: Int
    public let length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }

    public var upperBound: Int { location + length }

    public var nsRange: NSRange { NSRange(location: location, length: length) }

    public func range(in string: String) -> Range<String.Index>? {
        Range(nsRange, in: string)
    }

    public func substring(in string: String) -> String? {
        guard let range = range(in: string) else { return nil }
        return String(string[range])
    }
}

public struct TextSearchMatch: Equatable, Sendable {
    public let range: TextSearchRange
    /// Capture-group ranges in numeric order. An unmatched optional group is
    /// represented by `nil`. The full match is available through `range`.
    public let captures: [TextSearchRange?]

    public init(range: TextSearchRange, captures: [TextSearchRange?] = []) {
        self.range = range
        self.captures = captures
    }
}

public struct TextSearchResult: Equatable, Sendable {
    public let matches: [TextSearchMatch]

    public init(matches: [TextSearchMatch]) {
        self.matches = matches
    }
}

public struct TextReplacementResult: Equatable, Sendable {
    public let text: String
    public let replacementCount: Int

    public init(text: String, replacementCount: Int) {
        self.text = text
        self.replacementCount = replacementCount
    }
}

public enum TextSearchError: Error, Equatable, Sendable {
    case invalidLimit(name: String, value: Int)
    case patternLimitExceeded(actual: Int, limit: Int)
    case inputLimitExceeded(actual: Int, limit: Int)
    case matchLimitExceeded(limit: Int)
    case replacementLimitExceeded(actual: Int, limit: Int)
    case outputLimitExceeded(limit: Int)
    case invalidRegularExpression(reason: String)
    case unsafeRegularExpression(reason: String)
    case zeroWidthMatch(location: Int)
    case invalidUTF16Range(location: Int, length: Int)
}

extension TextSearchError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidLimit(name, value):
            "The text-search limit \(name) must be positive; received \(value)."
        case let .patternLimitExceeded(actual, limit):
            "The search pattern is too long (\(actual) UTF-16 units; limit \(limit))."
        case let .inputLimitExceeded(actual, limit):
            "The searched text is too large (\(actual) UTF-16 units; limit \(limit))."
        case let .matchLimitExceeded(limit):
            "The search produced more than \(limit) matches. Narrow the pattern and try again."
        case let .replacementLimitExceeded(actual, limit):
            "The replacement is too long (\(actual) UTF-16 units; limit \(limit))."
        case let .outputLimitExceeded(limit):
            "The replacement result would exceed the \(limit) UTF-16 unit safety limit."
        case let .invalidRegularExpression(reason):
            "Invalid regular expression: \(reason)"
        case let .unsafeRegularExpression(reason):
            "This regular expression was rejected for safety: \(reason)"
        case let .zeroWidthMatch(location):
            "The regular expression produces an empty match at UTF-16 offset \(location)."
        case let .invalidUTF16Range(location, length):
            "The search engine returned an invalid UTF-16 range at \(location) with length \(length)."
        }
    }
}

/// Compiles and executes bounded literal or regular-expression searches.
public struct TextSearchEngine: Sendable {
    public let options: TextSearchOptions

    public init(options: TextSearchOptions = .init()) {
        self.options = options
    }

    public func prepare(pattern: String) throws -> PreparedTextSearch {
        try Self.validate(limits: options.limits)
        let patternLength = pattern.utf16.count
        guard patternLength <= options.limits.maximumPatternUTF16Length else {
            throw TextSearchError.patternLimitExceeded(
                actual: patternLength,
                limit: options.limits.maximumPatternUTF16Length
            )
        }

        guard !pattern.isEmpty else {
            return PreparedTextSearch(
                expression: nil,
                mode: options.mode,
                limits: options.limits
            )
        }

        let expressionPattern: String
        switch options.mode {
        case .literal:
            expressionPattern = NSRegularExpression.escapedPattern(for: pattern)
        case .regularExpression:
            expressionPattern = pattern
        }

        let expression: NSRegularExpression
        do {
            expression = try NSRegularExpression(
                pattern: expressionPattern,
                options: options.caseSensitive ? [] : [.caseInsensitive]
            )
        } catch {
            throw TextSearchError.invalidRegularExpression(reason: error.localizedDescription)
        }

        if options.mode == .regularExpression {
            try RegexSafetyValidator.validate(pattern)
            let emptyRange = NSRange(location: 0, length: 0)
            if let match = expression.firstMatch(in: "", range: emptyRange),
               match.range.length == 0 {
                throw TextSearchError.zeroWidthMatch(location: 0)
            }
        }

        return PreparedTextSearch(
            expression: expression,
            mode: options.mode,
            limits: options.limits
        )
    }

    public func findAll(pattern: String, in input: String) throws -> TextSearchResult {
        try prepare(pattern: pattern).findAll(in: input)
    }

    public func replaceAll(
        pattern: String,
        in input: String,
        with replacement: String
    ) throws -> TextReplacementResult {
        try prepare(pattern: pattern).replaceAll(in: input, with: replacement)
    }

    private static func validate(limits: TextSearchLimits) throws {
        let values = [
            ("maximumPatternUTF16Length", limits.maximumPatternUTF16Length),
            ("maximumInputUTF16Length", limits.maximumInputUTF16Length),
            ("maximumMatchCount", limits.maximumMatchCount),
            ("maximumReplacementUTF16Length", limits.maximumReplacementUTF16Length),
            ("maximumOutputUTF16Length", limits.maximumOutputUTF16Length)
        ]
        if let invalid = values.first(where: { $0.1 <= 0 }) {
            throw TextSearchError.invalidLimit(name: invalid.0, value: invalid.1)
        }
    }
}

/// A compiled pattern that can be reused for line-by-line highlighting.
public struct PreparedTextSearch {
    private let expression: NSRegularExpression?
    public let mode: TextSearchMode
    public let limits: TextSearchLimits

    fileprivate init(
        expression: NSRegularExpression?,
        mode: TextSearchMode,
        limits: TextSearchLimits
    ) {
        self.expression = expression
        self.mode = mode
        self.limits = limits
    }

    public func contains(in input: String) throws -> Bool {
        try !boundedMatches(in: input).isEmpty
    }

    public func findAll(in input: String) throws -> TextSearchResult {
        let nativeMatches = try boundedMatches(in: input)
        return TextSearchResult(matches: try nativeMatches.map { match in
            guard match.range.location != NSNotFound,
                  match.range.location >= 0,
                  match.range.length > 0,
                  match.range.location + match.range.length <= input.utf16.count
            else {
                throw TextSearchError.invalidUTF16Range(
                    location: match.range.location,
                    length: match.range.length
                )
            }
            let captures = (1..<match.numberOfRanges).map { index -> TextSearchRange? in
                let range = match.range(at: index)
                guard range.location != NSNotFound else { return nil }
                return TextSearchRange(location: range.location, length: range.length)
            }
            return TextSearchMatch(
                range: TextSearchRange(
                    location: match.range.location,
                    length: match.range.length
                ),
                captures: captures
            )
        })
    }

    public func replaceAll(
        in input: String,
        with replacement: String
    ) throws -> TextReplacementResult {
        let replacementLength = replacement.utf16.count
        guard replacementLength <= limits.maximumReplacementUTF16Length else {
            throw TextSearchError.replacementLimitExceeded(
                actual: replacementLength,
                limit: limits.maximumReplacementUTF16Length
            )
        }

        let matches = try boundedMatches(in: input)
        guard !matches.isEmpty else {
            return TextReplacementResult(text: input, replacementCount: 0)
        }

        var replacements: [String] = []
        replacements.reserveCapacity(matches.count)
        var removedLength = 0
        for match in matches {
            let attempted = removedLength.addingReportingOverflow(match.range.length)
            guard !attempted.overflow,
                  attempted.partialValue <= input.utf16.count else {
                throw TextSearchError.invalidUTF16Range(
                    location: match.range.location,
                    length: match.range.length
                )
            }
            removedLength = attempted.partialValue
        }
        let retainedLength = input.utf16.count - removedLength
        guard retainedLength <= limits.maximumOutputUTF16Length else {
            throw TextSearchError.outputLimitExceeded(
                limit: limits.maximumOutputUTF16Length
            )
        }
        var totalReplacementLength = 0
        for match in matches {
            let replacementLimit = limits.maximumOutputUTF16Length
                - retainedLength
                - totalReplacementLength
            let expanded: String
            switch mode {
            case .literal:
                expanded = replacement
            case .regularExpression:
                expanded = try boundedRegexReplacement(
                    template: replacement,
                    match: match,
                    input: input,
                    maximumUTF16Length: replacementLimit
                )
            }

            let addedLength = expanded.utf16.count
            guard addedLength <= replacementLimit else {
                throw TextSearchError.outputLimitExceeded(
                    limit: limits.maximumOutputUTF16Length
                )
            }
            totalReplacementLength += addedLength
            replacements.append(expanded)
        }

        let mutable = NSMutableString(string: input)
        for (match, expanded) in zip(matches, replacements).reversed() {
            mutable.replaceCharacters(in: match.range, with: expanded)
        }
        return TextReplacementResult(
            text: mutable as String,
            replacementCount: matches.count
        )
    }

    private func boundedMatches(in input: String) throws -> [NSTextCheckingResult] {
        try validateInput(input)
        guard let expression else { return [] }

        var matches: [NSTextCheckingResult] = []
        matches.reserveCapacity(min(256, limits.maximumMatchCount))
        var failure: TextSearchError?
        let range = NSRange(location: 0, length: input.utf16.count)
        expression.enumerateMatches(in: input, range: range) { result, _, stop in
            guard let result else { return }
            if result.range.length == 0 {
                failure = .zeroWidthMatch(location: result.range.location)
                stop.pointee = true
            } else if matches.count == limits.maximumMatchCount {
                failure = .matchLimitExceeded(limit: limits.maximumMatchCount)
                stop.pointee = true
            } else {
                matches.append(result)
            }
        }
        if let failure { throw failure }
        return matches
    }

    private func validateInput(_ input: String) throws {
        let inputLength = input.utf16.count
        guard inputLength <= limits.maximumInputUTF16Length else {
            throw TextSearchError.inputLimitExceeded(
                actual: inputLength,
                limit: limits.maximumInputUTF16Length
            )
        }
    }

    /// Expands Foundation's numeric capture-template syntax while checking the
    /// allocation ceiling before every append. Calling
    /// `NSRegularExpression.replacementString` first would let a template such
    /// as `$1$1…` allocate an arbitrarily large intermediate string before the
    /// caller could enforce `maximumOutputUTF16Length`.
    private func boundedRegexReplacement(
        template: String,
        match: NSTextCheckingResult,
        input: String,
        maximumUTF16Length: Int
    ) throws -> String {
        var result = ""
        result.reserveCapacity(min(template.utf8.count, maximumUTF16Length))
        var resultUTF16Length = 0
        var index = template.startIndex

        func ensureCapacity(for additionalLength: Int) throws {
            let attempted = resultUTF16Length.addingReportingOverflow(additionalLength)
            guard !attempted.overflow,
                  attempted.partialValue <= maximumUTF16Length else {
                throw TextSearchError.outputLimitExceeded(
                    limit: limits.maximumOutputUTF16Length
                )
            }
            resultUTF16Length = attempted.partialValue
        }

        while index < template.endIndex {
            let character = template[index]
            let nextIndex = template.index(after: index)

            if character == "\\" {
                // Foundation drops a trailing escape and otherwise appends the
                // next character literally, including `$` and `\\`.
                guard nextIndex < template.endIndex else { break }
                let escaped = template[nextIndex]
                let escapedLength = String(escaped).utf16.count
                try ensureCapacity(for: escapedLength)
                result.append(escaped)
                index = template.index(after: nextIndex)
                continue
            }

            if character == "$", nextIndex < template.endIndex,
               let captureIndex = Self.asciiDigit(template[nextIndex]) {
                if captureIndex < match.numberOfRanges {
                    let captureRange = match.range(at: captureIndex)
                    if captureRange.location != NSNotFound {
                        guard captureRange.location >= 0,
                              captureRange.length >= 0,
                              captureRange.location + captureRange.length <= input.utf16.count,
                              let stringRange = Range(captureRange, in: input) else {
                            throw TextSearchError.invalidUTF16Range(
                                location: captureRange.location,
                                length: captureRange.length
                            )
                        }
                        try ensureCapacity(for: captureRange.length)
                        result.append(contentsOf: input[stringRange])
                    }
                }
                // Foundation consumes one digit only. `$10` is capture 1
                // followed by the literal `0`; an unavailable capture is empty.
                index = template.index(after: nextIndex)
                continue
            }

            let characterLength = String(character).utf16.count
            try ensureCapacity(for: characterLength)
            result.append(character)
            index = nextIndex
        }
        return result
    }

    private static func asciiDigit(_ character: Character) -> Int? {
        let utf8 = String(character).utf8
        guard utf8.count == 1, let value = utf8.first,
              value >= 48, value <= 57 else {
            return nil
        }
        return Int(value - 48)
    }
}

private enum RegexSafetyValidator {
    private struct GroupRisk {
        var containsUnboundedQuantifier = false
        var containsAlternation = false
    }

    static func validate(_ pattern: String) throws {
        let scalars = Array(pattern.unicodeScalars)
        var groups = [GroupRisk()]
        var inCharacterClass = false
        var escaped = false
        var lastClosedGroup: GroupRisk?
        var index = 0

        while index < scalars.count {
            let scalar = scalars[index]

            if escaped {
                if !inCharacterClass,
                   (scalar.value >= 49 && scalar.value <= 57
                    || (scalar == "k" || scalar == "g")
                    && index + 1 < scalars.count
                    && scalars[index + 1] == "<") {
                    throw TextSearchError.unsafeRegularExpression(
                        reason: "backreferences can cause unbounded backtracking"
                    )
                }
                escaped = false
                lastClosedGroup = nil
                index += 1
                continue
            }

            if scalar == "\\" {
                escaped = true
                index += 1
                continue
            }

            if inCharacterClass {
                if scalar == "]" { inCharacterClass = false }
                index += 1
                continue
            }

            switch scalar {
            case "[":
                inCharacterClass = true
                lastClosedGroup = nil
            case "(":
                groups.append(GroupRisk())
                lastClosedGroup = nil
            case ")":
                if groups.count > 1 {
                    let closed = groups.removeLast()
                    groups[groups.count - 1].containsUnboundedQuantifier =
                        groups[groups.count - 1].containsUnboundedQuantifier
                        || closed.containsUnboundedQuantifier
                    groups[groups.count - 1].containsAlternation =
                        groups[groups.count - 1].containsAlternation
                        || closed.containsAlternation
                    lastClosedGroup = closed
                } else {
                    lastClosedGroup = nil
                }
            case "|":
                groups[groups.count - 1].containsAlternation = true
                lastClosedGroup = nil
            case "*", "+":
                try noteUnboundedQuantifier(
                    after: lastClosedGroup,
                    currentGroup: &groups[groups.count - 1]
                )
                lastClosedGroup = nil
            case "{":
                if let quantifier = braceQuantifier(in: scalars, startingAt: index) {
                    if quantifier.isUnbounded {
                        try noteUnboundedQuantifier(
                            after: lastClosedGroup,
                            currentGroup: &groups[groups.count - 1]
                        )
                    }
                    index = quantifier.endIndex
                    lastClosedGroup = nil
                } else {
                    lastClosedGroup = nil
                }
            default:
                // `?` after a group is bounded; group prefixes such as `?:`
                // are likewise not repetition hazards by themselves.
                lastClosedGroup = nil
            }
            index += 1
        }
    }

    private static func noteUnboundedQuantifier(
        after group: GroupRisk?,
        currentGroup: inout GroupRisk
    ) throws {
        if let group, group.containsUnboundedQuantifier {
            throw TextSearchError.unsafeRegularExpression(
                reason: "nested unbounded quantifiers are not allowed"
            )
        }
        if let group, group.containsAlternation {
            throw TextSearchError.unsafeRegularExpression(
                reason: "an alternation cannot be repeated without an upper bound"
            )
        }
        currentGroup.containsUnboundedQuantifier = true
    }

    private static func braceQuantifier(
        in scalars: [Unicode.Scalar],
        startingAt start: Int
    ) -> (isUnbounded: Bool, endIndex: Int)? {
        var end = start + 1
        while end < scalars.count, scalars[end] != "}" { end += 1 }
        guard end < scalars.count else { return nil }
        let body = String(String.UnicodeScalarView(scalars[(start + 1)..<end]))
        let components = body.split(separator: ",", omittingEmptySubsequences: false)
        guard (components.count == 1 || components.count == 2),
              !components[0].isEmpty,
              components[0].allSatisfy(\.isNumber)
        else { return nil }
        if components.count == 1 { return (false, end) }
        guard components[1].isEmpty || components[1].allSatisfy(\.isNumber) else {
            return nil
        }
        return (components[1].isEmpty, end)
    }
}
