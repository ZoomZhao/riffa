import Foundation

public enum UnifiedPatchErrorCode: String, Hashable, Sendable {
    case invalidLabel
    case malformedFileHeader
    case malformedHunkHeader
    case malformedHunkLine
    case orphanNoNewlineMarker
    case countMismatch
    case countOverflow
    case fileIndexOutOfBounds
    case hunkOutOfOrder
    case hunkPositionMismatch
    case sourceRangeOutOfBounds
    case contextMismatch
    case deletionMismatch
    case invalidLineEndingPlacement
}

/// A structured patch failure. Patch line and hunk indices identify the
/// offending input without exposing or accessing any filesystem path.
public struct UnifiedPatchError: Error, Hashable, Sendable, LocalizedError {
    public let code: UnifiedPatchErrorCode
    public let message: String
    public let lineNumber: Int?
    public let fileIndex: Int?
    public let hunkIndex: Int?

    public init(
        code: UnifiedPatchErrorCode,
        message: String,
        lineNumber: Int? = nil,
        fileIndex: Int? = nil,
        hunkIndex: Int? = nil
    ) {
        self.code = code
        self.message = message
        self.lineNumber = lineNumber
        self.fileIndex = fileIndex
        self.hunkIndex = hunkIndex
    }

    public var errorDescription: String? {
        var location: [String] = []
        if let lineNumber { location.append("line \(lineNumber)") }
        if let fileIndex { location.append("file \(fileIndex + 1)") }
        if let hunkIndex { location.append("hunk \(hunkIndex + 1)") }
        guard !location.isEmpty else { return message }
        return "\(message) (\(location.joined(separator: ", ")))"
    }
}

public struct UnifiedPatchRange: Hashable, Sendable {
    public let start: Int
    public let count: Int

    public init(start: Int, count: Int) {
        self.start = start
        self.count = count
    }
}

public enum UnifiedPatchLineKind: Character, Hashable, Sendable {
    case context = " "
    case deletion = "-"
    case addition = "+"
}

/// One semantic hunk line. `ending` describes the corresponding file line,
/// not merely the patch container's separator. `.none` is represented with
/// the standard `\ No newline at end of file` marker when rendered.
public struct UnifiedPatchLine: Hashable, Sendable {
    public let kind: UnifiedPatchLineKind
    public let content: String
    public let ending: TextLineEnding
    public let patchLineNumber: Int?

    public init(
        kind: UnifiedPatchLineKind,
        content: String,
        ending: TextLineEnding,
        patchLineNumber: Int? = nil
    ) {
        self.kind = kind
        self.content = content
        self.ending = ending
        self.patchLineNumber = patchLineNumber
    }
}

public struct UnifiedPatchHunk: Identifiable, Hashable, Sendable {
    public let index: Int
    public let oldRange: UnifiedPatchRange
    public let newRange: UnifiedPatchRange
    public let sectionHeading: String?
    public let lines: [UnifiedPatchLine]
    public let headerLineNumber: Int?

    public init(
        index: Int,
        oldRange: UnifiedPatchRange,
        newRange: UnifiedPatchRange,
        sectionHeading: String? = nil,
        lines: [UnifiedPatchLine],
        headerLineNumber: Int? = nil
    ) {
        self.index = index
        self.oldRange = oldRange
        self.newRange = newRange
        self.sectionHeading = sectionHeading
        self.lines = lines
        self.headerLineNumber = headerLineNumber
    }

    public var id: Int { index }
}

public struct UnifiedPatchFile: Identifiable, Hashable, Sendable {
    public let index: Int
    public let oldLabel: String
    public let newLabel: String
    public let hunks: [UnifiedPatchHunk]
    public let headerLineNumber: Int?

    public init(
        index: Int,
        oldLabel: String,
        newLabel: String,
        hunks: [UnifiedPatchHunk],
        headerLineNumber: Int? = nil
    ) {
        self.index = index
        self.oldLabel = oldLabel
        self.newLabel = newLabel
        self.hunks = hunks
        self.headerLineNumber = headerLineNumber
    }

    public var id: Int { index }
}

public struct UnifiedPatch: Hashable, Sendable {
    public let files: [UnifiedPatchFile]

    public init(files: [UnifiedPatchFile]) {
        self.files = files
    }

    /// Renders a standard unified diff. Header syntax uses LF; hunk data keeps
    /// its semantic LF, CRLF, CR, or no-final-newline representation.
    public func renderedText() -> String {
        var output = ""

        for file in files {
            output += "--- \(file.oldLabel)\n"
            output += "+++ \(file.newLabel)\n"

            for hunk in file.hunks {
                output += "@@ -\(hunk.oldRange.start),\(hunk.oldRange.count)"
                output += " +\(hunk.newRange.start),\(hunk.newRange.count) @@"
                if let heading = hunk.sectionHeading, !heading.isEmpty {
                    output += " \(heading)"
                }
                output += "\n"

                for line in hunk.lines {
                    output.append(line.kind.rawValue)
                    output += line.content
                    if line.ending.isTerminated {
                        output += line.ending.rawValue
                    } else {
                        output += "\n\\ No newline at end of file\n"
                    }
                }
            }
        }

        return output
    }
}

/// Generates unified patches from the complete aligned representation in a
/// `TextDiffResult`, independently of the context used to build its own hunks.
public struct UnifiedDiffGenerator: Sendable {
    public let contextLineCount: Int

    public init(contextLineCount: Int = 3) {
        self.contextLineCount = max(0, contextLineCount)
    }

    public func patch(
        from result: TextDiffResult,
        oldLabel: String,
        newLabel: String
    ) throws -> UnifiedPatch {
        try validate(label: oldLabel)
        try validate(label: newLabel)

        let alignedLines = result.alignedLines
        let changedOffsets = alignedLines.indices.filter { offset in
            let line = alignedLines[offset]
            return line.kind != .unchanged || line.hasLineEndingDifference
        }
        guard !changedOffsets.isEmpty else {
            return UnifiedPatch(files: [])
        }

        let ranges = expandedRanges(
            changedOffsets: changedOffsets,
            lineCount: alignedLines.count
        )
        let leftPrefix = prefixCounts(in: alignedLines, side: .left)
        let rightPrefix = prefixCounts(in: alignedLines, side: .right)

        let hunks = ranges.enumerated().map { hunkIndex, range in
            let oldCount = leftPrefix[range.upperBound] - leftPrefix[range.lowerBound]
            let newCount = rightPrefix[range.upperBound] - rightPrefix[range.lowerBound]
            let oldBefore = leftPrefix[range.lowerBound]
            let newBefore = rightPrefix[range.lowerBound]
            let oldStart = oldCount == 0 ? oldBefore : oldBefore + 1
            let newStart = newCount == 0 ? newBefore : newBefore + 1

            return UnifiedPatchHunk(
                index: hunkIndex,
                oldRange: UnifiedPatchRange(start: oldStart, count: oldCount),
                newRange: UnifiedPatchRange(start: newStart, count: newCount),
                lines: makeHunkLines(from: alignedLines[range])
            )
        }

        return UnifiedPatch(
            files: [
                UnifiedPatchFile(
                    index: 0,
                    oldLabel: oldLabel,
                    newLabel: newLabel,
                    hunks: hunks
                )
            ]
        )
    }

    public func generate(
        from result: TextDiffResult,
        oldLabel: String,
        newLabel: String
    ) throws -> String {
        try patch(from: result, oldLabel: oldLabel, newLabel: newLabel).renderedText()
    }

    private enum Side {
        case left
        case right
    }

    private func validate(label: String) throws {
        guard !label.isEmpty,
              !label.contains("\n"),
              !label.contains("\r"),
              !label.contains("\t"),
              !label.contains("\0")
        else {
            throw UnifiedPatchError(
                code: .invalidLabel,
                message: "Patch labels must be non-empty single-line values without tabs or NULs."
            )
        }
    }

    private func expandedRanges(
        changedOffsets: [Int],
        lineCount: Int
    ) -> [Range<Int>] {
        var ranges: [Range<Int>] = []

        for offset in changedOffsets {
            let lowerBound = max(0, offset - contextLineCount)
            let upperBound = min(lineCount, offset + contextLineCount + 1)
            if let last = ranges.last, lowerBound <= last.upperBound {
                ranges[ranges.count - 1] = last.lowerBound..<max(last.upperBound, upperBound)
            } else {
                ranges.append(lowerBound..<upperBound)
            }
        }

        return ranges
    }

    private func prefixCounts(
        in lines: [AlignedDiffLine],
        side: Side
    ) -> [Int] {
        var counts = [0]
        counts.reserveCapacity(lines.count + 1)
        for line in lines {
            let exists = switch side {
            case .left: line.left != nil
            case .right: line.right != nil
            }
            counts.append(counts[counts.count - 1] + (exists ? 1 : 0))
        }
        return counts
    }

    private func makeHunkLines(
        from alignedLines: ArraySlice<AlignedDiffLine>
    ) -> [UnifiedPatchLine] {
        var output: [UnifiedPatchLine] = []
        var pendingDeletions: [UnifiedPatchLine] = []
        var pendingAdditions: [UnifiedPatchLine] = []

        func flushChanges() {
            output += pendingDeletions
            output += pendingAdditions
            pendingDeletions.removeAll(keepingCapacity: true)
            pendingAdditions.removeAll(keepingCapacity: true)
        }

        for aligned in alignedLines {
            let changed = aligned.kind != .unchanged || aligned.hasLineEndingDifference
            if changed {
                if let left = aligned.left {
                    pendingDeletions.append(
                        UnifiedPatchLine(
                            kind: .deletion,
                            content: left.line.content,
                            ending: left.line.ending
                        )
                    )
                }
                if let right = aligned.right {
                    pendingAdditions.append(
                        UnifiedPatchLine(
                            kind: .addition,
                            content: right.line.content,
                            ending: right.line.ending
                        )
                    )
                }
            } else {
                flushChanges()
                if let value = aligned.left ?? aligned.right {
                    output.append(
                        UnifiedPatchLine(
                            kind: .context,
                            content: value.line.content,
                            ending: value.line.ending
                        )
                    )
                }
            }
        }
        flushChanges()
        return output
    }
}

/// Strict parser for one or more `---`/`+++` unified-diff file sections.
public struct UnifiedPatchParser: Sendable {
    public let maximumLineCount: Int
    public let maximumLineUTF8ByteCount: Int

    public init(
        maximumLineCount: Int = 1_000_000,
        maximumLineUTF8ByteCount: Int = 1 * 1_024 * 1_024
    ) {
        self.maximumLineCount = max(1, maximumLineCount)
        self.maximumLineUTF8ByteCount = max(1, maximumLineUTF8ByteCount)
    }

    public func parse(_ text: String) throws -> UnifiedPatch {
        // Enforce the configured line budget before `TextDocument` allocates
        // one value per logical line. This matters for bounded byte inputs
        // containing millions of one-character patch lines: the decoded text
        // can be modest while the parsed representation is not.
        let inputLimitFailure = Self.inputLimitFailure(
            in: text,
            maximumLineCount: maximumLineCount,
            maximumLineUTF8ByteCount: maximumLineUTF8ByteCount
        )
        guard inputLimitFailure == nil else {
            let message = switch inputLimitFailure {
            case .lineCount:
                "Patch input exceeds the configured limit of \(maximumLineCount) logical lines."
            case let .lineByteCount(attempted):
                "A patch input line contains \(attempted) UTF-8 bytes; the configured limit is \(maximumLineUTF8ByteCount)."
            case nil:
                preconditionFailure("A present input limit failure was required")
            }
            throw UnifiedPatchError(
                code: .countOverflow,
                message: message
            )
        }

        let patchLines = TextDocument(text: text).lines
        var cursor = 0
        var files: [UnifiedPatchFile] = []

        while cursor < patchLines.count {
            if patchLines[cursor].content.isEmpty {
                cursor += 1
                continue
            }

            let fileIndex = files.count
            let oldHeaderLine = cursor + 1
            guard patchLines[cursor].content.hasPrefix("--- ") else {
                throw error(
                    .malformedFileHeader,
                    "Expected an old-file header beginning with '--- '.",
                    line: cursor + 1,
                    file: fileIndex
                )
            }
            let oldLabel = try parseLabel(
                patchLines[cursor].content,
                prefix: "--- ",
                line: cursor + 1,
                file: fileIndex
            )
            cursor += 1

            guard cursor < patchLines.count,
                  patchLines[cursor].content.hasPrefix("+++ ")
            else {
                throw error(
                    .malformedFileHeader,
                    "Expected a new-file header beginning with '+++ '.",
                    line: min(cursor + 1, patchLines.count + 1),
                    file: fileIndex
                )
            }
            let newLabel = try parseLabel(
                patchLines[cursor].content,
                prefix: "+++ ",
                line: cursor + 1,
                file: fileIndex
            )
            cursor += 1

            var hunks: [UnifiedPatchHunk] = []
            while cursor < patchLines.count,
                  patchLines[cursor].content.hasPrefix("@@ ")
            {
                let parsed = try parseHunk(
                    lines: patchLines,
                    cursor: cursor,
                    fileIndex: fileIndex,
                    hunkIndex: hunks.count
                )
                hunks.append(parsed.hunk)
                cursor = parsed.nextCursor
            }

            files.append(
                UnifiedPatchFile(
                    index: fileIndex,
                    oldLabel: oldLabel,
                    newLabel: newLabel,
                    hunks: hunks,
                    headerLineNumber: oldHeaderLine
                )
            )

            if cursor < patchLines.count,
               !patchLines[cursor].content.isEmpty,
               !patchLines[cursor].content.hasPrefix("--- ")
            {
                throw error(
                    .malformedHunkLine,
                    "Unexpected content outside a hunk.",
                    line: cursor + 1,
                    file: fileIndex
                )
            }
        }

        return UnifiedPatch(files: files)
    }

    private enum InputLimitFailure: Equatable {
        case lineCount
        case lineByteCount(attempted: Int)
    }

    /// Checks the same CR, LF, CRLF, and unterminated logical lines as
    /// `TextDocument`, but without materializing line strings or an array.
    private static func inputLimitFailure(
        in text: String,
        maximumLineCount: Int,
        maximumLineUTF8ByteCount: Int
    ) -> InputLimitFailure? {
        guard !text.isEmpty else { return nil }

        var lineCount = 0
        var lineByteCount = 0
        var previousWasCarriageReturn = false

        for byte in text.utf8 {
            if byte == 0x0D {
                lineCount += 1
                lineByteCount = 0
                previousWasCarriageReturn = true
            } else if byte == 0x0A {
                if !previousWasCarriageReturn {
                    lineCount += 1
                    lineByteCount = 0
                }
                previousWasCarriageReturn = false
            } else {
                previousWasCarriageReturn = false
                let (nextCount, overflow) = lineByteCount.addingReportingOverflow(1)
                if overflow || nextCount > maximumLineUTF8ByteCount {
                    return .lineByteCount(
                        attempted: overflow ? Int.max : nextCount
                    )
                }
                lineByteCount = nextCount
            }

            if lineCount > maximumLineCount { return .lineCount }
        }

        if lineByteCount > 0 {
            lineCount += 1
        }
        return lineCount > maximumLineCount ? .lineCount : nil
    }

    private func parseLabel(
        _ header: String,
        prefix: String,
        line: Int,
        file: Int
    ) throws -> String {
        let remainder = header.dropFirst(prefix.count)
        let label = remainder.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)[0]
        guard !label.isEmpty else {
            throw error(
                .malformedFileHeader,
                "A file header must contain a non-empty path label.",
                line: line,
                file: file
            )
        }
        return String(label)
    }

    private func parseHunk(
        lines: [TextLine],
        cursor initialCursor: Int,
        fileIndex: Int,
        hunkIndex: Int
    ) throws -> (hunk: UnifiedPatchHunk, nextCursor: Int) {
        let headerLineNumber = initialCursor + 1
        let header = try parseHunkHeader(
            lines[initialCursor].content,
            line: headerLineNumber,
            file: fileIndex,
            hunk: hunkIndex
        )
        var cursor = initialCursor + 1
        var parsedLines: [UnifiedPatchLine] = []
        var oldSeen = 0
        var newSeen = 0
        var markerAllowed = false

        while cursor < lines.count {
            let patchLine = lines[cursor]
            let lineNumber = cursor + 1

            if patchLine.content == "\\ No newline at end of file" {
                guard markerAllowed, let previous = parsedLines.last else {
                    throw error(
                        .orphanNoNewlineMarker,
                        "The no-newline marker must immediately follow a hunk data line.",
                        line: lineNumber,
                        file: fileIndex,
                        hunk: hunkIndex
                    )
                }
                parsedLines[parsedLines.count - 1] = UnifiedPatchLine(
                    kind: previous.kind,
                    content: previous.content,
                    ending: .none,
                    patchLineNumber: previous.patchLineNumber
                )
                markerAllowed = false
                cursor += 1
                continue
            }

            if oldSeen == header.oldRange.count,
               newSeen == header.newRange.count
            {
                break
            }

            guard let prefix = patchLine.content.first,
                  let kind = UnifiedPatchLineKind(rawValue: prefix)
            else {
                throw error(
                    .malformedHunkLine,
                    "A hunk line must begin with space, '+', or '-'.",
                    line: lineNumber,
                    file: fileIndex,
                    hunk: hunkIndex
                )
            }

            switch kind {
            case .context:
                oldSeen = try increment(
                    oldSeen,
                    limit: header.oldRange.count,
                    line: lineNumber,
                    file: fileIndex,
                    hunk: hunkIndex
                )
                newSeen = try increment(
                    newSeen,
                    limit: header.newRange.count,
                    line: lineNumber,
                    file: fileIndex,
                    hunk: hunkIndex
                )
            case .deletion:
                oldSeen = try increment(
                    oldSeen,
                    limit: header.oldRange.count,
                    line: lineNumber,
                    file: fileIndex,
                    hunk: hunkIndex
                )
            case .addition:
                newSeen = try increment(
                    newSeen,
                    limit: header.newRange.count,
                    line: lineNumber,
                    file: fileIndex,
                    hunk: hunkIndex
                )
            }

            parsedLines.append(
                UnifiedPatchLine(
                    kind: kind,
                    content: String(patchLine.content.dropFirst()),
                    ending: patchLine.ending,
                    patchLineNumber: lineNumber
                )
            )
            markerAllowed = true
            cursor += 1
        }

        guard oldSeen == header.oldRange.count,
              newSeen == header.newRange.count
        else {
            throw error(
                .countMismatch,
                "Hunk data does not satisfy its declared old and new line counts.",
                line: min(cursor + 1, lines.count + 1),
                file: fileIndex,
                hunk: hunkIndex
            )
        }

        return (
            UnifiedPatchHunk(
                index: hunkIndex,
                oldRange: header.oldRange,
                newRange: header.newRange,
                sectionHeading: header.sectionHeading,
                lines: parsedLines,
                headerLineNumber: headerLineNumber
            ),
            cursor
        )
    }

    private func parseHunkHeader(
        _ header: String,
        line: Int,
        file: Int,
        hunk: Int
    ) throws -> ParsedHunkHeader {
        guard header.hasPrefix("@@ "),
              let closingRange = header.range(of: " @@", range: header.index(header.startIndex, offsetBy: 3)..<header.endIndex)
        else {
            throw error(
                .malformedHunkHeader,
                "Malformed hunk header; expected '@@ -a,b +c,d @@'.",
                line: line,
                file: file,
                hunk: hunk
            )
        }

        let rangeText = header[header.index(header.startIndex, offsetBy: 3)..<closingRange.lowerBound]
        let tokens = rangeText.split(separator: " ", omittingEmptySubsequences: true)
        guard tokens.count == 2 else {
            throw error(
                .malformedHunkHeader,
                "A hunk header must contain exactly one old and one new range.",
                line: line,
                file: file,
                hunk: hunk
            )
        }

        let oldRange = try parseRange(
            tokens[0],
            sign: "-",
            line: line,
            file: file,
            hunk: hunk
        )
        let newRange = try parseRange(
            tokens[1],
            sign: "+",
            line: line,
            file: file,
            hunk: hunk
        )
        let headingStart = closingRange.upperBound
        let rawHeading = header[headingStart...]
        let sectionHeading = rawHeading.first == " "
            ? String(rawHeading.dropFirst())
            : String(rawHeading)

        return ParsedHunkHeader(
            oldRange: oldRange,
            newRange: newRange,
            sectionHeading: sectionHeading.isEmpty ? nil : sectionHeading
        )
    }

    private func parseRange(
        _ token: Substring,
        sign: Character,
        line: Int,
        file: Int,
        hunk: Int
    ) throws -> UnifiedPatchRange {
        guard token.first == sign else {
            throw error(
                .malformedHunkHeader,
                "Hunk ranges must begin with '\(sign)'.",
                line: line,
                file: file,
                hunk: hunk
            )
        }

        let body = token.dropFirst()
        let components = body.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        guard components.count == 1 || components.count == 2 else {
            throw error(
                .malformedHunkHeader,
                "Malformed hunk range.",
                line: line,
                file: file,
                hunk: hunk
            )
        }

        let start = try parseUnsigned(
            components[0],
            line: line,
            file: file,
            hunk: hunk
        )
        let count = components.count == 2
            ? try parseUnsigned(components[1], line: line, file: file, hunk: hunk)
            : 1

        guard count == 0 || start > 0 else {
            throw error(
                .malformedHunkHeader,
                "A non-empty hunk range must start at line 1 or later.",
                line: line,
                file: file,
                hunk: hunk
            )
        }
        let (_, overflow) = start.addingReportingOverflow(count)
        guard !overflow else {
            throw error(
                .countOverflow,
                "The hunk range overflows the supported integer size.",
                line: line,
                file: file,
                hunk: hunk
            )
        }
        return UnifiedPatchRange(start: start, count: count)
    }

    private func parseUnsigned(
        _ text: Substring,
        line: Int,
        file: Int,
        hunk: Int
    ) throws -> Int {
        guard !text.isEmpty else {
            throw error(
                .malformedHunkHeader,
                "Hunk ranges require decimal line numbers.",
                line: line,
                file: file,
                hunk: hunk
            )
        }

        var value = 0
        for byte in text.utf8 {
            guard byte >= 48, byte <= 57 else {
                throw error(
                    .malformedHunkHeader,
                    "Hunk ranges may contain only ASCII decimal digits.",
                    line: line,
                    file: file,
                    hunk: hunk
                )
            }
            let (multiplied, multiplyOverflow) = value.multipliedReportingOverflow(by: 10)
            let (next, addOverflow) = multiplied.addingReportingOverflow(Int(byte - 48))
            guard !multiplyOverflow, !addOverflow, next <= maximumLineCount else {
                throw error(
                    .countOverflow,
                    "A hunk line number or count exceeds the configured limit of \(maximumLineCount).",
                    line: line,
                    file: file,
                    hunk: hunk
                )
            }
            value = next
        }
        return value
    }

    private func increment(
        _ value: Int,
        limit: Int,
        line: Int,
        file: Int,
        hunk: Int
    ) throws -> Int {
        let (next, overflow) = value.addingReportingOverflow(1)
        guard !overflow, next <= limit else {
            throw error(
                .countMismatch,
                "Hunk data exceeds a declared line count.",
                line: line,
                file: file,
                hunk: hunk
            )
        }
        return next
    }

    private func error(
        _ code: UnifiedPatchErrorCode,
        _ message: String,
        line: Int? = nil,
        file: Int? = nil,
        hunk: Int? = nil
    ) -> UnifiedPatchError {
        UnifiedPatchError(
            code: code,
            message: message,
            lineNumber: line,
            fileIndex: file,
            hunkIndex: hunk
        )
    }
}

/// Applies a parsed file patch to an in-memory document. All validation and
/// construction occurs in local values, so a thrown error never exposes a
/// partially patched document.
public struct UnifiedPatchApplier: Sendable {
    public init() {}

    public func apply(
        _ patch: UnifiedPatch,
        fileIndex: Int = 0,
        to source: TextDocument
    ) throws -> TextDocument {
        guard patch.files.indices.contains(fileIndex) else {
            throw UnifiedPatchError(
                code: .fileIndexOutOfBounds,
                message: "The requested patch file index does not exist.",
                fileIndex: fileIndex
            )
        }
        return try apply(patch.files[fileIndex], to: source)
    }

    public func apply(
        _ file: UnifiedPatchFile,
        to source: TextDocument
    ) throws -> TextDocument {
        var output: [TextLine] = []
        var outputOrigins: [Int?] = []
        var sourceCursor = 0

        func append(_ line: TextLine, hunkIndex: Int?) {
            output.append(line)
            outputOrigins.append(hunkIndex)
        }

        for (position, hunk) in file.hunks.enumerated() {
            let hunkIndex = hunk.index
            guard hunk.index == position else {
                throw patchError(
                    .hunkOutOfOrder,
                    "Hunk indices must be contiguous and ordered.",
                    file: file,
                    hunk: hunk
                )
            }

            let oldStartIndex = zeroBasedStart(for: hunk.oldRange)
            let newStartIndex = zeroBasedStart(for: hunk.newRange)
            guard oldStartIndex >= sourceCursor else {
                throw patchError(
                    .hunkOutOfOrder,
                    "This hunk overlaps or precedes an earlier hunk.",
                    file: file,
                    hunk: hunk
                )
            }
            guard oldStartIndex <= source.lines.count else {
                throw patchError(
                    .sourceRangeOutOfBounds,
                    "The hunk starts beyond the end of the source document.",
                    file: file,
                    hunk: hunk
                )
            }

            while sourceCursor < oldStartIndex {
                append(source.lines[sourceCursor], hunkIndex: nil)
                sourceCursor += 1
            }

            guard output.count == newStartIndex else {
                throw patchError(
                    .hunkPositionMismatch,
                    "The new-file hunk position is inconsistent with preceding edits.",
                    file: file,
                    hunk: hunk
                )
            }

            let sourceAtHunkStart = sourceCursor
            let outputAtHunkStart = output.count
            for line in hunk.lines {
                switch line.kind {
                case .context:
                    let actual = try sourceLine(
                        at: sourceCursor,
                        source: source,
                        expected: line,
                        code: .contextMismatch,
                        description: "Context",
                        file: file,
                        hunk: hunk
                    )
                    append(actual, hunkIndex: hunkIndex)
                    sourceCursor += 1

                case .deletion:
                    _ = try sourceLine(
                        at: sourceCursor,
                        source: source,
                        expected: line,
                        code: .deletionMismatch,
                        description: "Deleted",
                        file: file,
                        hunk: hunk
                    )
                    sourceCursor += 1

                case .addition:
                    append(
                        TextLine(content: line.content, ending: line.ending),
                        hunkIndex: hunkIndex
                    )
                }
            }

            guard sourceCursor - sourceAtHunkStart == hunk.oldRange.count,
                  output.count - outputAtHunkStart == hunk.newRange.count
            else {
                throw patchError(
                    .countMismatch,
                    "Applied hunk data does not match the declared ranges.",
                    file: file,
                    hunk: hunk
                )
            }
        }

        while sourceCursor < source.lines.count {
            append(source.lines[sourceCursor], hunkIndex: nil)
            sourceCursor += 1
        }

        if output.count > 1 {
            for index in output.indices.dropLast() where output[index].ending == .none {
                throw UnifiedPatchError(
                    code: .invalidLineEndingPlacement,
                    message: "A no-newline marker may only describe the final output line.",
                    fileIndex: file.index,
                    hunkIndex: outputOrigins[index]
                )
            }
        }

        return TextDocument(text: output.lazy.map(\.sourceText).joined())
    }

    private func zeroBasedStart(for range: UnifiedPatchRange) -> Int {
        range.count == 0 ? range.start : range.start - 1
    }

    private func sourceLine(
        at index: Int,
        source: TextDocument,
        expected: UnifiedPatchLine,
        code: UnifiedPatchErrorCode,
        description: String,
        file: UnifiedPatchFile,
        hunk: UnifiedPatchHunk
    ) throws -> TextLine {
        guard source.lines.indices.contains(index) else {
            throw UnifiedPatchError(
                code: .sourceRangeOutOfBounds,
                message: "The hunk consumes beyond the end of the source document.",
                lineNumber: expected.patchLineNumber ?? hunk.headerLineNumber,
                fileIndex: file.index,
                hunkIndex: hunk.index
            )
        }

        let actual = source.lines[index]
        guard actual.content == expected.content,
              expected.ending != .none || actual.ending == .none
        else {
            throw UnifiedPatchError(
                code: code,
                message: "\(description) line does not match source line \(index + 1).",
                lineNumber: expected.patchLineNumber ?? hunk.headerLineNumber,
                fileIndex: file.index,
                hunkIndex: hunk.index
            )
        }
        return actual
    }

    private func patchError(
        _ code: UnifiedPatchErrorCode,
        _ message: String,
        file: UnifiedPatchFile,
        hunk: UnifiedPatchHunk
    ) -> UnifiedPatchError {
        UnifiedPatchError(
            code: code,
            message: message,
            lineNumber: hunk.headerLineNumber,
            fileIndex: file.index,
            hunkIndex: hunk.index
        )
    }
}

private struct ParsedHunkHeader {
    let oldRange: UnifiedPatchRange
    let newRange: UnifiedPatchRange
    let sectionHeading: String?
}
