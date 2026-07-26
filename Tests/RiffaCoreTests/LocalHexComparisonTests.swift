import Darwin
import Foundation
import Testing
@testable import RiffaCore

@Suite("Streamed local hexadecimal comparison")
struct LocalHexComparisonTests {
    @Test("Same and changed bytes are exact across chunk boundaries")
    func exactComparison() async throws {
        try await withTemporaryDirectory { directory in
            let left = directory.appending(path: "left.bin")
            let right = directory.appending(path: "right.bin")
            try Data([0, 1, 2, 3, 4, 5, 6, 7]).write(to: left)
            try Data([0, 1, 9, 8, 4, 5, 7, 7]).write(to: right)
            let limits = try LocalHexComparisonLimits(comparisonChunkByteCount: 3)
            let result = try await LocalHexComparisonEngine(limits: limits).compare(
                leftURL: left,
                rightURL: right
            )

            #expect(result.leftByteCount == 8)
            #expect(result.rightByteCount == 8)
            #expect(result.differingBytePositionCount == 3)
            #expect(result.differenceRangeCount == 2)
            #expect(result.publishedDifferenceRanges == [
                LocalBinaryDifferenceRange(startOffset: 2, leftCount: 2, rightCount: 2),
                LocalBinaryDifferenceRange(startOffset: 6, leftCount: 1, rightCount: 1),
            ])

            try Data([0, 1, 2, 3, 4, 5, 6, 7]).write(to: right)
            let same = try await LocalHexComparisonEngine(limits: limits).compare(
                leftURL: left,
                rightURL: right
            )
            #expect(!same.hasDifferences)
            #expect(same.differenceRangeCount == 0)
        }
    }

    @Test("A longer tail is one explicit one-sided range")
    func tailLengthDifference() async throws {
        try await withTemporaryDirectory { directory in
            let left = directory.appending(path: "short.bin")
            let right = directory.appending(path: "long.bin")
            try Data([0x41, 0x42]).write(to: left)
            try Data([0x41, 0x42, 0x43, 0x44, 0x45]).write(to: right)

            let result = try await LocalHexComparisonEngine().compare(
                leftURL: left,
                rightURL: right
            )
            #expect(result.differingBytePositionCount == 3)
            #expect(result.differenceRangeCount == 1)
            #expect(result.publishedDifferenceRanges == [
                LocalBinaryDifferenceRange(startOffset: 2, leftCount: 0, rightCount: 3),
            ])
        }
    }

    @Test("Alternating bytes cannot create an unbounded published range array")
    func boundedPublishedRanges() async throws {
        try await withTemporaryDirectory { directory in
            let left = directory.appending(path: "zeros.bin")
            let right = directory.appending(path: "alternating.bin")
            try Data(repeating: 0, count: 32).write(to: left)
            try Data((0..<32).map { $0.isMultiple(of: 2) ? UInt8(1) : UInt8(0) }).write(to: right)
            let limits = try LocalHexComparisonLimits(
                comparisonChunkByteCount: 5,
                maximumPublishedDifferenceRangeCount: 3
            )

            let result = try await LocalHexComparisonEngine(limits: limits).compare(
                leftURL: left,
                rightURL: right
            )
            #expect(result.differingBytePositionCount == 16)
            #expect(result.differenceRangeCount == 16)
            #expect(result.publishedDifferenceRanges.map(\.startOffset) == [0, 2, 4])
            #expect(result.differenceRangesTruncated)
        }
    }

    @Test("Pages are bounded, offset-safe, and retain row highlighting")
    func boundedPages() async throws {
        try await withTemporaryDirectory { directory in
            let left = directory.appending(path: "left.bin")
            let right = directory.appending(path: "right.bin")
            try Data(Array(UInt8(0)..<UInt8(12))).write(to: left)
            var changed = Array(UInt8(0)..<UInt8(12))
            changed[5] = 0xFF
            try Data(changed).write(to: right)
            let limits = try LocalHexComparisonLimits(pageByteCount: 5, bytesPerRow: 4)
            let engine = LocalHexComparisonEngine(limits: limits)
            let summary = try await engine.compare(leftURL: left, rightURL: right)
            let page = try await engine.page(
                leftURL: left,
                rightURL: right,
                matching: summary,
                offset: 4
            )

            #expect(page.offset == 4)
            #expect(page.endOffset == 9)
            #expect(page.rows.map(\.offset) == [4, 8])
            #expect(page.rows.map(\.leftBytes.count) == [4, 1])
            #expect(page.rows[0].differingColumns == [1])
            #expect(page.hasPreviousPage)
            #expect(page.hasNextPage)

            await #expect(throws: LocalHexComparisonError.pageLengthOutOfBounds(
                requested: 6,
                limit: 5
            )) {
                try await engine.page(
                    leftURL: left,
                    rightURL: right,
                    matching: summary,
                    offset: 0,
                    byteCount: 6
                )
            }
            await #expect(throws: LocalHexComparisonError.pageOffsetOutOfBounds(
                offset: 13,
                maximum: 12
            )) {
                try await engine.page(
                    leftURL: left,
                    rightURL: right,
                    matching: summary,
                    offset: 13
                )
            }
        }
    }

    @Test("Directories, FIFOs, and symbolic links are never followed")
    func rejectsSpecialFiles() async throws {
        try await withTemporaryDirectory { directory in
            let regular = directory.appending(path: "regular.bin")
            try Data([1]).write(to: regular)
            let fifo = directory.appending(path: "named-pipe")
            let fifoResult = fifo.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return Darwin.mkfifo(path, 0o600)
            }
            #expect(fifoResult == 0)
            let link = directory.appending(path: "private-link.bin")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: regular)
            let engine = LocalHexComparisonEngine()

            await #expect(throws: LocalHexComparisonError.notRegularFile(side: .left)) {
                try await engine.compare(leftURL: directory, rightURL: regular)
            }
            await #expect(throws: LocalHexComparisonError.notRegularFile(side: .left)) {
                try await engine.compare(leftURL: fifo, rightURL: regular)
            }
            do {
                _ = try await engine.compare(leftURL: link, rightURL: regular)
                Issue.record("Expected O_NOFOLLOW to reject a symbolic link")
            } catch let error as LocalHexComparisonError {
                #expect(error == .operationFailed(side: .left, operation: .open, code: ELOOP))
                #expect(!error.localizedDescription.contains("private-link.bin"))
                #expect(!error.localizedDescription.contains(directory.path))
            }
        }
    }

    @Test("Byte and chunk work limits fail before comparison allocation")
    func workLimits() async throws {
        try await withTemporaryDirectory { directory in
            let left = directory.appending(path: "left.bin")
            let right = directory.appending(path: "right.bin")
            try Data(repeating: 0, count: 5).write(to: left)
            try Data(repeating: 0, count: 5).write(to: right)

            let byteLimits = try LocalHexComparisonLimits(maximumComparableByteCount: 4)
            await #expect(throws: LocalHexComparisonError.fileTooLarge(
                side: .left,
                actualByteCount: 5,
                limit: 4
            )) {
                try await LocalHexComparisonEngine(limits: byteLimits).compare(
                    leftURL: left,
                    rightURL: right
                )
            }

            let chunkLimits = try LocalHexComparisonLimits(
                maximumComparableByteCount: 5,
                comparisonChunkByteCount: 2,
                maximumComparisonChunkCount: 2
            )
            await #expect(throws: LocalHexComparisonError.comparisonChunkLimitExceeded(
                requiredChunkCount: 3,
                limit: 2
            )) {
                try await LocalHexComparisonEngine(limits: chunkLimits).compare(
                    leftURL: left,
                    rightURL: right
                )
            }
        }
    }

    @Test("All configurable ceilings are strictly positive")
    func invalidLimits() {
        #expect(throws: LocalHexComparisonError.invalidLimits) {
            try LocalHexComparisonLimits(maximumComparableByteCount: 0)
        }
        #expect(throws: LocalHexComparisonError.invalidLimits) {
            try LocalHexComparisonLimits(comparisonChunkByteCount: 0)
        }
        #expect(throws: LocalHexComparisonError.invalidLimits) {
            try LocalHexComparisonLimits(maximumComparisonChunkCount: 0)
        }
        #expect(throws: LocalHexComparisonError.invalidLimits) {
            try LocalHexComparisonLimits(maximumPublishedDifferenceRangeCount: 0)
        }
        #expect(throws: LocalHexComparisonError.invalidLimits) {
            try LocalHexComparisonLimits(pageByteCount: 0)
        }
        #expect(throws: LocalHexComparisonError.invalidLimits) {
            try LocalHexComparisonLimits(bytesPerRow: 0)
        }
    }

    @Test("A page cannot reuse a summary after either input changes")
    func rejectsMutationBetweenSummaryAndPage() async throws {
        try await withTemporaryDirectory { directory in
            let left = directory.appending(path: "left.bin")
            let right = directory.appending(path: "right.bin")
            try Data([1, 2, 3, 4]).write(to: left)
            try Data([1, 2, 3, 4]).write(to: right)
            let engine = LocalHexComparisonEngine()
            let summary = try await engine.compare(leftURL: left, rightURL: right)
            try Data([9, 2, 3, 4]).write(to: left)

            await #expect(throws: LocalHexComparisonError.fileChangedDuringOperation(side: .left)) {
                try await engine.page(
                    leftURL: left,
                    rightURL: right,
                    matching: summary,
                    offset: 0
                )
            }
        }
    }

    @Test("Cancellation is observed and public values are Sendable")
    func cancellationAndSendable() async throws {
        try await withTemporaryDirectory { directory in
            let left = directory.appending(path: "left.bin")
            let right = directory.appending(path: "right.bin")
            try Data(repeating: 0, count: 1_024).write(to: left)
            try Data(repeating: 1, count: 1_024).write(to: right)
            let engine = LocalHexComparisonEngine()
            requireSendable(engine)
            requireSendable(LocalHexComparisonLimits.standard)

            let task = Task {
                try await engine.compare(leftURL: left, rightURL: right)
            }
            task.cancel()
            await #expect(throws: CancellationError.self) {
                try await task.value
            }

            let summary = try await engine.compare(leftURL: left, rightURL: right)
            requireSendable(summary)
            let page = try await engine.page(
                leftURL: left,
                rightURL: right,
                matching: summary,
                offset: 0
            )
            requireSendable(page)
        }
    }

    @Test("Streamed reports are stable, bounded, and preserve exact totals")
    func stableReport() async throws {
        try await withTemporaryDirectory { directory in
            let left = directory.appending(path: "secret-left.bin")
            let right = directory.appending(path: "secret-right.bin")
            try Data(repeating: 0, count: 8).write(to: left)
            try Data([1, 0, 1, 0, 1, 0, 1, 0]).write(to: right)
            let limits = try LocalHexComparisonLimits(maximumPublishedDifferenceRangeCount: 2)
            let summary = try await LocalHexComparisonEngine(limits: limits).compare(
                leftURL: left,
                rightURL: right
            )
            let generator = SpecializedComparisonReportGenerator()
            let first = try generator.generate(
                hex: summary,
                format: .json,
                leftLabel: "left.bin",
                rightLabel: "right.bin"
            )
            let second = try generator.generate(
                hex: summary,
                format: .json,
                leftLabel: "left.bin",
                rightLabel: "right.bin"
            )

            #expect(first == second)
            #expect(first.contains("differenceRangeCount"))
            #expect(first.contains("differenceRangesTruncated"))
            #expect(first.contains("publishedDifferenceRangeCount"))
            #expect(!first.contains(directory.path))
            #expect(generator.document(for: summary).rows.count == 2)
            for format in [ComparisonReportFormat.plainText, .html, .json] {
                let report = try generator.generate(
                    hex: summary,
                    format: format,
                    leftLabel: left.path,
                    rightLabel: right.path
                )
                #expect(!report.contains(directory.path))
                #expect(report.contains("secret-left.bin"))
                #expect(report.contains("secret-right.bin"))
            }
        }
    }

    private func requireSendable<T: Sendable>(_: T) {}

    private func withTemporaryDirectory(
        _ body: (URL) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "RiffaLocalHex-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }
}
