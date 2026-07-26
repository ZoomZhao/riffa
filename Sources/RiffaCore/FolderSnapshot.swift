import CryptoKit
import Darwin
import Foundation

/// A portable description of one item below a snapshotted folder.
///
/// The source root is deliberately not part of this model. File contents are
/// represented only by a SHA-256 digest and are never embedded in a snapshot.
public struct FolderSnapshotEntry: Equatable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case file
        case directory
        case symbolicLink
        case other
    }

    public let relativePath: String
    public let kind: Kind
    public let byteCount: UInt64
    public let modificationTimeNanoseconds: Int64
    public let posixPermissions: UInt16
    public let symbolicLinkTarget: String?
    public let sha256: String?

    public init(
        relativePath: String,
        kind: Kind,
        byteCount: UInt64,
        modificationTimeNanoseconds: Int64,
        posixPermissions: UInt16,
        symbolicLinkTarget: String? = nil,
        sha256: String? = nil
    ) {
        self.relativePath = relativePath
        self.kind = kind
        self.byteCount = byteCount
        self.modificationTimeNanoseconds = modificationTimeNanoseconds
        self.posixPermissions = posixPermissions
        self.symbolicLinkTarget = symbolicLinkTarget
        self.sha256 = sha256
    }
}

/// A structured, path-safe problem found while taking a snapshot.
///
/// Problems intentionally contain only relative paths, a stable kind, and an
/// optional numeric system error code. Localized system messages can contain
/// absolute paths, so they are not persisted.
public struct FolderSnapshotIssue: Equatable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case caseCollision
        case unicodeCollision
        case metadataUnavailable
        case directoryUnreadable
        case symbolicLinkTargetUnavailable
        case contentUnreadable
        case fileChangedDuringCapture
        case invalidSnapshot
    }

    public let kind: Kind
    public let relativePaths: [String]
    public let systemErrorCode: Int?

    public init(
        kind: Kind,
        relativePaths: [String],
        systemErrorCode: Int? = nil
    ) {
        self.kind = kind
        self.relativePaths = relativePaths
        self.systemErrorCode = systemErrorCode
    }
}

public struct FolderSnapshot: Equatable, Codable, Sendable {
    public let entries: [FolderSnapshotEntry]
    public let issues: [FolderSnapshotIssue]

    public init(
        entries: [FolderSnapshotEntry],
        issues: [FolderSnapshotIssue] = []
    ) {
        self.entries = entries
        self.issues = issues
    }

    public static let empty = FolderSnapshot(entries: [])
}

/// Versioned on-disk envelope. Older and newer schemas are explicitly rejected
/// until a migration is implemented.
public struct FolderSnapshotEnvelope: Equatable, Codable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let snapshot: FolderSnapshot

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        snapshot: FolderSnapshot
    ) {
        self.schemaVersion = schemaVersion
        self.snapshot = snapshot
    }
}

public struct FolderSnapshotCaptureOptions: Equatable, Codable, Sendable {
    /// The root itself is not an entry, so zero permits only an empty folder.
    public var maximumEntryCount: Int
    /// Maximum aggregate bytes read while hashing regular files.
    public var maximumByteCount: UInt64
    public var hashChunkSize: Int
    /// The root is depth zero and its direct children are depth one.
    /// An empty directory at this depth is allowed; encountering a descendant
    /// below it fails the capture rather than silently truncating the snapshot.
    public var maximumDepth: Int
    /// Maximum UTF-8 byte count of one root-relative path.
    public var maximumRelativePathUTF8ByteCount: Int

    public init(
        maximumEntryCount: Int = 1_000_000,
        maximumByteCount: UInt64 = 1 << 40,
        hashChunkSize: Int = 256 * 1_024,
        maximumDepth: Int = 512,
        maximumRelativePathUTF8ByteCount: Int = 64 * 1_024
    ) {
        // Preserve the established normalization behavior for the original
        // options. New signed limits are stored exactly and validated before
        // capture so mutation cannot bypass validation.
        self.maximumEntryCount = max(0, maximumEntryCount)
        self.maximumByteCount = maximumByteCount
        self.hashChunkSize = max(1, hashChunkSize)
        self.maximumDepth = maximumDepth
        self.maximumRelativePathUTF8ByteCount = maximumRelativePathUTF8ByteCount
    }

    private enum CodingKeys: String, CodingKey {
        case maximumEntryCount
        case maximumByteCount
        case hashChunkSize
        case maximumDepth
        case maximumRelativePathUTF8ByteCount
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let maximumEntryCount = try values.decode(Int.self, forKey: .maximumEntryCount)
        let maximumByteCount = try values.decode(UInt64.self, forKey: .maximumByteCount)
        let hashChunkSize = try values.decode(Int.self, forKey: .hashChunkSize)
        let maximumDepth = try values.decodeIfPresent(Int.self, forKey: .maximumDepth) ?? 512
        let maximumRelativePathUTF8ByteCount = try values.decodeIfPresent(
            Int.self,
            forKey: .maximumRelativePathUTF8ByteCount
        ) ?? 64 * 1_024

        guard maximumDepth >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .maximumDepth,
                in: values,
                debugDescription: "maximumDepth must be nonnegative"
            )
        }
        guard maximumRelativePathUTF8ByteCount >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .maximumRelativePathUTF8ByteCount,
                in: values,
                debugDescription: "maximumRelativePathUTF8ByteCount must be nonnegative"
            )
        }

        self.init(
            maximumEntryCount: maximumEntryCount,
            maximumByteCount: maximumByteCount,
            hashChunkSize: hashChunkSize,
            maximumDepth: maximumDepth,
            maximumRelativePathUTF8ByteCount: maximumRelativePathUTF8ByteCount
        )
    }
}

public enum FolderSnapshotIOOperation: String, Equatable, Codable, Sendable {
    case read
    case encode
    case write
    case createDirectory
}

public enum FolderSnapshotError: Error, Equatable, Sendable {
    case nonFileURL
    case rootUnavailable(systemErrorCode: Int)
    case rootIsNotDirectory
    case invalidCaptureOptions(reason: FolderSnapshotCaptureOptionValidationFailure)
    case entryLimitExceeded(limit: Int)
    case depthLimitExceeded(limit: Int, attempted: Int)
    case relativePathByteLimitExceeded(limit: Int, attempted: Int)
    case byteLimitExceeded(limit: UInt64, attempted: UInt64)
    case corruptedJSON
    case futureSchemaVersion(found: Int, supported: Int)
    case migrationRequired(found: Int, current: Int)
    case invalidSnapshot(reason: FolderSnapshotValidationFailure)
    case ioFailure(operation: FolderSnapshotIOOperation)
}

public enum FolderSnapshotCaptureOptionValidationFailure: Equatable, Sendable {
    case negativeMaximumDepth
    case negativeMaximumRelativePathUTF8ByteCount
}

public enum FolderSnapshotValidationFailure: Equatable, Sendable {
    case unsafeRelativePath(String)
    case duplicateRelativePath(String)
    case invalidDigest(String)
    case invalidSymbolicLinkTarget(String)
    case inconsistentEntry(String)
    case unsafeIssuePath(String)
}

/// Captures local folders without following symbolic links.
public struct FolderSnapshotCapture: Sendable {
    public init() {}

    public func capture(
        folderAt rootURL: URL,
        options: FolderSnapshotCaptureOptions = .init()
    ) async throws -> FolderSnapshot {
        guard rootURL.isFileURL else {
            throw FolderSnapshotError.nonFileURL
        }
        guard options.maximumDepth >= 0 else {
            throw FolderSnapshotError.invalidCaptureOptions(
                reason: .negativeMaximumDepth
            )
        }
        guard options.maximumRelativePathUTF8ByteCount >= 0 else {
            throw FolderSnapshotError.invalidCaptureOptions(
                reason: .negativeMaximumRelativePathUTF8ByteCount
            )
        }
        try Task.checkCancellation()

        let rootURL = rootURL.standardizedFileURL
        let rootMetadata: SnapshotFileMetadata
        do {
            rootMetadata = try Self.metadata(at: rootURL)
        } catch let failure as SnapshotPOSIXFailure {
            throw FolderSnapshotError.rootUnavailable(systemErrorCode: failure.code)
        }
        guard rootMetadata.kind == .directory else {
            throw FolderSnapshotError.rootIsNotDirectory
        }

        var state = CaptureState()
        try enumerateDirectory(rootURL, options: options, state: &state)
        state.issues.append(contentsOf: Self.detectPathCollisions(in: state.paths))

        return Self.normalized(
            FolderSnapshot(entries: state.entries, issues: state.issues)
        )
    }

    private func enumerateDirectory(
        _ rootURL: URL,
        options: FolderSnapshotCaptureOptions,
        state: inout CaptureState
    ) throws {
        try Task.checkCancellation()

        let diagnostics = SnapshotEnumerationDiagnostics(rootURL: rootURL)
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { url, error in
                diagnostics.record(url: url, error: error)
                return true
            }
        ) else {
            throw FolderSnapshotError.rootUnavailable(
                systemErrorCode: diagnostics.rootErrorCode ?? Int(EIO)
            )
        }

        while let childURL = enumerator.nextObject() as? URL {
            try Task.checkCancellation()

            if let code = diagnostics.rootErrorCode {
                throw FolderSnapshotError.rootUnavailable(systemErrorCode: code)
            }
            guard state.paths.count < options.maximumEntryCount else {
                throw FolderSnapshotError.entryLimitExceeded(limit: options.maximumEntryCount)
            }

            guard let relativePath = Self.relativePath(for: childURL, below: rootURL) else {
                // A directory enumerator must never escape its root. Treat an
                // unexpected value as a root enumeration failure without
                // persisting either absolute path.
                throw FolderSnapshotError.rootUnavailable(systemErrorCode: Int(EIO))
            }
            let depth = Self.relativePathDepth(relativePath)
            guard depth <= options.maximumDepth else {
                throw FolderSnapshotError.depthLimitExceeded(
                    limit: options.maximumDepth,
                    attempted: depth
                )
            }
            let relativePathByteCount = relativePath.utf8.count
            guard relativePathByteCount <= options.maximumRelativePathUTF8ByteCount else {
                throw FolderSnapshotError.relativePathByteLimitExceeded(
                    limit: options.maximumRelativePathUTF8ByteCount,
                    attempted: relativePathByteCount
                )
            }
            state.paths.append(relativePath)

            let metadata: SnapshotFileMetadata
            do {
                metadata = try Self.metadata(at: childURL)
            } catch let failure as SnapshotPOSIXFailure {
                if enumerator.fileAttributes?[.type] as? FileAttributeType == .typeDirectory {
                    enumerator.skipDescendants()
                }
                state.issues.append(
                    FolderSnapshotIssue(
                        kind: .metadataUnavailable,
                        relativePaths: [relativePath],
                        systemErrorCode: failure.code
                    )
                )
                continue
            }

            switch metadata.kind {
            case .file:
                var digest: String?
                do {
                    digest = try hashFile(
                        at: childURL,
                        expectedMetadata: metadata,
                        options: options,
                        bytesHashed: &state.bytesHashed
                    )
                } catch let error as FolderSnapshotError {
                    throw error
                } catch is CancellationError {
                    throw CancellationError()
                } catch let failure as SnapshotContentFailure {
                    state.issues.append(
                        FolderSnapshotIssue(
                            kind: failure.kind,
                            relativePaths: [relativePath],
                            systemErrorCode: failure.code
                        )
                    )
                } catch {
                    state.issues.append(
                        FolderSnapshotIssue(
                            kind: .contentUnreadable,
                            relativePaths: [relativePath]
                        )
                    )
                }

                state.entries.append(
                    Self.entry(
                        relativePath: relativePath,
                        metadata: metadata,
                        sha256: digest
                    )
                )

            case .directory:
                state.entries.append(
                    Self.entry(relativePath: relativePath, metadata: metadata)
                )
                // Re-check the directory immediately before traversal. This
                // prevents an ordinary replacement with a link from being
                // followed; symbolic links are otherwise never traversed.
                do {
                    let current = try Self.metadata(at: childURL)
                    guard current.kind == .directory,
                          current.device == metadata.device,
                          current.inode == metadata.inode else {
                        state.issues.append(
                            FolderSnapshotIssue(
                                kind: .fileChangedDuringCapture,
                                relativePaths: [relativePath]
                            )
                        )
                        enumerator.skipDescendants()
                        continue
                    }
                } catch let failure as SnapshotPOSIXFailure {
                    state.issues.append(
                        FolderSnapshotIssue(
                            kind: .directoryUnreadable,
                            relativePaths: [relativePath],
                            systemErrorCode: failure.code
                        )
                    )
                    enumerator.skipDescendants()
                    continue
                }

            case .symbolicLink:
                // DirectoryEnumerator does not follow symbolic links. Calling
                // skipDescendants() for a non-directory is unsafe because its
                // state can affect a later real directory on Darwin.
                var target: String?
                do {
                    let rawTarget = try FileManager.default.destinationOfSymbolicLink(
                        atPath: childURL.path
                    )
                    target = Self.portableSymbolicLinkTarget(
                        rawTarget,
                        rootURL: rootURL
                    )
                } catch {
                    state.issues.append(
                        FolderSnapshotIssue(
                            kind: .symbolicLinkTargetUnavailable,
                            relativePaths: [relativePath],
                            systemErrorCode: (error as NSError).code
                        )
                    )
                }
                state.entries.append(
                    Self.entry(
                        relativePath: relativePath,
                        metadata: metadata,
                        symbolicLinkTarget: target
                    )
                )

            case .other:
                state.entries.append(
                    Self.entry(relativePath: relativePath, metadata: metadata)
                )
            }
        }

        if let code = diagnostics.rootErrorCode {
            throw FolderSnapshotError.rootUnavailable(systemErrorCode: code)
        }
        state.issues.append(contentsOf: diagnostics.issues)
    }

    private static func relativePath(for url: URL, below rootURL: URL) -> String? {
        let rootComponents = rootURL.standardizedFileURL.pathComponents
        let childComponents = url.standardizedFileURL.pathComponents
        guard childComponents.count > rootComponents.count,
              childComponents.starts(with: rootComponents) else {
            return nil
        }
        let relativePath = childComponents.dropFirst(rootComponents.count).joined(separator: "/")
        return isSafeRelativePath(relativePath) ? relativePath : nil
    }

    private static func relativePathDepth(_ relativePath: String) -> Int {
        1 + relativePath.utf8.reduce(into: 0) { count, byte in
            if byte == 0x2F { count += 1 }
        }
    }

    private func hashFile(
        at fileURL: URL,
        expectedMetadata: SnapshotFileMetadata,
        options: FolderSnapshotCaptureOptions,
        bytesHashed: inout UInt64
    ) throws -> String {
        let attempted = bytesHashed.addingReportingOverflow(expectedMetadata.byteCount)
        if attempted.overflow || attempted.partialValue > options.maximumByteCount {
            throw FolderSnapshotError.byteLimitExceeded(
                limit: options.maximumByteCount,
                attempted: attempted.overflow ? UInt64.max : attempted.partialValue
            )
        }

        let descriptor = fileURL.path.withCString { path in
            Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw SnapshotContentFailure(kind: .contentUnreadable, code: Int(errno))
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }

        var openedStat = stat()
        guard Darwin.fstat(descriptor, &openedStat) == 0 else {
            throw SnapshotContentFailure(kind: .contentUnreadable, code: Int(errno))
        }
        guard openedStat.st_mode & S_IFMT == S_IFREG,
              UInt64(bitPattern: Int64(openedStat.st_dev)) == expectedMetadata.device,
              UInt64(openedStat.st_ino) == expectedMetadata.inode else {
            throw SnapshotContentFailure(kind: .fileChangedDuringCapture, code: nil)
        }

        let openedByteCount = UInt64(max(0, openedStat.st_size))
        let openedAttempt = bytesHashed.addingReportingOverflow(openedByteCount)
        if openedAttempt.overflow || openedAttempt.partialValue > options.maximumByteCount {
            throw FolderSnapshotError.byteLimitExceeded(
                limit: options.maximumByteCount,
                attempted: openedAttempt.overflow ? UInt64.max : openedAttempt.partialValue
            )
        }

        var hasher = SHA256()
        var fileBytesRead: UInt64 = 0
        while true {
            try Task.checkCancellation()
            let data: Data
            do {
                data = try handle.read(upToCount: options.hashChunkSize) ?? Data()
            } catch {
                throw SnapshotContentFailure(
                    kind: .contentUnreadable,
                    code: (error as NSError).code
                )
            }
            if data.isEmpty { break }

            let nextFileCount = fileBytesRead.addingReportingOverflow(UInt64(data.count))
            let nextTotal = bytesHashed.addingReportingOverflow(nextFileCount.partialValue)
            if nextFileCount.overflow || nextTotal.overflow
                || nextTotal.partialValue > options.maximumByteCount {
                throw FolderSnapshotError.byteLimitExceeded(
                    limit: options.maximumByteCount,
                    attempted: nextTotal.overflow ? UInt64.max : nextTotal.partialValue
                )
            }
            fileBytesRead = nextFileCount.partialValue
            hasher.update(data: data)
        }

        var finalStat = stat()
        guard Darwin.fstat(descriptor, &finalStat) == 0 else {
            throw SnapshotContentFailure(kind: .contentUnreadable, code: Int(errno))
        }
        let finalModificationTime = Self.modificationTimeNanoseconds(finalStat)
        guard UInt64(bitPattern: Int64(finalStat.st_dev)) == expectedMetadata.device,
              UInt64(finalStat.st_ino) == expectedMetadata.inode,
              UInt64(max(0, finalStat.st_size)) == fileBytesRead,
              finalModificationTime == expectedMetadata.modificationTimeNanoseconds else {
            throw SnapshotContentFailure(kind: .fileChangedDuringCapture, code: nil)
        }

        bytesHashed += fileBytesRead
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Internal so tests can exercise collision detection even on the common
    /// case-insensitive APFS configuration where colliding names cannot coexist.
    static func detectPathCollisions(in paths: [String]) -> [FolderSnapshotIssue] {
        var firstByCanonical: [String: String] = [:]
        var firstByFoldedCanonical: [String: String] = [:]
        var issues: [FolderSnapshotIssue] = []

        for path in paths.sorted(by: pathLess) {
            let canonical = path.precomposedStringWithCanonicalMapping
            if let first = firstByCanonical[canonical], !rawPathEqual(first, path) {
                issues.append(
                    FolderSnapshotIssue(
                        kind: .unicodeCollision,
                        relativePaths: [first, path].sorted(by: pathLess)
                    )
                )
            } else if firstByCanonical[canonical] == nil {
                firstByCanonical[canonical] = path
            }

            let folded = canonical.lowercased(with: Locale(identifier: "en_US_POSIX"))
            if let first = firstByFoldedCanonical[folded] {
                let firstCanonical = first.precomposedStringWithCanonicalMapping
                if firstCanonical != canonical {
                    issues.append(
                        FolderSnapshotIssue(
                            kind: .caseCollision,
                            relativePaths: [first, path].sorted(by: pathLess)
                        )
                    )
                }
            } else {
                firstByFoldedCanonical[folded] = path
            }
        }

        return normalizedIssues(issues)
    }

    fileprivate static func normalized(_ snapshot: FolderSnapshot) -> FolderSnapshot {
        FolderSnapshot(
            entries: snapshot.entries.sorted {
                pathLess($0.relativePath, $1.relativePath)
            },
            issues: normalizedIssues(snapshot.issues)
        )
    }

    fileprivate static func validate(_ snapshot: FolderSnapshot) throws {
        var paths: Set<SnapshotPathBytes> = []
        let issuePathKeys = Set(
            snapshot.issues.flatMap(\.relativePaths).map(SnapshotPathBytes.init)
        )

        for item in snapshot.entries {
            guard isSafeRelativePath(item.relativePath) else {
                throw FolderSnapshotError.invalidSnapshot(
                    reason: .unsafeRelativePath(item.relativePath)
                )
            }
            guard paths.insert(SnapshotPathBytes(item.relativePath)).inserted else {
                throw FolderSnapshotError.invalidSnapshot(
                    reason: .duplicateRelativePath(item.relativePath)
                )
            }
            guard item.posixPermissions <= 0o7777 else {
                throw FolderSnapshotError.invalidSnapshot(
                    reason: .inconsistentEntry(item.relativePath)
                )
            }

            switch item.kind {
            case .file:
                guard item.symbolicLinkTarget == nil else {
                    throw FolderSnapshotError.invalidSnapshot(
                        reason: .inconsistentEntry(item.relativePath)
                    )
                }
                if let digest = item.sha256 {
                    guard isSHA256(digest) else {
                        throw FolderSnapshotError.invalidSnapshot(
                            reason: .invalidDigest(item.relativePath)
                        )
                    }
                } else if !issuePathKeys.contains(SnapshotPathBytes(item.relativePath)) {
                    throw FolderSnapshotError.invalidSnapshot(
                        reason: .invalidDigest(item.relativePath)
                    )
                }

            case .symbolicLink:
                guard item.sha256 == nil else {
                    throw FolderSnapshotError.invalidSnapshot(
                        reason: .inconsistentEntry(item.relativePath)
                    )
                }
                if let target = item.symbolicLinkTarget, target.hasPrefix("/") {
                    throw FolderSnapshotError.invalidSnapshot(
                        reason: .invalidSymbolicLinkTarget(item.relativePath)
                    )
                }

            case .directory, .other:
                guard item.sha256 == nil, item.symbolicLinkTarget == nil else {
                    throw FolderSnapshotError.invalidSnapshot(
                        reason: .inconsistentEntry(item.relativePath)
                    )
                }
            }
        }

        for issue in snapshot.issues {
            guard !issue.relativePaths.isEmpty else {
                throw FolderSnapshotError.invalidSnapshot(reason: .unsafeIssuePath(""))
            }
            for path in issue.relativePaths where !isSafeRelativePath(path) {
                throw FolderSnapshotError.invalidSnapshot(reason: .unsafeIssuePath(path))
            }
        }
    }

    private static func metadata(at url: URL) throws -> SnapshotFileMetadata {
        var value = stat()
        let result = url.path.withCString { Darwin.lstat($0, &value) }
        guard result == 0 else {
            throw SnapshotPOSIXFailure(code: Int(errno))
        }

        let kind: FolderSnapshotEntry.Kind
        switch value.st_mode & S_IFMT {
        case S_IFREG: kind = .file
        case S_IFDIR: kind = .directory
        case S_IFLNK: kind = .symbolicLink
        default: kind = .other
        }

        return SnapshotFileMetadata(
            kind: kind,
            byteCount: UInt64(max(0, value.st_size)),
            modificationTimeNanoseconds: modificationTimeNanoseconds(value),
            posixPermissions: UInt16(value.st_mode & 0o7777),
            device: UInt64(bitPattern: Int64(value.st_dev)),
            inode: UInt64(value.st_ino)
        )
    }

    private static func modificationTimeNanoseconds(_ value: stat) -> Int64 {
        let seconds = Int64(value.st_mtimespec.tv_sec)
        let nanoseconds = Int64(value.st_mtimespec.tv_nsec)
        let product = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        if product.overflow {
            return seconds < 0 ? Int64.min : Int64.max
        }
        return product.partialValue.addingReportingOverflow(nanoseconds).partialValue
    }

    private static func entry(
        relativePath: String,
        metadata: SnapshotFileMetadata,
        symbolicLinkTarget: String? = nil,
        sha256: String? = nil
    ) -> FolderSnapshotEntry {
        FolderSnapshotEntry(
            relativePath: relativePath,
            kind: metadata.kind,
            byteCount: metadata.byteCount,
            modificationTimeNanoseconds: metadata.modificationTimeNanoseconds,
            posixPermissions: metadata.posixPermissions,
            symbolicLinkTarget: symbolicLinkTarget,
            sha256: sha256
        )
    }

    private static func portableSymbolicLinkTarget(
        _ target: String,
        rootURL: URL
    ) -> String {
        guard target.hasPrefix("/") else { return target }

        let targetURL = URL(fileURLWithPath: target).standardizedFileURL
        let rootComponents = rootURL.standardizedFileURL.pathComponents
        let targetComponents = targetURL.pathComponents
        if targetComponents.starts(with: rootComponents) {
            let relative = targetComponents.dropFirst(rootComponents.count).joined(separator: "/")
            return "snapshot-root:" + (relative.isEmpty ? "." : relative)
        }

        let digest = SHA256.hash(data: Data(target.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "absolute-target-sha256:" + digest
    }

    private static func normalizedIssues(
        _ issues: [FolderSnapshotIssue]
    ) -> [FolderSnapshotIssue] {
        issues
            .map {
                FolderSnapshotIssue(
                    kind: $0.kind,
                    relativePaths: $0.relativePaths.sorted(by: pathLess),
                    systemErrorCode: $0.systemErrorCode
                )
            }
            .sorted { left, right in
                if left.kind.rawValue != right.kind.rawValue {
                    return left.kind.rawValue < right.kind.rawValue
                }
                let leftPath = left.relativePaths.first ?? ""
                let rightPath = right.relativePaths.first ?? ""
                if !rawPathEqual(leftPath, rightPath) {
                    return pathLess(leftPath, rightPath)
                }
                if left.relativePaths.count != right.relativePaths.count {
                    return left.relativePaths.count < right.relativePaths.count
                }
                return (left.systemErrorCode ?? Int.min) < (right.systemErrorCode ?? Int.min)
            }
    }

    fileprivate static func pathLess(_ left: String, _ right: String) -> Bool {
        left.utf8.lexicographicallyPrecedes(right.utf8)
    }

    private static func rawPathEqual(_ left: String, _ right: String) -> Bool {
        left.utf8.elementsEqual(right.utf8)
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\0") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    private static func isSHA256(_ digest: String) -> Bool {
        digest.utf8.count == 64 && digest.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }
}

/// Actor-isolated, deterministic, atomic snapshot persistence.
public actor FolderSnapshotStore {
    public nonisolated let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> FolderSnapshot {
        try readExisting()
    }

    public func save(_ snapshot: FolderSnapshot) throws {
        // Never replace malformed or unsupported data implicitly.
        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try readExisting()
        }
        let normalized = FolderSnapshotCapture.normalized(snapshot)
        try FolderSnapshotCapture.validate(normalized)
        try write(normalized)
    }

    private func readExisting() throws -> FolderSnapshot {
        let data: Data
        do {
            data = try BoundedLocalFileReader(
                limits: .init(maximumByteCount: 512 * 1_024 * 1_024)
            ).read(url: fileURL)
        } catch {
            throw FolderSnapshotError.ioFailure(operation: .read)
        }

        let header: FolderSnapshotSchemaHeader
        do {
            header = try JSONDecoder().decode(FolderSnapshotSchemaHeader.self, from: data)
        } catch {
            throw FolderSnapshotError.corruptedJSON
        }

        if header.schemaVersion > FolderSnapshotEnvelope.currentSchemaVersion {
            throw FolderSnapshotError.futureSchemaVersion(
                found: header.schemaVersion,
                supported: FolderSnapshotEnvelope.currentSchemaVersion
            )
        }
        if header.schemaVersion < FolderSnapshotEnvelope.currentSchemaVersion {
            throw FolderSnapshotError.migrationRequired(
                found: header.schemaVersion,
                current: FolderSnapshotEnvelope.currentSchemaVersion
            )
        }

        let envelope: FolderSnapshotEnvelope
        do {
            envelope = try JSONDecoder().decode(FolderSnapshotEnvelope.self, from: data)
        } catch {
            throw FolderSnapshotError.corruptedJSON
        }
        let normalized = FolderSnapshotCapture.normalized(envelope.snapshot)
        try FolderSnapshotCapture.validate(normalized)
        return normalized
    }

    private func write(_ snapshot: FolderSnapshot) throws {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            data = try encoder.encode(FolderSnapshotEnvelope(snapshot: snapshot))
        } catch {
            throw FolderSnapshotError.ioFailure(operation: .encode)
        }

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw FolderSnapshotError.ioFailure(operation: .createDirectory)
        }

        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw FolderSnapshotError.ioFailure(operation: .write)
        }
    }
}

public enum FolderSnapshotComparisonStatus: String, Codable, Sendable {
    case same
    case changed
    case leftOnly
    case rightOnly
    case typeMismatch
    case error
}

public struct FolderSnapshotComparisonRow: Equatable, Codable, Sendable {
    public let relativePath: String
    public let left: FolderSnapshotEntry?
    public let right: FolderSnapshotEntry?
    public let status: FolderSnapshotComparisonStatus
    public let issues: [FolderSnapshotIssue]

    public init(
        relativePath: String,
        left: FolderSnapshotEntry?,
        right: FolderSnapshotEntry?,
        status: FolderSnapshotComparisonStatus,
        issues: [FolderSnapshotIssue] = []
    ) {
        self.relativePath = relativePath
        self.left = left
        self.right = right
        self.status = status
        self.issues = issues
    }
}

public struct FolderSnapshotComparisonResult: Equatable, Codable, Sendable {
    public let rows: [FolderSnapshotComparisonRow]

    public init(rows: [FolderSnapshotComparisonRow]) {
        self.rows = rows
    }

    public var hasDifferences: Bool {
        rows.contains { $0.status != .same }
    }
}

public struct FolderSnapshotComparator: Sendable {
    public init() {}

    public func compare(
        left: FolderSnapshot,
        right: FolderSnapshot
    ) -> FolderSnapshotComparisonResult {
        let left = FolderSnapshotCapture.normalized(left)
        let right = FolderSnapshotCapture.normalized(right)
        let leftIndex = entriesByPath(left.entries)
        let rightIndex = entriesByPath(right.entries)
        let leftEntries = leftIndex.entries
        let rightEntries = rightIndex.entries
        var leftIssues = issuesByPath(left.issues)
        var rightIssues = issuesByPath(right.issues)
        mergeIssues(leftIndex.issues, into: &leftIssues)
        mergeIssues(rightIndex.issues, into: &rightIssues)
        let keys = Set(leftEntries.keys)
            .union(rightEntries.keys)
            .union(leftIssues.keys)
            .union(rightIssues.keys)
            .sorted { FolderSnapshotCapture.pathLess($0.string, $1.string) }

        let rows = keys.map { key in
            let leftEntry = leftEntries[key]
            let rightEntry = rightEntries[key]
            let issues = (leftIssues[key, default: []] + rightIssues[key, default: []])
            let status: FolderSnapshotComparisonStatus

            if !issues.isEmpty {
                status = .error
            } else {
                switch (leftEntry, rightEntry) {
                case let (left?, right?):
                    if left.kind != right.kind {
                        status = .typeMismatch
                    } else if entryMetadataEqual(left, right) {
                        status = .same
                    } else {
                        status = .changed
                    }
                case (.some, nil):
                    status = .leftOnly
                case (nil, .some):
                    status = .rightOnly
                case (nil, nil):
                    status = .error
                }
            }

            return FolderSnapshotComparisonRow(
                relativePath: leftEntry?.relativePath ?? rightEntry?.relativePath ?? key.string,
                left: leftEntry,
                right: rightEntry,
                status: status,
                issues: issues
            )
        }
        return FolderSnapshotComparisonResult(rows: rows)
    }

    /// The stored snapshot is the left side; the freshly captured live folder
    /// is the right side.
    public func compare(
        snapshot: FolderSnapshot,
        toLiveFolderAt folderURL: URL,
        options: FolderSnapshotCaptureOptions = .init()
    ) async throws -> FolderSnapshotComparisonResult {
        let live = try await FolderSnapshotCapture().capture(
            folderAt: folderURL,
            options: options
        )
        return compare(left: snapshot, right: live)
    }

    private func issuesByPath(
        _ issues: [FolderSnapshotIssue]
    ) -> [SnapshotPathBytes: [FolderSnapshotIssue]] {
        var result: [SnapshotPathBytes: [FolderSnapshotIssue]] = [:]
        for issue in issues {
            for path in issue.relativePaths {
                result[SnapshotPathBytes(path), default: []].append(issue)
            }
        }
        return result
    }

    private func entriesByPath(
        _ entries: [FolderSnapshotEntry]
    ) -> (
        entries: [SnapshotPathBytes: FolderSnapshotEntry],
        issues: [SnapshotPathBytes: [FolderSnapshotIssue]]
    ) {
        var result: [SnapshotPathBytes: FolderSnapshotEntry] = [:]
        var issues: [SnapshotPathBytes: [FolderSnapshotIssue]] = [:]
        for entry in entries {
            let key = SnapshotPathBytes(entry.relativePath)
            if result[key] == nil {
                result[key] = entry
            } else {
                issues[key, default: []].append(
                    FolderSnapshotIssue(
                        kind: .invalidSnapshot,
                        relativePaths: [entry.relativePath]
                    )
                )
            }
        }
        return (result, issues)
    }

    private func mergeIssues(
        _ additions: [SnapshotPathBytes: [FolderSnapshotIssue]],
        into destination: inout [SnapshotPathBytes: [FolderSnapshotIssue]]
    ) {
        for (key, issues) in additions {
            destination[key, default: []].append(contentsOf: issues)
        }
    }

    private func entryMetadataEqual(
        _ left: FolderSnapshotEntry,
        _ right: FolderSnapshotEntry
    ) -> Bool {
        left.kind == right.kind
            && left.byteCount == right.byteCount
            && left.modificationTimeNanoseconds == right.modificationTimeNanoseconds
            && left.posixPermissions == right.posixPermissions
            && left.symbolicLinkTarget == right.symbolicLinkTarget
            && left.sha256 == right.sha256
    }
}

private struct CaptureState {
    var entries: [FolderSnapshotEntry] = []
    var issues: [FolderSnapshotIssue] = []
    var paths: [String] = []
    var bytesHashed: UInt64 = 0
}

/// FileManager's error handler cannot throw. Keep only path-safe diagnostics
/// here, then let the capture loop throw its own structured limit errors.
private final class SnapshotEnumerationDiagnostics {
    private let rootComponents: [String]
    var rootErrorCode: Int?
    var issues: [FolderSnapshotIssue] = []

    init(rootURL: URL) {
        rootComponents = rootURL.standardizedFileURL.pathComponents
    }

    func record(url: URL, error: Error) {
        let code = (error as NSError).code
        let components = url.standardizedFileURL.pathComponents
        guard components.count > rootComponents.count,
              components.starts(with: rootComponents) else {
            if rootErrorCode == nil { rootErrorCode = code }
            return
        }

        let relativePath = components.dropFirst(rootComponents.count).joined(separator: "/")
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\0"),
              relativePath.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".."
              }) else {
            if rootErrorCode == nil { rootErrorCode = code }
            return
        }
        issues.append(
            FolderSnapshotIssue(
                kind: .directoryUnreadable,
                relativePaths: [relativePath],
                systemErrorCode: code
            )
        )
    }
}

private struct SnapshotFileMetadata {
    let kind: FolderSnapshotEntry.Kind
    let byteCount: UInt64
    let modificationTimeNanoseconds: Int64
    let posixPermissions: UInt16
    let device: UInt64
    let inode: UInt64
}

private struct SnapshotPOSIXFailure: Error {
    let code: Int
}

private struct SnapshotContentFailure: Error {
    let kind: FolderSnapshotIssue.Kind
    let code: Int?
}

private struct FolderSnapshotSchemaHeader: Decodable {
    let schemaVersion: Int
}

private struct SnapshotPathBytes: Hashable {
    let bytes: [UInt8]

    init(_ path: String) {
        bytes = Array(path.utf8)
    }

    var string: String {
        String(decoding: bytes, as: UTF8.self)
    }
}
