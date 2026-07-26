import Foundation

public struct FolderMergeOptions: Hashable, Sendable {
    public let contentReadChunkSize: Int
    public let pathSemantics: PathSemantics

    public init(
        contentReadChunkSize: Int = 256 * 1_024,
        pathSemantics: PathSemantics = .macOSDefault
    ) {
        self.contentReadChunkSize = max(1, contentReadChunkSize)
        self.pathSemantics = pathSemantics
    }
}

public enum FolderMergeStatus: String, CaseIterable, Hashable, Codable, Sendable {
    case unchanged
    case leftChanged
    case rightChanged
    case bothChangedSame
    case leftDeleted
    case rightDeleted
    case bothDeleted
    case conflict
    case typeConflict
    case error
}

public enum FolderMergeNodeKind: String, Hashable, Codable, Sendable {
    case file
    case directory
    case symbolicLink
    case other
    case mixed
    case error
}

/// One path aligned across the base, left, and right directory trees.
public struct FolderMergeNode: Identifiable, Hashable, Sendable {
    public var id: String { relativePath }

    public let relativePath: String
    public let kind: FolderMergeNodeKind
    public let base: ResourceEntry?
    public let left: ResourceEntry?
    public let right: ResourceEntry?
    public let status: FolderMergeStatus
    public let issues: [ResourceIssue]

    public init(
        relativePath: String,
        kind: FolderMergeNodeKind,
        base: ResourceEntry?,
        left: ResourceEntry?,
        right: ResourceEntry?,
        status: FolderMergeStatus,
        issues: [ResourceIssue] = []
    ) {
        self.relativePath = relativePath
        self.kind = kind
        self.base = base
        self.left = left
        self.right = right
        self.status = status
        self.issues = issues
    }
}

public enum FolderMergeSource: String, Hashable, Codable, Sendable {
    case base
    case left
    case right
}

/// One logical action whose destination is a caller-selected, independent output root.
public struct FolderMergeAction: Identifiable, Hashable, Sendable {
    public enum Kind: String, CaseIterable, Hashable, Codable, Sendable {
        case copyFromLeft
        case copyFromRight
        case copyFromBase
        case createDirectory
        case omit
        case conflict
    }

    public var id: String { "\(kind.rawValue)|\(outputRelativePath)" }

    public let kind: Kind
    public let outputRelativePath: String
    public let source: FolderMergeSource?
    public let sourceRelativePath: String?
    public let status: FolderMergeStatus
    public let reason: String

    public init(
        kind: Kind,
        outputRelativePath: String,
        source: FolderMergeSource? = nil,
        sourceRelativePath: String? = nil,
        status: FolderMergeStatus,
        reason: String
    ) {
        self.kind = kind
        self.outputRelativePath = outputRelativePath
        self.source = source
        self.sourceRelativePath = sourceRelativePath
        self.status = status
        self.reason = reason
    }
}

public struct FolderMergeSummary: Hashable, Sendable {
    public let totalCount: Int
    public let unchangedCount: Int
    public let automaticallyResolvedCount: Int
    public let deletionCount: Int
    public let conflictCount: Int
    public let errorCount: Int

    public var hasConflicts: Bool { conflictCount > 0 || errorCount > 0 }

    public init(nodes: [FolderMergeNode]) {
        totalCount = nodes.count
        unchangedCount = nodes.count { $0.status == .unchanged }
        automaticallyResolvedCount = nodes.count {
            switch $0.status {
            case .leftChanged, .rightChanged, .bothChangedSame:
                true
            case .unchanged, .leftDeleted, .rightDeleted, .bothDeleted,
                 .conflict, .typeConflict, .error:
                false
            }
        }
        deletionCount = nodes.count {
            $0.status == .leftDeleted || $0.status == .rightDeleted || $0.status == .bothDeleted
        }
        conflictCount = nodes.count { $0.status == .conflict || $0.status == .typeConflict }
        errorCount = nodes.count { $0.status == .error }
    }
}

/// A read-only plan. Every materializing action is relative to an independent output root;
/// the base, left, and right roots are never mutation targets.
public struct FolderMergePlan: Hashable, Sendable {
    public let actions: [FolderMergeAction]

    public init(actions: [FolderMergeAction]) {
        self.actions = actions
    }

    public var hasConflicts: Bool {
        actions.contains { $0.kind == .conflict }
    }
}

public struct FolderMergeResult: Hashable, Sendable {
    public let nodes: [FolderMergeNode]
    public let plan: FolderMergePlan
    public let summary: FolderMergeSummary

    public init(nodes: [FolderMergeNode], plan: FolderMergePlan) {
        self.nodes = nodes
        self.plan = plan
        summary = FolderMergeSummary(nodes: nodes)
    }
}

/// Performs a clean-room, read-only three-tree folder analysis.
public struct FolderMerge: Sendable {
    public init() {}

    public func analyze(
        baseURL: URL,
        leftURL: URL,
        rightURL: URL,
        options: FolderMergeOptions = .init()
    ) async -> FolderMergeResult {
        async let baseOutcome = enumerate(baseURL, options: options)
        async let leftOutcome = enumerate(leftURL, options: options)
        async let rightOutcome = enumerate(rightURL, options: options)
        let outcomes = await (baseOutcome, leftOutcome, rightOutcome)

        let rootIssues = [outcomes.0.issue, outcomes.1.issue, outcomes.2.issue].compactMap { $0 }
        guard rootIssues.isEmpty,
              let baseEntries = outcomes.0.entries,
              let leftEntries = outcomes.1.entries,
              let rightEntries = outcomes.2.entries else {
            let node = FolderMergeNode(
                relativePath: ".",
                kind: .error,
                base: nil,
                left: nil,
                right: nil,
                status: .error,
                issues: rootIssues
            )
            return FolderMergeResult(nodes: [node], plan: makePlan(nodes: [node]))
        }

        let snapshots = MergeSnapshots(
            base: TreeSnapshot(entries: baseEntries, pathSemantics: options.pathSemantics),
            left: TreeSnapshot(entries: leftEntries, pathSemantics: options.pathSemantics),
            right: TreeSnapshot(entries: rightEntries, pathSemantics: options.pathSemantics)
        )
        let keys = Set(snapshots.base.keys)
            .union(snapshots.left.keys)
            .union(snapshots.right.keys)
            .sorted()
        var comparator = SnapshotComparator(
            snapshots: snapshots,
            allKeys: keys,
            chunkSize: options.contentReadChunkSize
        )
        var nodes: [FolderMergeNode] = []
        nodes.reserveCapacity(keys.count)

        for key in keys {
            let base = snapshots.base.entry(for: key)
            let left = snapshots.left.entry(for: key)
            let right = snapshots.right.entry(for: key)
            let collisionIssues = snapshots.collisionIssues(for: key)
            let entryIssues = [base?.issue, left?.issue, right?.issue].compactMap { $0 }
            var issues = collisionIssues + entryIssues
            let relativePath = base?.relativePath
                ?? left?.relativePath
                ?? right?.relativePath
                ?? key
            let kind = nodeKind(base: base, left: left, right: right, hasIssues: !issues.isEmpty)
            let status: FolderMergeStatus

            if !issues.isEmpty || [base, left, right].compactMap({ $0 }).contains(where: { $0.kind == .inaccessible }) {
                status = .error
            } else if kindsConflict(base, left, right) {
                status = .typeConflict
            } else {
                do {
                    status = try classify(
                        key: key,
                        base: base,
                        left: left,
                        right: right,
                        comparator: &comparator
                    )
                } catch let issue as ResourceIssue {
                    status = .error
                    issues.append(issue)
                } catch {
                    status = .error
                    issues.append(ResourceIssue(path: relativePath, underlying: error))
                }
            }

            nodes.append(
                FolderMergeNode(
                    relativePath: relativePath,
                    kind: status == .error ? .error : kind,
                    base: base,
                    left: left,
                    right: right,
                    status: status,
                    issues: issues
                )
            )
        }

        return FolderMergeResult(nodes: nodes, plan: makePlan(nodes: nodes))
    }

    private func enumerate(_ rootURL: URL, options: FolderMergeOptions) async -> EnumerationOutcome {
        do {
            let entries = try await LocalResourceProvider(
                rootURL: rootURL,
                pathSemantics: options.pathSemantics
            ).recursivelyEnumeratedEntries(followSymbolicLinks: false)
            return EnumerationOutcome(entries: entries, issue: nil)
        } catch let issue as ResourceIssue {
            return EnumerationOutcome(entries: nil, issue: issue)
        } catch {
            return EnumerationOutcome(
                entries: nil,
                issue: ResourceIssue(path: rootURL.path, underlying: error)
            )
        }
    }

    private func classify(
        key: String,
        base: ResourceEntry?,
        left: ResourceEntry?,
        right: ResourceEntry?,
        comparator: inout SnapshotComparator
    ) throws -> FolderMergeStatus {
        switch (base, left, right) {
        case (_?, _?, _?):
            let leftMatchesBase = try comparator.equal(.base, .left, key: key)
            let rightMatchesBase = try comparator.equal(.base, .right, key: key)
            if leftMatchesBase, rightMatchesBase {
                return .unchanged
            }
            if !leftMatchesBase, rightMatchesBase {
                return .leftChanged
            }
            if leftMatchesBase, !rightMatchesBase {
                return .rightChanged
            }
            return try comparator.equal(.left, .right, key: key) ? .bothChangedSame : .conflict

        case (_?, _?, nil):
            return try comparator.equal(.base, .left, key: key) ? .rightDeleted : .conflict

        case (_?, nil, _?):
            return try comparator.equal(.base, .right, key: key) ? .leftDeleted : .conflict

        case (_?, nil, nil):
            return .bothDeleted

        case (nil, _?, nil):
            return .leftChanged

        case (nil, nil, _?):
            return .rightChanged

        case (nil, _?, _?):
            return try comparator.equal(.left, .right, key: key) ? .bothChangedSame : .conflict

        case (nil, nil, nil):
            return .error
        }
    }

    private func kindsConflict(
        _ base: ResourceEntry?,
        _ left: ResourceEntry?,
        _ right: ResourceEntry?
    ) -> Bool {
        Set([base?.kind, left?.kind, right?.kind].compactMap { $0 }).count > 1
    }

    private func nodeKind(
        base: ResourceEntry?,
        left: ResourceEntry?,
        right: ResourceEntry?,
        hasIssues: Bool
    ) -> FolderMergeNodeKind {
        if hasIssues { return .error }
        let kinds = Set([base?.kind, left?.kind, right?.kind].compactMap { $0 })
        guard kinds.count == 1, let kind = kinds.first else { return .mixed }
        switch kind {
        case .file:
            return .file
        case .directory:
            return .directory
        case .symbolicLink:
            return .symbolicLink
        case .other:
            return .other
        case .inaccessible:
            return .error
        }
    }

    private func makePlan(nodes: [FolderMergeNode]) -> FolderMergePlan {
        let actions = nodes.map(makeAction).sorted(by: actionComesBefore)
        return FolderMergePlan(actions: actions)
    }

    private func makeAction(for node: FolderMergeNode) -> FolderMergeAction {
        switch node.status {
        case .unchanged:
            return materialize(node: node, source: .base, entry: node.base)
        case .leftChanged, .bothChangedSame:
            return materialize(node: node, source: .left, entry: node.left)
        case .rightChanged:
            return materialize(node: node, source: .right, entry: node.right)
        case .leftDeleted, .rightDeleted, .bothDeleted:
            return FolderMergeAction(
                kind: .omit,
                outputRelativePath: node.relativePath,
                status: node.status,
                reason: "The accepted merge result omits this deleted path."
            )
        case .conflict:
            return FolderMergeAction(
                kind: .conflict,
                outputRelativePath: node.relativePath,
                status: node.status,
                reason: "The two variants cannot be reconciled automatically."
            )
        case .typeConflict:
            return FolderMergeAction(
                kind: .conflict,
                outputRelativePath: node.relativePath,
                status: node.status,
                reason: "The path has incompatible resource types."
            )
        case .error:
            return FolderMergeAction(
                kind: .conflict,
                outputRelativePath: node.relativePath,
                status: node.status,
                reason: "An access or comparison error prevents a safe plan."
            )
        }
    }

    private func materialize(
        node: FolderMergeNode,
        source: FolderMergeSource,
        entry: ResourceEntry?
    ) -> FolderMergeAction {
        guard let entry else {
            return FolderMergeAction(
                kind: .conflict,
                outputRelativePath: node.relativePath,
                status: .error,
                reason: "The selected merge source is missing."
            )
        }

        if entry.kind == .directory {
            return FolderMergeAction(
                kind: .createDirectory,
                outputRelativePath: node.relativePath,
                source: source,
                sourceRelativePath: entry.relativePath,
                status: node.status,
                reason: "Create this directory beneath the independent output root."
            )
        }

        let kind: FolderMergeAction.Kind
        switch source {
        case .base:
            kind = .copyFromBase
        case .left:
            kind = .copyFromLeft
        case .right:
            kind = .copyFromRight
        }
        return FolderMergeAction(
            kind: kind,
            outputRelativePath: node.relativePath,
            source: source,
            sourceRelativePath: entry.relativePath,
            status: node.status,
            reason: "Copy the selected resource beneath the independent output root."
        )
    }

    private func actionComesBefore(_ left: FolderMergeAction, _ right: FolderMergeAction) -> Bool {
        let leftPhase = actionPhase(left.kind)
        let rightPhase = actionPhase(right.kind)
        if leftPhase != rightPhase { return leftPhase < rightPhase }

        let leftDepth = left.outputRelativePath.split(separator: "/").count
        let rightDepth = right.outputRelativePath.split(separator: "/").count
        if left.kind == .createDirectory, leftDepth != rightDepth {
            return leftDepth < rightDepth
        }
        if left.outputRelativePath != right.outputRelativePath {
            return left.outputRelativePath < right.outputRelativePath
        }
        return left.kind.rawValue < right.kind.rawValue
    }

    private func actionPhase(_ kind: FolderMergeAction.Kind) -> Int {
        switch kind {
        case .createDirectory:
            0
        case .copyFromLeft, .copyFromRight, .copyFromBase:
            1
        case .omit:
            2
        case .conflict:
            3
        }
    }
}

private struct EnumerationOutcome: Sendable {
    let entries: [ResourceEntry]?
    let issue: ResourceIssue?
}

private enum MergeTree: Int, Hashable {
    case base
    case left
    case right
}

private struct TreeSnapshot {
    let entriesByKey: [String: [ResourceEntry]]

    init(entries: [ResourceEntry], pathSemantics: PathSemantics) {
        entriesByKey = Dictionary(grouping: entries) {
            pathSemantics.comparisonKey(for: $0.relativePath)
        }
    }

    var keys: Dictionary<String, [ResourceEntry]>.Keys { entriesByKey.keys }

    func entry(for key: String) -> ResourceEntry? {
        entriesByKey[key]?.first
    }

    func collisionIssue(for key: String) -> ResourceIssue? {
        guard let entries = entriesByKey[key], entries.count > 1 else { return nil }
        return ResourceIssue(
            path: entries.map(\.relativePath).joined(separator: ", "),
            message: "Multiple paths normalize to the same comparison key"
        )
    }
}

private struct MergeSnapshots {
    let base: TreeSnapshot
    let left: TreeSnapshot
    let right: TreeSnapshot

    func snapshot(for tree: MergeTree) -> TreeSnapshot {
        switch tree {
        case .base:
            base
        case .left:
            left
        case .right:
            right
        }
    }

    func collisionIssues(for key: String) -> [ResourceIssue] {
        [base.collisionIssue(for: key), left.collisionIssue(for: key), right.collisionIssue(for: key)]
            .compactMap { $0 }
    }
}

private struct EqualityCacheKey: Hashable {
    let first: MergeTree
    let second: MergeTree
    let pathKey: String

    init(_ first: MergeTree, _ second: MergeTree, pathKey: String) {
        if first.rawValue <= second.rawValue {
            self.first = first
            self.second = second
        } else {
            self.first = second
            self.second = first
        }
        self.pathKey = pathKey
    }
}

private struct SnapshotComparator {
    let snapshots: MergeSnapshots
    let allKeys: [String]
    let chunkSize: Int
    var cache: [EqualityCacheKey: Result<Bool, ResourceIssue>] = [:]

    mutating func equal(_ first: MergeTree, _ second: MergeTree, key: String) throws -> Bool {
        let cacheKey = EqualityCacheKey(first, second, pathKey: key)
        if let cached = cache[cacheKey] {
            return try cached.get()
        }

        let result: Result<Bool, ResourceIssue>
        do {
            let firstSnapshot = snapshots.snapshot(for: first)
            let secondSnapshot = snapshots.snapshot(for: second)
            if firstSnapshot.collisionIssue(for: key) != nil ||
                secondSnapshot.collisionIssue(for: key) != nil {
                throw ResourceIssue(
                    path: key,
                    message: "A normalized path collision prevents resource comparison"
                )
            }
            guard let firstEntry = firstSnapshot.entry(for: key),
                  let secondEntry = secondSnapshot.entry(for: key) else {
                result = .success(false)
                cache[cacheKey] = result
                return false
            }
            result = .success(
                try compareEntries(
                    firstEntry,
                    secondEntry,
                    firstTree: first,
                    secondTree: second,
                    key: key
                )
            )
        } catch let issue as ResourceIssue {
            result = .failure(issue)
        } catch {
            result = .failure(ResourceIssue(path: key, underlying: error))
        }
        cache[cacheKey] = result
        return try result.get()
    }

    private mutating func compareEntries(
        _ first: ResourceEntry,
        _ second: ResourceEntry,
        firstTree: MergeTree,
        secondTree: MergeTree,
        key: String
    ) throws -> Bool {
        if let issue = first.issue ?? second.issue { throw issue }
        guard first.kind == second.kind else { return false }

        switch first.kind {
        case .file:
            return try compareFiles(first, second)

        case .symbolicLink:
            return first.symbolicLinkDestination == second.symbolicLinkDestination

        case .directory:
            let firstSnapshot = snapshots.snapshot(for: firstTree)
            let secondSnapshot = snapshots.snapshot(for: secondTree)
            for childKey in allKeys where isImmediateChild(childKey, of: key) {
                let firstChild = firstSnapshot.entry(for: childKey)
                let secondChild = secondSnapshot.entry(for: childKey)
                switch (firstChild, secondChild) {
                case (nil, nil):
                    continue
                case (.some, nil), (nil, .some):
                    return false
                case (.some, .some):
                    if try !equal(firstTree, secondTree, key: childKey) { return false }
                }
            }
            return true

        case .other:
            return metadataEqual(first, second)

        case .inaccessible:
            throw first.issue
                ?? second.issue
                ?? ResourceIssue(path: key, message: "Inaccessible resource")
        }
    }

    private func compareFiles(_ first: ResourceEntry, _ second: ResourceEntry) throws -> Bool {
        do {
            return try LocalFileByteComparator(chunkByteCount: chunkSize)
                .compare(first, second)
        } catch {
            throw ResourceIssue(path: first.relativePath, underlying: error)
        }
    }

    private func metadataEqual(_ first: ResourceEntry, _ second: ResourceEntry) -> Bool {
        first.byteCount == second.byteCount &&
            first.permissions == second.permissions &&
            first.modificationDate == second.modificationDate
    }

    private func isImmediateChild(_ candidate: String, of parent: String) -> Bool {
        let prefix = parent + "/"
        guard candidate.hasPrefix(prefix) else { return false }
        return !candidate.dropFirst(prefix.count).contains("/")
    }
}
