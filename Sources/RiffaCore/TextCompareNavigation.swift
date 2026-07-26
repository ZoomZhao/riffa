import CryptoKit
import Foundation

/// One side of a two-way text comparison.
public enum TextComparisonSide: String, CaseIterable, Codable, Hashable, Sendable {
    case left
    case right

    public var opposite: Self {
        self == .left ? .right : .left
    }
}

/// Work limits for session bookmarks.
///
/// Rebinding is deliberately local and conservative. A bookmark that cannot
/// be tied uniquely to its previous content and neighborhood is discarded
/// instead of silently moving to an unrelated duplicate line.
public struct TextBookmarkLimits: Hashable, Sendable {
    public let maximumBookmarkCount: Int
    public let maximumRebindDistance: Int
    public let maximumInspectedLineCount: Int
    public let maximumCandidatesPerBookmark: Int
    public let maximumPersistenceValueUTF8Length: Int

    public init(
        maximumBookmarkCount: Int = 256,
        maximumRebindDistance: Int = 128,
        maximumInspectedLineCount: Int = 32_768,
        maximumCandidatesPerBookmark: Int = 32,
        maximumPersistenceValueUTF8Length: Int = 4_096
    ) {
        self.maximumBookmarkCount = max(0, maximumBookmarkCount)
        self.maximumRebindDistance = max(0, maximumRebindDistance)
        self.maximumInspectedLineCount = max(0, maximumInspectedLineCount)
        self.maximumCandidatesPerBookmark = max(0, maximumCandidatesPerBookmark)
        self.maximumPersistenceValueUTF8Length = max(0, maximumPersistenceValueUTF8Length)
    }
}

/// A bookmark attached to a one-based logical line on one comparison side.
public struct TextLineBookmark: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let side: TextComparisonSide
    public let lineNumber: Int
    public let preview: String

    fileprivate let anchor: Anchor

    fileprivate struct Anchor: Hashable, Codable, Sendable {
        let contentSHA256: String
        let previousContentSHA256: String?
        let nextContentSHA256: String?
    }

    fileprivate init(
        id: UUID,
        side: TextComparisonSide,
        lineNumber: Int,
        preview: String,
        anchor: Anchor
    ) {
        self.id = id
        self.side = side
        self.lineNumber = lineNumber
        self.preview = preview
        self.anchor = anchor
    }
}

public enum TextBookmarkToggleResult: Equatable, Sendable {
    case added(TextLineBookmark)
    case removed(TextLineBookmark)
    case invalidLine
    case limitReached(Int)
}

public struct TextBookmarkRebindResult: Equatable, Sendable {
    public let reboundCount: Int
    public let discardedIDs: [UUID]

    public init(reboundCount: Int, discardedIDs: [UUID]) {
        self.reboundCount = reboundCount
        self.discardedIDs = discardedIDs
    }
}

public struct TextBookmarkRestoration: Sendable {
    public let collection: TextBookmarkCollection
    public let discardedValueCount: Int

    public init(collection: TextBookmarkCollection, discardedValueCount: Int) {
        self.collection = collection
        self.discardedValueCount = discardedValueCount
    }
}

/// A bounded, value-semantic bookmark collection for one Text Compare session.
public struct TextBookmarkCollection: Sendable {
    public private(set) var bookmarks: [TextLineBookmark]
    public let limits: TextBookmarkLimits

    private static let persistencePrefix = "riffa-text-bookmark-v1:"
    private static let maximumPreviewUnicodeScalarCount = 80
    private static let maximumPreviewUTF8Length = 256

    public init(limits: TextBookmarkLimits = TextBookmarkLimits()) {
        bookmarks = []
        self.limits = limits
    }

    public func bookmark(side: TextComparisonSide, lineNumber: Int) -> TextLineBookmark? {
        bookmarks.first { $0.side == side && $0.lineNumber == lineNumber }
    }

    @discardableResult
    public mutating func toggle(
        side: TextComparisonSide,
        lineNumber: Int,
        in document: TextDocument
    ) -> TextBookmarkToggleResult {
        guard lineNumber > 0 else {
            return .invalidLine
        }
        if let index = bookmarks.firstIndex(where: {
            $0.side == side && $0.lineNumber == lineNumber
        }) {
            return .removed(bookmarks.remove(at: index))
        }
        guard document.lines.indices.contains(lineNumber - 1) else {
            return .invalidLine
        }
        guard bookmarks.count < limits.maximumBookmarkCount else {
            return .limitReached(limits.maximumBookmarkCount)
        }

        let bookmark = Self.makeBookmark(
            id: UUID(),
            side: side,
            lineIndex: lineNumber - 1,
            document: document
        )
        bookmarks.append(bookmark)
        sortBookmarks()
        return .added(bookmark)
    }

    @discardableResult
    public mutating func remove(id: UUID) -> TextLineBookmark? {
        guard let index = bookmarks.firstIndex(where: { $0.id == id }) else { return nil }
        return bookmarks.remove(at: index)
    }

    public mutating func removeAll(on side: TextComparisonSide) {
        bookmarks.removeAll { $0.side == side }
    }

    public mutating func removeAll() {
        bookmarks.removeAll(keepingCapacity: false)
    }

    public mutating func swapSides() {
        bookmarks = bookmarks.map {
            TextLineBookmark(
                id: $0.id,
                side: $0.side.opposite,
                lineNumber: $0.lineNumber,
                preview: $0.preview,
                anchor: $0.anchor
            )
        }
        sortBookmarks()
    }

    /// Rebinds bookmarks on one side after an edit or reload.
    ///
    /// The scan is bounded globally and per bookmark. Moving to another line
    /// requires at least one matching neighbor, and ties are discarded.
    @discardableResult
    public mutating func rebind(
        side: TextComparisonSide,
        to document: TextDocument
    ) -> TextBookmarkRebindResult {
        let sideBookmarks = bookmarks.filter { $0.side == side }
        guard !sideBookmarks.isEmpty else {
            return TextBookmarkRebindResult(reboundCount: 0, discardedIDs: [])
        }

        var digestCache: [Int: String] = [:]
        digestCache.reserveCapacity(min(limits.maximumInspectedLineCount, 4_096))
        var inspectedLineCount = 0

        func digest(at lineIndex: Int) -> String? {
            guard document.lines.indices.contains(lineIndex) else { return nil }
            if let cached = digestCache[lineIndex] { return cached }
            guard inspectedLineCount < limits.maximumInspectedLineCount else { return nil }
            inspectedLineCount += 1
            let value = Self.digest(document.lines[lineIndex].content)
            digestCache[lineIndex] = value
            return value
        }

        var replacements: [UUID: TextLineBookmark] = [:]
        var discardedIDs: [UUID] = []
        var occupiedLines: Set<Int> = []

        for bookmark in sideBookmarks {
            let originalIndex = bookmark.lineNumber - 1
            var candidateIndices: [Int] = []
            candidateIndices.reserveCapacity(min(limits.maximumCandidatesPerBookmark, 8))

            if limits.maximumCandidatesPerBookmark > 0,
               digest(at: originalIndex) == bookmark.anchor.contentSHA256 {
                candidateIndices.append(originalIndex)
            }

            let effectiveRebindDistance = min(
                limits.maximumRebindDistance,
                limits.maximumInspectedLineCount,
                document.lines.count
            )
            if effectiveRebindDistance > 0,
               limits.maximumCandidatesPerBookmark > candidateIndices.count {
                for distance in 1...effectiveRebindDistance {
                    if distance <= originalIndex {
                        let lower = originalIndex - distance
                        if digest(at: lower) == bookmark.anchor.contentSHA256 {
                            candidateIndices.append(lower)
                        }
                    }
                    if candidateIndices.count >= limits.maximumCandidatesPerBookmark { break }

                    if originalIndex <= Int.max - distance {
                        let upper = originalIndex + distance
                        if digest(at: upper) == bookmark.anchor.contentSHA256 {
                            candidateIndices.append(upper)
                        }
                    }
                    if candidateIndices.count >= limits.maximumCandidatesPerBookmark { break }
                    if inspectedLineCount >= limits.maximumInspectedLineCount { break }
                }
            }

            let ranked = candidateIndices.map { candidateIndex in
                let previousMatches = bookmark.anchor.previousContentSHA256.map {
                    digest(at: candidateIndex - 1) == $0
                } ?? false
                let nextMatches = bookmark.anchor.nextContentSHA256.map {
                    digest(at: candidateIndex + 1) == $0
                } ?? false
                return Candidate(
                    lineIndex: candidateIndex,
                    contextScore: (previousMatches ? 1 : 0) + (nextMatches ? 1 : 0),
                    distance: abs(candidateIndex - originalIndex)
                )
            }.sorted(by: Candidate.isPreferred)

            guard let best = ranked.first,
                  best.distance == 0 || best.contextScore > 0,
                  !occupiedLines.contains(best.lineIndex),
                  ranked.dropFirst().first.map({
                      $0.contextScore == best.contextScore && $0.distance == best.distance
                  }) != true
            else {
                discardedIDs.append(bookmark.id)
                continue
            }

            occupiedLines.insert(best.lineIndex)
            replacements[bookmark.id] = Self.makeBookmark(
                id: bookmark.id,
                side: side,
                lineIndex: best.lineIndex,
                document: document
            )
        }

        bookmarks = bookmarks.compactMap { bookmark in
            guard bookmark.side == side else { return bookmark }
            return replacements[bookmark.id]
        }
        sortBookmarks()
        return TextBookmarkRebindResult(
            reboundCount: replacements.count,
            discardedIDs: discardedIDs
        )
    }

    /// Stable opaque values suitable for `SessionOptionValue.strings`.
    public func persistenceValues() -> [String] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return bookmarks.prefix(limits.maximumBookmarkCount).compactMap { bookmark in
            guard let data = try? encoder.encode(bookmark) else { return nil }
            let value = Self.persistencePrefix + data.base64EncodedString()
            guard value.utf8.count <= limits.maximumPersistenceValueUTF8Length else { return nil }
            return value
        }
    }

    /// Restores and validates saved bookmarks against the current documents.
    public static func restore(
        from values: [String],
        leftDocument: TextDocument,
        rightDocument: TextDocument,
        limits: TextBookmarkLimits = TextBookmarkLimits()
    ) -> TextBookmarkRestoration {
        var collection = TextBookmarkCollection(limits: limits)
        let decoder = JSONDecoder()
        var discardedCount = max(0, values.count - limits.maximumBookmarkCount)
        var seenIDs: Set<UUID> = []

        for value in values.prefix(limits.maximumBookmarkCount) {
            guard value.utf8.count <= limits.maximumPersistenceValueUTF8Length,
                  value.hasPrefix(persistencePrefix),
                  let data = Data(
                      base64Encoded: String(value.dropFirst(persistencePrefix.count)),
                      options: []
                  ),
                  let bookmark = try? decoder.decode(TextLineBookmark.self, from: data),
                  validate(bookmark),
                  seenIDs.insert(bookmark.id).inserted
            else {
                discardedCount += 1
                continue
            }
            collection.bookmarks.append(bookmark)
        }

        let leftResult = collection.rebind(side: .left, to: leftDocument)
        let rightResult = collection.rebind(side: .right, to: rightDocument)
        discardedCount += leftResult.discardedIDs.count + rightResult.discardedIDs.count
        collection.sortBookmarks()
        return TextBookmarkRestoration(
            collection: collection,
            discardedValueCount: discardedCount
        )
    }

    private struct Candidate {
        let lineIndex: Int
        let contextScore: Int
        let distance: Int

        static func isPreferred(_ left: Self, _ right: Self) -> Bool {
            if left.contextScore != right.contextScore {
                return left.contextScore > right.contextScore
            }
            if left.distance != right.distance {
                return left.distance < right.distance
            }
            return left.lineIndex < right.lineIndex
        }
    }

    private static func makeBookmark(
        id: UUID,
        side: TextComparisonSide,
        lineIndex: Int,
        document: TextDocument
    ) -> TextLineBookmark {
        let line = document.lines[lineIndex]
        return TextLineBookmark(
            id: id,
            side: side,
            lineNumber: lineIndex + 1,
            preview: boundedPreview(line.content),
            anchor: TextLineBookmark.Anchor(
                contentSHA256: digest(line.content),
                previousContentSHA256: document.lines.indices.contains(lineIndex - 1)
                    ? digest(document.lines[lineIndex - 1].content)
                    : nil,
                nextContentSHA256: document.lines.indices.contains(lineIndex + 1)
                    ? digest(document.lines[lineIndex + 1].content)
                    : nil
            )
        )
    }

    private static func validate(_ bookmark: TextLineBookmark) -> Bool {
        guard bookmark.lineNumber > 0,
              bookmark.preview.unicodeScalars.count <= maximumPreviewUnicodeScalarCount,
              bookmark.preview.utf8.count <= maximumPreviewUTF8Length,
              isSHA256(bookmark.anchor.contentSHA256)
        else { return false }
        return [
            bookmark.anchor.previousContentSHA256,
            bookmark.anchor.nextContentSHA256
        ].allSatisfy { $0.map(isSHA256) ?? true }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func boundedPreview(_ value: String) -> String {
        var scalars = String.UnicodeScalarView()
        var utf8Length = 0
        for scalar in value.unicodeScalars.prefix(maximumPreviewUnicodeScalarCount) {
            let scalarUTF8Length: Int
            switch scalar.value {
            case 0...0x7F: scalarUTF8Length = 1
            case 0x80...0x7FF: scalarUTF8Length = 2
            case 0x800...0xFFFF: scalarUTF8Length = 3
            default: scalarUTF8Length = 4
            }
            guard utf8Length <= maximumPreviewUTF8Length - scalarUTF8Length else { break }
            scalars.append(scalar)
            utf8Length += scalarUTF8Length
        }
        return String(scalars)
    }

    private mutating func sortBookmarks() {
        bookmarks.sort {
            if $0.side != $1.side { return $0.side == .left }
            if $0.lineNumber != $1.lineNumber { return $0.lineNumber < $1.lineNumber }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}

/// A bounded line-number to aligned-row index built once per published diff.
public struct TextDiffNavigationIndex: Sendable {
    public let isComplete: Bool
    private let leftOffsets: [Int]
    private let rightOffsets: [Int]

    public init(result: TextDiffResult, maximumIndexedAlignedLineCount: Int = 500_000) {
        let limit = max(0, maximumIndexedAlignedLineCount)
        guard result.alignedLines.count <= limit else {
            isComplete = false
            leftOffsets = []
            rightOffsets = []
            return
        }

        let maximumLeft = result.alignedLines.compactMap { $0.left?.lineNumber }.max() ?? 0
        let maximumRight = result.alignedLines.compactMap { $0.right?.lineNumber }.max() ?? 0
        guard maximumLeft <= limit,
              maximumRight <= limit,
              maximumLeft <= result.alignedLines.count,
              maximumRight <= result.alignedLines.count
        else {
            isComplete = false
            leftOffsets = []
            rightOffsets = []
            return
        }

        var left = Array(repeating: -1, count: maximumLeft)
        var right = Array(repeating: -1, count: maximumRight)
        for line in result.alignedLines {
            if let value = line.left, value.lineNumber > 0 {
                left[value.lineNumber - 1] = line.offset
            }
            if let value = line.right, value.lineNumber > 0 {
                right[value.lineNumber - 1] = line.offset
            }
        }
        isComplete = true
        leftOffsets = left
        rightOffsets = right
    }

    public func alignedOffset(side: TextComparisonSide, lineNumber: Int) -> Int? {
        guard lineNumber > 0 else { return nil }
        let offsets = side == .left ? leftOffsets : rightOffsets
        guard offsets.indices.contains(lineNumber - 1) else { return nil }
        let offset = offsets[lineNumber - 1]
        return offset >= 0 ? offset : nil
    }
}

public enum TextDiffOverviewKind: String, Hashable, Sendable {
    case inserted
    case deleted
    case modified
    case mixed
}

public struct TextDiffOverviewMarker: Identifiable, Hashable, Sendable {
    public let id: Int
    public let alignedRange: DiffLineRange
    public let firstHunkIndex: Int
    public let lastHunkIndex: Int
    public let targetHunkIndex: Int
    public let kind: TextDiffOverviewKind

    public init(
        id: Int,
        alignedRange: DiffLineRange,
        firstHunkIndex: Int,
        lastHunkIndex: Int,
        targetHunkIndex: Int,
        kind: TextDiffOverviewKind
    ) {
        self.id = id
        self.alignedRange = alignedRange
        self.firstHunkIndex = firstHunkIndex
        self.lastHunkIndex = lastHunkIndex
        self.targetHunkIndex = targetHunkIndex
        self.kind = kind
    }
}

public struct TextDiffOverview: Hashable, Sendable {
    public let alignedLineCount: Int
    public let hunkCount: Int
    public let markers: [TextDiffOverviewMarker]

    public init(alignedLineCount: Int, hunkCount: Int, markers: [TextDiffOverviewMarker]) {
        self.alignedLineCount = alignedLineCount
        self.hunkCount = hunkCount
        self.markers = markers
    }
}

public struct TextDiffOverviewLimits: Hashable, Sendable {
    public let maximumMarkerCount: Int
    public let maximumSampledHunksPerMarker: Int
    public let maximumSampledLinesPerHunk: Int

    public init(
        maximumMarkerCount: Int = 256,
        maximumSampledHunksPerMarker: Int = 3,
        maximumSampledLinesPerHunk: Int = 16
    ) {
        self.maximumMarkerCount = max(0, maximumMarkerCount)
        self.maximumSampledHunksPerMarker = max(0, maximumSampledHunksPerMarker)
        self.maximumSampledLinesPerHunk = max(0, maximumSampledLinesPerHunk)
    }
}

/// Builds a fixed-bin overview without walking every hunk or display row.
public struct TextDiffOverviewBuilder: Sendable {
    public let limits: TextDiffOverviewLimits

    public init(limits: TextDiffOverviewLimits = TextDiffOverviewLimits()) {
        self.limits = limits
    }

    public func build(from result: TextDiffResult) -> TextDiffOverview {
        let lineCount = result.alignedLines.count
        let hunks = result.hunks
        guard lineCount > 0, !hunks.isEmpty, limits.maximumMarkerCount > 0 else {
            return TextDiffOverview(
                alignedLineCount: lineCount,
                hunkCount: hunks.count,
                markers: []
            )
        }

        // A caller may supply `Int.max`; the renderer still has a hard ceiling
        // so overview generation and SwiftUI node count remain bounded.
        let binCount = min(lineCount, limits.maximumMarkerCount, 4_096)
        var markers: [TextDiffOverviewMarker] = []
        markers.reserveCapacity(min(binCount, hunks.count))

        for bin in 0..<binCount {
            let binStart = scaled(lineCount, by: bin, over: binCount)
            let binEnd = scaled(lineCount, by: bin + 1, over: binCount)
            var first = lowerBoundHunk(startingAtOrAfter: binStart, in: hunks)
            if first > 0, hunks[first - 1].alignedRange.end > binStart {
                first -= 1
            }
            let end = lowerBoundHunk(startingAtOrAfter: binEnd, in: hunks)
            guard first < end,
                  hunks[first].alignedRange.start < binEnd,
                  hunks[end - 1].alignedRange.end > binStart
            else { continue }

            let last = end - 1
            let target = first + ((last - first) / 2)
            let markerStart = max(binStart, hunks[first].alignedRange.start)
            let markerEnd = min(binEnd, max(markerStart + 1, hunks[last].alignedRange.end))
            markers.append(
                TextDiffOverviewMarker(
                    id: bin,
                    alignedRange: DiffLineRange(
                        start: markerStart,
                        count: max(1, markerEnd - markerStart)
                    ),
                    firstHunkIndex: first,
                    lastHunkIndex: last,
                    targetHunkIndex: target,
                    kind: overviewKind(for: first...last, hunks: hunks)
                )
            )
        }

        return TextDiffOverview(
            alignedLineCount: lineCount,
            hunkCount: hunks.count,
            markers: markers
        )
    }

    private func overviewKind(
        for range: ClosedRange<Int>,
        hunks: [DiffHunk]
    ) -> TextDiffOverviewKind {
        guard limits.maximumSampledHunksPerMarker > 0,
              limits.maximumSampledLinesPerHunk > 0
        else { return .mixed }

        let count = range.upperBound - range.lowerBound + 1
        let sampleCount = min(count, limits.maximumSampledHunksPerMarker, 16)
        var kinds: Set<TextDiffOverviewKind> = []
        for sample in 0..<sampleCount {
            let relative = sampleCount == 1
                ? count / 2
                : scaled(count - 1, by: sample, over: sampleCount - 1)
            let hunk = hunks[range.lowerBound + relative]
            for line in hunk.lines.prefix(min(limits.maximumSampledLinesPerHunk, 64)) {
                switch line.kind {
                case .inserted: kinds.insert(.inserted)
                case .deleted: kinds.insert(.deleted)
                case .modified: kinds.insert(.modified)
                case .unchanged: break
                }
                if kinds.count > 1 { return .mixed }
            }
        }
        return kinds.first ?? .mixed
    }

    private func lowerBoundHunk(startingAtOrAfter offset: Int, in hunks: [DiffHunk]) -> Int {
        var lower = 0
        var upper = hunks.count
        while lower < upper {
            let middle = lower + ((upper - lower) / 2)
            if hunks[middle].alignedRange.start < offset {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    private func scaled(_ value: Int, by numerator: Int, over denominator: Int) -> Int {
        guard denominator > 0 else { return 0 }
        let quotient = value / denominator
        let remainder = value % denominator
        let product = remainder.multipliedFullWidth(by: numerator)
        let fractional = denominator.dividingFullWidth(product).quotient
        return (quotient * numerator) + fractional
    }
}
