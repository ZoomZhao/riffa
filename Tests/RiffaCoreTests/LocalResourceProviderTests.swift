import Darwin
import Foundation
import Testing
@testable import RiffaCore

@Suite("Bounded local resource enumeration")
struct LocalResourceProviderTests {
    @Test("Limits validate strictly and preserve a Codable value boundary")
    func validatesAndRoundTripsLimits() throws {
        #expect(throws: LocalResourceLimitError.invalidMaximumEntryCount(actual: 0)) {
            _ = try LocalResourceLimits(
                maximumEntryCount: 0,
                maximumDepth: 1,
                maximumRelativePathUTF8ByteCount: 1
            )
        }
        #expect(throws: LocalResourceLimitError.invalidMaximumDepth(actual: -1)) {
            _ = try LocalResourceLimits(
                maximumEntryCount: 1,
                maximumDepth: -1,
                maximumRelativePathUTF8ByteCount: 1
            )
        }
        #expect(throws: LocalResourceLimitError.invalidMaximumRelativePathUTF8ByteCount(actual: 0)) {
            _ = try LocalResourceLimits(
                maximumEntryCount: 1,
                maximumDepth: 1,
                maximumRelativePathUTF8ByteCount: 0
            )
        }

        let limits = try LocalResourceLimits(
            maximumEntryCount: 17,
            maximumDepth: 3,
            maximumRelativePathUTF8ByteCount: 99
        )
        let encoded = try JSONEncoder().encode(limits)
        #expect(try JSONDecoder().decode(LocalResourceLimits.self, from: encoded) == limits)
        let invalidEncoded = Data(
            #"{"maximumEntryCount":-1,"maximumDepth":3,"maximumRelativePathUTF8ByteCount":99}"#.utf8
        )
        #expect(throws: LocalResourceLimitError.invalidMaximumEntryCount(actual: -1)) {
            _ = try JSONDecoder().decode(LocalResourceLimits.self, from: invalidEncoded)
        }
        #expect(LocalResourceLimits.default.maximumEntryCount > 0)
        #expect(LocalResourceLimits.default.maximumDepth > 0)
        #expect(LocalResourceLimits.default.maximumRelativePathUTF8ByteCount > 0)
    }

    @Test("Entry ceiling fails structurally without embedding a path")
    func enforcesEntryLimitPrivately() async throws {
        try await withTemporaryDirectory { root in
            try write("one", to: root.appending(path: "private-one.txt"))
            try write("two", to: root.appending(path: "private-two.txt"))
            let limits = try LocalResourceLimits(
                maximumEntryCount: 1,
                maximumDepth: 8,
                maximumRelativePathUTF8ByteCount: 128
            )

            do {
                _ = try await LocalResourceProvider(
                    rootURL: root,
                    limits: limits
                ).recursivelyEnumeratedEntries()
                Issue.record("Expected the entry ceiling to stop enumeration")
            } catch let error as LocalResourceLimitError {
                #expect(error == .entryCountExceeded(limit: 1))
                #expect(!error.localizedDescription.contains(root.path))
                #expect(!error.localizedDescription.contains("private"))
            }
        }
    }

    @Test("Depth and UTF-8 relative-path ceilings stop the streaming enumerator")
    func enforcesDepthAndPathLimits() async throws {
        try await withTemporaryDirectory { root in
            let nested = root.appending(path: "one/two", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

            let depthLimits = try LocalResourceLimits(
                maximumEntryCount: 10,
                maximumDepth: 1,
                maximumRelativePathUTF8ByteCount: 128
            )
            await #expect(throws: LocalResourceLimitError.depthExceeded(actual: 2, limit: 1)) {
                _ = try await LocalResourceProvider(
                    rootURL: root,
                    limits: depthLimits
                ).recursivelyEnumeratedEntries()
            }
        }

        try await withTemporaryDirectory { root in
            try write("wide", to: root.appending(path: "12345678"))
            let pathLimits = try LocalResourceLimits(
                maximumEntryCount: 10,
                maximumDepth: 2,
                maximumRelativePathUTF8ByteCount: 7
            )
            await #expect(throws: LocalResourceLimitError.relativePathUTF8ByteCountExceeded(
                actual: 8,
                limit: 7
            )) {
                _ = try await LocalResourceProvider(
                    rootURL: root,
                    limits: pathLimits
                ).recursivelyEnumeratedEntries()
            }
        }
    }

    @Test("Default enumeration is stable, does not follow links, and retains child access issues")
    func streamsStablyWithoutFollowingLinks() async throws {
        try await withTemporaryDirectory { root in
            let target = root.appending(path: "target", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try write("inside", to: target.appending(path: "inside.txt"))
            try FileManager.default.createSymbolicLink(
                at: root.appending(path: "alias"),
                withDestinationURL: target
            )
            try write("z", to: root.appending(path: "zeta.txt"))
            try write("a", to: root.appending(path: "Alpha.txt"))

            let denied = root.appending(path: "denied", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: true)
            try write("hidden", to: denied.appending(path: "hidden.txt"))
            let chmodResult = denied.path.withCString { Darwin.chmod($0, 0) }
            #expect(chmodResult == 0)
            defer { _ = denied.path.withCString { Darwin.chmod($0, 0o700) } }

            let provider = LocalResourceProvider(rootURL: root)
            let entries = try await provider.recursivelyEnumeratedEntries()
            let paths = entries.map(\.relativePath)
            let expectedOrder = paths.sorted { lhs, rhs in
                let leftKey = PathSemantics.macOSDefault.comparisonKey(for: lhs)
                let rightKey = PathSemantics.macOSDefault.comparisonKey(for: rhs)
                return leftKey == rightKey ? lhs < rhs : leftKey < rightKey
            }

            #expect(paths == expectedOrder)
            #expect(entries.contains { $0.relativePath == "alias" && $0.kind == .symbolicLink })
            #expect(!paths.contains { $0.hasPrefix("alias/") })
            #expect(entries.first { $0.relativePath == "denied" }?.issue != nil)
            #expect(!paths.contains("denied/hidden.txt"))
        }
    }

    @Test("Dangling and cyclic links remain entries in default no-follow enumeration")
    func retainsDanglingAndCyclicLinksWithoutFollowing() async throws {
        try await withTemporaryDirectory { root in
            try FileManager.default.createSymbolicLink(
                atPath: root.appending(path: "dangling").path,
                withDestinationPath: "missing-target"
            )
            try FileManager.default.createSymbolicLink(
                atPath: root.appending(path: "loop").path,
                withDestinationPath: "."
            )

            let provider = LocalResourceProvider(rootURL: root)
            let entries = try await provider.recursivelyEnumeratedEntries()
            let byPath = Dictionary(uniqueKeysWithValues: entries.map {
                ($0.relativePath, $0)
            })

            #expect(entries.count == 2)
            #expect(byPath["dangling"]?.kind == .symbolicLink)
            #expect(byPath["dangling"]?.symbolicLinkDestination == "missing-target")
            #expect(byPath["dangling"]?.issue == nil)
            #expect(byPath["loop"]?.kind == .symbolicLink)
            #expect(byPath["loop"]?.symbolicLinkDestination == ".")
            #expect(byPath["loop"]?.issue == nil)
            #expect(!entries.contains { $0.relativePath.hasPrefix("loop/") })

            let followed = try await provider.recursivelyEnumeratedEntries(
                followSymbolicLinks: true
            )
            #expect(followed.first { $0.relativePath == "dangling" }?.kind == .symbolicLink)
            #expect(followed.first { $0.relativePath == "loop" }?.kind == .symbolicLink)
            #expect(followed.first { $0.relativePath == "loop" }?.issue?.domain ==
                "RiffaCore.LocalResourceProvider")
            #expect(followed.count == 2)
        }
    }

    @Test("Opt-in link traversal detects active-inode cycles and shares aggregate ceilings")
    func followsLinksWithoutCyclingOrBypassingLimits() async throws {
        try await withTemporaryDirectory { root in
            let target = root.appending(path: "target", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try write("inside", to: target.appending(path: "inside.txt"))
            try FileManager.default.createSymbolicLink(
                at: target.appending(path: "back"),
                withDestinationURL: root
            )
            try FileManager.default.createSymbolicLink(
                at: root.appending(path: "alias"),
                withDestinationURL: target
            )

            let entries = try await LocalResourceProvider(
                rootURL: root
            ).recursivelyEnumeratedEntries(followSymbolicLinks: true)
            let paths = entries.map(\.relativePath)
            #expect(paths.contains("alias/inside.txt"))
            #expect(entries.first { $0.relativePath == "alias/back" }?.issue?.domain ==
                "RiffaCore.LocalResourceProvider")
            #expect(!paths.contains { $0.contains("back/alias") || $0.contains("back/target") })
            #expect(entries.count < 20)

            let limits = try LocalResourceLimits(
                maximumEntryCount: 1,
                maximumDepth: 32,
                maximumRelativePathUTF8ByteCount: 256
            )
            await #expect(throws: LocalResourceLimitError.entryCountExceeded(limit: 1)) {
                _ = try await LocalResourceProvider(
                    rootURL: root,
                    limits: limits
                ).recursivelyEnumeratedEntries(followSymbolicLinks: true)
            }
        }
    }

    @Test("Folder comparison forwards local resource limits as privacy-safe issues")
    func folderComparisonForwardsLimits() async throws {
        try await withTemporaryDirectory { root in
            let left = root.appending(path: "left", directoryHint: .isDirectory)
            let right = root.appending(path: "right", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
            for side in [left, right] {
                try write("a", to: side.appending(path: "secret-a.txt"))
                try write("b", to: side.appending(path: "secret-b.txt"))
            }
            let limits = try LocalResourceLimits(
                maximumEntryCount: 1,
                maximumDepth: 8,
                maximumRelativePathUTF8ByteCount: 128
            )

            let result = await FolderComparison().compare(
                leftURL: left,
                rightURL: right,
                options: FolderComparisonOptions(limits: limits)
            )

            #expect(result.count == 1)
            #expect(result.first?.status == .error)
            #expect(result.first?.issues.count == 2)
            #expect(result.first?.issues.allSatisfy {
                $0.path == "." && $0.domain == "RiffaCore.LocalResourceLimit"
            } == true)
            let descriptions = result.first?.issues.compactMap(\.errorDescription).joined() ?? ""
            #expect(!descriptions.contains(root.path))
            #expect(!descriptions.contains("secret"))
        }
    }

    private func withTemporaryDirectory(
        _ body: (URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "RiffaLocalResources-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root)
    }

    private func write(_ string: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(string.utf8).write(to: url)
    }
}
