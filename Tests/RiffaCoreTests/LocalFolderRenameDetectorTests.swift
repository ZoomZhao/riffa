import Darwin
import Foundation
import Testing
@testable import RiffaCore

@Suite("Local folder rename/move detection")
struct LocalFolderRenameDetectorTests {
    @Test("A unique same-content file is reported across path and directory changes")
    func uniqueRenameAndMove() async throws {
        try await withSandbox { sandbox in
            try sandbox.write("same payload", path: "old/name.txt", side: .left)
            try sandbox.write("same payload", path: "new/location.txt", side: .right)
            let nodes = await sandbox.compare()

            let result = try await LocalFolderRenameDetector().detect(nodes: nodes)

            #expect(result.matches.count == 1)
            #expect(result.matches.first?.leftRelativePath == "old/name.txt")
            #expect(result.matches.first?.rightRelativePath == "new/location.txt")
            #expect(result.matches.first?.byteCount == 12)
            #expect(result.matches.first?.digest.count == 64)
            #expect(result.ambiguousGroups.isEmpty)
            #expect(result.eligibleCandidateCount == 2)
            #expect(result.hashedCandidateCount == 2)
            #expect(result.hashedByteCount == 24)
            #expect(result.unmatchedCandidateCount == 0)
        }
    }

    @Test("Equal declared sizes are confirmed by content rather than guessed")
    func sameSizeDifferentContent() async throws {
        try await withSandbox { sandbox in
            try sandbox.write("LEFT", path: "old.txt", side: .left)
            try sandbox.write("RGHT", path: "new.txt", side: .right)

            let result = try await LocalFolderRenameDetector().detect(
                nodes: await sandbox.compare()
            )

            #expect(result.matches.isEmpty)
            #expect(result.ambiguousGroups.isEmpty)
            #expect(result.hashedCandidateCount == 2)
            #expect(result.unmatchedCandidateCount == 2)
        }
    }

    @Test("Repeated content is explicit ambiguity and is never arbitrarily paired")
    func duplicateContentIsAmbiguous() async throws {
        try await withSandbox { sandbox in
            for path in ["a.txt", "z.txt"] {
                try sandbox.write("duplicate", path: path, side: .left)
            }
            for path in ["b.txt", "y.txt"] {
                try sandbox.write("duplicate", path: path, side: .right)
            }

            let result = try await LocalFolderRenameDetector().detect(
                nodes: await sandbox.compare()
            )

            #expect(result.matches.isEmpty)
            #expect(result.ambiguousGroups.count == 1)
            #expect(result.ambiguousGroups.first?.leftRelativePaths == ["a.txt", "z.txt"])
            #expect(result.ambiguousGroups.first?.rightRelativePaths == ["b.txt", "y.txt"])
            #expect(result.ambiguousCandidateCount == 4)
            #expect(result.unmatchedCandidateCount == 0)
        }
    }

    @Test("Candidate, per-file, and aggregate hash budgets fail before unsafe work")
    func workBudgets() async throws {
        try await withSandbox { sandbox in
            try sandbox.write("AB", path: "left.bin", side: .left)
            try sandbox.write("AB", path: "right.bin", side: .right)
            let nodes = await sandbox.compare()

            let candidateLimits = try FolderRenameDetectionLimits(maximumCandidateCount: 1)
            await #expect(throws: FolderRenameDetectionError.candidateLimitExceeded(
                actual: 2,
                limit: 1
            )) {
                try await LocalFolderRenameDetector(limits: candidateLimits).detect(nodes: nodes)
            }

            let fileLimits = try FolderRenameDetectionLimits(
                maximumSingleFileByteCount: 1
            )
            await #expect(throws: FolderRenameDetectionError.fileByteLimitExceeded(
                side: .left,
                actual: 2,
                limit: 1
            )) {
                try await LocalFolderRenameDetector(limits: fileLimits).detect(nodes: nodes)
            }

            let totalLimits = try FolderRenameDetectionLimits(
                maximumSingleFileByteCount: 2,
                maximumTotalHashedByteCount: 3
            )
            await #expect(throws: FolderRenameDetectionError.totalHashedByteLimitExceeded(
                actual: 4,
                limit: 3
            )) {
                try await LocalFolderRenameDetector(limits: totalLimits).detect(nodes: nodes)
            }
        }
    }

    @Test("Files in one-sided size buckets are not hashed or rejected by byte limits")
    func hashesOnlySharedSizeBuckets() async throws {
        try await withSandbox { sandbox in
            try sandbox.write("AB", path: "only-left.bin", side: .left)
            try sandbox.write("XYZ", path: "only-right.bin", side: .right)
            let limits = try FolderRenameDetectionLimits(
                maximumSingleFileByteCount: 1,
                maximumTotalHashedByteCount: 1
            )

            let result = try await LocalFolderRenameDetector(limits: limits).detect(
                nodes: await sandbox.compare()
            )

            #expect(result.eligibleCandidateCount == 2)
            #expect(result.hashedCandidateCount == 0)
            #expect(result.hashedByteCount == 0)
        }
    }

    @Test("All limits are strict, round-trip through Codable, and zero is never unlimited")
    func strictCodableLimits() throws {
        let limits = try FolderRenameDetectionLimits(
            maximumCandidateCount: 7,
            maximumSingleFileByteCount: 8,
            maximumTotalHashedByteCount: 9,
            hashChunkByteCount: 10
        )
        let encoded = try JSONEncoder().encode(limits)
        #expect(try JSONDecoder().decode(FolderRenameDetectionLimits.self, from: encoded) == limits)
        requireSendable(limits)

        #expect(throws: FolderRenameDetectionError.invalidLimits) {
            try FolderRenameDetectionLimits(maximumCandidateCount: 0)
        }
        #expect(throws: FolderRenameDetectionError.invalidLimits) {
            try FolderRenameDetectionLimits(maximumSingleFileByteCount: 0)
        }
        #expect(throws: FolderRenameDetectionError.invalidLimits) {
            try FolderRenameDetectionLimits(maximumTotalHashedByteCount: 0)
        }
        #expect(throws: FolderRenameDetectionError.invalidLimits) {
            try FolderRenameDetectionLimits(hashChunkByteCount: 0)
        }

        let invalidJSON = Data("""
        {"maximumCandidateCount":1,"maximumSingleFileByteCount":1,"maximumTotalHashedByteCount":1,"hashChunkByteCount":0}
        """.utf8)
        #expect(throws: FolderRenameDetectionError.invalidLimits) {
            try JSONDecoder().decode(FolderRenameDetectionLimits.self, from: invalidJSON)
        }
    }

    @Test("A symbolic-link path swap is refused and errors do not expose paths")
    func rejectsSymbolicLinkSwap() async throws {
        try await withSandbox { sandbox in
            try sandbox.write("AA", path: "old.bin", side: .left)
            try sandbox.write("AA", path: "new.bin", side: .right)
            let nodes = await sandbox.compare()
            let replacement = sandbox.root.appending(path: "replacement.bin")
            try Data("AA".utf8).write(to: replacement)
            let original = sandbox.left.appending(path: "old.bin")
            try FileManager.default.removeItem(at: original)
            try FileManager.default.createSymbolicLink(at: original, withDestinationURL: replacement)

            do {
                _ = try await LocalFolderRenameDetector().detect(nodes: nodes)
                Issue.record("Expected O_NOFOLLOW to refuse the swapped symbolic link")
            } catch let error as FolderRenameDetectionError {
                #expect(error == .operationFailed(side: .left, operation: .open, code: ELOOP))
                #expect(!error.localizedDescription.contains(sandbox.root.path))
                #expect(!error.localizedDescription.contains("old.bin"))
            }
        }
    }

    @Test("A regular-file path swap is detected from enumeration identity")
    func rejectsRegularFileSwap() async throws {
        try await withSandbox { sandbox in
            try sandbox.write("AA", path: "old.bin", side: .left)
            try sandbox.write("AA", path: "new.bin", side: .right)
            let nodes = await sandbox.compare()
            let original = sandbox.left.appending(path: "old.bin")
            let replacement = sandbox.left.appending(path: "replacement.bin")
            try Data("AA".utf8).write(to: replacement)
            try FileManager.default.removeItem(at: original)
            try FileManager.default.moveItem(at: replacement, to: original)

            await #expect(throws: FolderRenameDetectionError.fileChangedDuringDetection(
                side: .left
            )) {
                try await LocalFolderRenameDetector().detect(nodes: nodes)
            }
        }
    }

    @Test("A special file cannot be smuggled in with a declared file kind")
    func rejectsSpecialFile() async throws {
        try await withSandbox { sandbox in
            let fifo = sandbox.left.appending(path: "pipe")
            let fifoResult = fifo.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return Darwin.mkfifo(path, 0o600)
            }
            #expect(fifoResult == 0)
            let regular = sandbox.right.appending(path: "empty")
            try Data().write(to: regular)
            let nodes = [
                candidateNode(url: fifo, path: "pipe", side: .left),
                candidateNode(url: regular, path: "empty", side: .right),
            ]

            await #expect(throws: FolderRenameDetectionError.notRegularFile(side: .left)) {
                try await LocalFolderRenameDetector().detect(nodes: nodes)
            }
        }
    }

    @Test("Results are deterministic for shuffled input and cancellation is observed")
    func determinismAndCancellation() async throws {
        try await withSandbox { sandbox in
            try sandbox.write("one", path: "z-old.txt", side: .left)
            try sandbox.write("one", path: "a-new.txt", side: .right)
            try sandbox.write("two", path: "a-old.txt", side: .left)
            try sandbox.write("two", path: "z-new.txt", side: .right)
            let nodes = await sandbox.compare()
            let detector = LocalFolderRenameDetector()
            requireSendable(detector)

            let first = try await detector.detect(nodes: nodes.reversed())
            let second = try await detector.detect(nodes: nodes.shuffled())
            #expect(first == second)
            #expect(first.matches.map(\.leftRelativePath) == ["a-old.txt", "z-old.txt"])
            requireSendable(first)

            let task = Task {
                try await detector.detect(nodes: nodes)
            }
            task.cancel()
            await #expect(throws: CancellationError.self) {
                try await task.value
            }
        }
    }

    private func candidateNode(
        url: URL,
        path: String,
        side: FolderRenameDetectionError.Side
    ) -> PairNode {
        let entry = ResourceEntry(
            locator: ResourceLocator(fileURL: url),
            relativePath: path,
            kind: .file,
            byteCount: 0
        )
        return PairNode(
            relativePath: path,
            left: side == .left ? entry : nil,
            right: side == .right ? entry : nil,
            status: side == .left ? .leftOnly : .rightOnly
        )
    }

    private func requireSendable<T: Sendable>(_: T) {}

    private func withSandbox(
        _ body: (RenameSandbox) async throws -> Void
    ) async throws {
        let sandbox = try RenameSandbox()
        defer { sandbox.remove() }
        try await body(sandbox)
    }
}

private struct RenameSandbox {
    enum Side { case left, right }

    let root: URL
    let left: URL
    let right: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "RiffaRenameDetection-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        left = root.appending(path: "left", directoryHint: .isDirectory)
        right = root.appending(path: "right", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func write(_ value: String, path: String, side: Side) throws {
        let sideRoot = side == .left ? left : right
        let destination = sideRoot.appending(path: path)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(value.utf8).write(to: destination)
    }

    func compare() async -> [PairNode] {
        await FolderComparison().compare(
            leftURL: left,
            rightURL: right,
            options: FolderComparisonOptions(compareModificationDates: false)
        )
    }
}
