import AppKit
import QuartzCore
import SwiftUI

struct TextEditorLineNavigationRequest: Equatable {
    let id: Int
    let lineNumber: Int
}

/// A plain-text AppKit editor used only by Text Compare.
///
/// SwiftUI's `TextEditor` has no public logical-line reveal API on macOS. This
/// wrapper keeps the normal NSTextView editing and undo behavior while adding
/// bounded line indexing for bookmark and difference navigation.
struct TextCompareNavigableEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var selectedLineNumber: Int?
    let navigationRequest: TextEditorLineNavigationRequest?
    let syntaxLanguage: TextSyntaxLanguage?
    let editorAccessibilityLabel: String
    @Environment(\.riffaTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let maximumIndexedLineCount = 500_000

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = theme.nsCanvas

        let textView = NSTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.string = text
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindPanel = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        textView.textColor = theme.nsInk
        textView.backgroundColor = theme.nsCanvas
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.setAccessibilityLabel(editorAccessibilityLabel)

        scrollView.documentView = textView
        applyTheme(to: scrollView, textView: textView)
        context.coordinator.install(textView: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        applyTheme(to: scrollView, textView: textView)

        if !textView.string.utf8.elementsEqual(text.utf8) {
            let selection = textView.selectedRange()
            context.coordinator.isInstallingModelText = true
            textView.string = text
            context.coordinator.isInstallingModelText = false
            let safeLocation = min(selection.location, textView.string.utf16.count)
            let safeLength = min(selection.length, textView.string.utf16.count - safeLocation)
            textView.setSelectedRange(NSRange(location: safeLocation, length: safeLength))
            context.coordinator.rebuildLineIndex(for: textView.string)
        }
        context.coordinator.applySyntaxHighlightingIfNeeded(to: textView)
        textView.setAccessibilityLabel(editorAccessibilityLabel)

        if let request = navigationRequest,
           context.coordinator.lastNavigationRequestID != request.id {
            context.coordinator.lastNavigationRequestID = request.id
            context.coordinator.reveal(lineNumber: request.lineNumber, in: textView)
        }
    }

    private func applyTheme(
        to scrollView: NSScrollView,
        textView: NSTextView
    ) {
        let appearanceName: NSAppearance.Name = theme.colorScheme == .dark
            ? .darkAqua
            : .aqua
        scrollView.appearance = NSAppearance(named: appearanceName)
        scrollView.backgroundColor = theme.nsCanvas
        textView.appearance = NSAppearance(named: appearanceName)
        textView.textColor = theme.nsInk
        textView.backgroundColor = theme.nsCanvas
        textView.insertionPointColor = NSColor(theme.accent)
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(theme.accent.opacity(0.32)),
            .foregroundColor: theme.nsInk,
        ]
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TextCompareNavigableEditor
        var lastNavigationRequestID: Int?
        var isInstallingModelText = false

        private weak var textView: NSTextView?
        private var lineStartUTF16Offsets: [Int] = []
        private var lineIndexIsComplete = true
        private var highlightingTask: Task<Void, Never>?
        private var lastHighlightedText: String?
        private var lastHighlightedLanguage: TextSyntaxLanguage?
        private var lastHighlightedPalette: RiffaThemePalette?
        private var lastHighlightedContrast = false
        private var isHighlightScheduled = false

        init(parent: TextCompareNavigableEditor) {
            self.parent = parent
        }

        func install(textView: NSTextView) {
            self.textView = textView
            rebuildLineIndex(for: textView.string)
            applySyntaxHighlightingIfNeeded(to: textView)
        }

        func textDidChange(_ notification: Notification) {
            guard !isInstallingModelText else { return }
            guard let textView = notification.object as? NSTextView else { return }
            rebuildLineIndex(for: textView.string)
            parent.text = textView.string
            publishSelection(from: textView)
            scheduleSyntaxHighlighting(for: textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            publishSelection(from: textView)
        }

        func rebuildLineIndex(for string: String) {
            lineStartUTF16Offsets.removeAll(keepingCapacity: true)
            let value = string as NSString
            guard value.length > 0 else {
                lineIndexIsComplete = true
                return
            }

            lineStartUTF16Offsets.reserveCapacity(
                min(parent.maximumIndexedLineCount, max(1, value.length / 40))
            )
            var location = 0
            while location < value.length,
                  lineStartUTF16Offsets.count < parent.maximumIndexedLineCount {
                lineStartUTF16Offsets.append(location)
                var lineEnd = 0
                value.getLineStart(
                    nil,
                    end: &lineEnd,
                    contentsEnd: nil,
                    for: NSRange(location: location, length: 0)
                )
                guard lineEnd > location else { break }
                location = lineEnd
            }
            lineIndexIsComplete = location >= value.length
        }

        func reveal(lineNumber: Int, in textView: NSTextView) {
            guard lineNumber > 0,
                  lineStartUTF16Offsets.indices.contains(lineNumber - 1)
            else { return }
            let location = lineStartUTF16Offsets[lineNumber - 1]
            let range = NSRange(location: location, length: 0)
            smoothlyCenter(range: range, in: textView)
            textView.showFindIndicator(for: range)
        }

        func applySyntaxHighlightingIfNeeded(to textView: NSTextView) {
            let theme = parent.theme
            let textChanged = lastHighlightedText != textView.string
            let styleChanged = lastHighlightedLanguage != parent.syntaxLanguage
                || lastHighlightedPalette != theme.palette
                || lastHighlightedContrast != theme.usesIncreasedContrast
            guard textChanged || styleChanged else { return }
            guard !isHighlightScheduled || styleChanged else { return }
            applySyntaxHighlighting(to: textView)
        }

        private func scheduleSyntaxHighlighting(for textView: NSTextView) {
            highlightingTask?.cancel()
            isHighlightScheduled = true
            highlightingTask = Task { @MainActor [weak self, weak textView] in
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled, let self, let textView else { return }
                self.isHighlightScheduled = false
                self.applySyntaxHighlightingIfNeeded(to: textView)
            }
        }

        private func applySyntaxHighlighting(to textView: NSTextView) {
            let value = textView.string
            let theme = parent.theme
            let tokens = TextSyntaxHighlighter.tokens(
                in: value,
                language: parent.syntaxLanguage
            )
            let fullRange = NSRange(location: 0, length: (value as NSString).length)
            let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
            guard let textStorage = textView.textStorage else { return }

            isInstallingModelText = true
            textStorage.beginEditing()
            textStorage.setAttributes(
                [
                    .font: font,
                    .foregroundColor: theme.nsInk,
                ],
                range: fullRange
            )
            for token in tokens where NSMaxRange(token.range) <= fullRange.length {
                textStorage.addAttribute(
                    .foregroundColor,
                    value: theme.nsSyntaxColor(for: token.kind),
                    range: token.range
                )
            }
            textStorage.endEditing()
            textView.typingAttributes = [
                .font: font,
                .foregroundColor: theme.nsInk,
            ]
            isInstallingModelText = false

            lastHighlightedText = value
            lastHighlightedLanguage = parent.syntaxLanguage
            lastHighlightedPalette = theme.palette
            lastHighlightedContrast = theme.usesIncreasedContrast
            isHighlightScheduled = false
        }

        private func smoothlyCenter(range: NSRange, in textView: NSTextView) {
            guard let scrollView = textView.enclosingScrollView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer
            else {
                textView.scrollRangeToVisible(range)
                return
            }

            layoutManager.ensureLayout(for: textContainer)
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: range,
                actualCharacterRange: nil
            )
            var targetRect = layoutManager.boundingRect(
                forGlyphRange: glyphRange,
                in: textContainer
            )
            targetRect.origin.x += textView.textContainerInset.width
            targetRect.origin.y += textView.textContainerInset.height

            let clipView = scrollView.contentView
            let visibleHeight = clipView.bounds.height
            let maximumY = max(0, textView.bounds.height - visibleHeight)
            let targetY = min(
                maximumY,
                max(0, targetRect.midY - (visibleHeight / 2))
            )
            let targetOrigin = NSPoint(x: clipView.bounds.origin.x, y: targetY)

            if parent.reduceMotion {
                clipView.scroll(to: targetOrigin)
                scrollView.reflectScrolledClipView(clipView)
                return
            }

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.24
                context.timingFunction = CAMediaTimingFunction(
                    name: .easeInEaseOut
                )
                clipView.animator().setBoundsOrigin(targetOrigin)
            }
        }

        private func publishSelection(from textView: NSTextView) {
            let location = min(textView.selectedRange().location, textView.string.utf16.count)
            let lineNumber = logicalLineNumber(atUTF16Location: location)
            if parent.selectedLineNumber != lineNumber {
                parent.selectedLineNumber = lineNumber
            }
        }

        private func logicalLineNumber(atUTF16Location location: Int) -> Int? {
            guard !lineStartUTF16Offsets.isEmpty else { return nil }
            if !lineIndexIsComplete,
               let last = lineStartUTF16Offsets.last,
               location > last {
                return nil
            }

            var lower = 0
            var upper = lineStartUTF16Offsets.count
            while lower < upper {
                let middle = lower + ((upper - lower) / 2)
                if lineStartUTF16Offsets[middle] <= location {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            return max(1, lower)
        }
    }
}
