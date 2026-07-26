import CryptoKit
import Darwin
import Foundation

/// Stable prefix only; the two independent UUID components are generated
/// inside the descriptor-backed mover and the resulting leaf is never returned
/// or persisted in an operation journal.
let riffaCaseOnlyRenameTemporaryLeafPrefix = ".riffa-case-rename-"

let riffaExactDirectoryScanMaximumEntryCount = 100_000
let riffaExactDirectoryScanMaximumNameByteCount = 16 * 1_024 * 1_024

enum RiffaExactDirectoryScanError: Error, Equatable, Sendable {
    case unavailable
    case budgetExceeded
    case invalidNameEncoding
    case ambiguousNormalizedName
}

struct RiffaExactDirectoryScanBudget: Equatable, Sendable {
    let maximumEntryCount: Int
    let maximumNameByteCount: Int
    private(set) var entryCount = 0
    private(set) var nameByteCount = 0

    init(
        maximumEntryCount: Int = riffaExactDirectoryScanMaximumEntryCount,
        maximumNameByteCount: Int = riffaExactDirectoryScanMaximumNameByteCount
    ) {
        self.maximumEntryCount = maximumEntryCount
        self.maximumNameByteCount = maximumNameByteCount
    }

    mutating func consume(nameByteCount: Int) throws {
        guard nameByteCount >= 0 else { throw RiffaExactDirectoryScanError.budgetExceeded }
        let nextEntries = entryCount.addingReportingOverflow(1)
        let nextBytes = self.nameByteCount.addingReportingOverflow(nameByteCount)
        guard !nextEntries.overflow,
              !nextBytes.overflow,
              nextEntries.partialValue <= maximumEntryCount,
              nextBytes.partialValue <= maximumNameByteCount else {
            throw RiffaExactDirectoryScanError.budgetExceeded
        }
        entryCount = nextEntries.partialValue
        self.nameByteCount = nextBytes.partialValue
    }
}

/// Returns the actual directory spelling that canonically matches `requestedLeaf`.
/// The scan is finite and rejects malformed POSIX names rather than repairing
/// invalid UTF-8 into replacement characters that could create a false match.
func riffaExactDirectoryEntryName(
    parent: Int32,
    requestedLeaf: String
) throws -> String? {
    // `dup(parent)` would share the directory-stream offset with every later
    // scan. Once one readdir pass reached EOF, a second proof pass could then
    // falsely report the selected source as missing. Re-open "." below the
    // retained parent capability to get an independent open-file description
    // while remaining path-free and no-follow.
    let scanDescriptor = retrying {
        Darwin.openat(
            parent,
            ".",
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
    }
    guard scanDescriptor >= 0 else {
        throw RiffaExactDirectoryScanError.unavailable
    }
    guard let directory = Darwin.fdopendir(scanDescriptor) else {
        _ = Darwin.close(scanDescriptor)
        throw RiffaExactDirectoryScanError.unavailable
    }
    defer { _ = Darwin.closedir(directory) }

    let requested = requestedLeaf.precomposedStringWithCanonicalMapping
    var budget = RiffaExactDirectoryScanBudget()
    var match: String?
    errno = 0
    while let entry = Darwin.readdir(directory) {
        let length = Int(entry.pointee.d_namlen)
        try budget.consume(nameByteCount: length)
        let name: String? = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: max(length, 1)) {
                String(bytes: UnsafeBufferPointer(start: $0, count: length), encoding: .utf8)
            }
        }
        guard let name else { throw RiffaExactDirectoryScanError.invalidNameEncoding }
        if name == "." || name == ".." { continue }
        guard name.precomposedStringWithCanonicalMapping == requested else { continue }
        guard match == nil else { throw RiffaExactDirectoryScanError.ambiguousNormalizedName }
        match = name
    }
    guard errno == 0 else { throw RiffaExactDirectoryScanError.unavailable }
    return match
}

enum LocalVerifiedFileMoveCaseOnlyDestinationRelationship: Equatable, Sendable {
    case missingOnCaseSensitiveVolume
    case selectedSourceAliasOnCaseInsensitiveVolume
    case occupied
}

func classifyCaseOnlyDestinationRelationship(
    exactDestinationExists: Bool,
    lookupFound: Bool,
    lookupMatchesSelectedRegularFile: Bool
) -> LocalVerifiedFileMoveCaseOnlyDestinationRelationship {
    if exactDestinationExists { return .occupied }
    if !lookupFound { return .missingOnCaseSensitiveVolume }
    return lookupMatchesSelectedRegularFile
        ? .selectedSourceAliasOnCaseInsensitiveVolume
        : .occupied
}

/// The two directory capabilities used by a verified local move.
public enum LocalVerifiedFileMoveRoot: String, Codable, Sendable {
    case target
    case reference
}

/// A path-free label for an entry involved in a verified local move.
public enum LocalVerifiedFileMoveOperand: String, Codable, Sendable {
    case source
    case destination
    case reference
}

/// A caller-supplied proof shared by the source and reference files.
public struct LocalVerifiedFileMoveProof: Equatable, Codable, Sendable {
    public let expectedByteCount: UInt64
    public let expectedSHA256: String

    public init(expectedByteCount: UInt64, expectedSHA256: String) {
        self.expectedByteCount = expectedByteCount
        self.expectedSHA256 = expectedSHA256
    }
}

/// The exact ordinary-file version captured when a user explicitly authorizes
/// a local rename. Unlike a detected-match proof, this binds the later write to
/// one inode and one metadata/content version rather than to matching bytes
/// alone. It contains no path or file bytes and is safe to retain in a plan.
public struct LocalVerifiedFileMoveSourceSnapshot: Hashable, Codable, Sendable {
    public let deviceID: UInt64
    public let fileID: UInt64
    public let byteCount: UInt64
    public let permissions: UInt16
    public let flags: UInt32
    public let modificationSeconds: Int64
    public let modificationNanoseconds: Int64
    public let statusChangeSeconds: Int64
    public let statusChangeNanoseconds: Int64
    public let sha256: String

    public init(
        deviceID: UInt64,
        fileID: UInt64,
        byteCount: UInt64,
        permissions: UInt16,
        flags: UInt32,
        modificationSeconds: Int64,
        modificationNanoseconds: Int64,
        statusChangeSeconds: Int64,
        statusChangeNanoseconds: Int64,
        sha256: String
    ) {
        self.deviceID = deviceID
        self.fileID = fileID
        self.byteCount = byteCount
        self.permissions = permissions
        self.flags = flags
        self.modificationSeconds = modificationSeconds
        self.modificationNanoseconds = modificationNanoseconds
        self.statusChangeSeconds = statusChangeSeconds
        self.statusChangeNanoseconds = statusChangeNanoseconds
        self.sha256 = sha256
    }
}

/// Whether a move's reference is independent evidence or is intentionally a
/// second no-follow descriptor for the same explicitly selected source file.
public enum LocalVerifiedFileMoveReferenceBinding: String, Codable, Sendable {
    case independent
    case selectedSource
    /// The reference is the selected source, while the destination is the same
    /// normalized leaf with different letter case. Execution always uses a
    /// two-stage same-directory rename so case-sensitive and case-insensitive
    /// volumes share one fail-closed implementation.
    case selectedSourceCaseOnlyRename
}

public enum LocalVerifiedFileMoveLimitProblem: String, Error, Codable, Sendable {
    case maximumFileByteCountMustBePositive
    case maximumFileByteCountTooLarge
    case chunkByteCountMustBePositive
    case chunkByteCountTooLarge
    case maximumRelativePathUTF8ByteCountMustBePositive
    case maximumRelativePathUTF8ByteCountTooLarge
    case maximumRelativePathDepthMustBePositive
    case maximumRelativePathDepthTooLarge
}

/// Finite ceilings applied before and during every verification pass.
public struct LocalVerifiedFileMoveLimits: Equatable, Codable, Sendable {
    public static let standard = LocalVerifiedFileMoveLimits(
        uncheckedMaximumFileByteCount: 64 * 1_024 * 1_024 * 1_024,
        chunkByteCount: 1 * 1_024 * 1_024,
        maximumRelativePathUTF8ByteCount: 64 * 1_024,
        maximumRelativePathDepth: 1_024
    )

    public let maximumFileByteCount: UInt64
    public let chunkByteCount: Int
    public let maximumRelativePathUTF8ByteCount: Int
    public let maximumRelativePathDepth: Int

    public init(
        maximumFileByteCount: UInt64 = 64 * 1_024 * 1_024 * 1_024,
        chunkByteCount: Int = 1 * 1_024 * 1_024,
        maximumRelativePathUTF8ByteCount: Int = 64 * 1_024,
        maximumRelativePathDepth: Int = 1_024
    ) throws {
        guard maximumFileByteCount > 0 else {
            throw LocalVerifiedFileMoveLimitProblem.maximumFileByteCountMustBePositive
        }
        guard maximumFileByteCount <= UInt64(Int64.max) else {
            throw LocalVerifiedFileMoveLimitProblem.maximumFileByteCountTooLarge
        }
        guard chunkByteCount > 0 else {
            throw LocalVerifiedFileMoveLimitProblem.chunkByteCountMustBePositive
        }
        guard chunkByteCount <= Self.maximumAllowedChunkByteCount else {
            throw LocalVerifiedFileMoveLimitProblem.chunkByteCountTooLarge
        }
        guard maximumRelativePathUTF8ByteCount > 0 else {
            throw LocalVerifiedFileMoveLimitProblem.maximumRelativePathUTF8ByteCountMustBePositive
        }
        guard maximumRelativePathUTF8ByteCount <= Self.maximumAllowedRelativePathUTF8ByteCount else {
            throw LocalVerifiedFileMoveLimitProblem.maximumRelativePathUTF8ByteCountTooLarge
        }
        guard maximumRelativePathDepth > 0 else {
            throw LocalVerifiedFileMoveLimitProblem.maximumRelativePathDepthMustBePositive
        }
        guard maximumRelativePathDepth <= Self.maximumAllowedRelativePathDepth else {
            throw LocalVerifiedFileMoveLimitProblem.maximumRelativePathDepthTooLarge
        }
        self.init(
            uncheckedMaximumFileByteCount: maximumFileByteCount,
            chunkByteCount: chunkByteCount,
            maximumRelativePathUTF8ByteCount: maximumRelativePathUTF8ByteCount,
            maximumRelativePathDepth: maximumRelativePathDepth
        )
    }

    private init(
        uncheckedMaximumFileByteCount: UInt64,
        chunkByteCount: Int,
        maximumRelativePathUTF8ByteCount: Int,
        maximumRelativePathDepth: Int
    ) {
        maximumFileByteCount = uncheckedMaximumFileByteCount
        self.chunkByteCount = chunkByteCount
        self.maximumRelativePathUTF8ByteCount = maximumRelativePathUTF8ByteCount
        self.maximumRelativePathDepth = maximumRelativePathDepth
    }

    private enum CodingKeys: String, CodingKey {
        case maximumFileByteCount
        case chunkByteCount
        case maximumRelativePathUTF8ByteCount
        case maximumRelativePathDepth
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            maximumFileByteCount: values.decode(UInt64.self, forKey: .maximumFileByteCount),
            chunkByteCount: values.decode(Int.self, forKey: .chunkByteCount),
            maximumRelativePathUTF8ByteCount: values.decode(
                Int.self,
                forKey: .maximumRelativePathUTF8ByteCount
            ),
            maximumRelativePathDepth: values.decode(Int.self, forKey: .maximumRelativePathDepth)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(maximumFileByteCount, forKey: .maximumFileByteCount)
        try values.encode(chunkByteCount, forKey: .chunkByteCount)
        try values.encode(maximumRelativePathUTF8ByteCount, forKey: .maximumRelativePathUTF8ByteCount)
        try values.encode(maximumRelativePathDepth, forKey: .maximumRelativePathDepth)
    }

    private static let maximumAllowedChunkByteCount = 16 * 1_024 * 1_024
    private static let maximumAllowedRelativePathUTF8ByteCount = 1 * 1_024 * 1_024
    private static let maximumAllowedRelativePathDepth = 4_096
}

/// One ordinary-file move within `targetRoot`, authorized by an independently
/// opened file below `referenceRoot`. Paths are slash-separated and relative to
/// their corresponding roots; validation is deliberately deferred to execute.
public struct LocalVerifiedFileMoveRequest: Equatable, Codable, Sendable {
    public let targetRoot: URL
    public let sourceRelativePath: String
    public let destinationRelativePath: String
    public let referenceRoot: URL
    public let referenceRelativePath: String
    public let proof: LocalVerifiedFileMoveProof
    public let expectedSourceSnapshot: LocalVerifiedFileMoveSourceSnapshot?
    public let referenceBinding: LocalVerifiedFileMoveReferenceBinding
    public let allowsCrossDeviceFallback: Bool

    public init(
        targetRoot: URL,
        sourceRelativePath: String,
        destinationRelativePath: String,
        referenceRoot: URL,
        referenceRelativePath: String,
        proof: LocalVerifiedFileMoveProof,
        expectedSourceSnapshot: LocalVerifiedFileMoveSourceSnapshot? = nil,
        referenceBinding: LocalVerifiedFileMoveReferenceBinding = .independent,
        allowsCrossDeviceFallback: Bool = true
    ) {
        self.targetRoot = targetRoot
        self.sourceRelativePath = sourceRelativePath
        self.destinationRelativePath = destinationRelativePath
        self.referenceRoot = referenceRoot
        self.referenceRelativePath = referenceRelativePath
        self.proof = proof
        self.expectedSourceSnapshot = expectedSourceSnapshot
        self.referenceBinding = referenceBinding
        self.allowsCrossDeviceFallback = allowsCrossDeviceFallback
    }
}

public enum LocalVerifiedFileMoveStrategy: String, Codable, Sendable {
    case atomicRename
    case verifiedCopyThenDelete
}

/// A path-free receipt. It can be persisted without exposing either local root.
public struct LocalVerifiedFileMoveResult: Equatable, Codable, Sendable {
    public let strategy: LocalVerifiedFileMoveStrategy
    public let byteCount: UInt64
    public let sha256: String
    public let installedSourceSnapshot: LocalVerifiedFileMoveSourceSnapshot?

    public init(
        strategy: LocalVerifiedFileMoveStrategy,
        byteCount: UInt64,
        sha256: String,
        installedSourceSnapshot: LocalVerifiedFileMoveSourceSnapshot? = nil
    ) {
        self.strategy = strategy
        self.byteCount = byteCount
        self.sha256 = sha256
        self.installedSourceSnapshot = installedSourceSnapshot
    }
}

/// A read-only preflight receipt. It deliberately contains no locator.
public struct LocalVerifiedFileMoveVerification: Equatable, Codable, Sendable {
    public let byteCount: UInt64
    public let sha256: String

    public init(byteCount: UInt64, sha256: String) {
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

public enum LocalVerifiedFileMoveProofProblem: String, Codable, Sendable {
    case malformedSHA256
}

public enum LocalVerifiedFileMoveStage: String, Codable, Sendable {
    case openRoot
    case traverseParent
    case openLeaf
    case verification
    case rename
    case copy
    case install
    case sourceRemoval
    case durability
    case rollback
}

/// Stable failures intentionally omit URLs, absolute paths, relative paths,
/// temporary names, file contents, and operating-system prose.
public enum LocalVerifiedFileMoveError: Error, Equatable, Codable, Sendable {
    case invalidRoot(LocalVerifiedFileMoveRoot)
    case invalidRelativePath(LocalVerifiedFileMoveOperand)
    case sourceAndDestinationMustDiffer
    case invalidProof(LocalVerifiedFileMoveProofProblem)
    case relativePathTooLong(
        operand: LocalVerifiedFileMoveOperand,
        actualUTF8ByteCount: Int,
        limit: Int
    )
    case relativePathTooDeep(operand: LocalVerifiedFileMoveOperand, actualDepth: Int, limit: Int)
    case proofExceedsFileLimit(actualByteCount: UInt64, limit: UInt64)
    case fileTooLarge(operand: LocalVerifiedFileMoveOperand, actualByteCount: UInt64, limit: UInt64)
    case rootOpenFailed(root: LocalVerifiedFileMoveRoot, code: Int32)
    case parentOpenFailed(operand: LocalVerifiedFileMoveOperand, code: Int32)
    case missingFile(LocalVerifiedFileMoveOperand)
    case symbolicLinkNotAllowed(LocalVerifiedFileMoveOperand)
    case notRegularFile(LocalVerifiedFileMoveOperand)
    case destinationExists
    case proofMismatch(LocalVerifiedFileMoveOperand)
    case fileChanged(LocalVerifiedFileMoveOperand)
    case operationFailed(stage: LocalVerifiedFileMoveStage, code: Int32)
    case rollbackIncomplete(
        originalStage: LocalVerifiedFileMoveStage,
        originalCode: Int32,
        rollbackStage: LocalVerifiedFileMoveStage,
        rollbackCode: Int32
    )
}

extension LocalVerifiedFileMoveError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidRoot(root):
            "The \(root.rawValue) root must be an existing local directory."
        case let .invalidRelativePath(operand):
            "The \(operand.rawValue) path is not a strict relative path."
        case .sourceAndDestinationMustDiffer:
            "The source and destination paths must differ."
        case .invalidProof:
            "The verified-move proof is malformed."
        case let .relativePathTooLong(operand, actual, limit):
            "The \(operand.rawValue) path uses \(actual) UTF-8 bytes, exceeding the \(limit)-byte limit."
        case let .relativePathTooDeep(operand, actual, limit):
            "The \(operand.rawValue) path has depth \(actual), exceeding the depth limit of \(limit)."
        case let .proofExceedsFileLimit(actual, limit):
            "The proof expects \(actual) bytes, exceeding the \(limit)-byte file limit."
        case let .fileTooLarge(operand, actual, limit):
            "The \(operand.rawValue) file has \(actual) bytes, exceeding the \(limit)-byte file limit."
        case let .rootOpenFailed(root, code):
            "The \(root.rawValue) root could not be opened (error \(code))."
        case let .parentOpenFailed(operand, code):
            "The \(operand.rawValue) parent could not be opened safely (error \(code))."
        case let .missingFile(operand):
            "The \(operand.rawValue) file does not exist."
        case let .symbolicLinkNotAllowed(operand):
            "The \(operand.rawValue) entry is a symbolic link."
        case let .notRegularFile(operand):
            "The \(operand.rawValue) entry is not a regular file."
        case .destinationExists:
            "The destination already exists."
        case let .proofMismatch(operand):
            "The \(operand.rawValue) file does not match the supplied proof."
        case let .fileChanged(operand):
            "The \(operand.rawValue) file changed during verification."
        case let .operationFailed(stage, code):
            "The verified move failed during \(stage.rawValue) (error \(code))."
        case let .rollbackIncomplete(originalStage, originalCode, rollbackStage, rollbackCode):
            "The verified move failed during \(originalStage.rawValue) (error \(originalCode)), and recovery was incomplete during \(rollbackStage.rawValue) (error \(rollbackCode))."
        }
    }
}

/// Descriptor-backed, no-clobber movement of a verified ordinary file.
///
/// This primitive performs no journaling or policy decisions. Callers remain
/// responsible for authorization, plan-level conflict checks, and any durable
/// operation journal that surrounds the move.
public struct LocalVerifiedFileMove: Sendable {
    public let limits: LocalVerifiedFileMoveLimits

    public init(limits: LocalVerifiedFileMoveLimits = .standard) {
        self.limits = limits
    }

    /// Captures one stable, path-bound source version for an explicit user
    /// rename. Callers must still execute through `verify`/`execute`; this
    /// receipt is authorization evidence, not a capability or a completed
    /// preflight.
    public func captureSourceSnapshot(
        root: URL,
        relativePath: String
    ) async throws -> LocalVerifiedFileMoveSourceSnapshot {
        do {
            guard isUsableRootURL(root) else {
                throw MoveAttemptFailure.publicFailure(
                    .invalidRoot(.target),
                    stage: .openRoot,
                    code: EINVAL
                )
            }
            guard Self.isStrictRelativePath(relativePath) else {
                throw MoveAttemptFailure.publicFailure(
                    .invalidRelativePath(.source),
                    stage: .traverseParent,
                    code: EINVAL
                )
            }
            try validatePathBudget(relativePath, operand: .source)
            try checkCancellation(stage: .openRoot)

            let openedRoot = try openRoot(root, role: .target)
            let path = PathComponents(relativePath)
            let parent = try openParent(
                below: openedRoot.descriptor,
                components: path.parents,
                operand: .source
            )
            let source = try openOrdinaryFile(
                parent: parent.descriptor,
                leaf: path.leaf,
                operand: .source
            )
            let verification = try await hashStable(
                source,
                parent: parent.descriptor,
                leaf: path.leaf,
                operand: .source
            )
            try verifyRootStillIdentifies(root, descriptor: openedRoot.descriptor, role: .target)
            try verifyParentStillIdentifies(
                root: openedRoot.descriptor,
                components: path.parents,
                expected: parent.descriptor,
                operand: .source
            )
            return verification.snapshot
        } catch let failure as MoveAttemptFailure {
            try failure.raisePublicError()
        }
    }

    public func verify(
        _ request: LocalVerifiedFileMoveRequest
    ) async throws -> LocalVerifiedFileMoveVerification {
        do {
            let prepared = try await prepare(request)
            return LocalVerifiedFileMoveVerification(
                byteCount: prepared.sourceVerification.byteCount,
                sha256: prepared.sourceVerification.sha256
            )
        } catch let failure as MoveAttemptFailure {
            try failure.raisePublicError()
        }
    }

    public func execute(
        _ request: LocalVerifiedFileMoveRequest
    ) async throws -> LocalVerifiedFileMoveResult {
        do {
            return try await executeInternal(request)
        } catch let failure as MoveAttemptFailure {
            try failure.raisePublicError()
        }
    }

    private func executeInternal(
        _ request: LocalVerifiedFileMoveRequest
    ) async throws -> LocalVerifiedFileMoveResult {
        let prepared = try await prepare(request)

        // Execute never trusts an earlier preflight receipt. It opens and
        // hashes again, then narrows the final proof-to-commit interval here.
        try requireDescriptorVersion(
            prepared.source.descriptor,
            equals: prepared.sourceVerification.version,
            operand: .source
        )
        try requireDescriptorVersion(
            prepared.reference.descriptor,
            equals: prepared.referenceVerification.version,
            operand: .reference
        )
        try verifyNameStillIdentifies(
            parent: prepared.sourceParent.descriptor,
            leaf: prepared.sourceLeaf,
            expected: prepared.sourceVerification.version,
            operand: .source
        )
        try verifyNameStillIdentifies(
            parent: prepared.referenceParent.descriptor,
            leaf: prepared.referenceLeaf,
            expected: prepared.referenceVerification.version,
            operand: .reference
        )
        try requireDestinationReady(
            prepared,
            request: request
        )

        let renameResult: Int32
        let renameCheckpoint = try checkpoint(.beforeRename, stage: .rename)
        // The checkpoint is intentionally before the last binding pass so a
        // root/parent/source/target race at the proof-to-commit boundary is
        // observed and refused rather than applied through a stale descriptor.
        try verifyPreparedBindings(prepared, request: request)
        if request.referenceBinding == .selectedSourceCaseOnlyRename {
            return try await completeCaseOnlyRename(
                prepared,
                request: request,
                initialCheckpoint: renameCheckpoint
            )
        }
        switch renameCheckpoint {
        case .forceCrossDevice:
            renameResult = -1
            errno = EXDEV
        default:
            renameResult = exclusiveRename(
                fromParent: prepared.sourceParent.descriptor,
                from: prepared.sourceLeaf,
                toParent: prepared.destinationParent.descriptor,
                to: prepared.destinationLeaf
            )
        }

        if renameResult == 0 {
            return try await completeAtomicRename(
                source: prepared.source,
                sourceVersion: prepared.sourceVerification.version,
                sourceParent: prepared.sourceParent.descriptor,
                sourceLeaf: prepared.sourceLeaf,
                destinationParent: prepared.destinationParent.descriptor,
                destinationLeaf: prepared.destinationLeaf,
                proof: request.proof
            )
        }

        let renameError = errno
        if renameError == EEXIST {
            throw MoveAttemptFailure.publicFailure(.destinationExists, stage: .rename, code: EEXIST)
        }
        guard renameError == EXDEV else {
            throw MoveAttemptFailure.system(stage: .rename, code: renameError)
        }
        guard request.allowsCrossDeviceFallback else {
            throw MoveAttemptFailure.system(stage: .rename, code: EXDEV)
        }

        return try await copyThenDelete(
            source: prepared.source,
            sourceVersion: prepared.sourceVerification.version,
            sourceParent: prepared.sourceParent.descriptor,
            sourceLeaf: prepared.sourceLeaf,
            reference: prepared.reference,
            referenceVersion: prepared.referenceVerification.version,
            referenceParent: prepared.referenceParent.descriptor,
            referenceLeaf: prepared.referenceLeaf,
            destinationParent: prepared.destinationParent.descriptor,
            destinationLeaf: prepared.destinationLeaf,
            proof: request.proof
        )
    }

    private func prepare(
        _ request: LocalVerifiedFileMoveRequest
    ) async throws -> PreparedMove {
        try validate(request)
        try checkCancellation(stage: .openRoot)

        let targetRoot = try openRoot(request.targetRoot, role: .target)
        let referenceRoot = try openRoot(request.referenceRoot, role: .reference)

        let sourcePath = PathComponents(request.sourceRelativePath)
        let destinationPath = PathComponents(request.destinationRelativePath)
        let referencePath = PathComponents(request.referenceRelativePath)

        let sourceParent = try openParent(
            below: targetRoot.descriptor,
            components: sourcePath.parents,
            operand: .source
        )
        let destinationParent = try openParent(
            below: targetRoot.descriptor,
            components: destinationPath.parents,
            operand: .destination
        )
        let referenceParent = try openParent(
            below: referenceRoot.descriptor,
            components: referencePath.parents,
            operand: .reference
        )

        let source = try openOrdinaryFile(
            parent: sourceParent.descriptor,
            leaf: sourcePath.leaf,
            operand: .source
        )
        let reference = try openOrdinaryFile(
            parent: referenceParent.descriptor,
            leaf: referencePath.leaf,
            operand: .reference
        )
        try requireDestinationReady(
            sourceParent: sourceParent.descriptor,
            sourceLeaf: sourcePath.leaf,
            sourceVersion: try inspect(source.descriptor, stage: .verification),
            destinationParent: destinationParent.descriptor,
            destinationLeaf: destinationPath.leaf,
            request: request
        )

        let sourceVerification = try await hashStable(
            source,
            parent: sourceParent.descriptor,
            leaf: sourcePath.leaf,
            operand: .source
        )
        let referenceVerification = try await hashStable(
            reference,
            parent: referenceParent.descriptor,
            leaf: referencePath.leaf,
            operand: .reference
        )

        try requireProof(request.proof, verification: sourceVerification, operand: .source)
        try requireProof(request.proof, verification: referenceVerification, operand: .reference)
        if let expectedSourceSnapshot = request.expectedSourceSnapshot {
            guard expectedSourceSnapshot == sourceVerification.snapshot else {
                throw MoveAttemptFailure.publicFailure(
                    .fileChanged(.source),
                    stage: .verification,
                    code: ESTALE
                )
            }
        }
        try verifyNameStillIdentifies(
            parent: sourceParent.descriptor,
            leaf: sourcePath.leaf,
            expected: sourceVerification.version,
            operand: .source
        )
        try verifyNameStillIdentifies(
            parent: referenceParent.descriptor,
            leaf: referencePath.leaf,
            expected: referenceVerification.version,
            operand: .reference
        )
        try requireDestinationReady(
            sourceParent: sourceParent.descriptor,
            sourceLeaf: sourcePath.leaf,
            sourceVersion: sourceVerification.version,
            destinationParent: destinationParent.descriptor,
            destinationLeaf: destinationPath.leaf,
            request: request
        )
        try verifyRootStillIdentifies(
            request.targetRoot,
            descriptor: targetRoot.descriptor,
            role: .target
        )
        try verifyRootStillIdentifies(
            request.referenceRoot,
            descriptor: referenceRoot.descriptor,
            role: .reference
        )
        try verifyParentStillIdentifies(
            root: targetRoot.descriptor,
            components: sourcePath.parents,
            expected: sourceParent.descriptor,
            operand: .source
        )
        try verifyParentStillIdentifies(
            root: targetRoot.descriptor,
            components: destinationPath.parents,
            expected: destinationParent.descriptor,
            operand: .destination
        )
        try verifyParentStillIdentifies(
            root: referenceRoot.descriptor,
            components: referencePath.parents,
            expected: referenceParent.descriptor,
            operand: .reference
        )

        return PreparedMove(
            targetRoot: targetRoot,
            referenceRoot: referenceRoot,
            source: source,
            reference: reference,
            sourceParent: sourceParent,
            destinationParent: destinationParent,
            referenceParent: referenceParent,
            sourceLeaf: sourcePath.leaf,
            destinationLeaf: destinationPath.leaf,
            referenceLeaf: referencePath.leaf,
            sourceVerification: sourceVerification,
            referenceVerification: referenceVerification
        )
    }
}

// MARK: - Validation and descriptor acquisition

private extension LocalVerifiedFileMove {
    func validate(_ request: LocalVerifiedFileMoveRequest) throws {
        guard isUsableRootURL(request.targetRoot) else {
            throw MoveAttemptFailure.publicFailure(.invalidRoot(.target), stage: .openRoot, code: EINVAL)
        }
        guard isUsableRootURL(request.referenceRoot) else {
            throw MoveAttemptFailure.publicFailure(.invalidRoot(.reference), stage: .openRoot, code: EINVAL)
        }
        guard Self.isStrictRelativePath(request.sourceRelativePath) else {
            throw MoveAttemptFailure.publicFailure(
                .invalidRelativePath(.source),
                stage: .traverseParent,
                code: EINVAL
            )
        }
        guard Self.isStrictRelativePath(request.destinationRelativePath) else {
            throw MoveAttemptFailure.publicFailure(
                .invalidRelativePath(.destination),
                stage: .traverseParent,
                code: EINVAL
            )
        }
        guard Self.isStrictRelativePath(request.referenceRelativePath) else {
            throw MoveAttemptFailure.publicFailure(
                .invalidRelativePath(.reference),
                stage: .traverseParent,
                code: EINVAL
            )
        }
        try validatePathBudget(request.sourceRelativePath, operand: .source)
        try validatePathBudget(request.destinationRelativePath, operand: .destination)
        try validatePathBudget(request.referenceRelativePath, operand: .reference)
        guard request.sourceRelativePath != request.destinationRelativePath else {
            throw MoveAttemptFailure.publicFailure(
                .sourceAndDestinationMustDiffer,
                stage: .verification,
                code: EINVAL
            )
        }
        switch request.referenceBinding {
        case .independent:
            break
        case .selectedSource, .selectedSourceCaseOnlyRename:
            guard request.targetRoot.standardizedFileURL == request.referenceRoot.standardizedFileURL,
                  request.sourceRelativePath == request.referenceRelativePath,
                  request.expectedSourceSnapshot != nil,
                  !request.allowsCrossDeviceFallback,
                  Self.parentPath(of: request.sourceRelativePath)
                    == Self.parentPath(of: request.destinationRelativePath) else {
                throw MoveAttemptFailure.publicFailure(
                    .invalidRelativePath(.reference),
                    stage: .verification,
                    code: EINVAL
                )
            }
            if request.referenceBinding == .selectedSourceCaseOnlyRename {
                let source = request.sourceRelativePath.precomposedStringWithCanonicalMapping
                let destination = request.destinationRelativePath.precomposedStringWithCanonicalMapping
                guard source != destination,
                      Self.caseFoldKey(source) == Self.caseFoldKey(destination) else {
                    throw MoveAttemptFailure.publicFailure(
                        .invalidRelativePath(.destination),
                        stage: .verification,
                        code: EINVAL
                    )
                }
            }
        }
        guard Self.isLowercaseSHA256(request.proof.expectedSHA256) else {
            throw MoveAttemptFailure.publicFailure(
                .invalidProof(.malformedSHA256),
                stage: .verification,
                code: EINVAL
            )
        }
        guard request.proof.expectedByteCount <= limits.maximumFileByteCount else {
            throw MoveAttemptFailure.publicFailure(
                .proofExceedsFileLimit(
                    actualByteCount: request.proof.expectedByteCount,
                    limit: limits.maximumFileByteCount
                ),
                stage: .verification,
                code: EFBIG
            )
        }
    }

    func validatePathBudget(_ path: String, operand: LocalVerifiedFileMoveOperand) throws {
        let byteCount = path.utf8.count
        guard byteCount <= limits.maximumRelativePathUTF8ByteCount else {
            throw MoveAttemptFailure.publicFailure(
                .relativePathTooLong(
                    operand: operand,
                    actualUTF8ByteCount: byteCount,
                    limit: limits.maximumRelativePathUTF8ByteCount
                ),
                stage: .traverseParent,
                code: ENAMETOOLONG
            )
        }
        let depth = path.split(separator: "/", omittingEmptySubsequences: false).count
        guard depth <= limits.maximumRelativePathDepth else {
            throw MoveAttemptFailure.publicFailure(
                .relativePathTooDeep(
                    operand: operand,
                    actualDepth: depth,
                    limit: limits.maximumRelativePathDepth
                ),
                stage: .traverseParent,
                code: ENAMETOOLONG
            )
        }
    }

    func isUsableRootURL(_ url: URL) -> Bool {
        url.isFileURL && url.path.hasPrefix("/") && !url.path.isEmpty && !url.path.contains("\0")
    }

    static func isStrictRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.hasSuffix("/"),
              !path.contains("\0") else {
            return false
        }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= Character("0").asciiValue! && $0 <= Character("9").asciiValue!) ||
                ($0 >= Character("a").asciiValue! && $0 <= Character("f").asciiValue!)
        }
    }

    static func parentPath(of path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .dropLast()
            .joined(separator: "/")
    }

    static func caseFoldKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    func openRoot(_ url: URL, role: LocalVerifiedFileMoveRoot) throws -> OwnedDescriptor {
        let descriptor = url.path.withCString { path in
            retrying {
                Darwin.open(path, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW_ANY)
            }
        }
        guard descriptor >= 0 else {
            throw MoveAttemptFailure.publicFailure(
                .rootOpenFailed(root: role, code: errno),
                stage: .openRoot,
                code: errno
            )
        }
        let owned = OwnedDescriptor(descriptor)
        var status = stat()
        guard retrying({ Darwin.fstat(descriptor, &status) }) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            let code = errno == 0 ? ENOTDIR : errno
            throw MoveAttemptFailure.publicFailure(
                .rootOpenFailed(root: role, code: code),
                stage: .openRoot,
                code: code
            )
        }
        return owned
    }

    func openParent(
        below root: Int32,
        components: ArraySlice<String>,
        operand: LocalVerifiedFileMoveOperand
    ) throws -> OwnedDescriptor {
        let rootCopy = ".".withCString { dot in
            retrying {
                Darwin.openat(root, dot, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
            }
        }
        guard rootCopy >= 0 else {
            throw MoveAttemptFailure.publicFailure(
                .parentOpenFailed(operand: operand, code: errno),
                stage: .traverseParent,
                code: errno
            )
        }
        var current = OwnedDescriptor(rootCopy)

        for component in components {
            try checkCancellation(stage: .traverseParent)
            let next = component.withCString { name in
                retrying {
                    Darwin.openat(
                        current.descriptor,
                        name,
                        O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
                    )
                }
            }
            guard next >= 0 else {
                throw MoveAttemptFailure.publicFailure(
                    .parentOpenFailed(operand: operand, code: errno),
                    stage: .traverseParent,
                    code: errno
                )
            }
            current = OwnedDescriptor(next)
        }
        return current
    }

    func openOrdinaryFile(
        parent: Int32,
        leaf: String,
        operand: LocalVerifiedFileMoveOperand
    ) throws -> OpenedOrdinaryFile {
        var nameStatus = stat()
        let inspection = leaf.withCString {
            Darwin.fstatat(parent, $0, &nameStatus, AT_SYMLINK_NOFOLLOW)
        }
        guard inspection == 0 else {
            let code = errno
            if code == ENOENT {
                throw MoveAttemptFailure.publicFailure(.missingFile(operand), stage: .openLeaf, code: code)
            }
            throw MoveAttemptFailure.system(stage: .openLeaf, code: code)
        }

        let nameKind = nameStatus.st_mode & mode_t(S_IFMT)
        if nameKind == mode_t(S_IFLNK) {
            throw MoveAttemptFailure.publicFailure(
                .symbolicLinkNotAllowed(operand),
                stage: .openLeaf,
                code: ELOOP
            )
        }
        guard nameKind == mode_t(S_IFREG) else {
            throw MoveAttemptFailure.publicFailure(
                .notRegularFile(operand),
                stage: .openLeaf,
                code: EFTYPE
            )
        }

        let descriptor = leaf.withCString { name in
            retrying {
                Darwin.openat(parent, name, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW)
            }
        }
        guard descriptor >= 0 else {
            let code = errno
            if code == ELOOP {
                throw MoveAttemptFailure.publicFailure(
                    .symbolicLinkNotAllowed(operand),
                    stage: .openLeaf,
                    code: code
                )
            }
            if code == ENOENT {
                throw MoveAttemptFailure.publicFailure(.fileChanged(operand), stage: .openLeaf, code: ESTALE)
            }
            throw MoveAttemptFailure.system(stage: .openLeaf, code: code)
        }

        let file = OpenedOrdinaryFile(descriptor)
        let openedVersion = try inspect(descriptor, stage: .openLeaf)
        guard openedVersion.isRegular,
              openedVersion.sameIdentity(as: FileVersion(nameStatus)) else {
            throw MoveAttemptFailure.publicFailure(.fileChanged(operand), stage: .openLeaf, code: ESTALE)
        }
        return file
    }

    func requireDestinationMissing(parent: Int32, leaf: String) throws {
        var status = stat()
        let result = leaf.withCString {
            Darwin.fstatat(parent, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        if result == 0 {
            throw MoveAttemptFailure.publicFailure(.destinationExists, stage: .verification, code: EEXIST)
        }
        let code = errno
        guard code == ENOENT else {
            throw MoveAttemptFailure.system(stage: .verification, code: code)
        }
    }

    func verifyRootStillIdentifies(
        _ url: URL,
        descriptor: Int32,
        role: LocalVerifiedFileMoveRoot
    ) throws {
        let reopened = try openRoot(url, role: role)
        guard try directoryIdentity(reopened.descriptor)
            == directoryIdentity(descriptor) else {
            throw MoveAttemptFailure.system(stage: .verification, code: ESTALE)
        }
    }

    func verifyParentStillIdentifies(
        root: Int32,
        components: ArraySlice<String>,
        expected: Int32,
        operand: LocalVerifiedFileMoveOperand
    ) throws {
        let reopened = try openParent(
            below: root,
            components: components,
            operand: operand
        )
        guard try directoryIdentity(reopened.descriptor)
            == directoryIdentity(expected) else {
            throw MoveAttemptFailure.publicFailure(
                .fileChanged(operand),
                stage: .verification,
                code: ESTALE
            )
        }
    }

    func directoryIdentity(_ descriptor: Int32) throws -> DescriptorIdentity {
        var status = stat()
        guard retrying({ Darwin.fstat(descriptor, &status) }) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw MoveAttemptFailure.system(
                stage: .verification,
                code: errno == 0 ? ENOTDIR : errno
            )
        }
        return DescriptorIdentity(status)
    }
}

// MARK: - Proof verification

private extension LocalVerifiedFileMove {
    func requireDestinationReady(
        _ prepared: PreparedMove,
        request: LocalVerifiedFileMoveRequest
    ) throws {
        try requireDestinationReady(
            sourceParent: prepared.sourceParent.descriptor,
            sourceLeaf: prepared.sourceLeaf,
            sourceVersion: prepared.sourceVerification.version,
            destinationParent: prepared.destinationParent.descriptor,
            destinationLeaf: prepared.destinationLeaf,
            request: request
        )
    }

    func requireDestinationReady(
        sourceParent: Int32,
        sourceLeaf: String,
        sourceVersion: FileVersion,
        destinationParent: Int32,
        destinationLeaf: String,
        request: LocalVerifiedFileMoveRequest
    ) throws {
        guard request.referenceBinding == .selectedSourceCaseOnlyRename else {
            try requireDestinationMissing(parent: destinationParent, leaf: destinationLeaf)
            return
        }

        guard try directoryIdentity(sourceParent) == directoryIdentity(destinationParent) else {
            throw MoveAttemptFailure.publicFailure(
                .fileChanged(.destination),
                stage: .verification,
                code: ESTALE
            )
        }
        try requireExactNameIdentifies(
            parent: sourceParent,
            leaf: sourceLeaf,
            expected: sourceVersion,
            operand: .source,
            stage: .verification
        )

        // An exact destination spelling always denotes an occupied directory
        // entry, even when it happens to be a hard link to the selected inode.
        // Only an absent exact spelling may be either ENOENT (case-sensitive
        // volume) or a lookup alias for the selected source (case-insensitive).
        let exactDestinationExists = try exactDirectoryEntryName(
            parent: destinationParent,
            requestedLeaf: destinationLeaf,
            stage: .verification
        ) != nil

        var aliased = stat()
        let lookup = destinationLeaf.withCString {
            Darwin.fstatat(destinationParent, $0, &aliased, AT_SYMLINK_NOFOLLOW)
        }
        let lookupCode = errno
        if lookup < 0, lookupCode != ENOENT {
            throw MoveAttemptFailure.system(stage: .verification, code: lookupCode)
        }
        let lookupMatchesSelectedRegularFile: Bool
        if lookup == 0 {
            let aliasVersion = FileVersion(aliased)
            lookupMatchesSelectedRegularFile = aliasVersion == sourceVersion
                && aliasVersion.isRegular
        } else {
            lookupMatchesSelectedRegularFile = false
        }
        switch classifyCaseOnlyDestinationRelationship(
            exactDestinationExists: exactDestinationExists,
            lookupFound: lookup == 0,
            lookupMatchesSelectedRegularFile: lookupMatchesSelectedRegularFile
        ) {
        case .missingOnCaseSensitiveVolume,
             .selectedSourceAliasOnCaseInsensitiveVolume:
            return
        case .occupied:
            throw MoveAttemptFailure.publicFailure(
                .destinationExists,
                stage: .verification,
                code: EEXIST
            )
        }
    }

    func verifyPreparedBindings(
        _ prepared: PreparedMove,
        request: LocalVerifiedFileMoveRequest
    ) throws {
        let sourcePath = PathComponents(request.sourceRelativePath)
        let destinationPath = PathComponents(request.destinationRelativePath)
        let referencePath = PathComponents(request.referenceRelativePath)

        try verifyRootStillIdentifies(
            request.targetRoot,
            descriptor: prepared.targetRoot.descriptor,
            role: .target
        )
        try verifyRootStillIdentifies(
            request.referenceRoot,
            descriptor: prepared.referenceRoot.descriptor,
            role: .reference
        )
        try verifyParentStillIdentifies(
            root: prepared.targetRoot.descriptor,
            components: sourcePath.parents,
            expected: prepared.sourceParent.descriptor,
            operand: .source
        )
        try verifyParentStillIdentifies(
            root: prepared.targetRoot.descriptor,
            components: destinationPath.parents,
            expected: prepared.destinationParent.descriptor,
            operand: .destination
        )
        try verifyParentStillIdentifies(
            root: prepared.referenceRoot.descriptor,
            components: referencePath.parents,
            expected: prepared.referenceParent.descriptor,
            operand: .reference
        )
        try requireDescriptorVersion(
            prepared.source.descriptor,
            equals: prepared.sourceVerification.version,
            operand: .source
        )
        try requireDescriptorVersion(
            prepared.reference.descriptor,
            equals: prepared.referenceVerification.version,
            operand: .reference
        )
        try verifyNameStillIdentifies(
            parent: prepared.sourceParent.descriptor,
            leaf: prepared.sourceLeaf,
            expected: prepared.sourceVerification.version,
            operand: .source
        )
        try verifyNameStillIdentifies(
            parent: prepared.referenceParent.descriptor,
            leaf: prepared.referenceLeaf,
            expected: prepared.referenceVerification.version,
            operand: .reference
        )
        try requireDestinationReady(prepared, request: request)
    }

    func hashStable(
        _ file: OpenedOrdinaryFile,
        parent: Int32,
        leaf: String,
        operand: LocalVerifiedFileMoveOperand
    ) async throws -> HashedFile {
        let before = try inspect(file.descriptor, stage: .verification)
        guard before.isRegular else {
            throw MoveAttemptFailure.publicFailure(.notRegularFile(operand), stage: .verification, code: EFTYPE)
        }
        guard before.byteCount <= limits.maximumFileByteCount else {
            throw MoveAttemptFailure.publicFailure(
                .fileTooLarge(
                    operand: operand,
                    actualByteCount: before.byteCount,
                    limit: limits.maximumFileByteCount
                ),
                stage: .verification,
                code: EFBIG
            )
        }
        guard retrying({ Darwin.lseek(file.descriptor, 0, SEEK_SET) }) >= 0 else {
            throw MoveAttemptFailure.system(stage: .verification, code: errno)
        }

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: limits.chunkByteCount)
        var byteCount: UInt64 = 0
        while true {
            try checkCancellation(stage: .verification)
            let count: Int = buffer.withUnsafeMutableBytes { bytes in
                retrying { Darwin.read(file.descriptor, bytes.baseAddress, bytes.count) }
            }
            guard count >= 0 else {
                throw MoveAttemptFailure.system(stage: .verification, code: errno)
            }
            if count == 0 { break }

            let addition = byteCount.addingReportingOverflow(UInt64(count))
            guard !addition.overflow else {
                throw MoveAttemptFailure.publicFailure(.fileChanged(operand), stage: .verification, code: EOVERFLOW)
            }
            byteCount = addition.partialValue
            guard byteCount <= limits.maximumFileByteCount else {
                throw MoveAttemptFailure.publicFailure(
                    .fileTooLarge(
                        operand: operand,
                        actualByteCount: byteCount,
                        limit: limits.maximumFileByteCount
                    ),
                    stage: .verification,
                    code: EFBIG
                )
            }
            buffer.withUnsafeBytes {
                hasher.update(data: Data(bytes: $0.baseAddress!, count: count))
            }
            _ = try checkpoint(.hashing(operand: operand, byteCount: byteCount), stage: .verification)
            await Task.yield()
        }

        let after = try inspect(file.descriptor, stage: .verification)
        guard before == after,
              after.byteCount == byteCount else {
            throw MoveAttemptFailure.publicFailure(.fileChanged(operand), stage: .verification, code: ESTALE)
        }
        try verifyNameStillIdentifies(
            parent: parent,
            leaf: leaf,
            expected: after,
            operand: operand
        )

        return HashedFile(
            version: after,
            byteCount: byteCount,
            sha256: Self.hex(hasher.finalize())
        )
    }

    func requireProof(
        _ proof: LocalVerifiedFileMoveProof,
        verification: HashedFile,
        operand: LocalVerifiedFileMoveOperand
    ) throws {
        guard proof.expectedByteCount == verification.byteCount,
              proof.expectedSHA256 == verification.sha256 else {
            throw MoveAttemptFailure.publicFailure(.proofMismatch(operand), stage: .verification, code: EBADMSG)
        }
    }

    func verifyNameStillIdentifies(
        parent: Int32,
        leaf: String,
        expected: FileVersion,
        operand: LocalVerifiedFileMoveOperand
    ) throws {
        var current = stat()
        let result = leaf.withCString {
            Darwin.fstatat(parent, $0, &current, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0,
              FileVersion(current) == expected else {
            throw MoveAttemptFailure.publicFailure(.fileChanged(operand), stage: .verification, code: ESTALE)
        }
    }

    func requireExactNameIdentifies(
        parent: Int32,
        leaf: String,
        expected: FileVersion,
        operand: LocalVerifiedFileMoveOperand,
        stage: LocalVerifiedFileMoveStage
    ) throws {
        guard let actualName = try exactDirectoryEntryName(
            parent: parent,
            requestedLeaf: leaf,
            stage: stage
        ) else {
            throw MoveAttemptFailure.publicFailure(.fileChanged(operand), stage: stage, code: ESTALE)
        }
        var current = stat()
        let result = actualName.withCString {
            Darwin.fstatat(parent, $0, &current, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0,
              FileVersion(current) == expected else {
            throw MoveAttemptFailure.publicFailure(.fileChanged(operand), stage: stage, code: ESTALE)
        }
    }

    func requireExactNameMissing(
        parent: Int32,
        leaf: String,
        stage: LocalVerifiedFileMoveStage
    ) throws {
        guard try exactDirectoryEntryName(
            parent: parent,
            requestedLeaf: leaf,
            stage: stage
        ) == nil else {
            throw MoveAttemptFailure.system(stage: stage, code: EEXIST)
        }
    }

    /// Enumerates an already opened parent so exact spelling remains distinct
    /// from a case-insensitive lookup alias. Canonically equivalent Unicode
    /// spellings compare equal because macOS filesystems may return decomposed
    /// names even when callers supplied precomposed text.
    func exactDirectoryEntryName(
        parent: Int32,
        requestedLeaf: String,
        stage: LocalVerifiedFileMoveStage
    ) throws -> String? {
        do {
            return try riffaExactDirectoryEntryName(
                parent: parent,
                requestedLeaf: requestedLeaf
            )
        } catch let error as RiffaExactDirectoryScanError {
            let code: Int32 = switch error {
            case .budgetExceeded: E2BIG
            case .invalidNameEncoding: EILSEQ
            case .ambiguousNormalizedName: ESTALE
            case .unavailable: EIO
            }
            throw MoveAttemptFailure.system(stage: stage, code: code)
        } catch {
            throw MoveAttemptFailure.system(stage: stage, code: EIO)
        }
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Case-only same-directory rename

private extension LocalVerifiedFileMove {
    func completeCaseOnlyRename(
        _ prepared: PreparedMove,
        request: LocalVerifiedFileMoveRequest,
        initialCheckpoint: LocalVerifiedFileMoveFaultAction
    ) async throws -> LocalVerifiedFileMoveResult {
        guard initialCheckpoint != .forceCrossDevice else {
            throw MoveAttemptFailure.system(stage: .rename, code: EXDEV)
        }

        var state = CaseOnlyRenameState.source
        do {
            let temporaryLeaf = try installCaseOnlyTemporary(
                prepared,
                request: request
            )
            state = .temporary(temporaryLeaf)
            try syncDirectory(prepared.sourceParent.descriptor)
            try verifyCaseOnlyTemporaryState(
                prepared,
                request: request,
                temporaryLeaf: temporaryLeaf,
                stage: .verification
            )

            _ = try checkpoint(.afterCaseOnlyTemporaryInstall, stage: .install)
            _ = try checkpoint(.beforeCaseOnlyFinalRename, stage: .rename)
            try verifyCaseOnlyTemporaryState(
                prepared,
                request: request,
                temporaryLeaf: temporaryLeaf,
                stage: .verification
            )

            let install = exclusiveRename(
                fromParent: prepared.sourceParent.descriptor,
                from: temporaryLeaf,
                toParent: prepared.destinationParent.descriptor,
                to: prepared.destinationLeaf
            )
            guard install == 0 else {
                let code = errno
                if code == EEXIST {
                    throw MoveAttemptFailure.publicFailure(
                        .destinationExists,
                        stage: .rename,
                        code: code
                    )
                }
                throw MoveAttemptFailure.system(stage: .rename, code: code)
            }
            state = .destination(temporaryLeaf)

            let installed = try verifyCaseOnlyDestinationState(
                prepared,
                request: request,
                temporaryLeaf: temporaryLeaf,
                stage: .verification
            )
            _ = try checkpoint(.afterInstall, stage: .install)
            try syncDirectory(prepared.destinationParent.descriptor)
            let durable = try verifyCaseOnlyDestinationState(
                prepared,
                request: request,
                temporaryLeaf: temporaryLeaf,
                stage: .verification
            )
            guard durable.sameMoveStableFields(as: installed) else {
                throw MoveAttemptFailure.publicFailure(
                    .fileChanged(.destination),
                    stage: .verification,
                    code: ESTALE
                )
            }
            try checkCancellation(stage: .durability)
            return LocalVerifiedFileMoveResult(
                strategy: .atomicRename,
                byteCount: request.proof.expectedByteCount,
                sha256: request.proof.expectedSHA256,
                installedSourceSnapshot: durable.snapshot(
                    sha256: request.proof.expectedSHA256
                )
            )
        } catch let original as MoveAttemptFailure {
            switch state {
            case .source:
                throw original
            case .temporary, .destination:
                do {
                    try rollbackCaseOnlyRename(
                        state: state,
                        prepared: prepared
                    )
                } catch let rollback as MoveAttemptFailure {
                    throw MoveAttemptFailure.rollbackIncomplete(
                        original: original,
                        rollback: rollback
                    )
                }
                throw original
            }
        }
    }

    func installCaseOnlyTemporary(
        _ prepared: PreparedMove,
        request: LocalVerifiedFileMoveRequest
    ) throws -> String {
        for _ in 0..<64 {
            try requireDestinationReady(prepared, request: request)
            let current = try verifyCaseOnlyOpenCapabilities(
                prepared,
                request: request,
                stage: .verification
            )
            try requireExactNameIdentifies(
                parent: prepared.sourceParent.descriptor,
                leaf: prepared.sourceLeaf,
                expected: current,
                operand: .source,
                stage: .verification
            )

            let temporaryLeaf = riffaCaseOnlyRenameTemporaryLeafPrefix
                + UUID().uuidString.lowercased()
                + UUID().uuidString.lowercased()
            let result = exclusiveRename(
                fromParent: prepared.sourceParent.descriptor,
                from: prepared.sourceLeaf,
                toParent: prepared.sourceParent.descriptor,
                to: temporaryLeaf
            )
            if result == 0 { return temporaryLeaf }
            if errno != EEXIST {
                throw MoveAttemptFailure.system(stage: .rename, code: errno)
            }
        }
        throw MoveAttemptFailure.system(stage: .rename, code: EEXIST)
    }

    func verifyCaseOnlyOpenCapabilities(
        _ prepared: PreparedMove,
        request: LocalVerifiedFileMoveRequest,
        stage: LocalVerifiedFileMoveStage
    ) throws -> FileVersion {
        try verifyRootStillIdentifies(
            request.targetRoot,
            descriptor: prepared.targetRoot.descriptor,
            role: .target
        )
        try verifyRootStillIdentifies(
            request.referenceRoot,
            descriptor: prepared.referenceRoot.descriptor,
            role: .reference
        )
        let sourcePath = PathComponents(request.sourceRelativePath)
        let destinationPath = PathComponents(request.destinationRelativePath)
        let referencePath = PathComponents(request.referenceRelativePath)
        try verifyParentStillIdentifies(
            root: prepared.targetRoot.descriptor,
            components: sourcePath.parents,
            expected: prepared.sourceParent.descriptor,
            operand: .source
        )
        try verifyParentStillIdentifies(
            root: prepared.targetRoot.descriptor,
            components: destinationPath.parents,
            expected: prepared.destinationParent.descriptor,
            operand: .destination
        )
        try verifyParentStillIdentifies(
            root: prepared.referenceRoot.descriptor,
            components: referencePath.parents,
            expected: prepared.referenceParent.descriptor,
            operand: .reference
        )

        let source = try inspect(prepared.source.descriptor, stage: stage)
        let reference = try inspect(prepared.reference.descriptor, stage: stage)
        guard source == reference,
              source.isRegular,
              source.sameMoveStableFields(as: prepared.sourceVerification.version),
              source.sameMoveStableFields(as: prepared.referenceVerification.version) else {
            throw MoveAttemptFailure.publicFailure(
                .fileChanged(.source),
                stage: stage,
                code: ESTALE
            )
        }
        return source
    }

    func verifyCaseOnlyTemporaryState(
        _ prepared: PreparedMove,
        request: LocalVerifiedFileMoveRequest,
        temporaryLeaf: String,
        stage: LocalVerifiedFileMoveStage
    ) throws {
        let current = try verifyCaseOnlyOpenCapabilities(
            prepared,
            request: request,
            stage: stage
        )
        try requireExactNameIdentifies(
            parent: prepared.sourceParent.descriptor,
            leaf: temporaryLeaf,
            expected: current,
            operand: .source,
            stage: stage
        )
        try requireExactNameMissing(
            parent: prepared.sourceParent.descriptor,
            leaf: prepared.sourceLeaf,
            stage: stage
        )
        try requireExactNameMissing(
            parent: prepared.destinationParent.descriptor,
            leaf: prepared.destinationLeaf,
            stage: stage
        )
    }

    func verifyCaseOnlyDestinationState(
        _ prepared: PreparedMove,
        request: LocalVerifiedFileMoveRequest,
        temporaryLeaf: String,
        stage: LocalVerifiedFileMoveStage
    ) throws -> FileVersion {
        let current = try verifyCaseOnlyOpenCapabilities(
            prepared,
            request: request,
            stage: stage
        )
        try requireExactNameIdentifies(
            parent: prepared.destinationParent.descriptor,
            leaf: prepared.destinationLeaf,
            expected: current,
            operand: .destination,
            stage: stage
        )
        try requireExactNameMissing(
            parent: prepared.sourceParent.descriptor,
            leaf: prepared.sourceLeaf,
            stage: stage
        )
        try requireExactNameMissing(
            parent: prepared.sourceParent.descriptor,
            leaf: temporaryLeaf,
            stage: stage
        )
        return current
    }

    func rollbackCaseOnlyRename(
        state: CaseOnlyRenameState,
        prepared: PreparedMove
    ) throws {
        _ = try checkpoint(.beforeRollback, stage: .rollback, honorsCancellation: false)
        switch state {
        case .source:
            return

        case let .temporary(temporaryLeaf):
            let current = try inspect(prepared.source.descriptor, stage: .rollback)
            guard current.isRegular,
                  current.sameMoveStableFields(as: prepared.sourceVerification.version) else {
                throw MoveAttemptFailure.system(stage: .rollback, code: ESTALE)
            }
            try requireExactNameIdentifies(
                parent: prepared.sourceParent.descriptor,
                leaf: temporaryLeaf,
                expected: current,
                operand: .source,
                stage: .rollback
            )
            try requireExactNameMissing(
                parent: prepared.sourceParent.descriptor,
                leaf: prepared.sourceLeaf,
                stage: .rollback
            )
            let restore = exclusiveRename(
                fromParent: prepared.sourceParent.descriptor,
                from: temporaryLeaf,
                toParent: prepared.sourceParent.descriptor,
                to: prepared.sourceLeaf
            )
            guard restore == 0 else {
                throw MoveAttemptFailure.system(stage: .rollback, code: errno)
            }
            try syncDirectoryForRollback(prepared.sourceParent.descriptor)
            let restored = try inspect(prepared.source.descriptor, stage: .rollback)
            guard restored.sameMoveStableFields(as: prepared.sourceVerification.version) else {
                throw MoveAttemptFailure.system(stage: .rollback, code: ESTALE)
            }
            try requireExactNameIdentifies(
                parent: prepared.sourceParent.descriptor,
                leaf: prepared.sourceLeaf,
                expected: restored,
                operand: .source,
                stage: .rollback
            )
            try requireExactNameMissing(
                parent: prepared.sourceParent.descriptor,
                leaf: temporaryLeaf,
                stage: .rollback
            )

        case let .destination(temporaryLeaf):
            let current = try inspect(prepared.source.descriptor, stage: .rollback)
            guard current.isRegular,
                  current.sameMoveStableFields(as: prepared.sourceVerification.version) else {
                throw MoveAttemptFailure.system(stage: .rollback, code: ESTALE)
            }
            try requireExactNameIdentifies(
                parent: prepared.destinationParent.descriptor,
                leaf: prepared.destinationLeaf,
                expected: current,
                operand: .destination,
                stage: .rollback
            )
            try requireExactNameMissing(
                parent: prepared.sourceParent.descriptor,
                leaf: prepared.sourceLeaf,
                stage: .rollback
            )
            try requireExactNameMissing(
                parent: prepared.sourceParent.descriptor,
                leaf: temporaryLeaf,
                stage: .rollback
            )

            let uninstall = exclusiveRename(
                fromParent: prepared.destinationParent.descriptor,
                from: prepared.destinationLeaf,
                toParent: prepared.sourceParent.descriptor,
                to: temporaryLeaf
            )
            guard uninstall == 0 else {
                throw MoveAttemptFailure.system(stage: .rollback, code: errno)
            }
            let restore = exclusiveRename(
                fromParent: prepared.sourceParent.descriptor,
                from: temporaryLeaf,
                toParent: prepared.sourceParent.descriptor,
                to: prepared.sourceLeaf
            )
            guard restore == 0 else {
                let restoreCode = errno
                let putBack = exclusiveRename(
                    fromParent: prepared.sourceParent.descriptor,
                    from: temporaryLeaf,
                    toParent: prepared.destinationParent.descriptor,
                    to: prepared.destinationLeaf
                )
                guard putBack == 0 else {
                    throw MoveAttemptFailure.system(stage: .rollback, code: errno)
                }
                throw MoveAttemptFailure.system(stage: .rollback, code: restoreCode)
            }
            try syncDirectoryForRollback(prepared.sourceParent.descriptor)
            let restored = try inspect(prepared.source.descriptor, stage: .rollback)
            guard restored.sameMoveStableFields(as: prepared.sourceVerification.version) else {
                throw MoveAttemptFailure.system(stage: .rollback, code: ESTALE)
            }
            try requireExactNameIdentifies(
                parent: prepared.sourceParent.descriptor,
                leaf: prepared.sourceLeaf,
                expected: restored,
                operand: .source,
                stage: .rollback
            )
            try requireExactNameMissing(
                parent: prepared.destinationParent.descriptor,
                leaf: prepared.destinationLeaf,
                stage: .rollback
            )
            try requireExactNameMissing(
                parent: prepared.sourceParent.descriptor,
                leaf: temporaryLeaf,
                stage: .rollback
            )
        }
    }
}

// MARK: - Atomic rename

private extension LocalVerifiedFileMove {
    func completeAtomicRename(
        source: OpenedOrdinaryFile,
        sourceVersion: FileVersion,
        sourceParent: Int32,
        sourceLeaf: String,
        destinationParent: Int32,
        destinationLeaf: String,
        proof: LocalVerifiedFileMoveProof
    ) async throws -> LocalVerifiedFileMoveResult {
        do {
            let installedVersion = try inspect(source.descriptor, stage: .verification)
            guard installedVersion.sameMoveStableFields(as: sourceVersion) else {
                throw MoveAttemptFailure.publicFailure(
                    .fileChanged(.source),
                    stage: .verification,
                    code: ESTALE
                )
            }
            _ = try checkpoint(.afterInstall, stage: .install)
            try syncDirectory(destinationParent)
            try syncDirectory(sourceParent)
            try verifyNameStillIdentifies(
                parent: destinationParent,
                leaf: destinationLeaf,
                expected: installedVersion,
                operand: .destination
            )
            try requireNameMissing(parent: sourceParent, leaf: sourceLeaf, stage: .verification)
            try checkCancellation(stage: .durability)
            return LocalVerifiedFileMoveResult(
                strategy: .atomicRename,
                byteCount: proof.expectedByteCount,
                sha256: proof.expectedSHA256,
                installedSourceSnapshot: installedVersion.snapshot(
                    sha256: proof.expectedSHA256
                )
            )
        } catch let original as MoveAttemptFailure {
            do {
                try rollbackAtomicRename(
                    descriptor: source.descriptor,
                    expected: sourceVersion,
                    sourceParent: sourceParent,
                    sourceLeaf: sourceLeaf,
                    destinationParent: destinationParent,
                    destinationLeaf: destinationLeaf
                )
            } catch let rollback as MoveAttemptFailure {
                throw MoveAttemptFailure.rollbackIncomplete(original: original, rollback: rollback)
            }
            throw original
        }
    }

    func rollbackAtomicRename(
        descriptor: Int32,
        expected: FileVersion,
        sourceParent: Int32,
        sourceLeaf: String,
        destinationParent: Int32,
        destinationLeaf: String
    ) throws {
        _ = try checkpoint(.beforeRollback, stage: .rollback, honorsCancellation: false)
        let currentDestination = try inspect(descriptor, stage: .rollback)
        guard currentDestination.sameIdentity(as: expected),
              currentDestination.isRegular else {
            throw MoveAttemptFailure.system(stage: .rollback, code: ESTALE)
        }
        try verifyNameStillIdentifies(
            parent: destinationParent,
            leaf: destinationLeaf,
            expected: currentDestination,
            operand: .destination
        )
        try requireNameMissing(parent: sourceParent, leaf: sourceLeaf, stage: .rollback)

        let result = exclusiveRename(
            fromParent: destinationParent,
            from: destinationLeaf,
            toParent: sourceParent,
            to: sourceLeaf
        )
        guard result == 0 else {
            throw MoveAttemptFailure.system(stage: .rollback, code: errno)
        }
        let restoredVersion = try inspect(descriptor, stage: .rollback)
        guard restoredVersion.sameMoveStableFields(as: expected) else {
            throw MoveAttemptFailure.system(stage: .rollback, code: ESTALE)
        }
        try syncDirectoryForRollback(sourceParent)
        try syncDirectoryForRollback(destinationParent)
        try verifyNameStillIdentifies(
            parent: sourceParent,
            leaf: sourceLeaf,
            expected: restoredVersion,
            operand: .source
        )
        try requireNameMissing(parent: destinationParent, leaf: destinationLeaf, stage: .rollback)
    }
}

// MARK: - Cross-device copy, install, delete, and recovery

private extension LocalVerifiedFileMove {
    func copyThenDelete(
        source: OpenedOrdinaryFile,
        sourceVersion: FileVersion,
        sourceParent: Int32,
        sourceLeaf: String,
        reference: OpenedOrdinaryFile,
        referenceVersion: FileVersion,
        referenceParent: Int32,
        referenceLeaf: String,
        destinationParent: Int32,
        destinationLeaf: String,
        proof: LocalVerifiedFileMoveProof
    ) async throws -> LocalVerifiedFileMoveResult {
        let temporary = try createTemporaryFile(parent: destinationParent)
        var state = FallbackState.temporary

        do {
            let copied = try await copyAndHash(
                from: source.descriptor,
                to: temporary.descriptor,
                injectFaults: true
            )
            guard copied.byteCount == proof.expectedByteCount,
                  copied.sha256 == proof.expectedSHA256 else {
                throw MoveAttemptFailure.publicFailure(.fileChanged(.source), stage: .copy, code: ESTALE)
            }
            try requireDescriptorVersion(source.descriptor, equals: sourceVersion, operand: .source)
            guard retrying({ Darwin.fchmod(temporary.descriptor, sourceVersion.permissions) }) == 0 else {
                throw MoveAttemptFailure.system(stage: .copy, code: errno)
            }
            try copyMetadata(
                from: source.descriptor,
                to: temporary.descriptor,
                stage: .copy
            )
            try requireDescriptorVersion(source.descriptor, equals: sourceVersion, operand: .source)
            try requireDescriptorVersion(
                reference.descriptor,
                equals: referenceVersion,
                operand: .reference
            )
            try verifyNameStillIdentifies(
                parent: referenceParent,
                leaf: referenceLeaf,
                expected: referenceVersion,
                operand: .reference
            )
            guard retrying({ Darwin.fsync(temporary.descriptor) }) == 0 else {
                throw MoveAttemptFailure.system(stage: .durability, code: errno)
            }
            let temporaryVersion = try inspect(temporary.descriptor, stage: .copy)
            guard temporaryVersion.isRegular,
                  temporaryVersion.sameCopiedMetadata(as: sourceVersion) else {
                throw MoveAttemptFailure.system(stage: .copy, code: EIO)
            }
            try verifyTemporaryName(
                parent: destinationParent,
                name: temporary.name,
                expected: temporaryVersion
            )
            try checkCancellation(stage: .copy)

            let install = exclusiveRename(
                fromParent: destinationParent,
                from: temporary.name,
                toParent: destinationParent,
                to: destinationLeaf
            )
            guard install == 0 else {
                let code = errno
                if code == EEXIST {
                    throw MoveAttemptFailure.publicFailure(.destinationExists, stage: .install, code: code)
                }
                throw MoveAttemptFailure.system(stage: .install, code: code)
            }
            state = .installed(destinationVersion: temporaryVersion)
            let installedVersion = try inspect(temporary.descriptor, stage: .install)
            guard installedVersion.sameMoveStableFields(as: temporaryVersion) else {
                throw MoveAttemptFailure.system(stage: .install, code: ESTALE)
            }
            state = .installed(destinationVersion: installedVersion)

            _ = try checkpoint(.afterInstall, stage: .install)
            try syncDirectory(destinationParent)
            try verifyNameStillIdentifies(
                parent: destinationParent,
                leaf: destinationLeaf,
                expected: installedVersion,
                operand: .destination
            )
            try requireDescriptorVersion(source.descriptor, equals: sourceVersion, operand: .source)
            try requireDescriptorVersion(
                reference.descriptor,
                equals: referenceVersion,
                operand: .reference
            )
            try verifyNameStillIdentifies(
                parent: sourceParent,
                leaf: sourceLeaf,
                expected: sourceVersion,
                operand: .source
            )
            try verifyNameStillIdentifies(
                parent: referenceParent,
                leaf: referenceLeaf,
                expected: referenceVersion,
                operand: .reference
            )
            try checkCancellation(stage: .sourceRemoval)

            let removal = sourceLeaf.withCString {
                Darwin.unlinkat(sourceParent, $0, 0)
            }
            guard removal == 0 else {
                throw MoveAttemptFailure.system(stage: .sourceRemoval, code: errno)
            }
            state = .sourceRemoved(destinationVersion: installedVersion)

            _ = try checkpoint(.afterUnlink, stage: .sourceRemoval)
            try syncDirectory(sourceParent)
            try verifyNameStillIdentifies(
                parent: destinationParent,
                leaf: destinationLeaf,
                expected: installedVersion,
                operand: .destination
            )
            try requireNameMissing(parent: sourceParent, leaf: sourceLeaf, stage: .verification)
            try checkCancellation(stage: .durability)

            return LocalVerifiedFileMoveResult(
                strategy: .verifiedCopyThenDelete,
                byteCount: proof.expectedByteCount,
                sha256: proof.expectedSHA256,
                installedSourceSnapshot: installedVersion.snapshot(
                    sha256: proof.expectedSHA256
                )
            )
        } catch let original as MoveAttemptFailure {
            do {
                try recoverFallback(
                    state: state,
                    temporary: temporary,
                    sourceDescriptor: source.descriptor,
                    sourceVersion: sourceVersion,
                    sourceParent: sourceParent,
                    sourceLeaf: sourceLeaf,
                    destinationParent: destinationParent,
                    destinationLeaf: destinationLeaf,
                    proof: proof
                )
            } catch let rollback as MoveAttemptFailure {
                throw MoveAttemptFailure.rollbackIncomplete(original: original, rollback: rollback)
            }
            throw original
        }
    }

    func recoverFallback(
        state: FallbackState,
        temporary: TemporaryFile,
        sourceDescriptor: Int32,
        sourceVersion: FileVersion,
        sourceParent: Int32,
        sourceLeaf: String,
        destinationParent: Int32,
        destinationLeaf: String,
        proof: LocalVerifiedFileMoveProof
    ) throws {
        _ = try checkpoint(.beforeRollback, stage: .rollback, honorsCancellation: false)

        switch state {
        case .temporary:
            try removeNameIfIdentityMatches(
                parent: destinationParent,
                name: temporary.name,
                descriptor: temporary.descriptor
            )
            try syncDirectoryForRollback(destinationParent)
            try verifyNameStillIdentifies(
                parent: sourceParent,
                leaf: sourceLeaf,
                expected: sourceVersion,
                operand: .source
            )
            // No destination entry was installed in this state. A foreign
            // no-clobber race is preserved rather than mistaken for failed
            // recovery or deleted as though it belonged to this operation.

        case let .installed(destinationVersion):
            let currentDestination = try inspect(temporary.descriptor, stage: .rollback)
            guard currentDestination.sameIdentity(as: destinationVersion),
                  currentDestination.isRegular else {
                throw MoveAttemptFailure.system(stage: .rollback, code: ESTALE)
            }
            try verifyNameStillIdentifies(
                parent: destinationParent,
                leaf: destinationLeaf,
                expected: currentDestination,
                operand: .destination
            )
            try verifyNameStillIdentifies(
                parent: sourceParent,
                leaf: sourceLeaf,
                expected: sourceVersion,
                operand: .source
            )
            try removeNameIfIdentityMatches(
                parent: destinationParent,
                name: destinationLeaf,
                descriptor: temporary.descriptor
            )
            try syncDirectoryForRollback(destinationParent)
            try requireNameMissing(parent: destinationParent, leaf: destinationLeaf, stage: .rollback)

        case let .sourceRemoved(destinationVersion):
            let currentDestination = try inspect(temporary.descriptor, stage: .rollback)
            guard currentDestination.sameIdentity(as: destinationVersion),
                  currentDestination.isRegular else {
                throw MoveAttemptFailure.system(stage: .rollback, code: ESTALE)
            }
            try verifyNameStillIdentifies(
                parent: destinationParent,
                leaf: destinationLeaf,
                expected: currentDestination,
                operand: .destination
            )
            try requireNameMissing(parent: sourceParent, leaf: sourceLeaf, stage: .rollback)

            let recovery = try createTemporaryFile(parent: sourceParent)
            do {
                let copied = try copyAndHashSynchronously(
                    from: sourceDescriptor,
                    to: recovery.descriptor
                )
                guard copied.byteCount == proof.expectedByteCount,
                      copied.sha256 == proof.expectedSHA256 else {
                    throw MoveAttemptFailure.system(stage: .rollback, code: EBADMSG)
                }
                guard retrying({ Darwin.fchmod(recovery.descriptor, sourceVersion.permissions) }) == 0 else {
                    throw MoveAttemptFailure.system(stage: .rollback, code: errno)
                }
                try copyMetadata(
                    from: sourceDescriptor,
                    to: recovery.descriptor,
                    stage: .rollback
                )
                guard retrying({ Darwin.fsync(recovery.descriptor) }) == 0 else {
                    throw MoveAttemptFailure.system(stage: .rollback, code: errno)
                }
                let recoveryVersion = try inspect(recovery.descriptor, stage: .rollback)
                guard recoveryVersion.sameCopiedMetadata(as: sourceVersion) else {
                    throw MoveAttemptFailure.system(stage: .rollback, code: EIO)
                }
                try verifyTemporaryName(
                    parent: sourceParent,
                    name: recovery.name,
                    expected: recoveryVersion
                )
                let install = exclusiveRename(
                    fromParent: sourceParent,
                    from: recovery.name,
                    toParent: sourceParent,
                    to: sourceLeaf
                )
                guard install == 0 else {
                    throw MoveAttemptFailure.system(stage: .rollback, code: errno)
                }
                let installedRecoveryVersion = try inspect(recovery.descriptor, stage: .rollback)
                guard installedRecoveryVersion.sameMoveStableFields(as: recoveryVersion) else {
                    throw MoveAttemptFailure.system(stage: .rollback, code: ESTALE)
                }
                try syncDirectoryForRollback(sourceParent)
                try verifyNameStillIdentifies(
                    parent: sourceParent,
                    leaf: sourceLeaf,
                    expected: installedRecoveryVersion,
                    operand: .source
                )
            } catch let failure as MoveAttemptFailure {
                try? removeNameIfIdentityMatches(
                    parent: sourceParent,
                    name: recovery.name,
                    descriptor: recovery.descriptor
                )
                throw failure
            }

            try verifyNameStillIdentifies(
                parent: destinationParent,
                leaf: destinationLeaf,
                expected: currentDestination,
                operand: .destination
            )
            try removeNameIfIdentityMatches(
                parent: destinationParent,
                name: destinationLeaf,
                descriptor: temporary.descriptor
            )
            try syncDirectoryForRollback(destinationParent)
            try requireNameMissing(parent: destinationParent, leaf: destinationLeaf, stage: .rollback)
        }
    }
}

// MARK: - Low-level helpers

private extension LocalVerifiedFileMove {
    func inspect(_ descriptor: Int32, stage: LocalVerifiedFileMoveStage) throws -> FileVersion {
        var status = stat()
        guard retrying({ Darwin.fstat(descriptor, &status) }) == 0,
              status.st_size >= 0 else {
            throw MoveAttemptFailure.system(stage: stage, code: errno == 0 ? EIO : errno)
        }
        return FileVersion(status)
    }

    func requireDescriptorVersion(
        _ descriptor: Int32,
        equals expected: FileVersion,
        operand: LocalVerifiedFileMoveOperand
    ) throws {
        let current = try inspect(descriptor, stage: .verification)
        guard current == expected else {
            throw MoveAttemptFailure.publicFailure(.fileChanged(operand), stage: .verification, code: ESTALE)
        }
    }

    func exclusiveRename(
        fromParent: Int32,
        from: String,
        toParent: Int32,
        to: String
    ) -> Int32 {
        from.withCString { fromName in
            to.withCString { toName in
                Darwin.renameatx_np(fromParent, fromName, toParent, toName, UInt32(RENAME_EXCL))
            }
        }
    }

    func syncDirectory(_ descriptor: Int32) throws {
        guard retrying({ Darwin.fsync(descriptor) }) == 0 else {
            throw MoveAttemptFailure.system(stage: .durability, code: errno)
        }
    }

    func syncDirectoryForRollback(_ descriptor: Int32) throws {
        guard retrying({ Darwin.fsync(descriptor) }) == 0 else {
            throw MoveAttemptFailure.system(stage: .rollback, code: errno)
        }
    }

    func copyMetadata(
        from source: Int32,
        to destination: Int32,
        stage: LocalVerifiedFileMoveStage
    ) throws {
        guard retrying({
            Darwin.fcopyfile(source, destination, nil, copyfile_flags_t(COPYFILE_METADATA))
        }) == 0 else {
            throw MoveAttemptFailure.system(stage: stage, code: errno)
        }
    }

    func requireNameMissing(parent: Int32, leaf: String, stage: LocalVerifiedFileMoveStage) throws {
        var status = stat()
        let result = leaf.withCString {
            Darwin.fstatat(parent, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        if result == 0 {
            throw MoveAttemptFailure.system(stage: stage, code: EEXIST)
        }
        guard errno == ENOENT else {
            throw MoveAttemptFailure.system(stage: stage, code: errno)
        }
    }

    func createTemporaryFile(parent: Int32) throws -> TemporaryFile {
        for _ in 0..<64 {
            let name = ".riffa-verified-move-\(UUID().uuidString.lowercased())"
            let descriptor = name.withCString { temporaryName in
                retrying {
                    Darwin.openat(
                        parent,
                        temporaryName,
                        O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                        mode_t(0o600)
                    )
                }
            }
            if descriptor >= 0 {
                return TemporaryFile(descriptor: descriptor, name: name)
            }
            if errno != EEXIST {
                throw MoveAttemptFailure.system(stage: .copy, code: errno)
            }
        }
        throw MoveAttemptFailure.system(stage: .copy, code: EEXIST)
    }

    func verifyTemporaryName(parent: Int32, name: String, expected: FileVersion) throws {
        var status = stat()
        let result = name.withCString {
            Darwin.fstatat(parent, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0,
              FileVersion(status) == expected else {
            throw MoveAttemptFailure.system(stage: .verification, code: ESTALE)
        }
    }

    func removeNameIfIdentityMatches(parent: Int32, name: String, descriptor: Int32) throws {
        let expected = try inspect(descriptor, stage: .rollback)
        var status = stat()
        let lookup = name.withCString {
            Darwin.fstatat(parent, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        if lookup < 0, errno == ENOENT { return }
        guard lookup == 0,
              FileVersion(status).sameIdentity(as: expected) else {
            throw MoveAttemptFailure.system(stage: .rollback, code: ESTALE)
        }
        var removal = name.withCString { Darwin.unlinkat(parent, $0, 0) }
        if removal < 0, errno == EPERM {
            var descriptorStatus = stat()
            guard Darwin.fstat(descriptor, &descriptorStatus) == 0 else {
                throw MoveAttemptFailure.system(stage: .rollback, code: errno)
            }
            let removableFlags = descriptorStatus.st_flags & ~UInt32(UF_IMMUTABLE | UF_APPEND)
            guard Darwin.fchflags(descriptor, removableFlags) == 0 else {
                throw MoveAttemptFailure.system(stage: .rollback, code: errno)
            }
            removal = name.withCString { Darwin.unlinkat(parent, $0, 0) }
        }
        guard removal == 0 else {
            throw MoveAttemptFailure.system(stage: .rollback, code: errno)
        }
    }

    func copyAndHash(
        from source: Int32,
        to destination: Int32,
        injectFaults: Bool
    ) async throws -> CopyReceipt {
        guard retrying({ Darwin.lseek(source, 0, SEEK_SET) }) >= 0,
              retrying({ Darwin.lseek(destination, 0, SEEK_SET) }) >= 0,
              Darwin.ftruncate(destination, 0) == 0 else {
            throw MoveAttemptFailure.system(stage: .copy, code: errno)
        }

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: limits.chunkByteCount)
        var total: UInt64 = 0
        while true {
            try checkCancellation(stage: .copy)
            let count: Int = buffer.withUnsafeMutableBytes { bytes in
                retrying { Darwin.read(source, bytes.baseAddress, bytes.count) }
            }
            guard count >= 0 else {
                throw MoveAttemptFailure.system(stage: .copy, code: errno)
            }
            if count == 0 { break }

            var written = 0
            while written < count {
                try checkCancellation(stage: .copy)
                let amount: Int = buffer.withUnsafeBytes { bytes in
                    retrying {
                        Darwin.write(
                            destination,
                            bytes.baseAddress!.advanced(by: written),
                            count - written
                        )
                    }
                }
                guard amount > 0 else {
                    throw MoveAttemptFailure.system(stage: .copy, code: amount == 0 ? EIO : errno)
                }
                written += amount
            }

            let addition = total.addingReportingOverflow(UInt64(count))
            guard !addition.overflow else {
                throw MoveAttemptFailure.system(stage: .copy, code: EOVERFLOW)
            }
            total = addition.partialValue
            guard total <= limits.maximumFileByteCount else {
                throw MoveAttemptFailure.publicFailure(
                    .fileTooLarge(
                        operand: .source,
                        actualByteCount: total,
                        limit: limits.maximumFileByteCount
                    ),
                    stage: .copy,
                    code: EFBIG
                )
            }
            buffer.withUnsafeBytes {
                hasher.update(data: Data(bytes: $0.baseAddress!, count: count))
            }
            if injectFaults {
                _ = try checkpoint(.copying(byteCount: total), stage: .copy)
            }
            await Task.yield()
        }
        return CopyReceipt(byteCount: total, sha256: Self.hex(hasher.finalize()))
    }

    func copyAndHashSynchronously(from source: Int32, to destination: Int32) throws -> CopyReceipt {
        guard retrying({ Darwin.lseek(source, 0, SEEK_SET) }) >= 0,
              retrying({ Darwin.lseek(destination, 0, SEEK_SET) }) >= 0,
              Darwin.ftruncate(destination, 0) == 0 else {
            throw MoveAttemptFailure.system(stage: .rollback, code: errno)
        }

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: limits.chunkByteCount)
        var total: UInt64 = 0
        while true {
            let count: Int = buffer.withUnsafeMutableBytes { bytes in
                retrying { Darwin.read(source, bytes.baseAddress, bytes.count) }
            }
            guard count >= 0 else {
                throw MoveAttemptFailure.system(stage: .rollback, code: errno)
            }
            if count == 0 { break }
            var written = 0
            while written < count {
                let amount: Int = buffer.withUnsafeBytes { bytes in
                    retrying {
                        Darwin.write(
                            destination,
                            bytes.baseAddress!.advanced(by: written),
                            count - written
                        )
                    }
                }
                guard amount > 0 else {
                    throw MoveAttemptFailure.system(stage: .rollback, code: amount == 0 ? EIO : errno)
                }
                written += amount
            }
            let addition = total.addingReportingOverflow(UInt64(count))
            guard !addition.overflow else {
                throw MoveAttemptFailure.system(stage: .rollback, code: EOVERFLOW)
            }
            total = addition.partialValue
            guard total <= limits.maximumFileByteCount else {
                throw MoveAttemptFailure.system(stage: .rollback, code: EFBIG)
            }
            buffer.withUnsafeBytes {
                hasher.update(data: Data(bytes: $0.baseAddress!, count: count))
            }
        }
        return CopyReceipt(byteCount: total, sha256: Self.hex(hasher.finalize()))
    }
}

// MARK: - Deterministic test-only fault injection

enum LocalVerifiedFileMoveCheckpoint: Equatable, Sendable {
    case hashing(operand: LocalVerifiedFileMoveOperand, byteCount: UInt64)
    case beforeRename
    case afterCaseOnlyTemporaryInstall
    case beforeCaseOnlyFinalRename
    case copying(byteCount: UInt64)
    case afterInstall
    case afterUnlink
    case beforeRollback
}

enum LocalVerifiedFileMoveFaultAction: Equatable, Sendable {
    case proceed
    case forceCrossDevice
    case fail(code: Int32)
    case cancel
}

enum LocalVerifiedFileMoveFaultInjection {
    @TaskLocal static var handler: (@Sendable (LocalVerifiedFileMoveCheckpoint) -> LocalVerifiedFileMoveFaultAction)?
}

private extension LocalVerifiedFileMove {
    @discardableResult
    func checkpoint(
        _ point: LocalVerifiedFileMoveCheckpoint,
        stage: LocalVerifiedFileMoveStage,
        honorsCancellation: Bool = true
    ) throws -> LocalVerifiedFileMoveFaultAction {
        if honorsCancellation {
            try checkCancellation(stage: stage)
        }
        let action = LocalVerifiedFileMoveFaultInjection.handler?(point) ?? .proceed
        switch action {
        case .proceed, .forceCrossDevice:
            return action
        case let .fail(code):
            throw MoveAttemptFailure.system(stage: stage, code: code)
        case .cancel:
            throw MoveAttemptFailure.cancelled(stage: stage)
        }
    }

    func checkCancellation(stage: LocalVerifiedFileMoveStage) throws {
        if Task.isCancelled {
            throw MoveAttemptFailure.cancelled(stage: stage)
        }
    }
}

// MARK: - Private state

private final class OwnedDescriptor {
    let descriptor: Int32

    init(_ descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        _ = Darwin.close(descriptor)
    }
}

private final class OpenedOrdinaryFile {
    let descriptor: Int32

    init(_ descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        _ = Darwin.close(descriptor)
    }
}

private final class TemporaryFile {
    let descriptor: Int32
    let name: String

    init(descriptor: Int32, name: String) {
        self.descriptor = descriptor
        self.name = name
    }

    deinit {
        _ = Darwin.close(descriptor)
    }
}

private struct PathComponents {
    let values: [String]

    init(_ path: String) {
        values = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    }

    var parents: ArraySlice<String> { values.dropLast() }
    var leaf: String { values[values.count - 1] }
}

private struct FileVersion: Equatable {
    let device: UInt64
    let inode: UInt64
    let byteCount: UInt64
    let type: mode_t
    let permissions: mode_t
    let flags: UInt32
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let statusChangeSeconds: Int64
    let statusChangeNanoseconds: Int64

    init(_ status: stat) {
        device = UInt64(bitPattern: Int64(status.st_dev))
        inode = UInt64(status.st_ino)
        byteCount = status.st_size >= 0 ? UInt64(status.st_size) : 0
        type = status.st_mode & mode_t(S_IFMT)
        permissions = status.st_mode & mode_t(0o7777)
        flags = UInt32(status.st_flags)
        modificationSeconds = Int64(status.st_mtimespec.tv_sec)
        modificationNanoseconds = Int64(status.st_mtimespec.tv_nsec)
        statusChangeSeconds = Int64(status.st_ctimespec.tv_sec)
        statusChangeNanoseconds = Int64(status.st_ctimespec.tv_nsec)
    }

    var isRegular: Bool { type == mode_t(S_IFREG) }

    func sameIdentity(as other: FileVersion) -> Bool {
        device == other.device && inode == other.inode
    }

    /// A successful rename may legitimately advance ctime. Every other field
    /// relevant to the proof, identity, and retained basic mode must be stable.
    func sameMoveStableFields(as other: FileVersion) -> Bool {
        device == other.device &&
            inode == other.inode &&
            byteCount == other.byteCount &&
            type == other.type &&
            permissions == other.permissions &&
            flags == other.flags &&
            modificationSeconds == other.modificationSeconds &&
            modificationNanoseconds == other.modificationNanoseconds
    }

    func sameCopiedMetadata(as other: FileVersion) -> Bool {
        byteCount == other.byteCount &&
            type == other.type &&
            permissions == other.permissions &&
            flags == other.flags &&
            modificationSeconds == other.modificationSeconds &&
            modificationNanoseconds == other.modificationNanoseconds
    }

    func snapshot(sha256: String) -> LocalVerifiedFileMoveSourceSnapshot {
        LocalVerifiedFileMoveSourceSnapshot(
            deviceID: device,
            fileID: inode,
            byteCount: byteCount,
            permissions: UInt16(permissions),
            flags: flags,
            modificationSeconds: modificationSeconds,
            modificationNanoseconds: modificationNanoseconds,
            statusChangeSeconds: statusChangeSeconds,
            statusChangeNanoseconds: statusChangeNanoseconds,
            sha256: sha256
        )
    }
}

private struct HashedFile {
    let version: FileVersion
    let byteCount: UInt64
    let sha256: String

    var snapshot: LocalVerifiedFileMoveSourceSnapshot {
        version.snapshot(sha256: sha256)
    }
}

private struct DescriptorIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
    let kind: mode_t

    init(_ status: stat) {
        device = UInt64(bitPattern: Int64(status.st_dev))
        inode = UInt64(status.st_ino)
        kind = status.st_mode & mode_t(S_IFMT)
    }
}

private struct CopyReceipt {
    let byteCount: UInt64
    let sha256: String
}

/// Retains every root, parent, and leaf descriptor from proof verification
/// through commit. Closing a root early would weaken the capability model even
/// though an opened child descriptor remains usable.
private struct PreparedMove {
    let targetRoot: OwnedDescriptor
    let referenceRoot: OwnedDescriptor
    let source: OpenedOrdinaryFile
    let reference: OpenedOrdinaryFile
    let sourceParent: OwnedDescriptor
    let destinationParent: OwnedDescriptor
    let referenceParent: OwnedDescriptor
    let sourceLeaf: String
    let destinationLeaf: String
    let referenceLeaf: String
    let sourceVerification: HashedFile
    let referenceVerification: HashedFile
}

private enum CaseOnlyRenameState {
    case source
    case temporary(String)
    case destination(String)
}

private enum FallbackState {
    case temporary
    case installed(destinationVersion: FileVersion)
    case sourceRemoved(destinationVersion: FileVersion)
}

private enum MoveAttemptFailure: Error {
    case publicFailure(
        LocalVerifiedFileMoveError,
        stage: LocalVerifiedFileMoveStage,
        code: Int32
    )
    case system(stage: LocalVerifiedFileMoveStage, code: Int32)
    case cancelled(stage: LocalVerifiedFileMoveStage)

    var stageAndCode: (LocalVerifiedFileMoveStage, Int32) {
        switch self {
        case let .publicFailure(_, stage, code), let .system(stage, code):
            (stage, code)
        case let .cancelled(stage):
            (stage, ECANCELED)
        }
    }

    func raisePublicError() throws -> Never {
        switch self {
        case let .publicFailure(error, _, _):
            throw error
        case let .system(stage, code):
            throw LocalVerifiedFileMoveError.operationFailed(stage: stage, code: code)
        case .cancelled:
            throw CancellationError()
        }
    }

    static func rollbackIncomplete(
        original: MoveAttemptFailure,
        rollback: MoveAttemptFailure
    ) -> MoveAttemptFailure {
        let originalSummary = original.stageAndCode
        let rollbackSummary = rollback.stageAndCode
        return .publicFailure(
            .rollbackIncomplete(
                originalStage: originalSummary.0,
                originalCode: originalSummary.1,
                rollbackStage: rollbackSummary.0,
                rollbackCode: rollbackSummary.1
            ),
            stage: .rollback,
            code: rollbackSummary.1
        )
    }
}

private func retrying<T: FixedWidthInteger>(_ operation: () -> T) -> T {
    while true {
        let result = operation()
        if result == T(-1), errno == EINTR { continue }
        return result
    }
}
