import Foundation

public struct FolderComparisonOptions: Hashable, Sendable {
    public let compareFileSize: Bool
    public let compareModificationDates: Bool
    public let modificationDateTolerance: TimeInterval
    public let compareFileContents: Bool
    public let followSymbolicLinks: Bool
    public let contentReadChunkSize: Int
    public let pathSemantics: PathSemantics
    public let limits: LocalResourceLimits
    public let pathRules: FolderPathRules

    public init(
        compareFileSize: Bool = true,
        compareModificationDates: Bool = true,
        modificationDateTolerance: TimeInterval = 1,
        compareFileContents: Bool = false,
        followSymbolicLinks: Bool = false,
        contentReadChunkSize: Int = 256 * 1_024,
        pathSemantics: PathSemantics = .macOSDefault,
        limits: LocalResourceLimits = .default,
        pathRules: FolderPathRules = .all
    ) {
        self.compareFileSize = compareFileSize
        self.compareModificationDates = compareModificationDates
        self.modificationDateTolerance = max(0, modificationDateTolerance)
        self.compareFileContents = compareFileContents
        self.followSymbolicLinks = followSymbolicLinks
        self.contentReadChunkSize = max(1, contentReadChunkSize)
        self.pathSemantics = pathSemantics
        self.limits = limits
        self.pathRules = pathRules
    }
}

/// The public rows from one folder scan plus the minimum non-public directory
/// context required to plan writes for those rows safely.
public struct FolderComparisonPublication: Hashable, Sendable {
    /// Rows that may be displayed, selected, reported, or passed to rename
    /// detection.
    public let visibleNodes: [PairNode]

    /// Non-public directory ancestors of visible rows. These nodes exist only
    /// so an operation planner can create or validate required parents. The
    /// array never contains a hidden file or hidden sibling and must never be
    /// displayed or made selectable.
    public let operationSupportNodes: [PairNode]

    fileprivate init(
        visibleNodes: [PairNode],
        operationSupportNodes: [PairNode] = []
    ) {
        self.visibleNodes = visibleNodes
        self.operationSupportNodes = operationSupportNodes
    }
}

/// Compares two local directory trees and returns one stable row per relative path.
public struct FolderComparison: Sendable {
    public init() {}

    public func compare(
        left: ResourceLocator,
        right: ResourceLocator,
        options: FolderComparisonOptions = .init()
    ) async -> [PairNode] {
        await comparePublication(left: left, right: right, options: options).visibleNodes
    }

    public func comparePublication(
        left: ResourceLocator,
        right: ResourceLocator,
        options: FolderComparisonOptions = .init()
    ) async -> FolderComparisonPublication {
        async let leftOutcome = enumerate(locator: left, options: options)
        async let rightOutcome = enumerate(locator: right, options: options)
        let outcomes = await (leftOutcome, rightOutcome)

        switch outcomes {
        case let (.success(leftEntries), .success(rightEntries)):
            let merged = merge(leftEntries, rightEntries, options: options)
            do {
                return try publication(merged, rules: options.pathRules)
            } catch let error as PathFilterError {
                return failurePublication(pathFilterErrorNode(error.localizedDescription))
            } catch is CancellationError {
                return failurePublication(
                    pathFilterErrorNode("Path filtering was cancelled safely.")
                )
            } catch {
                return failurePublication(pathFilterErrorNode("Path filtering failed safely."))
            }
        case let (.failure(leftIssue), .failure(rightIssue)):
            return failurePublication(
                PairNode(
                    relativePath: ".",
                    left: nil,
                    right: nil,
                    status: .error,
                    issues: [leftIssue, rightIssue]
                )
            )
        case let (.failure(issue), .success), let (.success, .failure(issue)):
            return failurePublication(
                PairNode(
                    relativePath: ".",
                    left: nil,
                    right: nil,
                    status: .error,
                    issues: [issue]
                )
            )
        }
    }

    public func compare(
        leftURL: URL,
        rightURL: URL,
        options: FolderComparisonOptions = .init()
    ) async -> [PairNode] {
        await compare(
            left: ResourceLocator(fileURL: leftURL),
            right: ResourceLocator(fileURL: rightURL),
            options: options
        )
    }

    public func comparePublication(
        leftURL: URL,
        rightURL: URL,
        options: FolderComparisonOptions = .init()
    ) async -> FolderComparisonPublication {
        await comparePublication(
            left: ResourceLocator(fileURL: leftURL),
            right: ResourceLocator(fileURL: rightURL),
            options: options
        )
    }

    private func enumerate(
        locator: ResourceLocator,
        options: FolderComparisonOptions
    ) async -> EnumerationOutcome {
        do {
            let entries = try await LocalResourceProvider(
                root: locator,
                pathSemantics: options.pathSemantics,
                limits: options.limits
            ).recursivelyEnumeratedEntries(followSymbolicLinks: options.followSymbolicLinks)
            return .success(entries)
        } catch let limitError as LocalResourceLimitError {
            return .failure(limitError.resourceIssue)
        } catch let issue as ResourceIssue {
            return .failure(issue)
        } catch {
            return .failure(ResourceIssue(path: locator.path, underlying: error))
        }
    }

    private func merge(
        _ leftEntries: [ResourceEntry],
        _ rightEntries: [ResourceEntry],
        options: FolderComparisonOptions
    ) -> [PairNode] {
        var leftIndex = 0
        var rightIndex = 0
        var result: [PairNode] = []

        while leftIndex < leftEntries.count || rightIndex < rightEntries.count {
            if leftIndex == leftEntries.count {
                let right = rightEntries[rightIndex]
                result.append(
                    PairNode(
                        relativePath: right.relativePath,
                        left: nil,
                        right: right,
                        status: right.issue == nil ? .rightOnly : .error,
                        issues: right.issue.map { [$0] } ?? []
                    )
                )
                rightIndex += 1
                continue
            }

            if rightIndex == rightEntries.count {
                let left = leftEntries[leftIndex]
                result.append(
                    PairNode(
                        relativePath: left.relativePath,
                        left: left,
                        right: nil,
                        status: left.issue == nil ? .leftOnly : .error,
                        issues: left.issue.map { [$0] } ?? []
                    )
                )
                leftIndex += 1
                continue
            }

            let left = leftEntries[leftIndex]
            let right = rightEntries[rightIndex]
            let leftKey = options.pathSemantics.comparisonKey(for: left.relativePath)
            let rightKey = options.pathSemantics.comparisonKey(for: right.relativePath)

            if leftKey == rightKey {
                result.append(comparePair(left: left, right: right, options: options))
                leftIndex += 1
                rightIndex += 1
            } else if leftKey < rightKey {
                result.append(
                    PairNode(
                        relativePath: left.relativePath,
                        left: left,
                        right: nil,
                        status: left.issue == nil ? .leftOnly : .error,
                        issues: left.issue.map { [$0] } ?? []
                    )
                )
                leftIndex += 1
            } else {
                result.append(
                    PairNode(
                        relativePath: right.relativePath,
                        left: nil,
                        right: right,
                        status: right.issue == nil ? .rightOnly : .error,
                        issues: right.issue.map { [$0] } ?? []
                    )
                )
                rightIndex += 1
            }
        }

        return result
    }

    private func comparePair(
        left: ResourceEntry,
        right: ResourceEntry,
        options: FolderComparisonOptions
    ) -> PairNode {
        let entryIssues = [left.issue, right.issue].compactMap { $0 }
        if !entryIssues.isEmpty {
            return PairNode(
                relativePath: left.relativePath,
                left: left,
                right: right,
                status: .error,
                issues: entryIssues
            )
        }

        guard left.kind == right.kind else {
            return PairNode(
                relativePath: left.relativePath,
                left: left,
                right: right,
                status: .typeMismatch
            )
        }

        switch left.kind {
        case .directory:
            return node(left: left, right: right, status: .same)

        case .symbolicLink:
            let destinationsMatch = left.symbolicLinkDestination == right.symbolicLinkDestination
            let metadataMatches = quickMetadataMatches(left: left, right: right, options: options)
            return node(
                left: left,
                right: right,
                status: destinationsMatch && metadataMatches ? .same : .different
            )

        case .file:
            var matches = quickMetadataMatches(left: left, right: right, options: options)
            if options.compareFileContents {
                switch compareContents(left: left, right: right, chunkSize: options.contentReadChunkSize) {
                case let .success(contentsMatch):
                    matches = matches && contentsMatch
                case let .failure(issue):
                    return PairNode(
                        relativePath: left.relativePath,
                        left: left,
                        right: right,
                        status: .error,
                        issues: [issue]
                    )
                }
            }
            return node(left: left, right: right, status: matches ? .same : .different)

        case .other:
            return node(
                left: left,
                right: right,
                status: quickMetadataMatches(left: left, right: right, options: options) ? .same : .different
            )

        case .inaccessible:
            return PairNode(
                relativePath: left.relativePath,
                left: left,
                right: right,
                status: .error,
                issues: entryIssues
            )
        }
    }

    private func quickMetadataMatches(
        left: ResourceEntry,
        right: ResourceEntry,
        options: FolderComparisonOptions
    ) -> Bool {
        if options.compareFileSize, left.byteCount != right.byteCount {
            return false
        }

        if options.compareModificationDates {
            switch (left.modificationDate, right.modificationDate) {
            case let (leftDate?, rightDate?):
                if abs(leftDate.timeIntervalSince(rightDate)) > options.modificationDateTolerance {
                    return false
                }
            case (nil, nil):
                break
            case (.some, nil), (nil, .some):
                return false
            }
        }
        return true
    }

    private func compareContents(
        left: ResourceEntry,
        right: ResourceEntry,
        chunkSize: Int
    ) -> Result<Bool, ResourceIssue> {
        do {
            return .success(
                try LocalFileByteComparator(chunkByteCount: chunkSize)
                    .compare(left, right)
            )
        } catch {
            return .failure(ResourceIssue(path: left.relativePath, underlying: error))
        }
    }

    private func node(left: ResourceEntry, right: ResourceEntry, status: PairNode.Status) -> PairNode {
        PairNode(
            relativePath: left.relativePath,
            left: left,
            right: right,
            status: status
        )
    }

    /// Filters only after both trees have been paired, so no one-sided path can
    /// be reclassified merely because its counterpart was hidden. A directory
    /// with any hidden descendant is also withheld: selecting a visible
    /// directory must never cause a copy/delete planner to operate on a hidden
    /// child through recursive filesystem semantics.
    private func publication(
        _ nodes: [PairNode],
        rules: FolderPathRules
    ) throws -> FolderComparisonPublication {
        guard rules.isEnabled else {
            return FolderComparisonPublication(visibleNodes: nodes)
        }

        var filter = try PathFilter(rules: rules)
        var visibility: [String: Bool] = [:]
        visibility.reserveCapacity(nodes.count)
        for node in nodes {
            try Task.checkCancellation()
            if node.relativePath == "." {
                visibility[node.relativePath] = true
            } else {
                visibility[node.relativePath] = try filter.includes(
                    relativePath: node.relativePath
                )
            }
        }

        var directoriesWithHiddenDescendants = Set<String>()
        for node in nodes where visibility[node.relativePath] == false {
            let components = node.relativePath.split(
                separator: "/",
                omittingEmptySubsequences: false
            )
            guard components.count > 1 else { continue }
            for count in 1..<components.count {
                directoriesWithHiddenDescendants.insert(
                    components.prefix(count).joined(separator: "/")
                )
            }
        }

        let visibleNodes = nodes.filter { node in
            guard node.relativePath == "." || visibility[node.relativePath] == true else {
                return false
            }
            let isDirectory = node.left?.kind == .directory
                || node.right?.kind == .directory
            return !isDirectory
                || !directoriesWithHiddenDescendants.contains(node.relativePath)
        }

        let visiblePaths = Set(visibleNodes.map(\.relativePath))
        var requiredParentPaths = Set<String>()
        for node in visibleNodes where node.relativePath != "." {
            let components = node.relativePath.split(
                separator: "/",
                omittingEmptySubsequences: false
            )
            guard components.count > 1 else { continue }
            for count in 1..<components.count {
                requiredParentPaths.insert(
                    components.prefix(count).joined(separator: "/")
                )
            }
        }

        let operationSupportNodes = nodes.filter { node in
            guard !visiblePaths.contains(node.relativePath),
                  requiredParentPaths.contains(node.relativePath) else {
                return false
            }
            return node.left?.kind == .directory || node.right?.kind == .directory
        }
        return FolderComparisonPublication(
            visibleNodes: visibleNodes,
            operationSupportNodes: operationSupportNodes
        )
    }

    private func failurePublication(_ node: PairNode) -> FolderComparisonPublication {
        FolderComparisonPublication(visibleNodes: [node])
    }

    private func pathFilterErrorNode(_ message: String) -> PairNode {
        PairNode(
            relativePath: ".",
            left: nil,
            right: nil,
            status: .error,
            issues: [
                ResourceIssue(
                    path: ".",
                    message: message,
                    domain: "RiffaCore.PathFilter",
                    code: 1
                )
            ]
        )
    }
}

private extension LocalResourceLimitError {
    var resourceIssue: ResourceIssue {
        let code: Int
        switch self {
        case .invalidMaximumEntryCount:
            code = 1
        case .invalidMaximumDepth:
            code = 2
        case .invalidMaximumRelativePathUTF8ByteCount:
            code = 3
        case .entryCountExceeded:
            code = 4
        case .depthExceeded:
            code = 5
        case .relativePathUTF8ByteCountExceeded:
            code = 6
        }
        return ResourceIssue(
            path: ".",
            message: errorDescription ?? "Local-resource enumeration exceeded a configured limit.",
            domain: "RiffaCore.LocalResourceLimit",
            code: code
        )
    }
}

private enum EnumerationOutcome: Sendable {
    case success([ResourceEntry])
    case failure(ResourceIssue)
}
