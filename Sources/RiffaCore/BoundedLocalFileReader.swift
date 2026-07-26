import Darwin
import Foundation

/// Limits for one descriptor-based local-file read.
public struct BoundedLocalFileReadLimits: Hashable, Codable, Sendable {
    public var maximumByteCount: Int
    public var chunkByteCount: Int

    public init(
        maximumByteCount: Int,
        chunkByteCount: Int = 1 * 1_024 * 1_024
    ) {
        self.maximumByteCount = maximumByteCount
        self.chunkByteCount = chunkByteCount
    }
}

/// Path-free failures from ``BoundedLocalFileReader``. Callers may add a
/// user-facing basename, but portable reports never receive an input locator.
public enum BoundedLocalFileReadError: Error, Equatable, Codable, Sendable {
    public enum Operation: String, Codable, Sendable {
        case open
        case inspect
        case read
        case close
    }

    case invalidLimits
    case nonFileURL
    case relativePath
    case operationFailed(operation: Operation, code: Int32)
    case notRegularFile
    case fileTooLarge(actualByteCount: Int64, limit: Int)
    case fileChangedDuringRead
}

extension BoundedLocalFileReadError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidLimits:
            "The bounded file-read limits are invalid."
        case .nonFileURL:
            "The input is not a local file URL."
        case .relativePath:
            "The local file path is not absolute."
        case let .operationFailed(operation, code):
            "The local file \(operation.rawValue) operation failed (errno \(code): \(Self.posixMessage(code)))."
        case .notRegularFile:
            "The input is not a regular file."
        case let .fileTooLarge(actualByteCount, limit):
            "The input contains at least \(actualByteCount) bytes, exceeding the \(limit)-byte limit."
        case .fileChangedDuringRead:
            "The input changed while it was being read."
        }
    }

    private static func posixMessage(_ code: Int32) -> String {
        guard let message = strerror(code) else { return "unknown error" }
        return String(cString: message)
    }
}

/// Reads one regular local file through a single descriptor with a strict
/// aggregate byte ceiling. Symbolic links may resolve when the descriptor is
/// opened, but the resolved object must be a regular file and is never reopened
/// by path. A final `fstat` rejects replacement, truncation, growth, or writes
/// observed during the read.
public struct BoundedLocalFileReader: Sendable {
    public let limits: BoundedLocalFileReadLimits

    public init(limits: BoundedLocalFileReadLimits) {
        self.limits = limits
    }

    public func read(url: URL) throws -> Data {
        guard limits.maximumByteCount > 0,
              limits.maximumByteCount < Int.max,
              limits.chunkByteCount > 0 else {
            throw BoundedLocalFileReadError.invalidLimits
        }
        guard url.isFileURL else {
            throw BoundedLocalFileReadError.nonFileURL
        }
        let standardized = url.standardizedFileURL
        guard standardized.path.hasPrefix("/") else {
            throw BoundedLocalFileReadError.relativePath
        }

        let descriptor = standardized.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            // O_NONBLOCK prevents a FIFO/device reached through a symbolic
            // link from hanging before `fstat` can reject the non-regular file.
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            throw BoundedLocalFileReadError.operationFailed(
                operation: .open,
                code: errno
            )
        }
        defer { _ = Darwin.close(descriptor) }

        let before = try inspect(descriptor)
        guard (before.st_mode & S_IFMT) == S_IFREG else {
            throw BoundedLocalFileReadError.notRegularFile
        }
        guard before.st_size >= 0 else {
            throw BoundedLocalFileReadError.operationFailed(
                operation: .inspect,
                code: EIO
            )
        }
        guard before.st_size <= limits.maximumByteCount else {
            throw BoundedLocalFileReadError.fileTooLarge(
                actualByteCount: Int64(before.st_size),
                limit: limits.maximumByteCount
            )
        }

        var data = Data()
        data.reserveCapacity(Int(before.st_size))
        var buffer = [UInt8](
            repeating: 0,
            count: min(limits.chunkByteCount, limits.maximumByteCount + 1)
        )

        while true {
            let remaining = limits.maximumByteCount - data.count
            let requested = min(buffer.count, remaining + 1)
            let count: Int = buffer.withUnsafeMutableBytes { bytes in
                while true {
                    let result = Darwin.read(descriptor, bytes.baseAddress, requested)
                    if result < 0, errno == EINTR { continue }
                    return result
                }
            }
            guard count >= 0 else {
                throw BoundedLocalFileReadError.operationFailed(
                    operation: .read,
                    code: errno
                )
            }
            guard count > 0 else { break }
            guard count <= remaining else {
                throw BoundedLocalFileReadError.fileTooLarge(
                    actualByteCount: Int64(limits.maximumByteCount) + 1,
                    limit: limits.maximumByteCount
                )
            }
            data.append(contentsOf: buffer[0..<count])
        }

        let after = try inspect(descriptor)
        guard Self.sameIdentityAndVersion(before, after),
              after.st_size == data.count else {
            throw BoundedLocalFileReadError.fileChangedDuringRead
        }
        return data
    }

    private func inspect(_ descriptor: Int32) throws -> stat {
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0 else {
            throw BoundedLocalFileReadError.operationFailed(
                operation: .inspect,
                code: errno
            )
        }
        return information
    }

    private static func sameIdentityAndVersion(_ left: stat, _ right: stat) -> Bool {
        left.st_dev == right.st_dev
            && left.st_ino == right.st_ino
            && left.st_size == right.st_size
            && left.st_mtimespec.tv_sec == right.st_mtimespec.tv_sec
            && left.st_mtimespec.tv_nsec == right.st_mtimespec.tv_nsec
            && left.st_ctimespec.tv_sec == right.st_ctimespec.tv_sec
            && left.st_ctimespec.tv_nsec == right.st_ctimespec.tv_nsec
    }
}
