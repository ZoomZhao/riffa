import Foundation

/// Strict resource ceilings for path-rule construction and matching.
public struct PathFilterLimits: Hashable, Codable, Sendable {
    /// Absolute ceilings keep untrusted persisted values from disabling the
    /// resource boundary by supplying values such as `Int.max`.
    public static let absoluteMaximumRuleCount = 4_096
    public static let absoluteMaximumRuleUTF8ByteCount = 64 * 1_024
    public static let absoluteMaximumTotalRuleUTF8ByteCount = 1 * 1_024 * 1_024
    public static let absoluteMaximumPathUTF8ByteCount = 1 * 1_024 * 1_024
    public static let absoluteMaximumMatchWork = 100_000_000

    public static let `default`: Self = {
        try! Self()
    }()

    public let maximumRuleCount: Int
    public let maximumRuleUTF8ByteCount: Int
    public let maximumTotalRuleUTF8ByteCount: Int
    public let maximumPathUTF8ByteCount: Int
    public let maximumMatchWork: Int

    public init(
        maximumRuleCount: Int = 256,
        maximumRuleUTF8ByteCount: Int = 4 * 1_024,
        maximumTotalRuleUTF8ByteCount: Int = 64 * 1_024,
        maximumPathUTF8ByteCount: Int = 16 * 1_024,
        maximumMatchWork: Int = 100_000_000
    ) throws {
        guard maximumRuleCount > 0 else {
            throw PathFilterError.invalidLimit(name: "maximumRuleCount")
        }
        guard maximumRuleUTF8ByteCount > 0 else {
            throw PathFilterError.invalidLimit(name: "maximumRuleUTF8ByteCount")
        }
        guard maximumTotalRuleUTF8ByteCount > 0 else {
            throw PathFilterError.invalidLimit(name: "maximumTotalRuleUTF8ByteCount")
        }
        guard maximumPathUTF8ByteCount > 0 else {
            throw PathFilterError.invalidLimit(name: "maximumPathUTF8ByteCount")
        }
        guard maximumMatchWork > 0 else {
            throw PathFilterError.invalidLimit(name: "maximumMatchWork")
        }
        guard maximumRuleCount <= Self.absoluteMaximumRuleCount else {
            throw PathFilterError.limitExceedsAbsoluteMaximum(
                name: "maximumRuleCount",
                maximum: Self.absoluteMaximumRuleCount
            )
        }
        guard maximumRuleUTF8ByteCount <= Self.absoluteMaximumRuleUTF8ByteCount else {
            throw PathFilterError.limitExceedsAbsoluteMaximum(
                name: "maximumRuleUTF8ByteCount",
                maximum: Self.absoluteMaximumRuleUTF8ByteCount
            )
        }
        guard maximumTotalRuleUTF8ByteCount <= Self.absoluteMaximumTotalRuleUTF8ByteCount else {
            throw PathFilterError.limitExceedsAbsoluteMaximum(
                name: "maximumTotalRuleUTF8ByteCount",
                maximum: Self.absoluteMaximumTotalRuleUTF8ByteCount
            )
        }
        guard maximumPathUTF8ByteCount <= Self.absoluteMaximumPathUTF8ByteCount else {
            throw PathFilterError.limitExceedsAbsoluteMaximum(
                name: "maximumPathUTF8ByteCount",
                maximum: Self.absoluteMaximumPathUTF8ByteCount
            )
        }
        guard maximumMatchWork <= Self.absoluteMaximumMatchWork else {
            throw PathFilterError.limitExceedsAbsoluteMaximum(
                name: "maximumMatchWork",
                maximum: Self.absoluteMaximumMatchWork
            )
        }
        guard maximumRuleUTF8ByteCount <= maximumTotalRuleUTF8ByteCount else {
            throw PathFilterError.invalidLimit(
                name: "maximumRuleUTF8ByteCount cannot exceed maximumTotalRuleUTF8ByteCount"
            )
        }

        self.maximumRuleCount = maximumRuleCount
        self.maximumRuleUTF8ByteCount = maximumRuleUTF8ByteCount
        self.maximumTotalRuleUTF8ByteCount = maximumTotalRuleUTF8ByteCount
        self.maximumPathUTF8ByteCount = maximumPathUTF8ByteCount
        self.maximumMatchWork = maximumMatchWork
    }

    private enum CodingKeys: String, CodingKey {
        case maximumRuleCount
        case maximumRuleUTF8ByteCount
        case maximumTotalRuleUTF8ByteCount
        case maximumPathUTF8ByteCount
        case maximumMatchWork
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            maximumRuleCount: values.decode(Int.self, forKey: .maximumRuleCount),
            maximumRuleUTF8ByteCount: values.decode(Int.self, forKey: .maximumRuleUTF8ByteCount),
            maximumTotalRuleUTF8ByteCount: values.decode(
                Int.self,
                forKey: .maximumTotalRuleUTF8ByteCount
            ),
            maximumPathUTF8ByteCount: values.decode(Int.self, forKey: .maximumPathUTF8ByteCount),
            maximumMatchWork: values.decode(Int.self, forKey: .maximumMatchWork)
        )
    }
}

/// Path-free failures for malformed or over-budget rule sets.
public enum PathFilterError: Error, Equatable, Sendable {
    public enum RuleList: String, Equatable, Sendable {
        case include
        case exclude
    }

    case invalidLimit(name: String)
    case limitExceedsAbsoluteMaximum(name: String, maximum: Int)
    case ruleCountExceeded(actual: Int, limit: Int)
    case emptyRule(list: RuleList, index: Int)
    case trailingEscape(list: RuleList, index: Int)
    case ruleByteLimitExceeded(list: RuleList, index: Int, actual: Int, limit: Int)
    case totalRuleByteLimitExceeded(actual: Int, limit: Int)
    case invalidRelativePath
    case pathByteLimitExceeded(actual: Int, limit: Int)
    case matchWorkLimitExceeded(limit: Int)
}

extension PathFilterError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidLimit(name):
            "The path-filter limit \(name) must be strictly positive and internally consistent."
        case let .limitExceedsAbsoluteMaximum(name, maximum):
            "The path-filter limit \(name) exceeds its absolute maximum of \(maximum)."
        case let .ruleCountExceeded(actual, limit):
            "The path rules contain \(actual) patterns, exceeding the \(limit)-pattern limit."
        case let .emptyRule(list, index):
            "The \(list.rawValue) pattern at line \(index + 1) is empty."
        case let .trailingEscape(list, index):
            "The \(list.rawValue) pattern at line \(index + 1) ends with an incomplete escape."
        case let .ruleByteLimitExceeded(list, index, actual, limit):
            "The \(list.rawValue) pattern at line \(index + 1) contains \(actual) UTF-8 bytes, "
                + "exceeding the \(limit)-byte limit."
        case let .totalRuleByteLimitExceeded(actual, limit):
            "The path rules contain \(actual) UTF-8 bytes, exceeding the \(limit)-byte total limit."
        case .invalidRelativePath:
            "The path filter received an invalid slash-separated relative path."
        case let .pathByteLimitExceeded(actual, limit):
            "A relative path contains \(actual) UTF-8 bytes, exceeding the \(limit)-byte limit."
        case let .matchWorkLimitExceeded(limit):
            "Path-rule matching exceeded its \(limit)-step work limit."
        }
    }
}

/// Persistent include/exclude rules for folder comparison.
///
/// Patterns are anchored to the complete, slash-separated relative path:
/// `*` matches zero or more non-`/` characters, `?` matches one non-`/`
/// character, and `**` matches zero or more characters including `/`.
/// A backslash escapes the following character, so `\*` matches a literal
/// asterisk and `\\` matches a literal backslash. When `**/` starts at a path
/// segment boundary it matches zero or more complete directory prefixes, so
/// `**/*.swift` includes both `Main.swift` and `Sources/Main.swift`.
///
/// An empty include list includes every path. Excludes are evaluated after
/// includes and always win. Empty patterns and incomplete trailing escapes are
/// rejected rather than interpreted broadly.
public struct FolderPathRules: Hashable, Codable, Sendable {
    public static let all: Self = {
        try! Self(isEnabled: false)
    }()

    public let isEnabled: Bool
    public let includePatterns: [String]
    public let excludePatterns: [String]
    public let isCaseSensitive: Bool
    public let limits: PathFilterLimits

    public init(
        isEnabled: Bool = true,
        includePatterns: [String] = [],
        excludePatterns: [String] = [],
        isCaseSensitive: Bool = true,
        limits: PathFilterLimits = .default
    ) throws {
        self.isEnabled = isEnabled
        self.includePatterns = includePatterns
        self.excludePatterns = excludePatterns
        self.isCaseSensitive = isCaseSensitive
        self.limits = limits
        try validate()
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case includePatterns
        case excludePatterns
        case isCaseSensitive
        case limits
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            isEnabled: values.decode(Bool.self, forKey: .isEnabled),
            includePatterns: values.decode([String].self, forKey: .includePatterns),
            excludePatterns: values.decode([String].self, forKey: .excludePatterns),
            isCaseSensitive: values.decode(Bool.self, forKey: .isCaseSensitive),
            limits: values.decode(PathFilterLimits.self, forKey: .limits)
        )
    }

    fileprivate func validate() throws {
        let ruleCount = includePatterns.count + excludePatterns.count
        guard ruleCount <= limits.maximumRuleCount else {
            throw PathFilterError.ruleCountExceeded(
                actual: ruleCount,
                limit: limits.maximumRuleCount
            )
        }

        var totalByteCount = 0
        try validate(
            includePatterns,
            list: .include,
            totalByteCount: &totalByteCount
        )
        try validate(
            excludePatterns,
            list: .exclude,
            totalByteCount: &totalByteCount
        )
        guard totalByteCount <= limits.maximumTotalRuleUTF8ByteCount else {
            throw PathFilterError.totalRuleByteLimitExceeded(
                actual: totalByteCount,
                limit: limits.maximumTotalRuleUTF8ByteCount
            )
        }
    }

    private func validate(
        _ patterns: [String],
        list: PathFilterError.RuleList,
        totalByteCount: inout Int
    ) throws {
        for (index, pattern) in patterns.enumerated() {
            guard !pattern.isEmpty else {
                throw PathFilterError.emptyRule(list: list, index: index)
            }
            let byteCount = pattern.utf8.count
            guard byteCount <= limits.maximumRuleUTF8ByteCount else {
                throw PathFilterError.ruleByteLimitExceeded(
                    list: list,
                    index: index,
                    actual: byteCount,
                    limit: limits.maximumRuleUTF8ByteCount
                )
            }
            let addition = totalByteCount.addingReportingOverflow(byteCount)
            guard !addition.overflow else {
                throw PathFilterError.totalRuleByteLimitExceeded(
                    actual: Int.max,
                    limit: limits.maximumTotalRuleUTF8ByteCount
                )
            }
            totalByteCount = addition.partialValue
            guard !Self.hasTrailingEscape(pattern) else {
                throw PathFilterError.trailingEscape(list: list, index: index)
            }
        }
    }

    private static func hasTrailingEscape(_ pattern: String) -> Bool {
        var trailingBackslashCount = 0
        for character in pattern.reversed() {
            guard character == "\\" else { break }
            trailingBackslashCount += 1
        }
        return trailingBackslashCount % 2 == 1
    }
}

/// Deterministic dynamic-programming matcher with a cumulative work budget.
/// One instance is intended for one folder-comparison publication pass.
public struct PathFilter: Sendable {
    private let rules: FolderPathRules
    private let includes: [[Token]]
    private let excludes: [[Token]]
    private var consumedWork = 0

    public init(rules: FolderPathRules) throws {
        try rules.validate()
        self.rules = rules
        includes = try rules.includePatterns.map {
            try Self.compile($0, caseSensitive: rules.isCaseSensitive)
        }
        excludes = try rules.excludePatterns.map {
            try Self.compile($0, caseSensitive: rules.isCaseSensitive)
        }
    }

    public mutating func includes(relativePath: String) throws -> Bool {
        guard rules.isEnabled else { return true }
        let byteCount = relativePath.utf8.count
        guard byteCount <= rules.limits.maximumPathUTF8ByteCount else {
            throw PathFilterError.pathByteLimitExceeded(
                actual: byteCount,
                limit: rules.limits.maximumPathUTF8ByteCount
            )
        }
        guard Self.isValidRelativePath(relativePath) else {
            throw PathFilterError.invalidRelativePath
        }

        let path = Self.prepared(relativePath, caseSensitive: rules.isCaseSensitive)
        let characters = Array(path)
        let included: Bool
        if includes.isEmpty {
            included = true
        } else {
            included = try includes.contains { tokens in
                try matches(tokens, path: characters)
            }
        }
        guard included else { return false }

        for tokens in excludes {
            if try matches(tokens, path: characters) {
                return false
            }
        }
        return true
    }

    private enum Token: Sendable {
        case literal(Character)
        case one
        case star
        case globstar
        case directoryGlobstar

        var isSlashLiteral: Bool {
            if case .literal("/") = self { return true }
            return false
        }
    }

    private static func compile(
        _ pattern: String,
        caseSensitive: Bool
    ) throws -> [Token] {
        let characters = Array(prepared(pattern, caseSensitive: caseSensitive))
        var tokens: [Token] = []
        tokens.reserveCapacity(characters.count)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\\" {
                guard index + 1 < characters.count else {
                    // Construction already reports the precise list and line.
                    throw PathFilterError.trailingEscape(list: .include, index: 0)
                }
                tokens.append(.literal(characters[index + 1]))
                index += 2
                continue
            }
            if character == "?" {
                tokens.append(.one)
                index += 1
                continue
            }
            if character == "*" {
                if index + 1 < characters.count, characters[index + 1] == "*" {
                    let atSegmentBoundary = tokens.isEmpty || tokens.last?.isSlashLiteral == true
                    if atSegmentBoundary,
                       index + 2 < characters.count,
                       characters[index + 2] == "/" {
                        tokens.append(.directoryGlobstar)
                        index += 3
                    } else {
                        tokens.append(.globstar)
                        index += 2
                    }
                } else {
                    tokens.append(.star)
                    index += 1
                }
                continue
            }
            tokens.append(.literal(character))
            index += 1
        }
        return tokens
    }

    private mutating func matches(
        _ tokens: [Token],
        path: [Character]
    ) throws -> Bool {
        var previous = [Bool](repeating: false, count: path.count + 1)
        previous[0] = true

        for token in tokens {
            var current = [Bool](repeating: false, count: path.count + 1)
            switch token {
            case let .literal(expected):
                for pathIndex in 1...path.count {
                    try consumeWork()
                    current[pathIndex] = previous[pathIndex - 1]
                        && path[pathIndex - 1] == expected
                }
                try consumeWork()

            case .one:
                for pathIndex in 1...path.count {
                    try consumeWork()
                    current[pathIndex] = previous[pathIndex - 1]
                        && path[pathIndex - 1] != "/"
                }
                try consumeWork()

            case .star:
                current[0] = previous[0]
                try consumeWork()
                for pathIndex in 1...path.count {
                    try consumeWork()
                    current[pathIndex] = previous[pathIndex]
                        || (current[pathIndex - 1] && path[pathIndex - 1] != "/")
                }

            case .globstar:
                current[0] = previous[0]
                try consumeWork()
                for pathIndex in 1...path.count {
                    try consumeWork()
                    current[pathIndex] = previous[pathIndex] || current[pathIndex - 1]
                }

            case .directoryGlobstar:
                var canConsumeDirectoryPrefix = false
                for pathIndex in 0...path.count {
                    try consumeWork()
                    if previous[pathIndex] {
                        current[pathIndex] = true
                        canConsumeDirectoryPrefix = true
                    }
                    if pathIndex > 0,
                       canConsumeDirectoryPrefix,
                       path[pathIndex - 1] == "/" {
                        current[pathIndex] = true
                    }
                }
            }
            previous = current
        }
        return previous[path.count]
    }

    private mutating func consumeWork() throws {
        if consumedWork.isMultiple(of: 4_096) {
            try Task.checkCancellation()
        }
        guard consumedWork < rules.limits.maximumMatchWork else {
            throw PathFilterError.matchWorkLimitExceeded(
                limit: rules.limits.maximumMatchWork
            )
        }
        consumedWork += 1
    }

    private static func prepared(_ value: String, caseSensitive: Bool) -> String {
        let normalized = value.precomposedStringWithCanonicalMapping
        guard !caseSensitive else { return normalized }
        return normalized
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }

    private static func isValidRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              path != ".",
              !path.hasPrefix("/"),
              !path.hasSuffix("/"),
              !path.contains("//") else {
            return false
        }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains {
            $0 == "." || $0 == ".."
        }
    }
}
