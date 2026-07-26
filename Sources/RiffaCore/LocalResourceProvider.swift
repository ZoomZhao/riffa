import Darwin
import Foundation

/// Resource ceilings applied while recursively enumerating a local directory.
///
/// The root itself is not an entry and is therefore not included in
/// `maximumEntryCount` or `maximumDepth`. A direct child has depth one.
public struct LocalResourceLimits: Hashable, Codable, Sendable {
    public static let `default` = Self(
        validatedMaximumEntryCount: 500_000,
        maximumDepth: 256,
        maximumRelativePathUTF8ByteCount: 16 * 1_024
    )

    public let maximumEntryCount: Int
    public let maximumDepth: Int
    public let maximumRelativePathUTF8ByteCount: Int

    /// Creates the documented default limits.
    public init() {
        self = .default
    }

    /// Creates validated limits. Invalid values are rejected instead of being
    /// silently clamped to a different policy.
    public init(
        maximumEntryCount: Int,
        maximumDepth: Int,
        maximumRelativePathUTF8ByteCount: Int
    ) throws {
        guard maximumEntryCount > 0 else {
            throw LocalResourceLimitError.invalidMaximumEntryCount(actual: maximumEntryCount)
        }
        guard maximumDepth >= 0 else {
            throw LocalResourceLimitError.invalidMaximumDepth(actual: maximumDepth)
        }
        guard maximumRelativePathUTF8ByteCount > 0 else {
            throw LocalResourceLimitError.invalidMaximumRelativePathUTF8ByteCount(
                actual: maximumRelativePathUTF8ByteCount
            )
        }
        self.init(
            validatedMaximumEntryCount: maximumEntryCount,
            maximumDepth: maximumDepth,
            maximumRelativePathUTF8ByteCount: maximumRelativePathUTF8ByteCount
        )
    }

    private init(
        validatedMaximumEntryCount: Int,
        maximumDepth: Int,
        maximumRelativePathUTF8ByteCount: Int
    ) {
        maximumEntryCount = validatedMaximumEntryCount
        self.maximumDepth = maximumDepth
        self.maximumRelativePathUTF8ByteCount = maximumRelativePathUTF8ByteCount
    }

    private enum CodingKeys: String, CodingKey {
        case maximumEntryCount
        case maximumDepth
        case maximumRelativePathUTF8ByteCount
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            maximumEntryCount: container.decode(Int.self, forKey: .maximumEntryCount),
            maximumDepth: container.decode(Int.self, forKey: .maximumDepth),
            maximumRelativePathUTF8ByteCount: container.decode(
                Int.self,
                forKey: .maximumRelativePathUTF8ByteCount
            )
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(maximumEntryCount, forKey: .maximumEntryCount)
        try container.encode(maximumDepth, forKey: .maximumDepth)
        try container.encode(
            maximumRelativePathUTF8ByteCount,
            forKey: .maximumRelativePathUTF8ByteCount
        )
    }
}

/// Structured, path-free failures raised by local directory ceilings.
public enum LocalResourceLimitError: Error, Hashable, Codable, Sendable {
    case invalidMaximumEntryCount(actual: Int)
    case invalidMaximumDepth(actual: Int)
    case invalidMaximumRelativePathUTF8ByteCount(actual: Int)
    case entryCountExceeded(limit: Int)
    case depthExceeded(actual: Int, limit: Int)
    case relativePathUTF8ByteCountExceeded(actual: Int, limit: Int)
}

extension LocalResourceLimitError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidMaximumEntryCount(actual):
            "The maximum local-resource entry count must be positive (received \(actual))."
        case let .invalidMaximumDepth(actual):
            "The maximum local-resource depth cannot be negative (received \(actual))."
        case let .invalidMaximumRelativePathUTF8ByteCount(actual):
            "The maximum relative-path UTF-8 byte count must be positive (received \(actual))."
        case let .entryCountExceeded(limit):
            "Local-resource enumeration exceeded the \(limit)-entry limit."
        case let .depthExceeded(actual, limit):
            "Local-resource enumeration reached depth \(actual), exceeding the depth limit of \(limit)."
        case let .relativePathUTF8ByteCountExceeded(actual, limit):
            "A local-resource relative path contains \(actual) UTF-8 bytes, exceeding the \(limit)-byte limit."
        }
    }
}

/// Recursively exposes a local directory as provider-neutral resource entries.
public struct LocalResourceProvider: Sendable {
    public let root: ResourceLocator
    public let pathSemantics: PathSemantics
    public let limits: LocalResourceLimits

    public let capabilities: ResourceCapabilities = [
        .enumerate,
        .recursiveEnumeration,
        .read,
        .readMetadata,
        .symbolicLinks,
    ]

    public init(
        root: ResourceLocator,
        pathSemantics: PathSemantics = .macOSDefault,
        limits: LocalResourceLimits = .default
    ) {
        self.root = root
        self.pathSemantics = pathSemantics
        self.limits = limits
    }

    public init(
        rootURL: URL,
        pathSemantics: PathSemantics = .macOSDefault,
        limits: LocalResourceLimits = .default
    ) {
        self.init(
            root: ResourceLocator(fileURL: rootURL),
            pathSemantics: pathSemantics,
            limits: limits
        )
    }

    /// Enumerates every item below the root. The root itself is not returned.
    ///
    /// Symbolic links are entries in their own right. They are not traversed unless
    /// `followSymbolicLinks` is explicitly enabled.
    public func recursivelyEnumeratedEntries(
        followSymbolicLinks: Bool = false
    ) async throws -> [ResourceEntry] {
        guard let rootURL = root.localFileURL else {
            throw ResourceIssue(
                path: root.path,
                message: "LocalResourceProvider requires a local resource locator"
            )
        }

        let rootMetadata: EntryMetadata
        do {
            rootMetadata = try Self.metadata(for: rootURL, relativePath: "")
        } catch let issue as ResourceIssue {
            throw Self.relativeIssue(issue, path: ".")
        }
        guard rootMetadata.entry.kind == .directory else {
            throw ResourceIssue(path: ".", message: "Expected a directory")
        }

        var entries: [ResourceEntry]
        if followSymbolicLinks {
            var activeDirectories: Set<FileIdentity> = [rootMetadata.identity]
            var state = EnumerationLimitState(limits: limits)
            entries = try enumerateDirectoryFollowingSymbolicLinks(
                at: rootURL,
                relativePrefix: "",
                activeDirectories: &activeDirectories,
                state: &state
            )
        } else {
            entries = try streamDirectoryTree(at: rootURL)
        }

        entries.sort { lhs, rhs in
            let leftKey = pathSemantics.comparisonKey(for: lhs.relativePath)
            let rightKey = pathSemantics.comparisonKey(for: rhs.relativePath)
            if leftKey != rightKey {
                return leftKey < rightKey
            }
            return lhs.relativePath < rhs.relativePath
        }
        return entries
    }

    /// `FileManager.DirectoryEnumerator` is intentionally used for the default
    /// no-follow mode so a single wide directory is not materialized before its
    /// first entry can be checked against the aggregate ceilings.
    private func streamDirectoryTree(at rootURL: URL) throws -> [ResourceEntry] {
        var traversalIssues: [String: ResourceIssue] = [:]
        var rootTraversalIssue: ResourceIssue?
        let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { failedURL, error in
                if let relativePath = Self.relativePath(of: failedURL, below: rootURL),
                   !relativePath.isEmpty
                {
                    traversalIssues[relativePath] = ResourceIssue(
                        path: relativePath,
                        underlying: error
                    )
                } else {
                    rootTraversalIssue = ResourceIssue(path: ".", underlying: error)
                }
                return true
            }
        )

        guard let enumerator else {
            throw ResourceIssue(path: ".", message: "Unable to enumerate the directory")
        }

        var state = EnumerationLimitState(limits: limits)
        var entries: [ResourceEntry] = []
        while let object = enumerator.nextObject() {
            guard let childURL = object as? URL,
                  let relativePath = Self.relativePath(of: childURL, below: rootURL),
                  !relativePath.isEmpty else {
                throw ResourceIssue(
                    path: ".",
                    message: "Directory enumeration returned an item outside its root"
                )
            }

            try state.observe(relativePath: relativePath)
            do {
                entries.append(try Self.metadata(for: childURL, relativePath: relativePath).entry)
            } catch let issue as ResourceIssue {
                entries.append(
                    ResourceEntry(
                        locator: ResourceLocator(fileURL: childURL),
                        relativePath: relativePath,
                        kind: .inaccessible,
                        issue: Self.relativeIssue(issue, path: relativePath)
                    )
                )
            }
        }

        if let rootTraversalIssue {
            throw rootTraversalIssue
        }

        if !traversalIssues.isEmpty {
            var indexByRelativePath = Dictionary(
                uniqueKeysWithValues: entries.indices.map { (entries[$0].relativePath, $0) }
            )
            let issuePaths = traversalIssues.keys.sorted { lhs, rhs in
                let leftKey = pathSemantics.comparisonKey(for: lhs)
                let rightKey = pathSemantics.comparisonKey(for: rhs)
                return leftKey == rightKey ? lhs < rhs : leftKey < rightKey
            }
            for relativePath in issuePaths {
                guard let issue = traversalIssues[relativePath] else { continue }
                if let index = indexByRelativePath[relativePath] {
                    entries[index] = entries[index].recording(issue: issue)
                } else {
                    try state.observe(relativePath: relativePath)
                    entries.append(
                        ResourceEntry(
                            locator: ResourceLocator(
                                fileURL: rootURL.appending(path: relativePath)
                            ),
                            relativePath: relativePath,
                            kind: .inaccessible,
                            issue: issue
                        )
                    )
                    indexByRelativePath[relativePath] = entries.endIndex - 1
                }
            }
        }
        return entries
    }

    /// Explicit recursion is reserved for opt-in symbolic-link traversal. It
    /// shares the exact same aggregate limit state as the streaming path.
    private func enumerateDirectoryFollowingSymbolicLinks(
        at directoryURL: URL,
        relativePrefix: String,
        activeDirectories: inout Set<FileIdentity>,
        state: inout EnumerationLimitState
    ) throws -> [ResourceEntry] {
        let childURLs: [URL]
        do {
            childURLs = try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: []
            )
        } catch {
            throw ResourceIssue(
                path: relativePrefix.isEmpty ? "." : relativePrefix,
                underlying: error
            )
        }

        let sortedChildren = childURLs.sorted { lhs, rhs in
            let leftKey = pathSemantics.comparisonKey(for: lhs.lastPathComponent)
            let rightKey = pathSemantics.comparisonKey(for: rhs.lastPathComponent)
            if leftKey != rightKey {
                return leftKey < rightKey
            }
            return lhs.lastPathComponent < rhs.lastPathComponent
        }

        var result: [ResourceEntry] = []
        for childURL in sortedChildren {
            let relativePath = relativePrefix.isEmpty
                ? childURL.lastPathComponent
                : relativePrefix + "/" + childURL.lastPathComponent
            try state.observe(relativePath: relativePath)

            let metadata: EntryMetadata
            do {
                metadata = try Self.metadata(for: childURL, relativePath: relativePath)
            } catch let issue as ResourceIssue {
                result.append(
                    ResourceEntry(
                        locator: ResourceLocator(fileURL: childURL),
                        relativePath: relativePath,
                        kind: .inaccessible,
                        issue: Self.relativeIssue(issue, path: relativePath)
                    )
                )
                continue
            }

            var entry = metadata.entry
            switch entry.kind {
            case .directory:
                if activeDirectories.contains(metadata.identity) {
                    entry = entry.recording(issue: Self.directoryCycleIssue(path: relativePath))
                } else {
                    activeDirectories.insert(metadata.identity)
                    do {
                        result += try enumerateDirectoryFollowingSymbolicLinks(
                            at: childURL,
                            relativePrefix: relativePath,
                            activeDirectories: &activeDirectories,
                            state: &state
                        )
                    } catch let issue as ResourceIssue {
                        entry = entry.recording(issue: Self.relativeIssue(issue, path: relativePath))
                    } catch {
                        activeDirectories.remove(metadata.identity)
                        throw error
                    }
                    activeDirectories.remove(metadata.identity)
                }

            case .symbolicLink:
                do {
                    if let followedDirectory = try Self.followedDirectory(for: childURL) {
                        guard !activeDirectories.contains(followedDirectory.identity) else {
                            entry = entry.recording(
                                issue: Self.directoryCycleIssue(path: relativePath)
                            )
                            result.append(entry)
                            continue
                        }
                        activeDirectories.insert(followedDirectory.identity)
                        do {
                            result += try enumerateDirectoryFollowingSymbolicLinks(
                                at: followedDirectory.url,
                                relativePrefix: relativePath,
                                activeDirectories: &activeDirectories,
                                state: &state
                            )
                        } catch let issue as ResourceIssue {
                            entry = entry.recording(
                                issue: Self.relativeIssue(issue, path: relativePath)
                            )
                        } catch {
                            activeDirectories.remove(followedDirectory.identity)
                            throw error
                        }
                        activeDirectories.remove(followedDirectory.identity)
                    }
                } catch let issue as ResourceIssue {
                    entry = entry.recording(issue: Self.relativeIssue(issue, path: relativePath))
                }

            case .file, .other, .inaccessible:
                break
            }

            result.append(entry)
        }
        return result
    }

    private static func relativePath(of childURL: URL, below rootURL: URL) -> String? {
        // `standardizedFileURL` may resolve the final symbolic-link component.
        // A loop such as `link -> .` would then collapse to the root and look
        // like an out-of-tree enumeration result. DirectoryEnumerator already
        // supplies absolute descendants, so compare lexical paths and let
        // `lstat` classify the final component without following it.
        // Canonicalize the containing directories so aliases such as `/var`
        // and `/private/var` compare consistently, but never canonicalize the
        // child's final component: doing that would follow the very symlink we
        // are trying to enumerate as a link.
        var rootPath = rootURL.resolvingSymlinksInPath().path
        while rootPath.count > 1, rootPath.hasSuffix("/") {
            rootPath.removeLast()
        }
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        let childPath = childURL
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .appending(path: childURL.lastPathComponent)
            .path
        guard childPath.hasPrefix(prefix) else {
            return nil
        }
        let relativePath = String(childPath.dropFirst(prefix.count))
        return relativePath.isEmpty ? nil : relativePath
    }

    private static func relativeIssue(_ issue: ResourceIssue, path: String) -> ResourceIssue {
        ResourceIssue(
            path: path,
            message: issue.message,
            domain: issue.domain,
            code: issue.code
        )
    }

    private static func directoryCycleIssue(path: String) -> ResourceIssue {
        ResourceIssue(
            path: path,
            message: "Symbolic-link traversal stopped before revisiting an active directory",
            domain: "RiffaCore.LocalResourceProvider",
            code: 1
        )
    }

    private static func metadata(for url: URL, relativePath: String) throws -> EntryMetadata {
        var fileStat = stat()
        let status = url.path.withCString { path in
            Darwin.lstat(path, &fileStat)
        }
        guard status == 0 else {
            let errorCode = errno
            throw posixIssue(path: url.path, code: errorCode)
        }

        let kind: ResourceEntry.Kind
        switch fileStat.st_mode & S_IFMT {
        case S_IFREG:
            kind = .file
        case S_IFDIR:
            kind = .directory
        case S_IFLNK:
            kind = .symbolicLink
        default:
            kind = .other
        }

        let destination: String?
        if kind == .symbolicLink {
            do {
                destination = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
            } catch {
                throw ResourceIssue(path: url.path, underlying: error)
            }
        } else {
            destination = nil
        }

        let seconds = TimeInterval(fileStat.st_mtimespec.tv_sec)
        let nanoseconds = TimeInterval(fileStat.st_mtimespec.tv_nsec) / 1_000_000_000
        let identity = FileIdentity(
            device: UInt64(bitPattern: Int64(fileStat.st_dev)),
            inode: UInt64(fileStat.st_ino)
        )

        return EntryMetadata(
            entry: ResourceEntry(
                locator: ResourceLocator(fileURL: url),
                relativePath: relativePath,
                kind: kind,
                byteCount: kind == .file || kind == .symbolicLink ? Int64(fileStat.st_size) : nil,
                modificationDate: Date(timeIntervalSince1970: seconds + nanoseconds),
                permissions: UInt16(fileStat.st_mode & 0o7777),
                fileIdentifier: "\(identity.device):\(identity.inode)",
                symbolicLinkDestination: destination
            ),
            identity: identity
        )
    }

    private static func followedDirectory(for url: URL) throws -> FollowedDirectory? {
        let resolvedURL = url.resolvingSymlinksInPath()
        let metadata = try metadata(for: resolvedURL, relativePath: "")
        guard metadata.entry.kind == .directory else { return nil }
        return FollowedDirectory(url: resolvedURL, identity: metadata.identity)
    }

    private static func posixIssue(path: String, code: Int32) -> ResourceIssue {
        ResourceIssue(
            path: path,
            message: String(cString: strerror(code)),
            domain: NSPOSIXErrorDomain,
            code: Int(code)
        )
    }
}

private struct FileIdentity: Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
}

private struct EntryMetadata: Sendable {
    let entry: ResourceEntry
    let identity: FileIdentity
}

private struct FollowedDirectory: Sendable {
    let url: URL
    let identity: FileIdentity
}

private struct EnumerationLimitState {
    let limits: LocalResourceLimits
    private(set) var entryCount = 0

    mutating func observe(relativePath: String) throws {
        let depth = relativePath.reduce(into: 1) { depth, character in
            if character == "/" {
                depth += 1
            }
        }
        guard depth <= limits.maximumDepth else {
            throw LocalResourceLimitError.depthExceeded(
                actual: depth,
                limit: limits.maximumDepth
            )
        }

        let byteCount = relativePath.utf8.count
        guard byteCount <= limits.maximumRelativePathUTF8ByteCount else {
            throw LocalResourceLimitError.relativePathUTF8ByteCountExceeded(
                actual: byteCount,
                limit: limits.maximumRelativePathUTF8ByteCount
            )
        }

        guard entryCount < limits.maximumEntryCount else {
            throw LocalResourceLimitError.entryCountExceeded(
                limit: limits.maximumEntryCount
            )
        }
        entryCount += 1
    }
}
