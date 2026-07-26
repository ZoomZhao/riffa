import CryptoKit
import Darwin
import Foundation

/// Explicit work and memory ceilings for local rename/move detection.
///
/// Every value is finite and strictly positive. Invalid values are rejected by
/// both the public initializer and `Decodable`; zero never means “unlimited”.
public struct FolderRenameDetectionLimits: Hashable, Codable, Sendable {
    public static let standard = Self(
        validatedMaximumCandidateCount: 100_000,
        maximumSingleFileByteCount: 64 * 1_024 * 1_024 * 1_024,
        maximumTotalHashedByteCount: 256 * 1_024 * 1_024 * 1_024,
        hashChunkByteCount: 1 * 1_024 * 1_024
    )

    public let maximumCandidateCount: Int
    public let maximumSingleFileByteCount: UInt64
    public let maximumTotalHashedByteCount: UInt64
    public let hashChunkByteCount: Int

    public init(
        maximumCandidateCount: Int = 100_000,
        maximumSingleFileByteCount: UInt64 = 64 * 1_024 * 1_024 * 1_024,
        maximumTotalHashedByteCount: UInt64 = 256 * 1_024 * 1_024 * 1_024,
        hashChunkByteCount: Int = 1 * 1_024 * 1_024
    ) throws {
        guard (1...Self.maximumAllowedCandidateCount).contains(maximumCandidateCount),
              maximumSingleFileByteCount > 0,
              maximumSingleFileByteCount <= UInt64(Int64.max),
              maximumTotalHashedByteCount > 0,
              (1...Self.maximumAllowedChunkByteCount).contains(hashChunkByteCount) else {
            throw FolderRenameDetectionError.invalidLimits
        }
        self.init(
            validatedMaximumCandidateCount: maximumCandidateCount,
            maximumSingleFileByteCount: maximumSingleFileByteCount,
            maximumTotalHashedByteCount: maximumTotalHashedByteCount,
            hashChunkByteCount: hashChunkByteCount
        )
    }

    private init(
        validatedMaximumCandidateCount: Int,
        maximumSingleFileByteCount: UInt64,
        maximumTotalHashedByteCount: UInt64,
        hashChunkByteCount: Int
    ) {
        maximumCandidateCount = validatedMaximumCandidateCount
        self.maximumSingleFileByteCount = maximumSingleFileByteCount
        self.maximumTotalHashedByteCount = maximumTotalHashedByteCount
        self.hashChunkByteCount = hashChunkByteCount
    }

    private enum CodingKeys: String, CodingKey {
        case maximumCandidateCount
        case maximumSingleFileByteCount
        case maximumTotalHashedByteCount
        case hashChunkByteCount
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            maximumCandidateCount: container.decode(Int.self, forKey: .maximumCandidateCount),
            maximumSingleFileByteCount: container.decode(
                UInt64.self,
                forKey: .maximumSingleFileByteCount
            ),
            maximumTotalHashedByteCount: container.decode(
                UInt64.self,
                forKey: .maximumTotalHashedByteCount
            ),
            hashChunkByteCount: container.decode(Int.self, forKey: .hashChunkByteCount)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(maximumCandidateCount, forKey: .maximumCandidateCount)
        try container.encode(maximumSingleFileByteCount, forKey: .maximumSingleFileByteCount)
        try container.encode(maximumTotalHashedByteCount, forKey: .maximumTotalHashedByteCount)
        try container.encode(hashChunkByteCount, forKey: .hashChunkByteCount)
    }

    private static let maximumAllowedCandidateCount = 1_000_000
    private static let maximumAllowedChunkByteCount = 16 * 1_024 * 1_024
}

/// One high-confidence rename/move suggestion. The digest confirms byte-for-byte
/// equality; callers should avoid displaying it unless specifically requested.
public struct FolderRenameMatch: Hashable, Codable, Sendable {
    public let leftRelativePath: String
    public let rightRelativePath: String
    public let byteCount: UInt64
    public let digest: String

    public init(
        leftRelativePath: String,
        rightRelativePath: String,
        byteCount: UInt64,
        digest: String
    ) {
        self.leftRelativePath = leftRelativePath
        self.rightRelativePath = rightRelativePath
        self.byteCount = byteCount
        self.digest = digest
    }
}

/// A same-content group that cannot be paired without guessing.
public struct FolderRenameAmbiguousGroup: Hashable, Codable, Sendable {
    public let leftRelativePaths: [String]
    public let rightRelativePaths: [String]
    public let byteCount: UInt64
    public let digest: String

    public init(
        leftRelativePaths: [String],
        rightRelativePaths: [String],
        byteCount: UInt64,
        digest: String
    ) {
        self.leftRelativePaths = leftRelativePaths
        self.rightRelativePaths = rightRelativePaths
        self.byteCount = byteCount
        self.digest = digest
    }

    public var candidateCount: Int {
        leftRelativePaths.count + rightRelativePaths.count
    }
}

/// Stable, bounded output from rename/move detection.
public struct FolderRenameDetectionResult: Hashable, Codable, Sendable {
    public let matches: [FolderRenameMatch]
    public let ambiguousGroups: [FolderRenameAmbiguousGroup]
    /// All unique-side regular files with a declared, non-negative size.
    public let eligibleCandidateCount: Int
    /// Candidates whose size appeared on both sides and were therefore hashed.
    public let hashedCandidateCount: Int
    public let hashedByteCount: UInt64
    /// Hashed candidates that were neither a unique match nor part of a
    /// cross-side ambiguous group.
    public let unmatchedCandidateCount: Int

    public init(
        matches: [FolderRenameMatch],
        ambiguousGroups: [FolderRenameAmbiguousGroup],
        eligibleCandidateCount: Int,
        hashedCandidateCount: Int,
        hashedByteCount: UInt64,
        unmatchedCandidateCount: Int
    ) {
        self.matches = matches
        self.ambiguousGroups = ambiguousGroups
        self.eligibleCandidateCount = eligibleCandidateCount
        self.hashedCandidateCount = hashedCandidateCount
        self.hashedByteCount = hashedByteCount
        self.unmatchedCandidateCount = unmatchedCandidateCount
    }

    public var ambiguousCandidateCount: Int {
        ambiguousGroups.reduce(into: 0) { $0 += $1.candidateCount }
    }
}

/// Path-free failures from local rename/move detection.
public enum FolderRenameDetectionError: Error, Hashable, Codable, Sendable {
    public enum Side: String, Hashable, Codable, Sendable {
        case left
        case right
    }

    public enum Operation: String, Hashable, Codable, Sendable {
        case open
        case inspect
        case read
    }

    case invalidLimits
    case candidateLimitExceeded(actual: Int, limit: Int)
    case fileByteLimitExceeded(side: Side, actual: UInt64, limit: UInt64)
    case totalHashedByteLimitExceeded(actual: UInt64, limit: UInt64)
    case nonLocalResource(side: Side)
    case operationFailed(side: Side, operation: Operation, code: Int32)
    case notRegularFile(side: Side)
    case fileChangedDuringDetection(side: Side)
}

extension FolderRenameDetectionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidLimits:
            "The rename-detection limits are invalid."
        case let .candidateLimitExceeded(actual, limit):
            "Rename detection found \(actual) candidates, exceeding the \(limit)-candidate limit."
        case let .fileByteLimitExceeded(side, actual, limit):
            "The \(side.rawValue) candidate has \(actual) bytes, exceeding the \(limit)-byte per-file limit."
        case let .totalHashedByteLimitExceeded(actual, limit):
            "Rename detection would hash \(actual) bytes, exceeding the \(limit)-byte total limit."
        case let .nonLocalResource(side):
            "The \(side.rawValue) candidate is not an absolute local file resource."
        case let .operationFailed(side, operation, code):
            "The \(side.rawValue) candidate \(operation.rawValue) operation failed (errno \(code))."
        case let .notRegularFile(side):
            "The \(side.rawValue) candidate is no longer a regular file."
        case let .fileChangedDuringDetection(side):
            "The \(side.rawValue) candidate changed during rename detection."
        }
    }
}

/// Descriptor-backed local rename/move candidate detection.
///
/// Only `.leftOnly`/`.rightOnly` regular-file rows are candidates. Files are
/// hashed only when their declared size occurs on both sides. A digest group is
/// published as a match only when it has exactly one member on each side;
/// repeated-content groups are explicitly ambiguous and never arbitrarily paired.
public actor LocalFolderRenameDetector {
    public nonisolated let limits: FolderRenameDetectionLimits

    public init(limits: FolderRenameDetectionLimits = .standard) {
        self.limits = limits
    }

    public func detect(nodes: [PairNode]) async throws -> FolderRenameDetectionResult {
        try Task.checkCancellation()
        let collected = try await collectCandidates(nodes)
        let sharedSizes = Set(collected.leftBySize.keys).intersection(collected.rightBySize.keys)

        var candidatesToHash: [Candidate] = []
        candidatesToHash.reserveCapacity(collected.eligibleCandidateCount)
        var plannedHashedByteCount: UInt64 = 0

        for byteCount in sharedSizes.sorted() {
            try Task.checkCancellation()
            let bucket = (collected.leftBySize[byteCount] ?? [])
                + (collected.rightBySize[byteCount] ?? [])
            for candidate in bucket {
                guard byteCount <= limits.maximumSingleFileByteCount else {
                    throw FolderRenameDetectionError.fileByteLimitExceeded(
                        side: candidate.side,
                        actual: byteCount,
                        limit: limits.maximumSingleFileByteCount
                    )
                }
                let next = plannedHashedByteCount.addingReportingOverflow(byteCount)
                guard !next.overflow,
                      next.partialValue <= limits.maximumTotalHashedByteCount else {
                    throw FolderRenameDetectionError.totalHashedByteLimitExceeded(
                        actual: next.overflow ? UInt64.max : next.partialValue,
                        limit: limits.maximumTotalHashedByteCount
                    )
                }
                plannedHashedByteCount = next.partialValue
                candidatesToHash.append(candidate)
            }
        }

        candidatesToHash.sort(by: candidateLess)
        var groups: [DigestKey: DigestGroup] = [:]
        groups.reserveCapacity(candidatesToHash.count)

        for candidate in candidatesToHash {
            try Task.checkCancellation()
            let digest = try await digest(candidate)
            let key = DigestKey(byteCount: candidate.byteCount, digest: digest)
            switch candidate.side {
            case .left:
                groups[key, default: DigestGroup()].leftPaths.append(candidate.relativePath)
            case .right:
                groups[key, default: DigestGroup()].rightPaths.append(candidate.relativePath)
            }
        }

        var matches: [FolderRenameMatch] = []
        var ambiguousGroups: [FolderRenameAmbiguousGroup] = []
        var unmatchedCandidateCount = 0

        for key in groups.keys.sorted(by: digestKeyLess) {
            try Task.checkCancellation()
            guard var group = groups[key] else { continue }
            group.leftPaths.sort(by: pathLess)
            group.rightPaths.sort(by: pathLess)
            if group.leftPaths.count == 1, group.rightPaths.count == 1 {
                matches.append(FolderRenameMatch(
                    leftRelativePath: group.leftPaths[0],
                    rightRelativePath: group.rightPaths[0],
                    byteCount: key.byteCount,
                    digest: key.digest
                ))
            } else if !group.leftPaths.isEmpty, !group.rightPaths.isEmpty {
                ambiguousGroups.append(FolderRenameAmbiguousGroup(
                    leftRelativePaths: group.leftPaths,
                    rightRelativePaths: group.rightPaths,
                    byteCount: key.byteCount,
                    digest: key.digest
                ))
            } else {
                unmatchedCandidateCount += group.leftPaths.count + group.rightPaths.count
            }
        }

        matches.sort {
            if $0.leftRelativePath != $1.leftRelativePath {
                return pathLess($0.leftRelativePath, $1.leftRelativePath)
            }
            return pathLess($0.rightRelativePath, $1.rightRelativePath)
        }
        ambiguousGroups.sort(by: ambiguousGroupLess)
        try Task.checkCancellation()
        return FolderRenameDetectionResult(
            matches: matches,
            ambiguousGroups: ambiguousGroups,
            eligibleCandidateCount: collected.eligibleCandidateCount,
            hashedCandidateCount: candidatesToHash.count,
            hashedByteCount: plannedHashedByteCount,
            unmatchedCandidateCount: unmatchedCandidateCount
        )
    }

    private func collectCandidates(_ nodes: [PairNode]) async throws -> CollectedCandidates {
        var leftBySize: [UInt64: [Candidate]] = [:]
        var rightBySize: [UInt64: [Candidate]] = [:]
        var eligibleCandidateCount = 0

        for (index, node) in nodes.enumerated() {
            if index.isMultiple(of: 1_024) {
                try Task.checkCancellation()
                await Task.yield()
            }
            let side: FolderRenameDetectionError.Side
            let entry: ResourceEntry
            switch node.status {
            case .leftOnly:
                guard let left = node.left, node.right == nil else { continue }
                side = .left
                entry = left
            case .rightOnly:
                guard let right = node.right, node.left == nil else { continue }
                side = .right
                entry = right
            case .same, .different, .typeMismatch, .error:
                continue
            }
            guard entry.kind == .file,
                  entry.issue == nil,
                  let declaredByteCount = entry.byteCount,
                  declaredByteCount >= 0 else {
                continue
            }

            eligibleCandidateCount += 1
            guard eligibleCandidateCount <= limits.maximumCandidateCount else {
                throw FolderRenameDetectionError.candidateLimitExceeded(
                    actual: eligibleCandidateCount,
                    limit: limits.maximumCandidateCount
                )
            }
            let expectedIdentity = entry.fileIdentifier.flatMap(ParsedIdentity.init)
            let candidate = Candidate(
                side: side,
                relativePath: entry.relativePath,
                locator: entry.locator,
                byteCount: UInt64(declaredByteCount),
                expectedIdentity: expectedIdentity,
                expectedIdentityWasMalformed: entry.fileIdentifier != nil && expectedIdentity == nil,
                expectedPermissions: entry.permissions
            )
            switch side {
            case .left:
                leftBySize[candidate.byteCount, default: []].append(candidate)
            case .right:
                rightBySize[candidate.byteCount, default: []].append(candidate)
            }
        }
        return CollectedCandidates(
            leftBySize: leftBySize,
            rightBySize: rightBySize,
            eligibleCandidateCount: eligibleCandidateCount
        )
    }

    private func digest(_ candidate: Candidate) async throws -> String {
        guard candidate.locator.providerID == ResourceLocator.localProviderID,
              candidate.locator.path.hasPrefix("/"),
              !candidate.locator.path.utf8.contains(0) else {
            throw FolderRenameDetectionError.nonLocalResource(side: candidate.side)
        }

        let descriptor = candidate.locator.path.withCString { path in
            Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw FolderRenameDetectionError.operationFailed(
                side: candidate.side,
                operation: .open,
                code: errno
            )
        }
        defer { _ = Darwin.close(descriptor) }

        let before = try inspect(descriptor, side: candidate.side)
        guard before.mode & UInt16(S_IFMT) == UInt16(S_IFREG) else {
            throw FolderRenameDetectionError.notRegularFile(side: candidate.side)
        }
        guard before.byteCount == candidate.byteCount,
              !candidate.expectedIdentityWasMalformed,
              candidate.expectedIdentity.map({
                  $0.device == before.device && $0.inode == before.inode
              }) ?? true,
              candidate.expectedPermissions.map({
                  $0 == before.mode & UInt16(0o7777)
              }) ?? true else {
            throw FolderRenameDetectionError.fileChangedDuringDetection(side: candidate.side)
        }

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: limits.hashChunkByteCount)
        var bytesRead: UInt64 = 0
        while true {
            try Task.checkCancellation()
            let readCount: Int = buffer.withUnsafeMutableBytes { rawBuffer in
                while true {
                    let result = Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
                    if result < 0, errno == EINTR { continue }
                    return result
                }
            }
            guard readCount >= 0 else {
                throw FolderRenameDetectionError.operationFailed(
                    side: candidate.side,
                    operation: .read,
                    code: errno
                )
            }
            if readCount == 0 { break }

            let next = bytesRead.addingReportingOverflow(UInt64(readCount))
            guard !next.overflow, next.partialValue <= candidate.byteCount else {
                throw FolderRenameDetectionError.fileChangedDuringDetection(side: candidate.side)
            }
            bytesRead = next.partialValue
            buffer.withUnsafeBytes { rawBuffer in
                hasher.update(data: Data(bytes: rawBuffer.baseAddress!, count: readCount))
            }
            await Task.yield()
        }

        let after = try inspect(descriptor, side: candidate.side)
        guard before == after, bytesRead == candidate.byteCount else {
            throw FolderRenameDetectionError.fileChangedDuringDetection(side: candidate.side)
        }
        try verifyPathStillNames(candidate, version: before)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// `fstat` protects the opened object, while this second no-follow open also
    /// catches a directory entry that was unlinked or rebound after the first
    /// descriptor was acquired.
    private func verifyPathStillNames(_ candidate: Candidate, version: FileVersion) throws {
        let verificationDescriptor = candidate.locator.path.withCString { path in
            Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW)
        }
        guard verificationDescriptor >= 0 else {
            throw FolderRenameDetectionError.fileChangedDuringDetection(side: candidate.side)
        }
        defer { _ = Darwin.close(verificationDescriptor) }

        let currentVersion: FileVersion
        do {
            currentVersion = try inspect(verificationDescriptor, side: candidate.side)
        } catch {
            throw FolderRenameDetectionError.fileChangedDuringDetection(side: candidate.side)
        }
        guard currentVersion == version,
              currentVersion.mode & UInt16(S_IFMT) == UInt16(S_IFREG) else {
            throw FolderRenameDetectionError.fileChangedDuringDetection(side: candidate.side)
        }
    }

    private func inspect(
        _ descriptor: Int32,
        side: FolderRenameDetectionError.Side
    ) throws -> FileVersion {
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0,
              information.st_size >= 0 else {
            throw FolderRenameDetectionError.operationFailed(
                side: side,
                operation: .inspect,
                code: errno
            )
        }
        return FileVersion(
            device: UInt64(bitPattern: Int64(information.st_dev)),
            inode: UInt64(information.st_ino),
            byteCount: UInt64(information.st_size),
            mode: UInt16(information.st_mode),
            modificationSeconds: Int64(information.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(information.st_mtimespec.tv_nsec),
            statusChangeSeconds: Int64(information.st_ctimespec.tv_sec),
            statusChangeNanoseconds: Int64(information.st_ctimespec.tv_nsec)
        )
    }
}

private struct Candidate: Sendable {
    let side: FolderRenameDetectionError.Side
    let relativePath: String
    let locator: ResourceLocator
    let byteCount: UInt64
    let expectedIdentity: ParsedIdentity?
    let expectedIdentityWasMalformed: Bool
    let expectedPermissions: UInt16?
}

private struct ParsedIdentity: Sendable {
    let device: UInt64
    let inode: UInt64

    init?(_ value: String) {
        let components = value.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 2,
              let device = UInt64(components[0]),
              let inode = UInt64(components[1]) else {
            return nil
        }
        self.device = device
        self.inode = inode
    }
}

private struct FileVersion: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let byteCount: UInt64
    let mode: UInt16
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let statusChangeSeconds: Int64
    let statusChangeNanoseconds: Int64
}

private struct CollectedCandidates: Sendable {
    let leftBySize: [UInt64: [Candidate]]
    let rightBySize: [UInt64: [Candidate]]
    let eligibleCandidateCount: Int
}

private struct DigestKey: Hashable, Sendable {
    let byteCount: UInt64
    let digest: String
}

private struct DigestGroup: Sendable {
    var leftPaths: [String] = []
    var rightPaths: [String] = []
}

private func pathLess(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
}

private func candidateLess(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
    if lhs.byteCount != rhs.byteCount { return lhs.byteCount < rhs.byteCount }
    if lhs.side != rhs.side { return lhs.side.rawValue < rhs.side.rawValue }
    return pathLess(lhs.relativePath, rhs.relativePath)
}

private func digestKeyLess(_ lhs: DigestKey, _ rhs: DigestKey) -> Bool {
    if lhs.byteCount != rhs.byteCount { return lhs.byteCount < rhs.byteCount }
    return lhs.digest < rhs.digest
}

private func ambiguousGroupLess(
    _ lhs: FolderRenameAmbiguousGroup,
    _ rhs: FolderRenameAmbiguousGroup
) -> Bool {
    let leftLHS = lhs.leftRelativePaths.first ?? ""
    let leftRHS = rhs.leftRelativePaths.first ?? ""
    if leftLHS != leftRHS { return pathLess(leftLHS, leftRHS) }
    let rightLHS = lhs.rightRelativePaths.first ?? ""
    let rightRHS = rhs.rightRelativePaths.first ?? ""
    if rightLHS != rightRHS { return pathLess(rightLHS, rightRHS) }
    if lhs.byteCount != rhs.byteCount { return lhs.byteCount < rhs.byteCount }
    return lhs.digest < rhs.digest
}
