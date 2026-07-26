import Foundation
import Testing
@testable import RiffaCore

@Suite("Bounded folder path rules")
struct PathFilterTests {
    @Test("Stars, double stars, question marks, and slash boundaries are deterministic")
    func wildcardSemantics() throws {
        var rootSwift = try filter(includes: ["*.swift"])
        #expect(try rootSwift.includes(relativePath: "Main.swift"))
        #expect(try !rootSwift.includes(relativePath: "Sources/Main.swift"))

        var anySwift = try filter(includes: ["**/*.swift"])
        #expect(try anySwift.includes(relativePath: "Main.swift"))
        #expect(try anySwift.includes(relativePath: "Sources/Main.swift"))
        #expect(try !anySwift.includes(relativePath: "Sources/Main.swift.bak"))

        var nested = try filter(includes: ["Sources/**", "foo/**/bar?.txt"])
        #expect(try nested.includes(relativePath: "Sources/Deep/File.txt"))
        #expect(try !nested.includes(relativePath: "Other/Sources/File.txt"))
        #expect(try nested.includes(relativePath: "foo/bar1.txt"))
        #expect(try nested.includes(relativePath: "foo/a/b/barZ.txt"))
        #expect(try !nested.includes(relativePath: "foo/a/b/barZZ.txt"))
    }

    @Test("Backslash escapes metacharacters, slash, and backslash")
    func escapeSemantics() throws {
        var escaped = try filter(includes: [
            #"literal\*.txt"#,
            #"what\?.txt"#,
            #"folder\/file"#,
            #"back\\slash"#
        ])
        #expect(try escaped.includes(relativePath: "literal*.txt"))
        #expect(try !escaped.includes(relativePath: "literalX.txt"))
        #expect(try escaped.includes(relativePath: "what?.txt"))
        #expect(try escaped.includes(relativePath: "folder/file"))
        #expect(try escaped.includes(relativePath: #"back\slash"#))

        #expect(throws: PathFilterError.trailingEscape(list: .include, index: 0)) {
            _ = try FolderPathRules(includePatterns: [#"unfinished\"#])
        }
    }

    @Test("Unicode normalization and optional case folding are stable")
    func unicodeAndCase() throws {
        var insensitive = try filter(
            includes: ["Cafe\u{301}/file.txt"],
            caseSensitive: false
        )
        #expect(try insensitive.includes(relativePath: "CAFÉ/FILE.TXT"))

        var sensitive = try filter(includes: ["CAFÉ/FILE.TXT"])
        #expect(try sensitive.includes(relativePath: "CAFÉ/FILE.TXT"))
        #expect(try !sensitive.includes(relativePath: "Café/FILE.TXT"))
    }

    @Test("An empty include list means all paths and excludes always win")
    func excludePrecedence() throws {
        var emptyIncludes = try filter(excludes: ["build/**"])
        #expect(try emptyIncludes.includes(relativePath: "Sources/Main.swift"))
        #expect(try !emptyIncludes.includes(relativePath: "build/output.o"))

        var precedence = try filter(
            includes: ["**", "build/output.o"],
            excludes: ["build/**"]
        )
        #expect(try !precedence.includes(relativePath: "build/output.o"))
    }

    @Test("Rule construction enforces every count and UTF-8 ceiling")
    func ruleLimits() throws {
        #expect(throws: PathFilterError.invalidLimit(name: "maximumRuleCount")) {
            _ = try PathFilterLimits(maximumRuleCount: 0)
        }
        #expect(throws: PathFilterError.invalidLimit(name: "maximumRuleUTF8ByteCount")) {
            _ = try PathFilterLimits(maximumRuleUTF8ByteCount: 0)
        }
        #expect(throws: PathFilterError.invalidLimit(name: "maximumTotalRuleUTF8ByteCount")) {
            _ = try PathFilterLimits(maximumTotalRuleUTF8ByteCount: 0)
        }
        #expect(throws: PathFilterError.invalidLimit(name: "maximumPathUTF8ByteCount")) {
            _ = try PathFilterLimits(maximumPathUTF8ByteCount: 0)
        }
        #expect(throws: PathFilterError.invalidLimit(name: "maximumMatchWork")) {
            _ = try PathFilterLimits(maximumMatchWork: 0)
        }
        #expect(throws: PathFilterError.invalidLimit(
            name: "maximumRuleUTF8ByteCount cannot exceed maximumTotalRuleUTF8ByteCount"
        )) {
            _ = try PathFilterLimits(
                maximumRuleUTF8ByteCount: 2,
                maximumTotalRuleUTF8ByteCount: 1
            )
        }
        #expect(throws: PathFilterError.limitExceedsAbsoluteMaximum(
            name: "maximumMatchWork",
            maximum: PathFilterLimits.absoluteMaximumMatchWork
        )) {
            _ = try PathFilterLimits(
                maximumMatchWork: PathFilterLimits.absoluteMaximumMatchWork + 1
            )
        }

        let countLimits = try limits(ruleCount: 1)
        #expect(throws: PathFilterError.ruleCountExceeded(actual: 2, limit: 1)) {
            _ = try FolderPathRules(
                includePatterns: ["a", "b"],
                limits: countLimits
            )
        }

        let byteLimits = try limits(ruleBytes: 2, totalBytes: 3)
        #expect(throws: PathFilterError.ruleByteLimitExceeded(
            list: .include,
            index: 0,
            actual: 3,
            limit: 2
        )) {
            _ = try FolderPathRules(includePatterns: ["éx"], limits: byteLimits)
        }
        #expect(throws: PathFilterError.totalRuleByteLimitExceeded(actual: 4, limit: 3)) {
            _ = try FolderPathRules(
                includePatterns: ["aa"],
                excludePatterns: ["bb"],
                limits: byteLimits
            )
        }
        #expect(throws: PathFilterError.emptyRule(list: .exclude, index: 0)) {
            _ = try FolderPathRules(excludePatterns: [""])
        }
    }

    @Test("Path bytes and cumulative dynamic-programming work are bounded")
    func matchingLimits() throws {
        let pathLimits = try limits(pathBytes: 3)
        var pathFilter = try filter(includes: ["**"], limits: pathLimits)
        #expect(throws: PathFilterError.pathByteLimitExceeded(actual: 4, limit: 3)) {
            _ = try pathFilter.includes(relativePath: "éé")
        }

        let workLimits = try limits(matchWork: 3)
        var workFilter = try filter(includes: ["*"], limits: workLimits)
        #expect(throws: PathFilterError.matchWorkLimitExceeded(limit: 3)) {
            _ = try workFilter.includes(relativePath: "abc")
        }

        var invalidPathFilter = try filter()
        #expect(throws: PathFilterError.invalidRelativePath) {
            _ = try invalidPathFilter.includes(relativePath: "../private-name")
        }
        #expect(!PathFilterError.invalidRelativePath.localizedDescription.contains("private-name"))
    }

    @Test("Matching observes task cancellation inside the DP work loop")
    func matchingCancellation() async throws {
        let task = Task { () throws -> Bool in
            while !Task.isCancelled {
                await Task.yield()
            }
            var matcher = try filter(includes: ["**a"])
            return try matcher.includes(relativePath: String(repeating: "x", count: 16_000))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test("Codable rejects invalid persisted values and Sendable values round-trip")
    func strictPersistenceBoundary() throws {
        let rules = try FolderPathRules(
            includePatterns: ["**/*.swift"],
            excludePatterns: ["Generated/**"],
            isCaseSensitive: false
        )
        requireSendable(rules)
        requireSendable(rules.limits)
        let encoded = try JSONEncoder().encode(rules)
        #expect(try JSONDecoder().decode(FolderPathRules.self, from: encoded) == rules)

        let invalidLimits = Data(
            #"{"maximumRuleCount":0,"maximumRuleUTF8ByteCount":1,"maximumTotalRuleUTF8ByteCount":1,"maximumPathUTF8ByteCount":1,"maximumMatchWork":1}"#.utf8
        )
        #expect(throws: PathFilterError.invalidLimit(name: "maximumRuleCount")) {
            _ = try JSONDecoder().decode(PathFilterLimits.self, from: invalidLimits)
        }

        let excessiveLimits = Data(
            "{\"maximumRuleCount\":1,\"maximumRuleUTF8ByteCount\":1,\"maximumTotalRuleUTF8ByteCount\":1,\"maximumPathUTF8ByteCount\":1,\"maximumMatchWork\":\(PathFilterLimits.absoluteMaximumMatchWork + 1)}".utf8
        )
        #expect(throws: PathFilterError.limitExceedsAbsoluteMaximum(
            name: "maximumMatchWork",
            maximum: PathFilterLimits.absoluteMaximumMatchWork
        )) {
            _ = try JSONDecoder().decode(PathFilterLimits.self, from: excessiveLimits)
        }

        let invalidRules = Data(
            #"{"isEnabled":true,"includePatterns":[""],"excludePatterns":[],"isCaseSensitive":true,"limits":{"maximumRuleCount":1,"maximumRuleUTF8ByteCount":1,"maximumTotalRuleUTF8ByteCount":1,"maximumPathUTF8ByteCount":1,"maximumMatchWork":1}}"#.utf8
        )
        #expect(throws: PathFilterError.emptyRule(list: .include, index: 0)) {
            _ = try JSONDecoder().decode(FolderPathRules.self, from: invalidRules)
        }
    }

    @Test("Folder publication filters after pairing and withholds unsafe recursive parents")
    func folderComparisonIntegration() async throws {
        try await withTemporaryFolderPair { left, right in
            try write("same", to: left.appending(path: "visible/shown.txt"))
            try write("same", to: right.appending(path: "visible/shown.txt"))
            try write("secret", to: left.appending(path: "visible/hidden.txt"))
            try write("other", to: right.appending(path: "visible/hidden.txt"))
            try write("ignore", to: left.appending(path: "ignore.tmp"))

            let rules = try FolderPathRules(
                includePatterns: ["**"],
                excludePatterns: ["visible/hidden.txt", "*.tmp"]
            )
            let publication = await FolderComparison().comparePublication(
                leftURL: left,
                rightURL: right,
                options: FolderComparisonOptions(
                    compareModificationDates: false,
                    pathRules: rules
                )
            )
            let result = publication.visibleNodes
            #expect(result.map(\.relativePath) == ["visible/shown.txt"])
            #expect(result.first?.status == .same)
            #expect(publication.operationSupportNodes.map(\.relativePath) == ["visible"])
            #expect(publication.operationSupportNodes.allSatisfy {
                $0.left?.kind == .directory || $0.right?.kind == .directory
            })
        }
    }

    @Test("A visible nested leaf copies with support parents but never its hidden sibling")
    func copyPlanningUsesOnlyDirectorySupport() async throws {
        try await withTemporaryFolderPair { left, right in
            try write("shown", to: left.appending(path: "visible/shown.txt"))
            try write("hidden", to: left.appending(path: "visible/hidden.txt"))
            let rules = try FolderPathRules(excludePatterns: ["visible/hidden.txt"])
            let publication = await FolderComparison().comparePublication(
                leftURL: left,
                rightURL: right,
                options: FolderComparisonOptions(
                    compareModificationDates: false,
                    pathRules: rules
                )
            )

            #expect(publication.visibleNodes.map(\.relativePath) == ["visible/shown.txt"])
            #expect(publication.operationSupportNodes.map(\.relativePath) == ["visible"])
            #expect(!publication.operationSupportNodes.contains {
                $0.relativePath == "visible/hidden.txt"
            })

            let result = try FolderSelectionCopyPlanner().plan(
                publication: publication,
                selectedIDs: ["visible/shown.txt"],
                sourceSide: .left
            )
            #expect(result.automaticallyAddedParentCount == 1)
            #expect(result.plan.actions.map(\.targetRelativePath).compactMap { $0 } == [
                "visible", "visible/shown.txt"
            ])
            #expect(result.plan.actions.contains {
                $0.kind == .createDirectory && $0.targetRelativePath == "visible"
            })
            #expect(result.plan.actions.contains {
                $0.kind == .copy && $0.targetRelativePath == "visible/shown.txt"
            })
            #expect(!result.plan.actions.contains {
                $0.sourceRelativePath == "visible/hidden.txt"
                    || $0.targetRelativePath == "visible/hidden.txt"
            })

            #expect(throws: FolderSelectionCopyPlanningError.selectionIsNotVisible) {
                _ = try FolderSelectionCopyPlanner().plan(
                    publication: publication,
                    selectedIDs: ["visible"],
                    sourceSide: .left
                )
            }
        }
    }

    @Test("Root comparison errors survive an exclude-all rule")
    func rootErrorSurvives() async throws {
        try await withTemporaryFolderPair { left, right in
            let fileRoot = left.appending(path: "not-a-folder")
            try write("file", to: fileRoot)
            let rules = try FolderPathRules(excludePatterns: ["**"])
            let publication = await FolderComparison().comparePublication(
                leftURL: fileRoot,
                rightURL: right,
                options: FolderComparisonOptions(pathRules: rules)
            )
            let result = publication.visibleNodes
            #expect(result.count == 1)
            #expect(result.first?.relativePath == ".")
            #expect(result.first?.status == .error)
            #expect(publication.operationSupportNodes.isEmpty)
        }
    }

    @Test("Cancelled comparison publication fails closed without operation support")
    func cancelledPublicationHasNoSupport() async throws {
        try await withTemporaryFolderPair { left, right in
            try write("value", to: left.appending(path: "nested/file.txt"))
            let rules = try FolderPathRules(includePatterns: ["**"])
            let task = Task {
                while !Task.isCancelled { await Task.yield() }
                return await FolderComparison().comparePublication(
                    leftURL: left,
                    rightURL: right,
                    options: FolderComparisonOptions(pathRules: rules)
                )
            }
            task.cancel()
            let publication = await task.value
            #expect(publication.visibleNodes.count == 1)
            #expect(publication.visibleNodes.first?.relativePath == ".")
            #expect(publication.visibleNodes.first?.status == .error)
            #expect(publication.operationSupportNodes.isEmpty)
        }
    }

    private func filter(
        includes: [String] = [],
        excludes: [String] = [],
        caseSensitive: Bool = true,
        limits: PathFilterLimits = .default
    ) throws -> PathFilter {
        try PathFilter(
            rules: FolderPathRules(
                includePatterns: includes,
                excludePatterns: excludes,
                isCaseSensitive: caseSensitive,
                limits: limits
            )
        )
    }

    private func limits(
        ruleCount: Int = 32,
        ruleBytes: Int = 64,
        totalBytes: Int = 256,
        pathBytes: Int = 256,
        matchWork: Int = 10_000
    ) throws -> PathFilterLimits {
        try PathFilterLimits(
            maximumRuleCount: ruleCount,
            maximumRuleUTF8ByteCount: ruleBytes,
            maximumTotalRuleUTF8ByteCount: totalBytes,
            maximumPathUTF8ByteCount: pathBytes,
            maximumMatchWork: matchWork
        )
    }

    private func requireSendable<T: Sendable>(_ value: T) {
        _ = value
    }

    private func withTemporaryFolderPair(
        _ operation: (URL, URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "RiffaPathFilterTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let left = root.appending(path: "left", directoryHint: .isDirectory)
        let right = root.appending(path: "right", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await operation(left, right)
    }

    private func write(_ value: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(value.utf8).write(to: url)
    }
}
