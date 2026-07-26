import Darwin
import Foundation
import Testing
@testable import RiffaCore

@Suite("Descriptor-backed local file byte equality")
struct LocalFileByteComparatorTests {
    @Test("Same, different, and empty files compare in bounded chunks")
    func basicEquality() async throws {
        try await withSandbox { sandbox in
            try sandbox.write(Data("abcdefgh".utf8), name: "left.bin")
            try sandbox.write(Data("abcdefgh".utf8), name: "right.bin")
            var entries = try await sandbox.entries()
            let comparator = try LocalFileByteComparator(chunkByteCount: 3)

            #expect(try comparator.compare(entries["left.bin"]!, entries["right.bin"]!))

            try sandbox.write(Data("abcdEfgh".utf8), name: "right.bin")
            entries = try await sandbox.entries()
            #expect(try !comparator.compare(entries["left.bin"]!, entries["right.bin"]!))

            try sandbox.write(Data(), name: "left.bin")
            try sandbox.write(Data(), name: "right.bin")
            entries = try await sandbox.entries()
            #expect(try comparator.compare(entries["left.bin"]!, entries["right.bin"]!))
        }
    }

    @Test("Chunk sizes are rejected instead of silently normalized")
    func invalidChunkSize() {
        #expect(throws: LocalFileByteComparisonError.invalidChunkByteCount) {
            try LocalFileByteComparator(chunkByteCount: 0)
        }
        #expect(throws: LocalFileByteComparisonError.invalidChunkByteCount) {
            try LocalFileByteComparator(chunkByteCount: -1)
        }
    }

    @Test("Declared identity, size, and permission mismatches fail closed")
    func declaredMetadataMismatches() async throws {
        try await withSandbox { sandbox in
            try sandbox.write(Data("same".utf8), name: "left.bin")
            try sandbox.write(Data("same".utf8), name: "right.bin")
            let entries = try await sandbox.entries()
            let left = entries["left.bin"]!
            let right = entries["right.bin"]!
            let comparator = try LocalFileByteComparator(chunkByteCount: 2)

            let wrongIdentity = copy(left, fileIdentifier: "0:1")
            #expect(throws: LocalFileByteComparisonError.declaredFileIdentifierMismatch(side: .left)) {
                try comparator.compare(wrongIdentity, right)
            }

            let wrongSize = copy(left, byteCount: (left.byteCount ?? 0) + 1)
            #expect(throws: LocalFileByteComparisonError.declaredByteCountMismatch(
                side: .left,
                expected: 5,
                actual: 4
            )) {
                try comparator.compare(wrongSize, right)
            }

            let actualPermissions = try #require(left.permissions)
            let wrongPermissions = copy(left, permissions: actualPermissions ^ 0o100)
            #expect(throws: LocalFileByteComparisonError.declaredPermissionsMismatch(
                side: .left,
                expected: actualPermissions ^ 0o100,
                actual: actualPermissions
            )) {
                try comparator.compare(wrongPermissions, right)
            }
        }
    }

    @Test("A regular path replaced by a different inode is rejected")
    func rejectsInodeReplacement() async throws {
        try await withSandbox { sandbox in
            try sandbox.write(Data("same".utf8), name: "left.bin")
            try sandbox.write(Data("same".utf8), name: "right.bin")
            let entries = try await sandbox.entries()
            let oldLeft = entries["left.bin"]!
            let right = entries["right.bin"]!

            try FileManager.default.removeItem(at: sandbox.url("left.bin"))
            try sandbox.write(Data("same".utf8), name: "left.bin")

            let comparator = try LocalFileByteComparator(chunkByteCount: 2)
            #expect(throws: LocalFileByteComparisonError.declaredFileIdentifierMismatch(side: .left)) {
                try comparator.compare(oldLeft, right)
            }
        }
    }

    @Test("A regular path replaced by a symbolic link is never followed")
    func rejectsSymlinkReplacement() async throws {
        try await withSandbox { sandbox in
            try sandbox.write(Data("same".utf8), name: "left.bin")
            try sandbox.write(Data("same".utf8), name: "right.bin")
            let entries = try await sandbox.entries()
            let oldLeft = entries["left.bin"]!
            let right = entries["right.bin"]!

            try FileManager.default.removeItem(at: sandbox.url("left.bin"))
            try FileManager.default.createSymbolicLink(
                at: sandbox.url("left.bin"),
                withDestinationURL: sandbox.url("right.bin")
            )

            do {
                _ = try LocalFileByteComparator(chunkByteCount: 2).compare(oldLeft, right)
                Issue.record("Expected O_NOFOLLOW to reject the replacement link")
            } catch let error as LocalFileByteComparisonError {
                #expect(error == .operationFailed(side: .left, operation: .open, code: ELOOP))
                #expect(!error.localizedDescription.contains(sandbox.root.path))
                #expect(!error.localizedDescription.contains("left.bin"))
            }
        }
    }

    @Test("FIFO inputs are rejected without blocking")
    func rejectsFIFOWithoutBlocking() async throws {
        try await withSandbox { sandbox in
            try sandbox.write(Data("regular".utf8), name: "right.bin")
            let right = try #require(try await sandbox.entries()["right.bin"])
            let fifoURL = sandbox.url("named-pipe")
            let status = fifoURL.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return Darwin.mkfifo(path, 0o600)
            }
            #expect(status == 0)
            let declaredFile = ResourceEntry(
                locator: ResourceLocator(fileURL: fifoURL),
                relativePath: "named-pipe",
                kind: .file,
                byteCount: 0,
                permissions: 0o600
            )

            do {
                _ = try LocalFileByteComparator(chunkByteCount: 4)
                    .compare(declaredFile, right)
                Issue.record("Expected the FIFO to be rejected")
            } catch let error as LocalFileByteComparisonError {
                #expect(error == .notRegularFile(side: .left))
                #expect(!error.localizedDescription.contains(sandbox.root.path))
                #expect(!error.localizedDescription.contains("named-pipe"))
            }
        }
    }

    @Test("Cancellation is observed after descriptors are validated")
    func cancellation() async throws {
        try await withSandbox { sandbox in
            try sandbox.write(Data(repeating: 0x41, count: 32), name: "left.bin")
            try sandbox.write(Data(repeating: 0x41, count: 32), name: "right.bin")
            let entries = try await sandbox.entries()
            let left = entries["left.bin"]!
            let right = entries["right.bin"]!

            let task = Task {
                let comparator = try LocalFileByteComparator(
                    chunkByteCount: 1,
                    checkpoint: { checkpoint in
                        if case .descriptorsValidated = checkpoint {
                            withUnsafeCurrentTask { $0?.cancel() }
                        }
                    }
                )
                return try comparator.compare(left, right)
            }
            do {
                _ = try await task.value
                Issue.record("Expected deterministic cancellation")
            } catch is CancellationError {
                // Expected.
            }
        }
    }

    @Test("An early byte mismatch still performs final TOCTOU verification")
    func earlyMismatchVerifiesVersions() async throws {
        try await withSandbox { sandbox in
            try sandbox.write(Data("LEFT".utf8), name: "left.bin")
            try sandbox.write(Data("RGHT".utf8), name: "right.bin")
            let entries = try await sandbox.entries()
            let left = entries["left.bin"]!
            let right = entries["right.bin"]!
            let leftURL = sandbox.url("left.bin")
            let changedMode = mode_t((left.permissions ?? 0o600) ^ 0o100)

            let comparator = try LocalFileByteComparator(
                chunkByteCount: 4,
                checkpoint: { checkpoint in
                    guard case .beforeFinalVerification = checkpoint else { return }
                    let status = leftURL.withUnsafeFileSystemRepresentation { path in
                        guard let path else { return Int32(-1) }
                        return Darwin.chmod(path, changedMode)
                    }
                    guard status == 0 else { throw ComparatorTestMutationError.failed }
                }
            )
            #expect(throws: LocalFileByteComparisonError.fileChangedDuringComparison(side: .left)) {
                try comparator.compare(left, right)
            }
        }
    }

    @Test("A regular path rebound after opening cannot return equality")
    func finalPathRebindingIsRejected() async throws {
        try await withSandbox { sandbox in
            try sandbox.write(Data("same".utf8), name: "left.bin")
            try sandbox.write(Data("same".utf8), name: "right.bin")
            let entries = try await sandbox.entries()
            let left = entries["left.bin"]!
            let right = entries["right.bin"]!
            let leftURL = sandbox.url("left.bin")

            let comparator = try LocalFileByteComparator(
                chunkByteCount: 2,
                checkpoint: { checkpoint in
                    guard case .beforeFinalVerification = checkpoint else { return }
                    try FileManager.default.removeItem(at: leftURL)
                    try Data("same".utf8).write(to: leftURL)
                }
            )
            #expect(throws: LocalFileByteComparisonError.fileChangedDuringComparison(side: .left)) {
                try comparator.compare(left, right)
            }
        }
    }
}

private enum ComparatorTestMutationError: Error {
    case failed
}

private struct LocalFileComparatorSandbox {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "RiffaLocalFileComparatorTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func url(_ name: String) -> URL {
        root.appending(path: name)
    }

    func write(_ data: Data, name: String) throws {
        try data.write(to: url(name))
    }

    func entries() async throws -> [String: ResourceEntry] {
        let values = try await LocalResourceProvider(rootURL: root)
            .recursivelyEnumeratedEntries()
        return Dictionary(uniqueKeysWithValues: values.map { ($0.relativePath, $0) })
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func withSandbox(
    _ operation: (LocalFileComparatorSandbox) async throws -> Void
) async throws {
    let sandbox = try LocalFileComparatorSandbox()
    defer { sandbox.remove() }
    try await operation(sandbox)
}

private func copy(
    _ entry: ResourceEntry,
    byteCount: Int64? = nil,
    permissions: UInt16? = nil,
    fileIdentifier: String? = nil
) -> ResourceEntry {
    ResourceEntry(
        locator: entry.locator,
        relativePath: entry.relativePath,
        kind: entry.kind,
        byteCount: byteCount ?? entry.byteCount,
        modificationDate: entry.modificationDate,
        permissions: permissions ?? entry.permissions,
        fileIdentifier: fileIdentifier ?? entry.fileIdentifier,
        symbolicLinkDestination: entry.symbolicLinkDestination,
        issue: entry.issue
    )
}
