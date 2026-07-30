import Darwin
@preconcurrency import Dispatch
import Foundation
import RiffaCore

enum LocalFileChangeMonitorError: Error, LocalizedError {
    case notLocalFile
    case couldNotObserve
    case notRegularFile

    var errorDescription: String? {
        switch self {
        case .notLocalFile:
            RiffaLocalization.string("Only a local file can be observed.")
        case .couldNotObserve:
            RiffaLocalization.string(
                "The selected file is not currently available for observation."
            )
        case .notRegularFile:
            RiffaLocalization.string(
                "The selected resource is not a regular file."
            )
        }
    }
}

/// Event-driven observation for one already-authorized local file URL.
///
/// The monitor never starts a security scope and never scans or reads file
/// contents. Its caller must keep the URL's existing sandbox authorization
/// alive. Content identity is still checked by `DecodedTextDocumentStore` when
/// reloading or saving.
@MainActor
final class LocalFileChangeMonitor {
    typealias ChangeHandler = @MainActor (TextExternalFileChangeKind) -> Void

    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64

        init(_ status: stat) {
            device = UInt64(status.st_dev)
            inode = UInt64(status.st_ino)
        }
    }

    private enum PathStatus {
        case present(FileIdentity)
        case missing
        case unavailable
    }

    private static let watchedEvents: DispatchSource.FileSystemEvent = [
        .write,
        .delete,
        .rename,
        .attrib,
        .extend,
        .link,
        .revoke
    ]

    private let url: URL
    private let debounceNanoseconds: UInt64
    private let handler: ChangeHandler
    // Dispatch source handlers are created from this @MainActor type and
    // therefore carry main-actor isolation under Swift 6. Run the tiny event
    // and cancellation callbacks on the matching executor; using a private
    // queue here causes an executor precondition trap as soon as a comparison
    // replaces or swaps an already-monitored file.
    private let eventQueue = DispatchQueue.main

    private var source: (any DispatchSourceFileSystemObject)?
    private var identity: FileIdentity?
    private var pendingEventRawValue: UInt = 0
    private var debounceTask: Task<Void, Never>?
    private var isStopped = false

    init(
        url: URL,
        expectedFingerprint: DecodedTextFileFingerprint,
        debounceMilliseconds: Int = 250,
        handler: @escaping ChangeHandler
    ) throws {
        guard url.isFileURL else {
            throw LocalFileChangeMonitorError.notLocalFile
        }
        self.url = url
        self.debounceNanoseconds = UInt64(max(0, debounceMilliseconds)) * 1_000_000
        self.handler = handler
        let status = try installSource()
        if !Self.metadata(status, matches: expectedFingerprint) {
            // Close the load-to-watch race without a second content read. The
            // later bounded Reload (or optimistic Save) remains authoritative.
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, !isStopped else { return }
                handler(.changed)
            }
        }
    }

    deinit {
        debounceTask?.cancel()
        source?.cancel()
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        debounceTask?.cancel()
        debounceTask = nil
        pendingEventRawValue = 0
        source?.cancel()
        source = nil
        identity = nil
    }

    @discardableResult
    private func installSource() throws -> stat {
        let descriptor = try Self.openEventDescriptor(for: url)
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            Darwin.close(descriptor)
            throw LocalFileChangeMonitorError.couldNotObserve
        }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(descriptor)
            throw LocalFileChangeMonitorError.notRegularFile
        }

        let nextSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: Self.watchedEvents,
            queue: eventQueue
        )
        nextSource.setCancelHandler {
            Darwin.close(descriptor)
        }
        nextSource.setEventHandler { [weak self, weak nextSource] in
            guard let nextSource else { return }
            let rawValue = nextSource.data.rawValue
            Task { @MainActor [weak self] in
                self?.receiveEvent(rawValue: rawValue)
            }
        }

        identity = FileIdentity(status)
        source = nextSource
        nextSource.resume()
        return status
    }

    private func receiveEvent(rawValue: UInt) {
        guard !isStopped else { return }
        pendingEventRawValue |= rawValue
        debounceTask?.cancel()
        let delay = debounceNanoseconds
        debounceTask = Task { @MainActor [weak self] in
            do {
                try await Task<Never, Never>.sleep(nanoseconds: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.emitPendingEvent()
        }
    }

    private func emitPendingEvent() {
        guard !isStopped, pendingEventRawValue != 0 else { return }
        let events = DispatchSource.FileSystemEvent(rawValue: pendingEventRawValue)
        pendingEventRawValue = 0
        debounceTask = nil

        let change = classify(events)
        handler(change)
    }

    private func classify(
        _ events: DispatchSource.FileSystemEvent
    ) -> TextExternalFileChangeKind {
        if events.contains(.revoke) {
            return .unavailable
        }

        switch Self.pathStatus(for: url) {
        case .missing:
            if events.contains(.rename) {
                return .moved
            }
            return .deleted
        case .unavailable:
            return .unavailable
        case let .present(currentIdentity):
            // Atomic writers replace the vnode. Re-arm on the new inode so
            // subsequent edits keep producing events instead of leaving the
            // monitor attached to the unlinked predecessor.
            if currentIdentity != identity {
                if !reinstallSource() {
                    return .unavailable
                }
                return .changed
            }
            return .changed
        }
    }

    private func reinstallSource() -> Bool {
        source?.cancel()
        source = nil
        identity = nil
        do {
            try installSource()
            return true
        } catch {
            return false
        }
    }

    private static func openEventDescriptor(for url: URL) throws -> Int32 {
        let descriptor: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Darwin.open(path, O_EVTONLY | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw LocalFileChangeMonitorError.couldNotObserve
        }
        return descriptor
    }

    private static func pathStatus(for url: URL) -> PathStatus {
        var status = stat()
        let result: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Darwin.fstatat(AT_FDCWD, path, &status, 0)
        }
        guard result == 0 else {
            switch errno {
            case ENOENT, ENOTDIR:
                return .missing
            default:
                return .unavailable
            }
        }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            return .unavailable
        }
        return .present(FileIdentity(status))
    }

    private static func metadata(
        _ status: stat,
        matches fingerprint: DecodedTextFileFingerprint
    ) -> Bool {
        guard status.st_size >= 0,
              UInt64(status.st_size) == fingerprint.byteCount else {
            return false
        }
        guard let expectedTime = fingerprint.modificationTimeNanoseconds,
              let observedTime = modificationTimeNanoseconds(status) else {
            return true
        }
        return expectedTime == observedTime
    }

    private static func modificationTimeNanoseconds(_ status: stat) -> Int64? {
        let seconds = Int64(status.st_mtimespec.tv_sec)
        let nanoseconds = Int64(status.st_mtimespec.tv_nsec)
        let (scaled, scaleOverflow) = seconds.multipliedReportingOverflow(
            by: 1_000_000_000
        )
        guard !scaleOverflow else { return nil }
        let (result, additionOverflow) = scaled.addingReportingOverflow(nanoseconds)
        return additionOverflow ? nil : result
    }
}
