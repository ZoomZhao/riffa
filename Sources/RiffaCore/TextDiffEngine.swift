/// A deterministic, value-typed two-way line comparison engine.
///
/// Small regions use Swift's Myers-style `CollectionDifference`. Large
/// regions use a bounded Patience diff, and regions that cannot be examined
/// within the configured limits degrade to deterministic coarse changes.
/// Changed line pairs receive a separately budgeted token-level diff.
public struct TextDiffEngine: Sendable {
    public var options: TextDiffOptions

    public init(options: TextDiffOptions = TextDiffOptions()) {
        self.options = options
    }

    /// Performs the same deterministic comparison while cooperatively stopping
    /// CPU and allocation work when the current task is cancelled.
    public func compareCancellable(
        _ left: TextDocument,
        to right: TextDocument
    ) throws -> TextDiffResult {
        let result = TextDiffCancellationContext.$isEnabled.withValue(true) {
            compare(left, to: right)
        }
        try Task.checkCancellation()
        return result
    }

    public func compare(_ left: TextDocument, to right: TextDocument) -> TextDiffResult {
        if cancellationRequested { return Self.cancelledResult }
        var leftKeys: [LineComparisonKey] = []
        leftKeys.reserveCapacity(left.lines.count)
        for (offset, line) in left.lines.enumerated() {
            if offset & 0x3FF == 0, cancellationRequested {
                return Self.cancelledResult
            }
            leftKeys.append(comparisonKey(for: line))
        }
        var rightKeys: [LineComparisonKey] = []
        rightKeys.reserveCapacity(right.lines.count)
        for (offset, line) in right.lines.enumerated() {
            if offset & 0x3FF == 0, cancellationRequested {
                return Self.cancelledResult
            }
            rightKeys.append(comparisonKey(for: line))
        }
        let offsets = lineChangeOffsets(from: leftKeys, to: rightKeys)
        if cancellationRequested { return Self.cancelledResult }

        var alignedLines: [AlignedDiffLine] = []
        alignedLines.reserveCapacity(max(left.lines.count, right.lines.count))

        var leftOffset = 0
        var rightOffset = 0

        while leftOffset < left.lines.count || rightOffset < right.lines.count {
            if cancellationRequested { return Self.cancelledResult }
            let leftIsRemoved = offsets.isRemoved(leftOffset)
            let rightIsInserted = offsets.isInserted(rightOffset)

            if leftOffset < left.lines.count,
               rightOffset < right.lines.count,
               !leftIsRemoved,
               !rightIsInserted {
                alignedLines.append(
                    makeAlignedLine(
                        kind: .unchanged,
                        leftOffset: leftOffset,
                        leftLine: left.lines[leftOffset],
                        rightOffset: rightOffset,
                        rightLine: right.lines[rightOffset],
                        alignedOffset: alignedLines.count
                    )
                )
                leftOffset += 1
                rightOffset += 1
                continue
            }

            var removedOffsets: [Int] = []
            while leftOffset < left.lines.count, offsets.isRemoved(leftOffset) {
                if cancellationRequested { return Self.cancelledResult }
                removedOffsets.append(leftOffset)
                leftOffset += 1
            }

            var insertedOffsets: [Int] = []
            while rightOffset < right.lines.count, offsets.isInserted(rightOffset) {
                if cancellationRequested { return Self.cancelledResult }
                insertedOffsets.append(rightOffset)
                rightOffset += 1
            }

            // A valid CollectionDifference always advances through one of the
            // two change sets here. Keep a defensive fallback so malformed or
            // future diff sources cannot make this loop stall.
            if removedOffsets.isEmpty, insertedOffsets.isEmpty {
                if leftOffset < left.lines.count {
                    removedOffsets.append(leftOffset)
                    leftOffset += 1
                } else if rightOffset < right.lines.count {
                    insertedOffsets.append(rightOffset)
                    rightOffset += 1
                }
            }

            appendChangedBlock(
                removedOffsets: removedOffsets,
                insertedOffsets: insertedOffsets,
                leftLines: left.lines,
                rightLines: right.lines,
                to: &alignedLines
            )
        }

        if cancellationRequested { return Self.cancelledResult }
        let statistics = makeStatistics(for: alignedLines)
        let hunks = makeHunks(from: alignedLines, contextLineCount: options.contextLineCount)

        if cancellationRequested { return Self.cancelledResult }

        return TextDiffResult(
            alignedLines: alignedLines,
            hunks: hunks,
            statistics: statistics
        )
    }

    private var cancellationRequested: Bool {
        TextDiffCancellationContext.isEnabled && Task.isCancelled
    }

    private static var cancelledResult: TextDiffResult {
        TextDiffResult(
            alignedLines: [],
            hunks: [],
            statistics: TextDiffStatistics(
                unchangedLineCount: 0,
                insertedLineCount: 0,
                deletedLineCount: 0,
                modifiedLineCount: 0
            )
        )
    }

    private func appendChangedBlock(
        removedOffsets: [Int],
        insertedOffsets: [Int],
        leftLines: [TextLine],
        rightLines: [TextLine],
        to alignedLines: inout [AlignedDiffLine]
    ) {
        let pairedCount = min(removedOffsets.count, insertedOffsets.count)

        for pairOffset in 0..<pairedCount {
            if cancellationRequested { return }
            let leftOffset = removedOffsets[pairOffset]
            let rightOffset = insertedOffsets[pairOffset]
            alignedLines.append(
                makeAlignedLine(
                    kind: .modified,
                    leftOffset: leftOffset,
                    leftLine: leftLines[leftOffset],
                    rightOffset: rightOffset,
                    rightLine: rightLines[rightOffset],
                    alignedOffset: alignedLines.count
                )
            )
        }

        for leftOffset in removedOffsets.dropFirst(pairedCount) {
            if cancellationRequested { return }
            alignedLines.append(
                makeAlignedLine(
                    kind: .deleted,
                    leftOffset: leftOffset,
                    leftLine: leftLines[leftOffset],
                    rightOffset: nil,
                    rightLine: nil,
                    alignedOffset: alignedLines.count
                )
            )
        }

        for rightOffset in insertedOffsets.dropFirst(pairedCount) {
            if cancellationRequested { return }
            alignedLines.append(
                makeAlignedLine(
                    kind: .inserted,
                    leftOffset: nil,
                    leftLine: nil,
                    rightOffset: rightOffset,
                    rightLine: rightLines[rightOffset],
                    alignedOffset: alignedLines.count
                )
            )
        }
    }

    private func makeAlignedLine(
        kind: DiffLineKind,
        leftOffset: Int?,
        leftLine: TextLine?,
        rightOffset: Int?,
        rightLine: TextLine?,
        alignedOffset: Int
    ) -> AlignedDiffLine {
        let leftValue = leftOffset.flatMap { offset in
            leftLine.map { DiffLineValue(lineNumber: offset + 1, line: $0) }
        }
        let rightValue = rightOffset.flatMap { offset in
            rightLine.map { DiffLineValue(lineNumber: offset + 1, line: $0) }
        }

        let endingDiffers: Bool
        if let leftLine, let rightLine {
            endingDiffers = leftLine.ending != rightLine.ending
        } else {
            endingDiffers = false
        }
        let inlineDifferences: [InlineDifference]
        if !cancellationRequested,
           kind == .modified, let leftLine, let rightLine {
            inlineDifferences = tokenDifferences(
                from: leftLine.content,
                to: rightLine.content
            )
        } else {
            inlineDifferences = []
        }

        return AlignedDiffLine(
            offset: alignedOffset,
            kind: kind,
            left: leftValue,
            right: rightValue,
            inlineDifferences: inlineDifferences,
            hasLineEndingDifference: endingDiffers
        )
    }

    private func comparisonKey(for line: TextLine) -> LineComparisonKey {
        var content = line.content
        if options.ignoreWhitespace {
            content.removeAll(where: \.isWhitespace)
        }
        if options.ignoreCase {
            content = content.lowercased()
        }

        let ending: ComparableLineEnding
        if !line.ending.isTerminated {
            ending = .none
        } else if options.ignoreLineEndingStyle {
            ending = .terminated
        } else {
            ending = switch line.ending {
            case .none: .none
            case .lf: .lf
            case .crlf: .crlf
            case .cr: .cr
            }
        }

        return LineComparisonKey(content: content, ending: ending)
    }

    private func tokenDifferences(from left: String, to right: String) -> [InlineDifference] {
        guard !cancellationRequested else { return [] }
        guard left != right else {
            return []
        }

        let limits = options.limits
        let leftCharacterCount = left.count
        let rightCharacterCount = right.count
        guard sumWithinBudget(
            leftCharacterCount,
            rightCharacterCount,
            maximum: limits.maximumInlineCharacterCount
        ) else {
            return wholeLineDifference(
                leftCharacterCount: leftCharacterCount,
                rightCharacterCount: rightCharacterCount
            )
        }

        guard let leftTokens = tokenize(
            left,
            maximumTokenCount: limits.maximumInlineTokenCount
        ), leftTokens.count <= limits.maximumInlineTokenCount,
              let rightTokens = tokenize(
                right,
                maximumTokenCount: limits.maximumInlineTokenCount - leftTokens.count
              ) else {
            return wholeLineDifference(
                leftCharacterCount: leftCharacterCount,
                rightCharacterCount: rightCharacterCount
            )
        }

        let leftKeys = leftTokens.map(\.comparisonKey)
        let rightKeys = rightTokens.map(\.comparisonKey)
        guard exactRegionFitsBudget(
            leftCount: leftKeys.count,
            rightCount: rightKeys.count
        ) else {
            return wholeLineDifference(
                leftCharacterCount: leftCharacterCount,
                rightCharacterCount: rightCharacterCount
            )
        }
        let offsets = exactChangeOffsets(from: leftKeys, to: rightKeys)

        var differences: [InlineDifference] = []
        var leftOffset = 0
        var rightOffset = 0

        while leftOffset < leftTokens.count || rightOffset < rightTokens.count {
            if cancellationRequested { return [] }
            if leftOffset < leftTokens.count,
               rightOffset < rightTokens.count,
               !offsets.isRemoved(leftOffset),
               !offsets.isInserted(rightOffset) {
                leftOffset += 1
                rightOffset += 1
                continue
            }

            var removedTokens: [Token] = []
            while leftOffset < leftTokens.count, offsets.isRemoved(leftOffset) {
                if cancellationRequested { return [] }
                removedTokens.append(leftTokens[leftOffset])
                leftOffset += 1
            }

            var insertedTokens: [Token] = []
            while rightOffset < rightTokens.count, offsets.isInserted(rightOffset) {
                if cancellationRequested { return [] }
                insertedTokens.append(rightTokens[rightOffset])
                rightOffset += 1
            }

            if removedTokens.isEmpty, insertedTokens.isEmpty {
                // Defensive progress for the same reason as the line loop.
                if leftOffset < leftTokens.count {
                    removedTokens.append(leftTokens[leftOffset])
                    leftOffset += 1
                } else if rightOffset < rightTokens.count {
                    insertedTokens.append(rightTokens[rightOffset])
                    rightOffset += 1
                }
            }

            let kind: InlineDifferenceKind
            if removedTokens.isEmpty {
                kind = .inserted
            } else if insertedTokens.isEmpty {
                kind = .deleted
            } else {
                kind = .modified
            }

            differences.append(
                InlineDifference(
                    kind: kind,
                    leftRange: coveringRange(of: removedTokens),
                    rightRange: coveringRange(of: insertedTokens)
                )
            )
        }

        return differences
    }

    private func wholeLineDifference(
        leftCharacterCount: Int,
        rightCharacterCount: Int
    ) -> [InlineDifference] {
        let kind: InlineDifferenceKind
        if leftCharacterCount == 0 {
            kind = .inserted
        } else if rightCharacterCount == 0 {
            kind = .deleted
        } else {
            kind = .modified
        }

        return [
            InlineDifference(
                kind: kind,
                leftRange: leftCharacterCount == 0
                    ? nil
                    : TextCharacterRange(offset: 0, length: leftCharacterCount),
                rightRange: rightCharacterCount == 0
                    ? nil
                    : TextCharacterRange(offset: 0, length: rightCharacterCount)
            )
        ]
    }

    private func tokenize(_ text: String, maximumTokenCount: Int) -> [Token]? {
        guard text.isEmpty || maximumTokenCount > 0 else {
            return nil
        }

        var tokens: [Token] = []
        tokens.reserveCapacity(min(maximumTokenCount, 128))
        var activeKind: TokenKind?
        var activeText = ""
        var activeOffset = 0
        var characterOffset = 0

        func flushActiveToken() -> Bool {
            guard let activeKind, !activeText.isEmpty else {
                return true
            }

            if !(options.ignoreWhitespace && activeKind == .whitespace) {
                guard tokens.count < maximumTokenCount else {
                    return false
                }
                var key = activeText
                if options.ignoreCase {
                    key = key.lowercased()
                }
                tokens.append(
                    Token(
                        comparisonKey: key,
                        range: TextCharacterRange(
                            offset: activeOffset,
                            length: activeText.count
                        )
                    )
                )
            }
            activeText = ""
            return true
        }

        for (offset, character) in text.enumerated() {
            if offset & 0x3FF == 0, cancellationRequested { return nil }
            let kind = tokenKind(for: character)

            // Symbols remain individual tokens; word and whitespace runs are
            // grouped to keep the edit script small on natural-language text.
            if kind == .symbol {
                guard flushActiveToken(), tokens.count < maximumTokenCount else {
                    return nil
                }
                activeKind = nil
                var key = String(character)
                if options.ignoreCase {
                    key = key.lowercased()
                }
                tokens.append(
                    Token(
                        comparisonKey: key,
                        range: TextCharacterRange(offset: characterOffset, length: 1)
                    )
                )
            } else if activeKind == kind {
                activeText.append(character)
            } else {
                guard flushActiveToken() else {
                    return nil
                }
                activeKind = kind
                activeOffset = characterOffset
                activeText = String(character)
            }

            characterOffset += 1
        }

        guard flushActiveToken() else {
            return nil
        }
        return tokens
    }

    private func tokenKind(for character: Character) -> TokenKind {
        if character.isWhitespace {
            return .whitespace
        }
        if character.isLetter || character.isNumber || character == "_" {
            return .word
        }
        return .symbol
    }

    private func coveringRange(of tokens: [Token]) -> TextCharacterRange? {
        guard let first = tokens.first, let last = tokens.last else {
            return nil
        }
        return TextCharacterRange(
            offset: first.range.offset,
            length: last.range.endOffset - first.range.offset
        )
    }

    private func lineChangeOffsets(
        from left: [LineComparisonKey],
        to right: [LineComparisonKey]
    ) -> ChangeOffsets {
        if cancellationRequested {
            return ChangeOffsets(
                removed: Array(repeating: true, count: left.count),
                inserted: Array(repeating: true, count: right.count)
            )
        }
        let limits = options.limits
        guard sumWithinBudget(
            left.count,
            right.count,
            maximum: limits.maximumTotalLineCount
        ) else {
            return coarseChangeOffsetsPreservingCommonEdges(from: left, to: right)
        }

        switch options.algorithm {
        case .automatic:
            if exactRegionFitsBudget(leftCount: left.count, rightCount: right.count) {
                return exactChangeOffsets(from: left, to: right)
            }
            return patienceChangeOffsets(from: left, to: right)
        case .collectionDifference:
            guard exactRegionFitsBudget(leftCount: left.count, rightCount: right.count) else {
                return coarseChangeOffsetsPreservingCommonEdges(from: left, to: right)
            }
            return exactChangeOffsets(from: left, to: right)
        case .patience:
            return patienceChangeOffsets(from: left, to: right)
        }
    }

    private func exactRegionFitsBudget(leftCount: Int, rightCount: Int) -> Bool {
        guard leftCount > 0, rightCount > 0 else {
            return true
        }
        let (cost, overflow) = leftCount.multipliedReportingOverflow(by: rightCount)
        return !overflow && cost <= options.limits.maximumExactRegionCost
    }

    private func sumWithinBudget(_ lhs: Int, _ rhs: Int, maximum: Int) -> Bool {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return !overflow && sum <= maximum
    }

    private func exactChangeOffsets<Element: Equatable>(
        from left: [Element],
        to right: [Element]
    ) -> ChangeOffsets {
        if cancellationRequested {
            return ChangeOffsets(
                removed: Array(repeating: true, count: left.count),
                inserted: Array(repeating: true, count: right.count)
            )
        }
        guard !left.isEmpty, !right.isEmpty else {
            return ChangeOffsets(
                removed: Array(repeating: true, count: left.count),
                inserted: Array(repeating: true, count: right.count)
            )
        }

        let difference = right.difference(from: left)
        if cancellationRequested {
            return ChangeOffsets(
                removed: Array(repeating: true, count: left.count),
                inserted: Array(repeating: true, count: right.count)
            )
        }
        var removed = Array(repeating: false, count: left.count)
        var inserted = Array(repeating: false, count: right.count)

        for change in difference {
            if cancellationRequested { break }
            switch change {
            case let .remove(offset, _, _):
                removed[offset] = true
            case let .insert(offset, _, _):
                inserted[offset] = true
            }
        }

        return ChangeOffsets(removed: removed, inserted: inserted)
    }

    private func coarseChangeOffsetsPreservingCommonEdges<Element: Equatable>(
        from left: [Element],
        to right: [Element]
    ) -> ChangeOffsets {
        var matchedLeft = Array(repeating: false, count: left.count)
        var matchedRight = Array(repeating: false, count: right.count)
        var prefixCount = 0

        while prefixCount < left.count,
              prefixCount < right.count,
              !cancellationRequested,
              left[prefixCount] == right[prefixCount] {
            matchedLeft[prefixCount] = true
            matchedRight[prefixCount] = true
            prefixCount += 1
        }

        var leftSuffix = left.count
        var rightSuffix = right.count
        while leftSuffix > prefixCount,
              rightSuffix > prefixCount,
              !cancellationRequested,
              left[leftSuffix - 1] == right[rightSuffix - 1] {
            leftSuffix -= 1
            rightSuffix -= 1
            matchedLeft[leftSuffix] = true
            matchedRight[rightSuffix] = true
        }

        return ChangeOffsets(matchedLeft: matchedLeft, matchedRight: matchedRight)
    }

    private func patienceChangeOffsets<Element: Hashable>(
        from left: [Element],
        to right: [Element]
    ) -> ChangeOffsets {
        let limits = options.limits
        guard limits.maximumPatienceWorkItemCount > 0 else {
            return coarseChangeOffsetsPreservingCommonEdges(from: left, to: right)
        }

        var matchedLeft = Array(repeating: false, count: left.count)
        var matchedRight = Array(repeating: false, count: right.count)
        var workItems = [
            PatienceWorkItem(
                leftRange: 0..<left.count,
                rightRange: 0..<right.count,
                depth: 0
            )
        ]
        var processedWorkItemCount = 0

        while let workItem = workItems.popLast() {
            if cancellationRequested { break }
            guard processedWorkItemCount < limits.maximumPatienceWorkItemCount else {
                break
            }
            processedWorkItemCount += 1

            guard workItem.depth <= limits.maximumPatienceDepth else {
                continue
            }

            var leftStart = workItem.leftRange.lowerBound
            var rightStart = workItem.rightRange.lowerBound
            var leftEnd = workItem.leftRange.upperBound
            var rightEnd = workItem.rightRange.upperBound

            while leftStart < leftEnd,
                  rightStart < rightEnd,
                  !cancellationRequested,
                  left[leftStart] == right[rightStart] {
                matchedLeft[leftStart] = true
                matchedRight[rightStart] = true
                leftStart += 1
                rightStart += 1
            }

            while leftEnd > leftStart,
                  rightEnd > rightStart,
                  !cancellationRequested,
                  left[leftEnd - 1] == right[rightEnd - 1] {
                leftEnd -= 1
                rightEnd -= 1
                matchedLeft[leftEnd] = true
                matchedRight[rightEnd] = true
            }

            guard leftStart < leftEnd, rightStart < rightEnd else {
                continue
            }

            let leftRange = leftStart..<leftEnd
            let rightRange = rightStart..<rightEnd
            let anchors = patienceAnchors(
                left: left,
                leftRange: leftRange,
                right: right,
                rightRange: rightRange
            )

            if cancellationRequested { break }

            guard !anchors.isEmpty else {
                if exactRegionFitsBudget(
                    leftCount: leftRange.count,
                    rightCount: rightRange.count
                ) {
                    markExactMatches(
                        left: left,
                        leftRange: leftRange,
                        right: right,
                        rightRange: rightRange,
                        matchedLeft: &matchedLeft,
                        matchedRight: &matchedRight
                    )
                }
                continue
            }

            for anchor in anchors {
                if cancellationRequested { break }
                matchedLeft[anchor.leftOffset] = true
                matchedRight[anchor.rightOffset] = true
            }

            guard workItem.depth < limits.maximumPatienceDepth else {
                continue
            }

            // Push gaps from right to left so the leftmost subregion is popped
            // first. Constructing them in place avoids an anchors-sized
            // temporary array when every line is already an anchor.
            let lastAnchor = anchors[anchors.count - 1]
            if lastAnchor.leftOffset + 1 < leftEnd,
               lastAnchor.rightOffset + 1 < rightEnd,
               processedWorkItemCount + workItems.count
                    < limits.maximumPatienceWorkItemCount {
                workItems.append(
                    PatienceWorkItem(
                        leftRange: (lastAnchor.leftOffset + 1)..<leftEnd,
                        rightRange: (lastAnchor.rightOffset + 1)..<rightEnd,
                        depth: workItem.depth + 1
                    )
                )
            }

            if anchors.count > 1 {
                for anchorIndex in stride(
                    from: anchors.count - 1,
                    through: 1,
                    by: -1
                ) {
                    if cancellationRequested { break }
                    guard processedWorkItemCount + workItems.count
                            < limits.maximumPatienceWorkItemCount else {
                        break
                    }
                    let previous = anchors[anchorIndex - 1]
                    let current = anchors[anchorIndex]
                    if previous.leftOffset + 1 < current.leftOffset,
                       previous.rightOffset + 1 < current.rightOffset {
                        workItems.append(
                            PatienceWorkItem(
                                leftRange: (previous.leftOffset + 1)..<current.leftOffset,
                                rightRange: (previous.rightOffset + 1)..<current.rightOffset,
                                depth: workItem.depth + 1
                            )
                        )
                    }
                }
            }

            let firstAnchor = anchors[0]
            if leftStart < firstAnchor.leftOffset,
               rightStart < firstAnchor.rightOffset,
               processedWorkItemCount + workItems.count
                    < limits.maximumPatienceWorkItemCount {
                workItems.append(
                    PatienceWorkItem(
                        leftRange: leftStart..<firstAnchor.leftOffset,
                        rightRange: rightStart..<firstAnchor.rightOffset,
                        depth: workItem.depth + 1
                    )
                )
            }
        }

        return ChangeOffsets(matchedLeft: matchedLeft, matchedRight: matchedRight)
    }

    private func patienceAnchors<Element: Hashable>(
        left: [Element],
        leftRange: Range<Int>,
        right: [Element],
        rightRange: Range<Int>
    ) -> [MatchedLinePair] {
        var leftOccurrences: [Element: ElementOccurrence] = [:]
        leftOccurrences.reserveCapacity(min(leftRange.count, 4_096))
        for offset in leftRange {
            if cancellationRequested { return [] }
            if var occurrence = leftOccurrences[left[offset]] {
                occurrence.count += 1
                leftOccurrences[left[offset]] = occurrence
            } else {
                leftOccurrences[left[offset]] = ElementOccurrence(offset: offset, count: 1)
            }
        }

        var rightOccurrences: [Element: ElementOccurrence] = [:]
        rightOccurrences.reserveCapacity(min(rightRange.count, 4_096))
        for offset in rightRange {
            if cancellationRequested { return [] }
            if var occurrence = rightOccurrences[right[offset]] {
                occurrence.count += 1
                rightOccurrences[right[offset]] = occurrence
            } else {
                rightOccurrences[right[offset]] = ElementOccurrence(offset: offset, count: 1)
            }
        }

        var candidates: [MatchedLinePair] = []
        candidates.reserveCapacity(min(leftRange.count, rightRange.count, 4_096))
        for leftOffset in leftRange {
            if cancellationRequested { return [] }
            guard leftOccurrences[left[leftOffset]]?.count == 1,
                  let rightOccurrence = rightOccurrences[left[leftOffset]],
                  rightOccurrence.count == 1 else {
                continue
            }
            candidates.append(
                MatchedLinePair(
                    leftOffset: leftOffset,
                    rightOffset: rightOccurrence.offset
                )
            )
        }

        return longestIncreasingSubsequence(in: candidates)
    }

    private func longestIncreasingSubsequence(
        in candidates: [MatchedLinePair]
    ) -> [MatchedLinePair] {
        guard !candidates.isEmpty else {
            return []
        }

        var tailCandidateIndices: [Int] = []
        tailCandidateIndices.reserveCapacity(candidates.count)
        var predecessorIndices = Array(repeating: -1, count: candidates.count)

        for candidateIndex in candidates.indices {
            if cancellationRequested { return [] }
            let rightOffset = candidates[candidateIndex].rightOffset
            var lower = 0
            var upper = tailCandidateIndices.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if candidates[tailCandidateIndices[middle]].rightOffset < rightOffset {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }

            if lower > 0 {
                predecessorIndices[candidateIndex] = tailCandidateIndices[lower - 1]
            }
            if lower == tailCandidateIndices.count {
                tailCandidateIndices.append(candidateIndex)
            } else {
                tailCandidateIndices[lower] = candidateIndex
            }
        }

        var result: [MatchedLinePair] = []
        result.reserveCapacity(tailCandidateIndices.count)
        var candidateIndex = tailCandidateIndices.last ?? -1
        while candidateIndex >= 0 {
            if cancellationRequested { return [] }
            result.append(candidates[candidateIndex])
            candidateIndex = predecessorIndices[candidateIndex]
        }
        result.reverse()
        return result
    }

    private func markExactMatches<Element: Equatable>(
        left: [Element],
        leftRange: Range<Int>,
        right: [Element],
        rightRange: Range<Int>,
        matchedLeft: inout [Bool],
        matchedRight: inout [Bool]
    ) {
        let localOffsets = exactChangeOffsets(
            from: Array(left[leftRange]),
            to: Array(right[rightRange])
        )
        var leftOffset = 0
        var rightOffset = 0

        while leftOffset < leftRange.count || rightOffset < rightRange.count {
            if cancellationRequested { return }
            if leftOffset < leftRange.count,
               rightOffset < rightRange.count,
               !localOffsets.isRemoved(leftOffset),
               !localOffsets.isInserted(rightOffset) {
                matchedLeft[leftRange.lowerBound + leftOffset] = true
                matchedRight[rightRange.lowerBound + rightOffset] = true
                leftOffset += 1
                rightOffset += 1
                continue
            }

            if leftOffset < leftRange.count, localOffsets.isRemoved(leftOffset) {
                leftOffset += 1
            } else if rightOffset < rightRange.count, localOffsets.isInserted(rightOffset) {
                rightOffset += 1
            } else if leftOffset < leftRange.count {
                leftOffset += 1
            } else {
                rightOffset += 1
            }
        }
    }

    private func makeStatistics(for lines: [AlignedDiffLine]) -> TextDiffStatistics {
        var unchanged = 0
        var inserted = 0
        var deleted = 0
        var modified = 0

        for line in lines {
            if cancellationRequested { break }
            switch line.kind {
            case .unchanged: unchanged += 1
            case .inserted: inserted += 1
            case .deleted: deleted += 1
            case .modified: modified += 1
            }
        }

        return TextDiffStatistics(
            unchangedLineCount: unchanged,
            insertedLineCount: inserted,
            deletedLineCount: deleted,
            modifiedLineCount: modified
        )
    }

    private func makeHunks(
        from lines: [AlignedDiffLine],
        contextLineCount: Int
    ) -> [DiffHunk] {
        let contextLineCount = max(0, contextLineCount)
        var changedOffsets: [Int] = []
        changedOffsets.reserveCapacity(min(lines.count, 4_096))
        for offset in lines.indices {
            if cancellationRequested { return [] }
            if lines[offset].kind != .unchanged {
                changedOffsets.append(offset)
            }
        }
        guard !changedOffsets.isEmpty else {
            return []
        }

        var intervals: [(start: Int, end: Int)] = []
        for changedOffset in changedOffsets {
            if cancellationRequested { return [] }
            let start = max(0, changedOffset - contextLineCount)
            let end = min(lines.count, changedOffset + contextLineCount + 1)

            if let last = intervals.last, start <= last.end {
                intervals[intervals.count - 1].end = max(last.end, end)
            } else {
                intervals.append((start: start, end: end))
            }
        }

        var leftPrefix = Array(repeating: 0, count: lines.count + 1)
        var rightPrefix = Array(repeating: 0, count: lines.count + 1)
        for (offset, line) in lines.enumerated() {
            if cancellationRequested { return [] }
            leftPrefix[offset + 1] = leftPrefix[offset] + (line.left == nil ? 0 : 1)
            rightPrefix[offset + 1] = rightPrefix[offset] + (line.right == nil ? 0 : 1)
        }

        var hunks: [DiffHunk] = []
        hunks.reserveCapacity(intervals.count)
        for (hunkIndex, interval) in intervals.enumerated() {
            if cancellationRequested { return [] }
            hunks.append(DiffHunk(
                index: hunkIndex,
                alignedRange: DiffLineRange(
                    start: interval.start,
                    count: interval.end - interval.start
                ),
                leftRange: DiffLineRange(
                    start: leftPrefix[interval.start],
                    count: leftPrefix[interval.end] - leftPrefix[interval.start]
                ),
                rightRange: DiffLineRange(
                    start: rightPrefix[interval.start],
                    count: rightPrefix[interval.end] - rightPrefix[interval.start]
                ),
                lines: Array(lines[interval.start..<interval.end])
            ))
        }
        return hunks
    }
}

private enum TextDiffCancellationContext {
    @TaskLocal static var isEnabled = false
}

private struct LineComparisonKey: Hashable {
    let content: String
    let ending: ComparableLineEnding
}

private enum ComparableLineEnding: Hashable {
    case none
    case terminated
    case lf
    case crlf
    case cr
}

private struct ChangeOffsets {
    let removed: [Bool]
    let inserted: [Bool]

    init(removed: [Bool], inserted: [Bool]) {
        self.removed = removed
        self.inserted = inserted
    }

    init(matchedLeft: [Bool], matchedRight: [Bool]) {
        removed = matchedLeft.map(!)
        inserted = matchedRight.map(!)
    }

    func isRemoved(_ offset: Int) -> Bool {
        removed.indices.contains(offset) && removed[offset]
    }

    func isInserted(_ offset: Int) -> Bool {
        inserted.indices.contains(offset) && inserted[offset]
    }
}

private struct PatienceWorkItem {
    let leftRange: Range<Int>
    let rightRange: Range<Int>
    let depth: Int
}

private struct ElementOccurrence {
    let offset: Int
    var count: Int
}

private struct MatchedLinePair {
    let leftOffset: Int
    let rightOffset: Int
}

private enum TokenKind: Equatable {
    case word
    case whitespace
    case symbol
}

private struct Token {
    let comparisonKey: String
    let range: TextCharacterRange
}
