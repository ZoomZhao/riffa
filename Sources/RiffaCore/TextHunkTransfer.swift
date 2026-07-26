import Foundation

public enum TextHunkTransferSide: String, Hashable, Codable, Sendable {
    case left
    case right
}

public enum TextHunkTransferError: Error, Hashable, Sendable, LocalizedError {
    case sourceRangeOutOfBounds
    case targetRangeOutOfBounds

    public var errorDescription: String? {
        switch self {
        case .sourceRangeOutOfBounds:
            "The source hunk range no longer matches its document."
        case .targetRangeOutOfBounds:
            "The target hunk range no longer matches its document."
        }
    }
}

public struct TextHunkTransferResult: Hashable, Sendable {
    public let left: TextDocument
    public let right: TextDocument

    public init(left: TextDocument, right: TextDocument) {
        self.left = left
        self.right = right
    }
}

/// Copies one aligned hunk between immutable text documents without touching disk.
public struct TextHunkTransfer: Sendable {
    public init() {}

    public func copy(
        _ hunk: DiffHunk,
        from sourceSide: TextHunkTransferSide,
        left: TextDocument,
        right: TextDocument
    ) throws -> TextHunkTransferResult {
        let source = sourceSide == .left ? left : right
        var targetLines = sourceSide == .left ? right.lines : left.lines
        let sourceRange = sourceSide == .left ? hunk.leftRange : hunk.rightRange
        let targetRange = sourceSide == .left ? hunk.rightRange : hunk.leftRange

        guard sourceRange.start >= 0, sourceRange.end <= source.lines.count else {
            throw TextHunkTransferError.sourceRangeOutOfBounds
        }
        guard targetRange.start >= 0, targetRange.end <= targetLines.count else {
            throw TextHunkTransferError.targetRangeOutOfBounds
        }

        targetLines.replaceSubrange(
            targetRange.start..<targetRange.end,
            with: source.lines[sourceRange.start..<sourceRange.end]
        )
        let targetText: String = targetLines.map(\.sourceText).joined()
        if sourceSide == .left {
            return TextHunkTransferResult(left: left, right: TextDocument(text: targetText))
        }
        return TextHunkTransferResult(left: TextDocument(text: targetText), right: right)
    }
}
