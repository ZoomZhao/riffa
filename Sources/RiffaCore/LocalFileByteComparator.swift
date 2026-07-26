import Darwin
import Foundation

/// Path-free failures from descriptor-backed equality checks.
enum LocalFileByteComparisonError: Error, Equatable, Sendable {
    enum Side: String, Equatable, Sendable {
        case left
        case right
    }

    enum Operation: String, Equatable, Sendable {
        case open
        case inspect
        case read
    }

    case invalidChunkByteCount
    case nonLocalResource(side: Side)
    case relativePath(side: Side)
    case expectedRegularFile(side: Side)
    case operationFailed(side: Side, operation: Operation, code: Int32)
    case notRegularFile(side: Side)
    case invalidDeclaredFileIdentifier(side: Side)
    case declaredFileIdentifierMismatch(side: Side)
    case declaredByteCountMismatch(side: Side, expected: Int64, actual: Int64)
    case declaredPermissionsMismatch(side: Side, expected: UInt16, actual: UInt16)
    case unexpectedEndOfFile(side: Side)
    case fileChangedDuringComparison(side: Side)
}

extension LocalFileByteComparisonError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidChunkByteCount:
            "The local file comparison chunk size must be greater than zero."
        case let .nonLocalResource(side):
            "The \(side.rawValue) input is not a local file resource."
        case let .relativePath(side):
            "The \(side.rawValue) local file path is not absolute."
        case let .expectedRegularFile(side):
            "The \(side.rawValue) resource entry is not declared as a regular file."
        case let .operationFailed(side, operation, code):
            "The \(side.rawValue) file \(operation.rawValue) operation failed "
                + "(errno \(code): \(Self.posixMessage(code)))."
        case let .notRegularFile(side):
            "The \(side.rawValue) input is no longer a regular file."
        case let .invalidDeclaredFileIdentifier(side):
            "The \(side.rawValue) resource has an invalid declared file identifier."
        case let .declaredFileIdentifierMismatch(side):
            "The \(side.rawValue) file identity no longer matches its enumerated identity."
        case let .declaredByteCountMismatch(side, expected, actual):
            "The \(side.rawValue) file size changed from the declared \(expected) bytes "
                + "to \(actual) bytes before comparison."
        case let .declaredPermissionsMismatch(side, expected, actual):
            "The \(side.rawValue) file permissions changed from "
                + "\(String(expected, radix: 8)) to \(String(actual, radix: 8)) before comparison."
        case let .unexpectedEndOfFile(side):
            "The \(side.rawValue) file ended before its inspected size."
        case let .fileChangedDuringComparison(side):
            "The \(side.rawValue) file changed during content comparison."
        }
    }

    private static func posixMessage(_ code: Int32) -> String {
        guard let message = strerror(code) else { return "unknown error" }
        return String(cString: message)
    }
}

/// Compares two enumerated local regular files without following links or
/// materializing either file. Both descriptors are validated against the
/// `ResourceEntry` snapshots and re-inspected before any equality result is
/// returned, including early content mismatches.
struct LocalFileByteComparator: Sendable {
    enum Checkpoint: Sendable {
        case descriptorsValidated
        case beforeFinalVerification
    }

    let chunkByteCount: Int
    private let checkpoint: (@Sendable (Checkpoint) throws -> Void)?

    init(chunkByteCount: Int) throws {
        try self.init(chunkByteCount: chunkByteCount, checkpoint: nil)
    }

    /// Internal deterministic mutation hook used only by security regression
    /// tests. Production callers use the public-shape initializer above.
    init(
        chunkByteCount: Int,
        checkpoint: (@Sendable (Checkpoint) throws -> Void)?
    ) throws {
        guard chunkByteCount > 0 else {
            throw LocalFileByteComparisonError.invalidChunkByteCount
        }
        self.chunkByteCount = chunkByteCount
        self.checkpoint = checkpoint
    }

    func compare(_ left: ResourceEntry, _ right: ResourceEntry) throws -> Bool {
        try Task.checkCancellation()
        let pair = try openPair(left: left, right: right)
        defer {
            _ = Darwin.close(pair.left.descriptor)
            _ = Darwin.close(pair.right.descriptor)
        }

        try checkpoint?(.descriptorsValidated)
        try Task.checkCancellation()

        if pair.left.version.byteCount != pair.right.version.byteCount {
            return try finish(false, pair: pair)
        }

        let byteCount = pair.left.version.byteCount
        guard byteCount > 0 else {
            return try finish(true, pair: pair)
        }

        let bufferByteCount = Int(min(Int64(chunkByteCount), byteCount))
        var leftBuffer = [UInt8](repeating: 0, count: bufferByteCount)
        var rightBuffer = [UInt8](repeating: 0, count: bufferByteCount)
        var remaining = byteCount

        while remaining > 0 {
            try Task.checkCancellation()
            let requested = Int(min(Int64(chunkByteCount), remaining))
            try readExactly(
                descriptor: pair.left.descriptor,
                into: &leftBuffer,
                count: requested,
                side: .left
            )
            try readExactly(
                descriptor: pair.right.descriptor,
                into: &rightBuffer,
                count: requested,
                side: .right
            )

            guard leftBuffer[..<requested].elementsEqual(rightBuffer[..<requested]) else {
                return try finish(false, pair: pair)
            }
            remaining -= Int64(requested)
        }

        return try finish(true, pair: pair)
    }

    private struct FileVersion: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let byteCount: Int64
        let mode: UInt16
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let statusChangeSeconds: Int64
        let statusChangeNanoseconds: Int64
    }

    private struct OpenFile {
        let descriptor: Int32
        let version: FileVersion
        let url: URL
        let entry: ResourceEntry
    }

    private struct OpenPair {
        let left: OpenFile
        let right: OpenFile
    }

    private func openPair(
        left: ResourceEntry,
        right: ResourceEntry
    ) throws -> OpenPair {
        let leftFile = try open(left, side: .left)
        do {
            try Task.checkCancellation()
            let rightFile = try open(right, side: .right)
            return OpenPair(left: leftFile, right: rightFile)
        } catch {
            _ = Darwin.close(leftFile.descriptor)
            throw error
        }
    }

    private func open(
        _ entry: ResourceEntry,
        side: LocalFileByteComparisonError.Side
    ) throws -> OpenFile {
        guard entry.kind == .file else {
            throw LocalFileByteComparisonError.expectedRegularFile(side: side)
        }
        guard entry.locator.providerID == ResourceLocator.localProviderID,
              let url = entry.locator.localFileURL else {
            throw LocalFileByteComparisonError.nonLocalResource(side: side)
        }
        guard NSString(string: entry.locator.path).isAbsolutePath else {
            throw LocalFileByteComparisonError.relativePath(side: side)
        }

        let descriptor = try openDescriptor(url, side: side)

        do {
            let version = try inspect(descriptor, side: side)
            guard (version.mode & UInt16(S_IFMT)) == UInt16(S_IFREG) else {
                throw LocalFileByteComparisonError.notRegularFile(side: side)
            }
            try validate(version, against: entry, side: side)
            return OpenFile(
                descriptor: descriptor,
                version: version,
                url: url,
                entry: entry
            )
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private func openDescriptor(
        _ url: URL,
        side: LocalFileByteComparisonError.Side
    ) throws -> Int32 {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else {
                errno = EINVAL
                return -1
            }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw LocalFileByteComparisonError.operationFailed(
                side: side,
                operation: .open,
                code: errno
            )
        }
        return descriptor
    }

    private func validate(
        _ version: FileVersion,
        against entry: ResourceEntry,
        side: LocalFileByteComparisonError.Side
    ) throws {
        if let identifier = entry.fileIdentifier {
            let components = identifier.split(separator: ":", omittingEmptySubsequences: false)
            guard components.count == 2,
                  let device = UInt64(components[0]),
                  let inode = UInt64(components[1]) else {
                throw LocalFileByteComparisonError.invalidDeclaredFileIdentifier(side: side)
            }
            guard device == version.device, inode == version.inode else {
                throw LocalFileByteComparisonError.declaredFileIdentifierMismatch(side: side)
            }
        }

        if let expectedByteCount = entry.byteCount,
           expectedByteCount != version.byteCount {
            throw LocalFileByteComparisonError.declaredByteCountMismatch(
                side: side,
                expected: expectedByteCount,
                actual: version.byteCount
            )
        }

        if let expectedPermissions = entry.permissions {
            let actualPermissions = version.mode & 0o7777
            guard expectedPermissions == actualPermissions else {
                throw LocalFileByteComparisonError.declaredPermissionsMismatch(
                    side: side,
                    expected: expectedPermissions,
                    actual: actualPermissions
                )
            }
        }
    }

    private func inspect(
        _ descriptor: Int32,
        side: LocalFileByteComparisonError.Side
    ) throws -> FileVersion {
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0 else {
            throw LocalFileByteComparisonError.operationFailed(
                side: side,
                operation: .inspect,
                code: errno
            )
        }
        guard information.st_size >= 0 else {
            throw LocalFileByteComparisonError.operationFailed(
                side: side,
                operation: .inspect,
                code: EIO
            )
        }
        return FileVersion(
            device: UInt64(bitPattern: Int64(information.st_dev)),
            inode: UInt64(information.st_ino),
            byteCount: Int64(information.st_size),
            mode: UInt16(information.st_mode),
            modificationSeconds: Int64(information.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(information.st_mtimespec.tv_nsec),
            statusChangeSeconds: Int64(information.st_ctimespec.tv_sec),
            statusChangeNanoseconds: Int64(information.st_ctimespec.tv_nsec)
        )
    }

    private func readExactly(
        descriptor: Int32,
        into buffer: inout [UInt8],
        count: Int,
        side: LocalFileByteComparisonError.Side
    ) throws {
        var total = 0
        while total < count {
            try Task.checkCancellation()
            let readCount: Int = buffer.withUnsafeMutableBytes { storage in
                Darwin.read(
                    descriptor,
                    storage.baseAddress?.advanced(by: total),
                    count - total
                )
            }
            if readCount < 0, errno == EINTR { continue }
            guard readCount >= 0 else {
                throw LocalFileByteComparisonError.operationFailed(
                    side: side,
                    operation: .read,
                    code: errno
                )
            }
            guard readCount > 0 else {
                throw LocalFileByteComparisonError.unexpectedEndOfFile(side: side)
            }
            total += readCount
        }
    }

    private func finish(_ result: Bool, pair: OpenPair) throws -> Bool {
        try checkpoint?(.beforeFinalVerification)
        var firstFailure: (any Error)?
        let checks: [() throws -> Void] = [
            { try verifyDescriptorUnchanged(pair.left, side: .left) },
            { try verifyDescriptorUnchanged(pair.right, side: .right) },
            { try verifyPathStillNamesFile(pair.left, side: .left) },
            { try verifyPathStillNamesFile(pair.right, side: .right) },
        ]
        for check in checks {
            do {
                try check()
            } catch {
                if firstFailure == nil { firstFailure = error }
            }
        }
        if let firstFailure { throw firstFailure }
        try Task.checkCancellation()
        return result
    }

    private func verifyDescriptorUnchanged(
        _ file: OpenFile,
        side: LocalFileByteComparisonError.Side
    ) throws {
        guard try inspect(file.descriptor, side: side) == file.version else {
            throw LocalFileByteComparisonError.fileChangedDuringComparison(side: side)
        }
    }

    /// Descriptor validation alone cannot detect a path that was unlinked and
    /// rebound to a new inode while the original descriptor remained valid.
    /// Reopening with O_NOFOLLOW closes that gap without trusting a new path
    /// lookup for content bytes.
    private func verifyPathStillNamesFile(
        _ file: OpenFile,
        side: LocalFileByteComparisonError.Side
    ) throws {
        let descriptor = try openDescriptor(file.url, side: side)
        defer { _ = Darwin.close(descriptor) }
        let current = try inspect(descriptor, side: side)
        guard (current.mode & UInt16(S_IFMT)) == UInt16(S_IFREG) else {
            throw LocalFileByteComparisonError.notRegularFile(side: side)
        }
        guard current == file.version else {
            throw LocalFileByteComparisonError.fileChangedDuringComparison(side: side)
        }
        try validate(current, against: file.entry, side: side)
    }
}
