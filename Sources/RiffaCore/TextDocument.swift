/// An immutable text document split into logical lines without losing source
/// line terminators.
public struct TextDocument: Hashable, Sendable {
    public let lines: [TextLine]

    public init(text: String) {
        lines = Self.parseLines(in: text)
    }

    public var text: String {
        lines.lazy.map(\.sourceText).joined()
    }

    public var isEmpty: Bool {
        lines.isEmpty
    }

    public var hasTrailingLineEnding: Bool {
        lines.last?.ending.isTerminated ?? false
    }

    /// The most frequently occurring terminator, with first occurrence used
    /// as a stable tie-breaker. Returns `nil` for an unterminated document.
    public var preferredLineEnding: TextLineEnding? {
        var counts: [TextLineEnding: Int] = [:]
        var firstOffsets: [TextLineEnding: Int] = [:]

        for (offset, line) in lines.enumerated() where line.ending.isTerminated {
            counts[line.ending, default: 0] += 1
            firstOffsets[line.ending, default: offset] = offset
        }

        return counts.keys.max { lhs, rhs in
            let lhsCount = counts[lhs, default: 0]
            let rhsCount = counts[rhs, default: 0]
            if lhsCount != rhsCount {
                return lhsCount < rhsCount
            }
            return firstOffsets[lhs, default: .max] > firstOffsets[rhs, default: .max]
        }
    }

    private static func parseLines(in text: String) -> [TextLine] {
        guard !text.isEmpty else {
            return []
        }

        var result: [TextLine] = []
        result.reserveCapacity(max(1, text.utf8.count / 40))

        let scalars = text.unicodeScalars
        var lineStart = scalars.startIndex
        var cursor = lineStart

        while cursor < scalars.endIndex {
            let scalar = scalars[cursor]

            if scalar == "\n" {
                result.append(
                    TextLine(content: String(scalars[lineStart..<cursor]), ending: .lf)
                )
                cursor = scalars.index(after: cursor)
                lineStart = cursor
                continue
            }

            if scalar == "\r" {
                let afterCarriageReturn = scalars.index(after: cursor)
                if afterCarriageReturn < scalars.endIndex,
                   scalars[afterCarriageReturn] == "\n" {
                    result.append(
                        TextLine(content: String(scalars[lineStart..<cursor]), ending: .crlf)
                    )
                    cursor = scalars.index(after: afterCarriageReturn)
                } else {
                    result.append(
                        TextLine(content: String(scalars[lineStart..<cursor]), ending: .cr)
                    )
                    cursor = afterCarriageReturn
                }
                lineStart = cursor
                continue
            }

            cursor = scalars.index(after: cursor)
        }

        if lineStart < scalars.endIndex {
            result.append(
                TextLine(content: String(scalars[lineStart..<scalars.endIndex]), ending: .none)
            )
        }

        return result
    }
}
