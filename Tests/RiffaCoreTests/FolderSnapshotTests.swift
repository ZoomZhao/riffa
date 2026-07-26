import CryptoKit
import Darwin
import Foundation
import Testing
@testable import RiffaCore

@Suite("Portable folder snapshots")
struct FolderSnapshotTests {
    @Test("Capture records portable metadata, chunked hashes, and deterministic JSON")
    func captureAndRoundTrip() async throws {
        let fixture = try SnapshotFixture()
        defer { fixture.remove() }
        let secret = "source-content-must-not-be-embedded-\(UUID().uuidString)"
        try fixture.write(secret, to: "zeta.txt")
        try fixture.write("nested", to: "folder/alpha.txt")
        let zetaURL = fixture.rootURL.appendingPathComponent("zeta.txt")
        #expect(Darwin.chmod(zetaURL.path, 0o640) == 0)

        let capture = FolderSnapshotCapture()
        let first = try await capture.capture(
            folderAt: fixture.rootURL,
            options: FolderSnapshotCaptureOptions(hashChunkSize: 3)
        )
        let second = try await capture.capture(
            folderAt: fixture.rootURL,
            options: FolderSnapshotCaptureOptions(hashChunkSize: 1)
        )

        #expect(first == second)
        #expect(first.entries.map(\.relativePath) == [
            "folder", "folder/alpha.txt", "zeta.txt",
        ])
        let zeta = try #require(first.entries.first { $0.relativePath == "zeta.txt" })
        #expect(zeta.kind == .file)
        #expect(zeta.byteCount == UInt64(secret.utf8.count))
        #expect(zeta.posixPermissions == 0o640)
        #expect(zeta.sha256 == sha256(secret))
        #expect(zeta.symbolicLinkTarget == nil)
        #expect(first.issues.isEmpty)

        let firstFile = fixture.directoryURL.appendingPathComponent("one.riffasnapshot")
        let secondFile = fixture.directoryURL.appendingPathComponent("two.riffasnapshot")
        try await FolderSnapshotStore(fileURL: firstFile).save(
            FolderSnapshot(
                entries: first.entries.reversed(),
                issues: first.issues.reversed()
            )
        )
        try await FolderSnapshotStore(fileURL: secondFile).save(second)
        let firstData = try Data(contentsOf: firstFile)
        let secondData = try Data(contentsOf: secondFile)
        let json = String(decoding: firstData, as: UTF8.self)

        #expect(firstData == secondData)
        #expect(!json.contains(fixture.rootURL.path))
        #expect(!json.contains(secret))
        #expect(json.contains(zeta.sha256!))
        let envelope = try JSONDecoder().decode(FolderSnapshotEnvelope.self, from: firstData)
        #expect(envelope.schemaVersion == FolderSnapshotEnvelope.currentSchemaVersion)
        #expect(envelope.snapshot == first)
        #expect(try await FolderSnapshotStore(fileURL: firstFile).load() == first)
    }

    @Test("Snapshot comparison reports additions, removals, changes, and type mismatches")
    func comparison() async throws {
        let fixture = try SnapshotFixture()
        defer { fixture.remove() }
        try fixture.write("same", to: "same.txt")
        try fixture.write("old", to: "changed.txt")
        try fixture.write("remove", to: "removed.txt")
        try fixture.write("file", to: "type")
        let capture = FolderSnapshotCapture()
        let baseline = try await capture.capture(folderAt: fixture.rootURL)

        try fixture.write("new", to: "changed.txt")
        try FileManager.default.removeItem(
            at: fixture.rootURL.appendingPathComponent("removed.txt")
        )
        try fixture.write("added", to: "added.txt")
        try FileManager.default.removeItem(
            at: fixture.rootURL.appendingPathComponent("type")
        )
        try FileManager.default.createDirectory(
            at: fixture.rootURL.appendingPathComponent("type"),
            withIntermediateDirectories: false
        )
        let current = try await capture.capture(folderAt: fixture.rootURL)
        let comparator = FolderSnapshotComparator()
        let result = comparator.compare(left: baseline, right: current)
        let statuses = Dictionary(
            uniqueKeysWithValues: result.rows.map { ($0.relativePath, $0.status) }
        )

        #expect(statuses["same.txt"] == .same)
        #expect(statuses["changed.txt"] == .changed)
        #expect(statuses["removed.txt"] == .leftOnly)
        #expect(statuses["added.txt"] == .rightOnly)
        #expect(statuses["type"] == .typeMismatch)
        #expect(result.hasDifferences)

        let liveResult = try await comparator.compare(
            snapshot: baseline,
            toLiveFolderAt: fixture.rootURL
        )
        #expect(liveResult == result)
        #expect(comparator.compare(left: current, right: current).rows.allSatisfy {
            $0.status == .same
        })
    }

    @Test("Symbolic links are recorded but never followed or exposed as absolute paths")
    func symbolicLinksArePortableAndBounded() async throws {
        let fixture = try SnapshotFixture()
        defer { fixture.remove() }
        let external = fixture.directoryURL.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data("external secret".utf8).write(
            to: external.appendingPathComponent("secret.txt")
        )
        try fixture.write("target", to: "target.txt")
        try FileManager.default.createSymbolicLink(
            atPath: fixture.rootURL.appendingPathComponent("relative-link").path,
            withDestinationPath: "target.txt"
        )
        try FileManager.default.createSymbolicLink(
            atPath: fixture.rootURL.appendingPathComponent("internal-absolute-link").path,
            withDestinationPath: fixture.rootURL.appendingPathComponent("target.txt").path
        )
        try FileManager.default.createSymbolicLink(
            atPath: fixture.rootURL.appendingPathComponent("external-link").path,
            withDestinationPath: external.path
        )
        try FileManager.default.createSymbolicLink(
            atPath: fixture.rootURL.appendingPathComponent("cycle").path,
            withDestinationPath: "."
        )

        let snapshot = try await FolderSnapshotCapture().capture(folderAt: fixture.rootURL)
        let entries = Dictionary(
            uniqueKeysWithValues: snapshot.entries.map { ($0.relativePath, $0) }
        )

        #expect(entries["relative-link"]?.kind == .symbolicLink)
        #expect(entries["relative-link"]?.symbolicLinkTarget == "target.txt")
        #expect(entries["internal-absolute-link"]?.symbolicLinkTarget == "snapshot-root:target.txt")
        #expect(entries["external-link"]?.symbolicLinkTarget?.hasPrefix(
            "absolute-target-sha256:"
        ) == true)
        #expect(entries["cycle"]?.symbolicLinkTarget == ".")
        #expect(!snapshot.entries.contains { $0.relativePath.contains("secret.txt") })
        #expect(!snapshot.entries.contains { $0.relativePath.hasPrefix("cycle/") })

        let fileURL = fixture.directoryURL.appendingPathComponent("links.json")
        try await FolderSnapshotStore(fileURL: fileURL).save(snapshot)
        let json = String(decoding: try Data(contentsOf: fileURL), as: UTF8.self)
        #expect(!json.contains(fixture.rootURL.path))
        #expect(!json.contains(external.path))
        #expect(!json.contains("external secret"))
    }

    @Test("Case and canonical-Unicode collisions are explicit comparison errors")
    func pathCollisions() {
        let decomposed = "cafe\u{301}.txt"
        let precomposed = "caf\u{e9}.txt"
        let issues = FolderSnapshotCapture.detectPathCollisions(in: [
            "Readme", "README", decomposed, precomposed,
        ])

        #expect(issues.count == 2)
        #expect(issues.map(\.kind).contains(.caseCollision))
        #expect(issues.map(\.kind).contains(.unicodeCollision))

        let entry = regularEntry(path: "Readme", digestSeed: "left")
        let left = FolderSnapshot(entries: [entry], issues: issues)
        let right = FolderSnapshot(entries: [entry])
        let rows = FolderSnapshotComparator().compare(left: left, right: right).rows
        #expect(rows.first { $0.relativePath == "Readme" }?.status == .error)
        #expect(rows.contains { $0.status == .error })
    }

    @Test("Entry and aggregate hashing byte limits fail before returning partial snapshots")
    func limits() async throws {
        let entryFixture = try SnapshotFixture()
        defer { entryFixture.remove() }
        try entryFixture.write("one", to: "one.txt")
        try entryFixture.write("two", to: "two.txt")

        do {
            _ = try await FolderSnapshotCapture().capture(
                folderAt: entryFixture.rootURL,
                options: FolderSnapshotCaptureOptions(maximumEntryCount: 1)
            )
            Issue.record("Expected the entry limit to fail")
        } catch let error as FolderSnapshotError {
            #expect(error == .entryLimitExceeded(limit: 1))
        }

        let byteFixture = try SnapshotFixture()
        defer { byteFixture.remove() }
        try byteFixture.write("1234", to: "four-bytes.txt")
        do {
            _ = try await FolderSnapshotCapture().capture(
                folderAt: byteFixture.rootURL,
                options: FolderSnapshotCaptureOptions(maximumByteCount: 3)
            )
            Issue.record("Expected the byte limit to fail")
        } catch let error as FolderSnapshotError {
            #expect(error == .byteLimitExceeded(limit: 3, attempted: 4))
        }

        let emptyFixture = try SnapshotFixture()
        defer { emptyFixture.remove() }
        try emptyFixture.write("", to: "empty.txt")
        let empty = try await FolderSnapshotCapture().capture(
            folderAt: emptyFixture.rootURL,
            options: FolderSnapshotCaptureOptions(
                maximumEntryCount: 1,
                maximumByteCount: 0
            )
        )
        #expect(empty.entries.first?.sha256 == sha256(""))
    }

    @Test("Depth and UTF-8 relative path limits have exact boundaries and path-free errors")
    func traversalLimits() async throws {
        let emptyFixture = try SnapshotFixture()
        defer { emptyFixture.remove() }
        let empty = try await FolderSnapshotCapture().capture(
            folderAt: emptyFixture.rootURL,
            options: FolderSnapshotCaptureOptions(maximumDepth: 0)
        )
        #expect(empty == .empty)

        let fixture = try SnapshotFixture()
        defer { fixture.remove() }
        try fixture.write("nested", to: "one/two.txt")

        do {
            _ = try await FolderSnapshotCapture().capture(
                folderAt: fixture.rootURL,
                options: FolderSnapshotCaptureOptions(maximumDepth: 1)
            )
            Issue.record("Expected the depth limit to fail")
        } catch let error as FolderSnapshotError {
            #expect(error == .depthLimitExceeded(limit: 1, attempted: 2))
            #expect(!String(reflecting: error).contains(fixture.rootURL.path))
        }

        let boundary = try await FolderSnapshotCapture().capture(
            folderAt: fixture.rootURL,
            options: FolderSnapshotCaptureOptions(maximumDepth: 2)
        )
        #expect(boundary.entries.map(\.relativePath) == ["one", "one/two.txt"])

        let pathFixture = try SnapshotFixture()
        defer { pathFixture.remove() }
        try pathFixture.write("x", to: "abcdef")
        do {
            _ = try await FolderSnapshotCapture().capture(
                folderAt: pathFixture.rootURL,
                options: FolderSnapshotCaptureOptions(
                    maximumRelativePathUTF8ByteCount: 5
                )
            )
            Issue.record("Expected the relative path byte limit to fail")
        } catch let error as FolderSnapshotError {
            #expect(error == .relativePathByteLimitExceeded(limit: 5, attempted: 6))
            #expect(!String(reflecting: error).contains(pathFixture.rootURL.path))
        }

        let pathBoundary = try await FolderSnapshotCapture().capture(
            folderAt: pathFixture.rootURL,
            options: FolderSnapshotCaptureOptions(
                maximumRelativePathUTF8ByteCount: 6
            )
        )
        #expect(pathBoundary.entries.map(\.relativePath) == ["abcdef"])
    }

    @Test("New traversal options decode compatibly and reject invalid signed limits")
    func traversalOptionValidation() async throws {
        let options = FolderSnapshotCaptureOptions(
            maximumEntryCount: 7,
            maximumByteCount: 99,
            hashChunkSize: 11,
            maximumDepth: 3,
            maximumRelativePathUTF8ByteCount: 123
        )
        let roundTrip = try JSONDecoder().decode(
            FolderSnapshotCaptureOptions.self,
            from: JSONEncoder().encode(options)
        )
        #expect(roundTrip == options)

        let legacy = Data(
            #"{"maximumEntryCount":7,"maximumByteCount":99,"hashChunkSize":11}"#.utf8
        )
        let decodedLegacy = try JSONDecoder().decode(
            FolderSnapshotCaptureOptions.self,
            from: legacy
        )
        #expect(decodedLegacy.maximumDepth == 512)
        #expect(decodedLegacy.maximumRelativePathUTF8ByteCount == 64 * 1_024)

        var invalidDepth = options
        invalidDepth.maximumDepth = -1
        do {
            _ = try JSONDecoder().decode(
                FolderSnapshotCaptureOptions.self,
                from: JSONEncoder().encode(invalidDepth)
            )
            Issue.record("Expected decoding to reject a negative depth")
        } catch is DecodingError {
            // Expected.
        }

        let fixture = try SnapshotFixture()
        defer { fixture.remove() }
        do {
            _ = try await FolderSnapshotCapture().capture(
                folderAt: fixture.rootURL,
                options: invalidDepth
            )
            Issue.record("Expected capture to reject a mutated negative depth")
        } catch let error as FolderSnapshotError {
            #expect(error == .invalidCaptureOptions(reason: .negativeMaximumDepth))
        }

        var invalidPath = options
        invalidPath.maximumRelativePathUTF8ByteCount = -1
        do {
            _ = try await FolderSnapshotCapture().capture(
                folderAt: fixture.rootURL,
                options: invalidPath
            )
            Issue.record("Expected capture to reject a mutated negative path limit")
        } catch let error as FolderSnapshotError {
            #expect(error == .invalidCaptureOptions(
                reason: .negativeMaximumRelativePathUTF8ByteCount
            ))
        }
    }

    @Test("FIFO entries do not block and large directory output remains deterministic")
    func specialFileAndLargeDirectoryDeterminism() async throws {
        let fixture = try SnapshotFixture()
        defer { fixture.remove() }

        let fifoURL = fixture.rootURL.appendingPathComponent("named-pipe")
        #expect(Darwin.mkfifo(fifoURL.path, 0o600) == 0)
        for index in (0..<512).reversed() {
            try fixture.write("", to: String(format: "items/%04d.txt", index))
        }
        try FileManager.default.createSymbolicLink(
            atPath: fixture.rootURL.appendingPathComponent("items-link").path,
            withDestinationPath: "items"
        )

        let capture = FolderSnapshotCapture()
        let first = try await capture.capture(folderAt: fixture.rootURL)
        let second = try await capture.capture(folderAt: fixture.rootURL)

        #expect(first == second)
        #expect(first.entries.count == 515)
        #expect(first.entries.first { $0.relativePath == "named-pipe" }?.kind == .other)
        #expect(first.entries.first { $0.relativePath == "items-link" }?.kind == .symbolicLink)
        #expect(!first.entries.contains { $0.relativePath.hasPrefix("items-link/") })
        #expect(first.entries.map(\.relativePath) == first.entries.map(\.relativePath).sorted {
            $0.utf8.lexicographicallyPrecedes($1.utf8)
        })
    }

    @Test("Capture cooperatively observes task cancellation")
    func cancellation() async throws {
        let fixture = try SnapshotFixture()
        defer { fixture.remove() }
        let large = Data(repeating: 0x61, count: 256 * 1_024)
        try large.write(to: fixture.rootURL.appendingPathComponent("large.bin"))

        let task = Task {
            try await FolderSnapshotCapture().capture(
                folderAt: fixture.rootURL,
                options: FolderSnapshotCaptureOptions(hashChunkSize: 1)
            )
        }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected cancellation error: \(error)")
        }
    }

    @Test("Corrupted and unsupported files are rejected and never overwritten")
    func persistenceGuards() async throws {
        let fixture = try SnapshotFixture()
        defer { fixture.remove() }
        let snapshot = FolderSnapshot.empty
        let destination = fixture.directoryURL.appendingPathComponent("guard.json")
        let store = FolderSnapshotStore(fileURL: destination)

        let corrupt = Data("{ broken snapshot".utf8)
        try corrupt.write(to: destination)
        do {
            try await store.save(snapshot)
            Issue.record("Expected corrupt data to block save")
        } catch let error as FolderSnapshotError {
            #expect(error == .corruptedJSON)
        }
        #expect(try Data(contentsOf: destination) == corrupt)

        let future = Data("{\"schemaVersion\":99,\"snapshot\":{\"entries\":[],\"issues\":[]}}".utf8)
        try future.write(to: destination)
        do {
            try await store.save(snapshot)
            Issue.record("Expected future data to block save")
        } catch let error as FolderSnapshotError {
            #expect(error == .futureSchemaVersion(found: 99, supported: 1))
        }
        #expect(try Data(contentsOf: destination) == future)

        let old = Data("{\"schemaVersion\":0,\"snapshot\":{\"entries\":[],\"issues\":[]}}".utf8)
        try old.write(to: destination)
        do {
            _ = try await store.load()
            Issue.record("Expected old data to require migration")
        } catch let error as FolderSnapshotError {
            #expect(error == .migrationRequired(found: 0, current: 1))
        }
        #expect(try Data(contentsOf: destination) == old)
    }

    @Test("Store validates relative paths, digests, and link targets before atomic replacement")
    func validationAndAtomicReplacement() async throws {
        let fixture = try SnapshotFixture()
        defer { fixture.remove() }
        let destination = fixture.directoryURL.appendingPathComponent("validated.json")
        let store = FolderSnapshotStore(fileURL: destination)
        try await store.save(.empty)
        let original = try Data(contentsOf: destination)

        let unsafe = FolderSnapshot(entries: [
            FolderSnapshotEntry(
                relativePath: "../escape",
                kind: .file,
                byteCount: 0,
                modificationTimeNanoseconds: 0,
                posixPermissions: 0o600,
                sha256: sha256("")
            ),
        ])
        do {
            try await store.save(unsafe)
            Issue.record("Expected unsafe path validation")
        } catch let error as FolderSnapshotError {
            #expect(error == .invalidSnapshot(reason: .unsafeRelativePath("../escape")))
        }
        #expect(try Data(contentsOf: destination) == original)

        let absoluteLink = FolderSnapshot(entries: [
            FolderSnapshotEntry(
                relativePath: "link",
                kind: .symbolicLink,
                byteCount: 4,
                modificationTimeNanoseconds: 0,
                posixPermissions: 0o777,
                symbolicLinkTarget: "/private/source"
            ),
        ])
        do {
            try await store.save(absoluteLink)
            Issue.record("Expected absolute link target validation")
        } catch let error as FolderSnapshotError {
            #expect(error == .invalidSnapshot(reason: .invalidSymbolicLinkTarget("link")))
        }
        #expect(try Data(contentsOf: destination) == original)

        let replacement = FolderSnapshot(entries: [regularEntry(path: "safe.txt", digestSeed: "safe")])
        try await store.save(replacement)
        #expect(try await store.load() == replacement)
        let contents = try FileManager.default.contentsOfDirectory(
            at: fixture.directoryURL,
            includingPropertiesForKeys: nil
        )
        #expect(contents.filter { $0.lastPathComponent.hasPrefix("validated.json") }.count == 1)

        let duplicate = FolderSnapshot(entries: [
            regularEntry(path: "duplicate", digestSeed: "one"),
            regularEntry(path: "duplicate", digestSeed: "two"),
        ])
        let duplicateRows = FolderSnapshotComparator().compare(
            left: duplicate,
            right: .empty
        ).rows
        #expect(duplicateRows.count == 1)
        #expect(duplicateRows[0].status == .error)
        #expect(duplicateRows[0].issues.first?.kind == .invalidSnapshot)
    }

}

private func regularEntry(
    path: String,
    digestSeed: String
) -> FolderSnapshotEntry {
    FolderSnapshotEntry(
        relativePath: path,
        kind: .file,
        byteCount: UInt64(digestSeed.utf8.count),
        modificationTimeNanoseconds: 100,
        posixPermissions: 0o644,
        sha256: sha256(digestSeed)
    )
}

private func sha256(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
}

private struct SnapshotFixture {
    let directoryURL: URL
    let rootURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RiffaFolderSnapshotTests-\(UUID().uuidString)")
        rootURL = directoryURL.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    func write(_ string: String, to relativePath: String) throws {
        let url = rootURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(string.utf8).write(to: url)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
