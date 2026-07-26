import AppKit
import Foundation
import RiffaCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class TextCompareModel: ObservableObject {
    enum Side: String, CaseIterable, Equatable, Hashable, Identifiable, Sendable {
        case left = "Left"
        case right = "Right"

        var id: Self { self }

        var comparisonSide: TextComparisonSide {
            self == .left ? .left : .right
        }
    }

    struct NavigationRequest: Equatable {
        let id: Int
        let alignedOffset: Int
        let side: TextComparisonSide
        let lineNumber: Int
    }

    enum SearchSide: String, CaseIterable, Identifiable {
        case both = "Both"
        case left = "Left"
        case right = "Right"

        var id: Self { self }

        var optionValue: String { rawValue.lowercased() }

        init?(optionValue: String) {
            switch optionValue.lowercased() {
            case "both": self = .both
            case "left": self = .left
            case "right": self = .right
            default: return nil
            }
        }
    }

    @Published private(set) var leftURL: URL?
    @Published private(set) var rightURL: URL?
    @Published private(set) var leftDocument: TextDocument?
    @Published private(set) var rightDocument: TextDocument?
    @Published private(set) var result: TextDiffResult?
    @Published var errorMessage: String?
    @Published var currentHunkIndex: Int?
    @Published var isEditing = false
    @Published var leftDraft = ""
    @Published var rightDraft = ""
    @Published var searchQuery = "" { didSet { refreshSearchSelection() } }
    @Published var replacementText = "" { didSet { refreshSearchSelection() } }
    @Published var searchSide: SearchSide = .both { didSet { refreshSearchSelection() } }
    @Published var searchCaseSensitive = false { didSet { refreshSearchSelection() } }
    @Published var searchMode: TextSearchMode = .literal { didSet { refreshSearchSelection() } }
    @Published private(set) var searchErrorMessage: String?
    @Published private(set) var searchOffsets: [Int] = []
    @Published private(set) var selectedSearchOffset: Int?
    @Published private(set) var currentSearchMatchIndex: Int?
    @Published private(set) var externalChanges: [Side: TextExternalFileChangeKind] = [:]
    @Published private(set) var bookmarks: [TextLineBookmark] = []
    @Published private(set) var currentBookmarkID: UUID?
    @Published var bookmarkNotice: String?
    @Published private(set) var diffOverview = TextDiffOverview(
        alignedLineCount: 0,
        hunkCount: 0,
        markers: []
    )
    @Published private(set) var navigationRequest: NavigationRequest?
    @Published var leftSelectedLineNumber: Int?
    @Published var rightSelectedLineNumber: Int?

    private var leftBackingURL: URL?
    private var rightBackingURL: URL?
    private var leftDecodedDocument: DecodedTextDocument?
    private var rightDecodedDocument: DecodedTextDocument?
    private var leftLoadTask: Task<Void, Never>?
    private var rightLoadTask: Task<Void, Never>?
    private var leftLoadGeneration = 0
    private var rightLoadGeneration = 0
    private let documentStore = DecodedTextDocumentStore()
    private var searchOffsetSet: Set<Int> = []
    private var bookmarkCollection = TextBookmarkCollection()
    private var pendingBookmarkPersistenceValues: [String]?
    private var navigationIndex: TextDiffNavigationIndex?
    private var navigationRequestID = 0
    private var externalChangeStates: [Side: TextExternalChangeCoordinationState] = [
        .left: .init(),
        .right: .init()
    ]
    private var fileChangeMonitors: [Side: LocalFileChangeMonitor] = [:]

    @Published var ignoreCase = false {
        didSet { compareIfReady() }
    }
    @Published var ignoreWhitespace = false {
        didSet { compareIfReady() }
    }

    var selectedOffset: Int? {
        guard let currentHunkIndex,
              let hunks = result?.hunks,
              hunks.indices.contains(currentHunkIndex)
        else { return nil }
        return hunks[currentHunkIndex].alignedRange.start
    }

    var scrollTargetOffset: Int? { selectedSearchOffset ?? selectedOffset }

    var bookmarkPersistenceValues: [String] {
        bookmarkCollection.persistenceValues()
    }

    var hasBookmarks: Bool { !bookmarks.isEmpty }

    var canExportPatch: Bool {
        result?.alignedLines.contains { line in
            line.kind != .unchanged || line.hasLineEndingDifference
        } == true
    }

    var canApplyPatch: Bool {
        leftDocument != nil
    }

    var sidesWithExternalChanges: [Side] {
        Side.allCases.filter { externalChanges[$0] != nil }
    }

    func externalChange(for side: Side) -> TextExternalFileChangeKind? {
        externalChanges[side]
    }

    func hasUnsavedDraft(for side: Side) -> Bool {
        guard let document = decodedDocument(for: side) else { return false }
        switch side {
        case .left: return leftDraft != document.text
        case .right: return rightDraft != document.text
        }
    }

    func chooseFile(for side: Side) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = side == .left
            ? RiffaLocalization.string("Choose Left Text File")
            : RiffaLocalization.string("Choose Right Text File")
        panel.prompt = RiffaLocalization.string("Choose")

        guard panel.runModal() == .OK, let url = panel.url else { return }
        replaceInput(with: url, for: side)
    }

    func replaceInput(with url: URL, for side: Side) {
        if hasUnsavedDraft(for: side),
           !confirmDiscardDraftAndReload(side: side, fileURL: url) {
            return
        }
        load(url: url, for: side)
    }

    func reloadAfterExternalChange(for side: Side) {
        guard let url = backingURL(for: side) else {
            keepCurrentAfterExternalChange(for: side)
            return
        }

        let state = externalChangeStates[side, default: .init()]
        if state.reloadSafety(hasUnsavedEdits: hasUnsavedDraft(for: side))
            == .requiresDiscardConfirmation,
           !confirmDiscardDraftAndReload(side: side, fileURL: url) {
            return
        }
        load(
            url: url,
            for: side,
            externalReloadDraftSnapshot: draft(for: side)
        )
    }

    func keepCurrentAfterExternalChange(for side: Side) {
        var state = externalChangeStates[side, default: .init()]
        state.keepCurrent()
        externalChangeStates[side] = state
        publishExternalChange(for: side)
    }

    func openInitial(_ urls: [URL], options: [String: String] = [:]) {
        bookmarkCollection.removeAll()
        publishBookmarks()
        pendingBookmarkPersistenceValues = options.riffaStrings(for: "bookmarks") ?? []
        if let value = options.riffaBoolean(for: "ignoreCase") {
            ignoreCase = value
        }
        if let value = options.riffaBoolean(for: "ignoreWhitespace") {
            ignoreWhitespace = value
        }
        if let value = options.riffaBoolean(for: "searchCaseSensitive") {
            searchCaseSensitive = value
        }
        if let value = options["searchMode"].flatMap(TextSearchMode.init(rawValue:)) {
            searchMode = value
        }
        if let value = options["searchSide"].flatMap(SearchSide.init(optionValue:)) {
            searchSide = value
        }
        if let left = urls.first { load(url: left, for: .left) }
        if urls.count > 1 { load(url: urls[1], for: .right) }
    }

    func loadClipboard(for side: Side) {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            errorMessage = RiffaLocalization.string(
                "The clipboard does not contain text."
            )
            return
        }
        invalidateLoad(for: side)
        stopMonitoring(side)
        establishExternalBaseline(for: side)
        let decodedDocument = Self.defaultDecodedDocument(text: text)
        let document = TextDocument(text: decodedDocument.text)
        pendingBookmarkPersistenceValues = nil
        bookmarkCollection.removeAll(on: side.comparisonSide)
        publishBookmarks()
        switch side {
        case .left:
            leftURL = URL(fileURLWithPath: "/Clipboard/Left Clipboard.txt")
            leftBackingURL = nil
            leftDecodedDocument = decodedDocument
            leftDocument = document
            leftDraft = text
        case .right:
            rightURL = URL(fileURLWithPath: "/Clipboard/Right Clipboard.txt")
            rightBackingURL = nil
            rightDecodedDocument = decodedDocument
            rightDocument = document
            rightDraft = text
        }
        errorMessage = nil
        compareIfReady()
    }

    func loadDemo() {
        invalidateAllLoads()
        stopAllFileChangeMonitoring()
        for side in Side.allCases {
            establishExternalBaseline(for: side)
        }
        pendingBookmarkPersistenceValues = nil
        bookmarkCollection.removeAll()
        publishBookmarks()
        leftURL = URL(fileURLWithPath: "/Demo/plan-v1.json")
        rightURL = URL(fileURLWithPath: "/Demo/plan-v2.json")
        leftDecodedDocument = Self.defaultDecodedDocument(
            text: """
            {
              "name": "Riffa",
              "platform": "macOS",
              "features": ["text", "folder"]
            }
            """
        )
        rightDecodedDocument = Self.defaultDecodedDocument(
            text: """
            {
              "name": "Riffa",
              "platform": "macOS arm64",
              "features": ["text", "folder", "image"]
            }
            """
        )
        leftDocument = leftDecodedDocument.map { TextDocument(text: $0.text) }
        rightDocument = rightDecodedDocument.map { TextDocument(text: $0.text) }
        leftDraft = leftDocument?.text ?? ""
        rightDraft = rightDocument?.text ?? ""
        leftBackingURL = nil
        rightBackingURL = nil
        errorMessage = nil
        compareIfReady()
    }

    func swapSides() {
        invalidateAllLoads()
        stopAllFileChangeMonitoring()
        (leftURL, rightURL) = (rightURL, leftURL)
        (leftDocument, rightDocument) = (rightDocument, leftDocument)
        (leftDecodedDocument, rightDecodedDocument) = (rightDecodedDocument, leftDecodedDocument)
        (leftDraft, rightDraft) = (rightDraft, leftDraft)
        (leftBackingURL, rightBackingURL) = (rightBackingURL, leftBackingURL)
        let leftState = externalChangeStates[.left, default: .init()]
        externalChangeStates[.left] = externalChangeStates[.right, default: .init()]
        externalChangeStates[.right] = leftState
        bookmarkCollection.swapSides()
        publishBookmarks()
        publishExternalChange(for: .left)
        publishExternalChange(for: .right)
        startMonitoring(.left)
        startMonitoring(.right)
        compareIfReady()
    }

    func exportPatch() {
        guard let result, canExportPatch else {
            errorMessage = RiffaLocalization.string(
                "There are no differences to export as a patch."
            )
            return
        }

        do {
            let patchText = try UnifiedDiffGenerator(contextLineCount: 3).generate(
                from: result,
                oldLabel: patchLabel(for: leftURL, fallback: "left.txt", prefix: "a"),
                newLabel: patchLabel(for: rightURL, fallback: "right.txt", prefix: "b")
            )

            let panel = NSSavePanel()
            panel.title = RiffaLocalization.string("Export Unified Diff")
            panel.prompt = RiffaLocalization.string("Export")
            panel.nameFieldStringValue = suggestedPatchName
            if let patchType = UTType(filenameExtension: "patch") {
                panel.allowedContentTypes = [patchType]
            }

            guard panel.runModal() == .OK, let url = panel.url else { return }
            try patchText.write(to: url, atomically: true, encoding: .utf8)
            errorMessage = nil
        } catch {
            errorMessage = String(
                localized: "Could not export patch: \(error.localizedDescription)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
    }

    func applyPatch() {
        guard activeLeftDocument != nil else {
            errorMessage = RiffaLocalization.string(
                "Choose or create a left document before applying a patch."
            )
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = RiffaLocalization.string("Apply Unified Diff")
        panel.prompt = RiffaLocalization.string("Apply")
        panel.allowedContentTypes = ["patch", "diff"].compactMap {
            UTType(filenameExtension: $0)
        }

        guard panel.runModal() == .OK, let patchURL = panel.url else { return }
        Task { [weak self] in
            await self?.applyPatch(at: patchURL)
        }
    }

    func saveReport(format: ComparisonReportFormat) {
        guard let result else { return }
        let fileExtension: String
        switch format {
        case .plainText: fileExtension = "txt"
        case .html: fileExtension = "html"
        case .json: fileExtension = "json"
        }

        let panel = NSSavePanel()
        panel.title = RiffaLocalization.string(
            "Export Text Comparison Report"
        )
        panel.prompt = RiffaLocalization.string("Export")
        panel.nameFieldStringValue = "Riffa-Text-Report.\(fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let report = try ComparisonReportGenerator().generate(
                text: result,
                format: format,
                leftLabel: leftURL?.lastPathComponent
                    ?? RiffaLocalization.string("Left"),
                rightLabel: rightURL?.lastPathComponent
                    ?? RiffaLocalization.string("Right")
            )
            try report.write(to: url, atomically: true, encoding: .utf8)
            errorMessage = nil
        } catch {
            errorMessage = String(
                localized: "Could not export report: \(error.localizedDescription)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
    }

    func refreshDraftComparison(changedSide: Side) {
        guard isEditing else { return }
        rebindBookmarks(for: changedSide, to: TextDocument(text: draft(for: changedSide)))
        compareIfReady()
    }

    func compareIfReadyForView() {
        compareIfReady()
    }

    func saveDraft(for side: Side) {
        guard isEditing else { return }
        let sourceURL = side == .left ? leftURL : rightURL
        let panel = NSSavePanel()
        panel.title = side == .left
            ? RiffaLocalization.string("Save Left Text As")
            : RiffaLocalization.string("Save Right Text As")
        panel.prompt = RiffaLocalization.string("Save")
        let preferredFormat = decodedDocument(for: side)?.format ?? .utf8
        panel.message = String(
            localized: "The edited text will use \(Self.formatDescription(preferredFormat)). Overwriting the original is blocked if it changed outside Riffa.",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
        if let sourceURL {
            let stem = sourceURL.deletingPathExtension().lastPathComponent
            let ext = sourceURL.pathExtension
            panel.nameFieldStringValue = if ext.isEmpty {
                String(
                    localized: "\(stem)-edited.txt",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
            } else {
                String(
                    localized: "\(stem)-edited.\(ext)",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
            }
        } else {
            panel.nameFieldStringValue = side == .left
                ? RiffaLocalization.string("Left-edited.txt")
                : RiffaLocalization.string("Right-edited.txt")
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = side == .left ? leftDraft : rightDraft
        let sourceDocument = decodedDocument(for: side) ?? Self.defaultDecodedDocument(text: text)
        let document = sourceDocument.replacingText(with: text)
        let backingURL = backingURL(for: side)

        Task { [weak self] in
            guard let self else { return }
            do {
                if let backingURL,
                   Self.sameFileLocation(url, backingURL) {
                    let fingerprint = try await documentStore.save(
                        document,
                        to: backingURL,
                        ifContentsMatch: sourceDocument.fingerprint
                    )
                    guard decodedDocument(for: side) == sourceDocument else { return }
                    installSavedDocument(
                        DecodedTextDocument(
                            text: text,
                            format: sourceDocument.format,
                            fingerprint: fingerprint
                        ),
                        for: side,
                        updateDraft: false
                    )
                } else {
                    _ = try await documentStore.save(document, to: url)
                }
                errorMessage = nil
            } catch {
                errorMessage = saveFailureMessage(error, fileURL: url)
            }
        }
    }

    func nextDifference() {
        guard let hunks = result?.hunks, !hunks.isEmpty else { return }
        selectedSearchOffset = nil
        currentHunkIndex = ((currentHunkIndex ?? -1) + 1) % hunks.count
        navigateToCurrentHunk()
    }

    func previousDifference() {
        guard let hunks = result?.hunks, !hunks.isEmpty else { return }
        selectedSearchOffset = nil
        currentHunkIndex = ((currentHunkIndex ?? 0) - 1 + hunks.count) % hunks.count
        navigateToCurrentHunk()
    }

    func selectDifference(at index: Int) {
        guard let hunks = result?.hunks, hunks.indices.contains(index) else { return }
        selectedSearchOffset = nil
        currentHunkIndex = index
        navigateToCurrentHunk()
    }

    func isBookmarked(side: Side, lineNumber: Int) -> Bool {
        bookmarkCollection.bookmark(
            side: side.comparisonSide,
            lineNumber: lineNumber
        ) != nil
    }

    func toggleBookmark(side: Side, lineNumber: Int) {
        guard let document = activeDocument(for: side) else { return }
        switch bookmarkCollection.toggle(
            side: side.comparisonSide,
            lineNumber: lineNumber,
            in: document
        ) {
        case let .added(bookmark):
            publishBookmarks()
            navigate(to: bookmark)
        case let .removed(bookmark):
            if currentBookmarkID == bookmark.id { currentBookmarkID = nil }
            publishBookmarks()
        case .invalidLine:
            bookmarkNotice = RiffaLocalization.string(
                "That logical line is no longer available."
            )
        case let .limitReached(limit):
            bookmarkNotice = String(
                localized: "This comparison supports at most \(limit) bookmarks.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
    }

    func toggleBookmarkAtCaret(side: Side) {
        let lineNumber = side == .left ? leftSelectedLineNumber : rightSelectedLineNumber
        guard let lineNumber else {
            let sideTitle = RiffaLocalization.string(side.rawValue).lowercased()
            bookmarkNotice = String(
                localized: "Place the insertion point on a \(sideTitle) logical line first.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
            return
        }
        toggleBookmark(side: side, lineNumber: lineNumber)
    }

    func nextBookmark() {
        moveBookmark(by: 1)
    }

    func previousBookmark() {
        moveBookmark(by: -1)
    }

    func selectBookmark(id: UUID) {
        guard let bookmark = bookmarks.first(where: { $0.id == id }) else { return }
        navigate(to: bookmark)
    }

    func removeBookmark(id: UUID) {
        guard bookmarkCollection.remove(id: id) != nil else { return }
        if currentBookmarkID == id { currentBookmarkID = nil }
        publishBookmarks()
    }

    func removeCurrentBookmark() {
        guard let currentBookmarkID else { return }
        removeBookmark(id: currentBookmarkID)
    }

    func nextSearchMatch() {
        moveSearchMatch(by: 1)
    }

    func previousSearchMatch() {
        moveSearchMatch(by: -1)
    }

    func isSearchMatch(_ line: AlignedDiffLine) -> Bool {
        searchOffsetSet.contains(line.offset)
    }

    func replaceAllSearchMatches() {
        guard isEditing, !searchQuery.isEmpty, searchErrorMessage == nil else { return }
        do {
            let prepared = try searchEngine.prepare(pattern: searchQuery)
            var nextLeftDraft = leftDraft
            var nextRightDraft = rightDraft
            switch searchSide {
            case .both:
                nextLeftDraft = try prepared.replaceAll(
                    in: leftDraft,
                    with: replacementText
                ).text
                nextRightDraft = try prepared.replaceAll(
                    in: rightDraft,
                    with: replacementText
                ).text
            case .left:
                nextLeftDraft = try prepared.replaceAll(
                    in: leftDraft,
                    with: replacementText
                ).text
            case .right:
                nextRightDraft = try prepared.replaceAll(
                    in: rightDraft,
                    with: replacementText
                ).text
            }
            leftDraft = nextLeftDraft
            rightDraft = nextRightDraft
            searchErrorMessage = nil
            compareIfReady()
        } catch let error as TextSearchError {
            searchErrorMessage = Self.textSearchErrorMessage(error)
        } catch {
            searchErrorMessage = error.localizedDescription
        }
    }

    var canReplaceAllSearchMatches: Bool {
        isEditing && !searchQuery.isEmpty && searchErrorMessage == nil
    }

    func copyCurrentDifference(from source: Side) {
        guard let result, let currentHunkIndex,
              result.hunks.indices.contains(currentHunkIndex),
              let leftDocument, let rightDocument
        else { return }
        let hunk = result.hunks[currentHunkIndex]
        let left = isEditing ? TextDocument(text: leftDraft) : leftDocument
        let right = isEditing ? TextDocument(text: rightDraft) : rightDocument
        do {
            let transferred = try TextHunkTransfer().copy(
                hunk,
                from: source == .left ? .left : .right,
                left: left,
                right: right
            )
            leftDraft = transferred.left.text
            rightDraft = transferred.right.text
            isEditing = true
            compareIfReady()
        } catch {
            errorMessage = String(
                localized: "Could not copy the selected difference: \(error.localizedDescription)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
    }

    private func load(
        url: URL,
        for side: Side,
        externalReloadDraftSnapshot: String? = nil
    ) {
        invalidateLoad(for: side)
        errorMessage = nil
        let generation = loadGeneration(for: side)
        let store = documentStore
        let task = Task { [weak self] in
            do {
                let decodedDocument = try await store.load(from: url)
                try Task.checkCancellation()
                guard let self, loadGeneration(for: side) == generation else { return }
                if let externalReloadDraftSnapshot,
                   draft(for: side) != externalReloadDraftSnapshot {
                    let sideTitle = RiffaLocalization.string(side.rawValue).lowercased()
                    errorMessage = String(
                        localized: "The \(sideTitle) draft changed while the file was reloading. Riffa kept the newer draft; choose Reload again when ready.",
                        bundle: RiffaLocalization.localizedBundle,
                        locale: RiffaLocalization.locale
                    )
                    clearLoadTask(for: side, generation: generation)
                    return
                }
                installLoadedDocument(
                    decodedDocument,
                    from: url,
                    for: side,
                    preserveBookmarks: externalReloadDraftSnapshot != nil
                )
                compareIfReady()
                clearLoadTask(for: side, generation: generation)
            } catch is CancellationError {
                return
            } catch {
                guard let self, loadGeneration(for: side) == generation else { return }
                errorMessage = String(
                    localized: "Could not read \(url.lastPathComponent): \(error.localizedDescription)",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
                clearLoadTask(for: side, generation: generation)
            }
        }
        setLoadTask(task, for: side)
    }

    private func compareIfReady() {
        guard leftDocument != nil, rightDocument != nil else {
            result = nil
            currentHunkIndex = nil
            navigationIndex = nil
            diffOverview = TextDiffOverview(
                alignedLineCount: 0,
                hunkCount: 0,
                markers: []
            )
            return
        }

        let options = TextDiffOptions(
            ignoreCase: ignoreCase,
            ignoreWhitespace: ignoreWhitespace,
            contextLineCount: 3
        )
        let left = isEditing ? TextDocument(text: leftDraft) : leftDocument!
        let right = isEditing ? TextDocument(text: rightDraft) : rightDocument!
        let nextResult = TextDiffEngine(options: options).compare(left, to: right)
        result = nextResult
        navigationIndex = TextDiffNavigationIndex(result: nextResult)
        diffOverview = TextDiffOverviewBuilder().build(from: nextResult)
        currentHunkIndex = nextResult.hunks.isEmpty ? nil : 0
        restorePendingBookmarksIfReady(left: left, right: right)
        refreshSearchSelection()
    }

    private var searchEngine: TextSearchEngine {
        TextSearchEngine(
            options: TextSearchOptions(
                mode: searchMode,
                caseSensitive: searchCaseSensitive
            )
        )
    }

    private func refreshSearchSelection() {
        guard !searchQuery.isEmpty else {
            searchErrorMessage = nil
            installSearchOffsets([])
            return
        }

        let offsets: [Int]
        do {
            let prepared = try searchEngine.prepare(pattern: searchQuery)
            guard let result else {
                searchErrorMessage = nil
                installSearchOffsets([])
                return
            }

            var matches: [Int] = []
            matches.reserveCapacity(min(result.alignedLines.count, 256))
            for line in result.alignedLines {
                let isMatch: Bool
                switch searchSide {
                case .both:
                    isMatch = try contains(prepared, text: line.left?.line.content)
                        || contains(prepared, text: line.right?.line.content)
                case .left:
                    isMatch = try contains(prepared, text: line.left?.line.content)
                case .right:
                    isMatch = try contains(prepared, text: line.right?.line.content)
                }
                if isMatch {
                    guard matches.count < prepared.limits.maximumMatchCount else {
                        throw TextSearchError.matchLimitExceeded(
                            limit: prepared.limits.maximumMatchCount
                        )
                    }
                    matches.append(line.offset)
                }
            }
            searchErrorMessage = nil
            offsets = matches
        } catch let error as TextSearchError {
            searchErrorMessage = Self.textSearchErrorMessage(error)
            offsets = []
        } catch {
            searchErrorMessage = error.localizedDescription
            offsets = []
        }

        installSearchOffsets(offsets)
    }

    private func contains(_ search: PreparedTextSearch, text: String?) throws -> Bool {
        guard let text else { return false }
        return try search.contains(in: text)
    }

    private func installSearchOffsets(_ offsets: [Int]) {
        searchOffsets = offsets
        searchOffsetSet = Set(offsets)
        guard !offsets.isEmpty else {
            currentSearchMatchIndex = nil
            selectedSearchOffset = nil
            return
        }
        let index = min(currentSearchMatchIndex ?? 0, offsets.count - 1)
        currentSearchMatchIndex = index
        selectedSearchOffset = offsets[index]
        publishNavigation(alignedOffset: offsets[index])
    }

    private func moveSearchMatch(by delta: Int) {
        let offsets = searchOffsets
        guard !offsets.isEmpty else {
            refreshSearchSelection()
            return
        }
        let current = currentSearchMatchIndex ?? (delta > 0 ? -1 : 0)
        let index = (current + delta + offsets.count) % offsets.count
        currentSearchMatchIndex = index
        selectedSearchOffset = offsets[index]
        publishNavigation(alignedOffset: offsets[index])
    }

    private func moveBookmark(by delta: Int) {
        guard delta != 0, let navigationIndex else { return }
        let navigable = bookmarks.compactMap { bookmark -> (TextLineBookmark, Int)? in
            guard let offset = navigationIndex.alignedOffset(
                side: bookmark.side,
                lineNumber: bookmark.lineNumber
            ) else { return nil }
            return (bookmark, offset)
        }.sorted { left, right in
            if left.1 != right.1 { return left.1 < right.1 }
            if left.0.side != right.0.side { return left.0.side == .left }
            return left.0.lineNumber < right.0.lineNumber
        }
        guard !navigable.isEmpty else { return }

        let current = currentBookmarkID.flatMap { id in
            navigable.firstIndex { $0.0.id == id }
        } ?? (delta > 0 ? -1 : 0)
        let next = (current + delta + navigable.count) % navigable.count
        navigate(to: navigable[next].0)
    }

    private func navigate(to bookmark: TextLineBookmark) {
        guard let offset = navigationIndex?.alignedOffset(
            side: bookmark.side,
            lineNumber: bookmark.lineNumber
        ) else {
            bookmarkNotice = RiffaLocalization.string(
                "That bookmark is outside the current bounded navigation index."
            )
            return
        }
        currentBookmarkID = bookmark.id
        selectedSearchOffset = nil
        publishNavigation(
            alignedOffset: offset,
            preferredSide: bookmark.side,
            preferredLineNumber: bookmark.lineNumber
        )
    }

    private func navigateToCurrentHunk() {
        guard let result,
              let currentHunkIndex,
              result.hunks.indices.contains(currentHunkIndex)
        else { return }
        publishNavigation(alignedOffset: result.hunks[currentHunkIndex].alignedRange.start)
    }

    private func publishNavigation(
        alignedOffset: Int,
        preferredSide: TextComparisonSide? = nil,
        preferredLineNumber: Int? = nil
    ) {
        guard let result, result.alignedLines.indices.contains(alignedOffset) else { return }
        let line = result.alignedLines[alignedOffset]
        let target: (TextComparisonSide, Int)?
        if let preferredSide, let preferredLineNumber {
            target = (preferredSide, preferredLineNumber)
        } else if let value = line.left {
            target = (.left, value.lineNumber)
        } else if let value = line.right {
            target = (.right, value.lineNumber)
        } else {
            target = nil
        }
        guard let target else { return }
        navigationRequestID &+= 1
        navigationRequest = NavigationRequest(
            id: navigationRequestID,
            alignedOffset: alignedOffset,
            side: target.0,
            lineNumber: target.1
        )
    }

    private func restorePendingBookmarksIfReady(
        left: TextDocument,
        right: TextDocument
    ) {
        guard let values = pendingBookmarkPersistenceValues else { return }
        pendingBookmarkPersistenceValues = nil
        let restoration = TextBookmarkCollection.restore(
            from: values,
            leftDocument: left,
            rightDocument: right
        )
        bookmarkCollection = restoration.collection
        publishBookmarks()
        if restoration.discardedValueCount > 0 {
            if restoration.discardedValueCount == 1 {
                bookmarkNotice = RiffaLocalization.string(
                    "Removed one saved bookmark that no longer matched these documents."
                )
            } else {
                bookmarkNotice = String(
                    localized: "Removed \(restoration.discardedValueCount) saved bookmarks that no longer matched these documents.",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
            }
        }
    }

    private func rebindBookmarks(for side: Side, to document: TextDocument) {
        let outcome = bookmarkCollection.rebind(side: side.comparisonSide, to: document)
        guard !outcome.discardedIDs.isEmpty else {
            publishBookmarks()
            return
        }
        if let currentBookmarkID, outcome.discardedIDs.contains(currentBookmarkID) {
            self.currentBookmarkID = nil
        }
        publishBookmarks()
        if outcome.discardedIDs.count == 1 {
            bookmarkNotice = RiffaLocalization.string(
                "Removed one bookmark whose anchored line could not be rebound safely."
            )
        } else {
            bookmarkNotice = String(
                localized: "Removed \(outcome.discardedIDs.count) bookmarks whose anchored lines could not be rebound safely.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
    }

    private func publishBookmarks() {
        bookmarks = bookmarkCollection.bookmarks
        if let currentBookmarkID,
           !bookmarks.contains(where: { $0.id == currentBookmarkID }) {
            self.currentBookmarkID = nil
        }
    }

    private func activeDocument(for side: Side) -> TextDocument? {
        if isEditing {
            return TextDocument(text: draft(for: side))
        }
        return side == .left ? leftDocument : rightDocument
    }

    private var activeLeftDocument: TextDocument? {
        if isEditing {
            return TextDocument(text: leftDraft)
        }
        return leftDocument
    }

    private func applyPatch(at patchURL: URL) async {
        do {
            let patchDocument = try await documentStore.load(from: patchURL)
            let patch = try UnifiedPatchParser().parse(patchDocument.text)
            guard patch.files.count == 1, let filePatch = patch.files.first else {
                throw UnifiedPatchError(
                    code: .malformedFileHeader,
                    message: RiffaLocalization.string(
                        "Text Compare can apply exactly one file section at a time."
                    )
                )
            }
            guard let source = activeLeftDocument else {
                errorMessage = RiffaLocalization.string(
                    "The left document changed while the patch was loading. Choose it again."
                )
                return
            }

            // Application stays in local values until every hunk validates.
            let updated = try UnifiedPatchApplier().apply(filePatch, to: source)

            if isEditing || leftBackingURL == nil {
                installInEditingBuffer(updated)
                errorMessage = nil
                return
            }

            guard let backingURL = leftBackingURL,
                  let sourceDocument = leftDecodedDocument else {
                installInEditingBuffer(updated)
                errorMessage = nil
                return
            }
            switch confirmPatchDestination(fileURL: backingURL, format: sourceDocument.format) {
            case .replaceFile:
                let replacement = sourceDocument.replacingText(with: updated.text)
                let fingerprint = try await documentStore.save(
                    replacement,
                    to: backingURL,
                    ifContentsMatch: sourceDocument.fingerprint
                )
                guard leftBackingURL == backingURL,
                      leftDecodedDocument == sourceDocument else { return }
                installSavedDocument(
                    DecodedTextDocument(
                        text: updated.text,
                        format: sourceDocument.format,
                        fingerprint: fingerprint
                    ),
                    for: .left,
                    updateDraft: true
                )
                compareIfReady()
                errorMessage = nil
            case .editingBuffer:
                installInEditingBuffer(updated)
                errorMessage = nil
            case .cancel:
                return
            }
        } catch {
            if let textError = error as? DecodedTextDocumentError,
               textError.code == .externalModification {
                errorMessage = RiffaLocalization.string(
                    "The left file changed outside Riffa, so it was not overwritten. Reload it and apply the patch again."
                )
            } else {
                errorMessage = String(
                    localized: "Could not apply \(patchURL.lastPathComponent): \(error.localizedDescription)",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
            }
        }
    }

    private var suggestedPatchName: String {
        let leftStem = leftURL?.deletingPathExtension().lastPathComponent
            ?? RiffaLocalization.string("left")
        let rightStem = rightURL?.deletingPathExtension().lastPathComponent
            ?? RiffaLocalization.string("right")
        return String(
            localized: "\(leftStem)-to-\(rightStem).patch",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
    }

    private func patchLabel(for url: URL?, fallback: String, prefix: String) -> String {
        let name = url?.lastPathComponent ?? fallback
        return "\(prefix)/\(name)"
    }

    private func installInEditingBuffer(_ document: TextDocument) {
        leftDraft = document.text
        isEditing = true
        compareIfReady()
    }

    private enum PatchDestination {
        case replaceFile
        case editingBuffer
        case cancel
    }

    private func confirmPatchDestination(
        fileURL: URL,
        format: DecodedTextDocumentFormat
    ) -> PatchDestination {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "Replace \(fileURL.lastPathComponent)?",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
        alert.informativeText = String(
            localized: "Riffa validated every patch hunk. Replacing preserves the source's \(Self.formatDescription(format)) representation and line endings. The write is blocked if another process changed the file. You can instead keep the result only in the editing buffer.",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
        alert.addButton(withTitle: RiffaLocalization.string("Replace File"))
        alert.addButton(
            withTitle: RiffaLocalization.string("Use Editing Buffer")
        )
        alert.addButton(withTitle: RiffaLocalization.string("Cancel"))

        switch alert.runModal() {
        case .alertFirstButtonReturn: return .replaceFile
        case .alertSecondButtonReturn: return .editingBuffer
        default: return .cancel
        }
    }

    private func installLoadedDocument(
        _ document: DecodedTextDocument,
        from url: URL,
        for side: Side,
        preserveBookmarks: Bool
    ) {
        switch side {
        case .left:
            leftURL = url
            leftBackingURL = url
            leftDecodedDocument = document
            leftDocument = TextDocument(text: document.text)
            leftDraft = document.text
        case .right:
            rightURL = url
            rightBackingURL = url
            rightDecodedDocument = document
            rightDocument = TextDocument(text: document.text)
            rightDraft = document.text
        }
        if preserveBookmarks {
            rebindBookmarks(for: side, to: TextDocument(text: document.text))
        } else {
            bookmarkCollection.removeAll(on: side.comparisonSide)
            publishBookmarks()
        }
        establishExternalBaseline(for: side)
        startMonitoring(side)
    }

    private func installSavedDocument(
        _ document: DecodedTextDocument,
        for side: Side,
        updateDraft: Bool
    ) {
        switch side {
        case .left:
            leftDecodedDocument = document
            leftDocument = TextDocument(text: document.text)
            if updateDraft { leftDraft = document.text }
        case .right:
            rightDecodedDocument = document
            rightDocument = TextDocument(text: document.text)
            if updateDraft { rightDraft = document.text }
        }
        rebindBookmarks(for: side, to: TextDocument(text: document.text))
        establishExternalBaseline(for: side)
        startMonitoring(side)
        compareIfReady()
    }

    private func decodedDocument(for side: Side) -> DecodedTextDocument? {
        switch side {
        case .left: leftDecodedDocument
        case .right: rightDecodedDocument
        }
    }

    private func draft(for side: Side) -> String {
        switch side {
        case .left: leftDraft
        case .right: rightDraft
        }
    }

    private func backingURL(for side: Side) -> URL? {
        switch side {
        case .left: leftBackingURL
        case .right: rightBackingURL
        }
    }

    private func invalidateLoad(for side: Side) {
        switch side {
        case .left:
            leftLoadTask?.cancel()
            leftLoadTask = nil
            leftLoadGeneration &+= 1
        case .right:
            rightLoadTask?.cancel()
            rightLoadTask = nil
            rightLoadGeneration &+= 1
        }
    }

    private func invalidateAllLoads() {
        invalidateLoad(for: .left)
        invalidateLoad(for: .right)
    }

    private func loadGeneration(for side: Side) -> Int {
        switch side {
        case .left: leftLoadGeneration
        case .right: rightLoadGeneration
        }
    }

    private func setLoadTask(_ task: Task<Void, Never>, for side: Side) {
        switch side {
        case .left: leftLoadTask = task
        case .right: rightLoadTask = task
        }
    }

    private func clearLoadTask(for side: Side, generation: Int) {
        guard loadGeneration(for: side) == generation else { return }
        switch side {
        case .left: leftLoadTask = nil
        case .right: rightLoadTask = nil
        }
    }

    private func startMonitoring(_ side: Side) {
        stopMonitoring(side)
        guard let url = backingURL(for: side),
              let fingerprint = decodedDocument(for: side)?.fingerprint else { return }

        do {
            fileChangeMonitors[side] = try LocalFileChangeMonitor(
                url: url,
                expectedFingerprint: fingerprint
            ) {
                [weak self] change in
                self?.observeExternalChange(change, for: side)
            }
        } catch {
            observeExternalChange(.unavailable, for: side)
        }
    }

    private func stopMonitoring(_ side: Side) {
        fileChangeMonitors.removeValue(forKey: side)?.stop()
    }

    private func stopAllFileChangeMonitoring() {
        for monitor in fileChangeMonitors.values {
            monitor.stop()
        }
        fileChangeMonitors.removeAll()
    }

    private func observeExternalChange(
        _ change: TextExternalFileChangeKind,
        for side: Side
    ) {
        var state = externalChangeStates[side, default: .init()]
        state.observe(change)
        externalChangeStates[side] = state
        publishExternalChange(for: side)
    }

    private func establishExternalBaseline(for side: Side) {
        var state = externalChangeStates[side, default: .init()]
        state.establishBaseline()
        externalChangeStates[side] = state
        publishExternalChange(for: side)
    }

    private func publishExternalChange(for side: Side) {
        externalChanges[side] = externalChangeStates[side]?.pendingChange
    }

    private func confirmDiscardDraftAndReload(side: Side, fileURL: URL) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        let sideTitle = RiffaLocalization.string(side.rawValue).lowercased()
        alert.messageText = String(
            localized: "Discard unsaved \(sideTitle) edits?",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
        alert.informativeText = String(
            localized: "Reloading \(fileURL.lastPathComponent) replaces the in-memory draft with the current file. Use Save As first if you want to keep those edits.",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
        alert.addButton(
            withTitle: RiffaLocalization.string("Reload and Discard")
        )
        alert.addButton(withTitle: RiffaLocalization.string("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func saveFailureMessage(_ error: any Error, fileURL: URL) -> String {
        if let textError = error as? DecodedTextDocumentError,
           textError.code == .externalModification {
            return String(
                localized: "\(fileURL.lastPathComponent) changed outside Riffa, so it was not overwritten. Reload the file before saving again.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
        return String(
            localized: "Could not save \(fileURL.lastPathComponent): \(error.localizedDescription)",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
    }

    private static func textSearchErrorMessage(_ error: TextSearchError) -> String {
        switch error {
        case let .invalidLimit(name, value):
            String(
                localized: "The text-search limit \(name) must be positive; received \(value).",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .patternLimitExceeded(actual, limit):
            String(
                localized: "The search pattern is too long (\(actual) UTF-16 units; limit \(limit)).",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .inputLimitExceeded(actual, limit):
            String(
                localized: "The searched text is too large (\(actual) UTF-16 units; limit \(limit)).",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .matchLimitExceeded(limit):
            String(
                localized: "The search produced more than \(limit) matches. Narrow the pattern and try again.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .replacementLimitExceeded(actual, limit):
            String(
                localized: "The replacement is too long (\(actual) UTF-16 units; limit \(limit)).",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .outputLimitExceeded(limit):
            String(
                localized: "The replacement result would exceed the \(limit) UTF-16 unit safety limit.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .invalidRegularExpression(reason):
            String(
                localized: "Invalid regular expression: \(reason)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .unsafeRegularExpression(reason):
            String(
                localized: "This regular expression was rejected for safety: \(reason)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .zeroWidthMatch(location):
            String(
                localized: "The regular expression produces an empty match at UTF-16 offset \(location).",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .invalidUTF16Range(location, length):
            String(
                localized: "The search engine returned an invalid UTF-16 range at \(location) with length \(length).",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
    }

    private static func defaultDecodedDocument(text: String) -> DecodedTextDocument {
        let data = Data(text.utf8)
        return DecodedTextDocument(
            text: text,
            format: .utf8,
            fingerprint: DecodedTextFileFingerprint(data: data)
        )
    }

    private static func sameFileLocation(_ first: URL, _ second: URL) -> Bool {
        first.standardizedFileURL.resolvingSymlinksInPath()
            == second.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func formatDescription(_ format: DecodedTextDocumentFormat) -> String {
        switch format {
        case .utf8:
            RiffaLocalization.string("UTF-8")
        case .utf8WithByteOrderMark:
            RiffaLocalization.string("UTF-8 with BOM")
        case .utf16LittleEndianWithByteOrderMark:
            RiffaLocalization.string("UTF-16 little-endian with BOM")
        case .utf16BigEndianWithByteOrderMark:
            RiffaLocalization.string("UTF-16 big-endian with BOM")
        }
    }
}

struct TextCompareView: View {
    @StateObject private var model = TextCompareModel()
    @State private var showFind = false
    @FocusState private var searchFieldFocused: Bool
    @Environment(\.riffaTheme) private var theme
    private let initialURLs: [URL]
    private let initialOptions: [String: String]

    init(
        initialURLs: [URL] = [],
        initialOptions: [String: String] = [:]
    ) {
        self.initialURLs = initialURLs
        self.initialOptions = initialOptions
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if showFind {
                findBar
            }
            pathBar
            if !model.sidesWithExternalChanges.isEmpty {
                RiffaHairline()
                externalChangeBanner
            }
            if model.bookmarkNotice != nil {
                RiffaHairline()
                bookmarkNoticeBanner
            }

            if let result = model.result {
                if model.isEditing {
                    editorContent(result)
                } else {
                    diffContent(result)
                }
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Text Compare")
        .background(theme.canvas)
        .riffaWindowDropZones([
            RiffaDropZone(
                role: .left,
                acceptedKind: .regularFileFollowingFinalSymbolicLink
            ) {
                model.replaceInput(with: $0, for: .left)
            },
            RiffaDropZone(
                role: .right,
                acceptedKind: .regularFileFollowingFinalSymbolicLink
            ) {
                model.replaceInput(with: $0, for: .right)
            },
        ])
        .onChange(of: model.leftDraft) { _, _ in
            model.refreshDraftComparison(changedSide: .left)
        }
        .onChange(of: model.rightDraft) { _, _ in
            model.refreshDraftComparison(changedSide: .right)
        }
        .onChange(of: model.isEditing) { _, _ in model.compareIfReadyForView() }
        .onChange(of: showFind) { _, isShown in
            if isShown { searchFieldFocused = true }
        }
        .alert(
            "Text comparison error",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            ),
            actions: { Button("OK", role: .cancel) {} },
            message: {
                Text(
                    verbatim: model.errorMessage
                        ?? RiffaLocalization.string("Unknown error")
                )
            }
        )
        .task(id: ComparisonInitialLoad(urls: initialURLs, options: initialOptions)) {
            model.openInitial(initialURLs, options: initialOptions)
        }
    }

    private var header: some View {
        RiffaComparisonHeader(
            title: "Text Compare",
            subtitle: "Two-way, line aligned"
        ) {
            SessionSaveButton(
                request: SessionSaveRequest(
                    kind: .textComparison,
                    urls: [model.leftURL, model.rightURL].compactMap { $0 },
                    options: [
                        "ignoreCase": .boolean(model.ignoreCase),
                        "ignoreWhitespace": .boolean(model.ignoreWhitespace),
                        "searchMode": .string(model.searchMode.rawValue),
                        "searchCaseSensitive": .boolean(model.searchCaseSensitive),
                        "searchSide": .string(model.searchSide.optionValue),
                        "bookmarks": .strings(model.bookmarkPersistenceValues)
                    ]
                ),
                errorMessage: $model.errorMessage
            )

            Button {
                showFind.toggle()
            } label: {
                Label("Find", systemImage: "magnifyingglass")
            }
            .labelStyle(.iconOnly)
            .keyboardShortcut("f", modifiers: .command)
            .help("Find in both compared files")

            Button {
                model.previousDifference()
            } label: {
                Label("Previous Difference", systemImage: "chevron.up")
            }
            .labelStyle(.iconOnly)
            .keyboardShortcut("[", modifiers: .command)
            .help("Previous difference")
            .disabled(model.result?.hunks.isEmpty != false)

            Button {
                model.nextDifference()
            } label: {
                Label("Next Difference", systemImage: "chevron.down")
            }
            .labelStyle(.iconOnly)
            .keyboardShortcut("]", modifiers: .command)
            .help("Next difference")
            .disabled(model.result?.hunks.isEmpty != false)

            Menu {
                if model.isEditing {
                    Button("Toggle Left Bookmark at Caret") {
                        model.toggleBookmarkAtCaret(side: .left)
                    }
                    .disabled(model.leftSelectedLineNumber == nil)
                    Button("Toggle Right Bookmark at Caret") {
                        model.toggleBookmarkAtCaret(side: .right)
                    }
                    .disabled(model.rightSelectedLineNumber == nil)
                    Divider()
                }
                Button("Previous Bookmark") { model.previousBookmark() }
                    .keyboardShortcut("[", modifiers: [.command, .option])
                    .disabled(!model.hasBookmarks)
                Button("Next Bookmark") { model.nextBookmark() }
                    .keyboardShortcut("]", modifiers: [.command, .option])
                    .disabled(!model.hasBookmarks)
                Button("Remove Current Bookmark") { model.removeCurrentBookmark() }
                    .disabled(model.currentBookmarkID == nil)
                if !model.bookmarks.isEmpty {
                    Divider()
                    ForEach(model.bookmarks) { bookmark in
                        Menu {
                            Button("Go to Bookmark") {
                                model.selectBookmark(id: bookmark.id)
                            }
                            Button("Remove Bookmark", role: .destructive) {
                                model.removeBookmark(id: bookmark.id)
                            }
                        } label: {
                            Text(verbatim: bookmarkMenuTitle(bookmark))
                        }
                    }
                }
            } label: {
                Label {
                    Text(
                        verbatim: String(
                            localized: "Bookmarks (\(model.bookmarks.count))",
                            bundle: RiffaLocalization.localizedBundle,
                            locale: RiffaLocalization.locale
                        )
                    )
                } icon: {
                    Image(
                        systemName: model.hasBookmarks
                            ? "bookmark.fill"
                            : "bookmark"
                    )
                }
            }
            .labelStyle(.iconOnly)
            .help("Toggle, remove, and navigate logical-line bookmarks")
            .accessibilityLabel(
                String(
                    localized: "Bookmarks, \(model.bookmarks.count)",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
            )

            Menu {
                Toggle("Ignore case", isOn: $model.ignoreCase)
                Toggle("Ignore whitespace", isOn: $model.ignoreWhitespace)
                Toggle("Edit compared text", isOn: $model.isEditing)
                    .disabled(model.result == nil)

                if model.isEditing {
                    Divider()
                    Button("Save Left As…") { model.saveDraft(for: .left) }
                    Button("Save Right As…") { model.saveDraft(for: .right) }
                }

                Divider()
                Menu("Clipboard") {
                    Button("Load Clipboard to Left") {
                        model.loadClipboard(for: .left)
                    }
                    Button("Load Clipboard to Right") {
                        model.loadClipboard(for: .right)
                    }
                }

                Menu("Export Report") {
                    Button("HTML…") { model.saveReport(format: .html) }
                    Button("Plain Text…") { model.saveReport(format: .plainText) }
                    Button("JSON…") { model.saveReport(format: .json) }
                }
                .disabled(model.result == nil)

                Button("Export Patch…") {
                    model.exportPatch()
                }
                .disabled(!model.canExportPatch)

                Button("Apply Patch…") {
                    model.applyPatch()
                }
                .disabled(!model.canApplyPatch)

                Divider()
                Button("Copy Right to Left") {
                    model.copyCurrentDifference(from: .right)
                }
                .disabled(model.currentHunkIndex == nil)

                Button("Copy Left to Right") {
                    model.copyCurrentDifference(from: .left)
                }
                .disabled(model.currentHunkIndex == nil)
            } label: {
                Label("More actions", systemImage: "ellipsis.circle")
            }
            .labelStyle(.iconOnly)
            .help("Comparison options, clipboard, export, patch, and copy actions")
        }
    }

    private var findBar: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find", text: $model.searchQuery)
                .riffaInputSurface(minHeight: 34)
                .focused($searchFieldFocused)
                .frame(minWidth: 150, idealWidth: 230, maxWidth: 320)
                .onSubmit { model.nextSearchMatch() }
            Picker("Search side", selection: $model.searchSide) {
                ForEach(TextCompareModel.SearchSide.allCases) {
                    Text(LocalizedStringKey($0.rawValue)).tag($0)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 155)
            Toggle("Regex", isOn: Binding(
                get: { model.searchMode == .regularExpression },
                set: { model.searchMode = $0 ? .regularExpression : .literal }
            ))
            .toggleStyle(.checkbox)
            Toggle("Case", isOn: $model.searchCaseSensitive).toggleStyle(.checkbox)
            if let searchErrorMessage = model.searchErrorMessage {
                Label {
                    Text(verbatim: searchErrorMessage)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                    .font(.caption)
                    .foregroundStyle(theme.danger)
                    .lineLimit(1)
                    .frame(minWidth: 120, maxWidth: 280, alignment: .leading)
                    .help(searchErrorMessage)
                    .accessibilityLabel(
                        String(
                            localized: "Search error: \(searchErrorMessage)",
                            bundle: RiffaLocalization.localizedBundle,
                            locale: RiffaLocalization.locale
                        )
                    )
            } else {
                Text(verbatim: searchSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 72)
            }
            Button {
                model.previousSearchMatch()
            } label: {
                Label("Previous Search Match", systemImage: "chevron.up")
            }
                .labelStyle(.iconOnly)
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .accessibilityLabel("Previous search match")
                .disabled(model.searchOffsets.isEmpty)
            Button {
                model.nextSearchMatch()
            } label: {
                Label("Next Search Match", systemImage: "chevron.down")
            }
                .labelStyle(.iconOnly)
                .keyboardShortcut("g", modifiers: .command)
                .accessibilityLabel("Next search match")
                .disabled(model.searchOffsets.isEmpty)
            if model.isEditing {
                Divider().frame(height: 22)
                TextField("Replace with", text: $model.replacementText)
                    .riffaInputSurface(minHeight: 34)
                    .frame(minWidth: 130, idealWidth: 190, maxWidth: 250)
                Button("Replace All") { model.replaceAllSearchMatches() }
                    .disabled(!model.canReplaceAllSearchMatches)
            }
            Spacer(minLength: 0)
            Button {
                showFind = false
            } label: {
                Label("Close Find", systemImage: "xmark")
            }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Close Find")
                .accessibilityLabel("Close Find")
        }
        .padding(.horizontal, RiffaSpacing.sm)
        .padding(.vertical, RiffaSpacing.xxs)
        .frame(minHeight: 40)
        .background(theme.surface(.two))
        .overlay(alignment: .bottom) {
            RiffaHairline()
        }
    }

    private var searchSummary: String {
        let count = model.searchOffsets.count
        guard count > 0, let index = model.currentSearchMatchIndex else {
            return model.searchQuery.isEmpty
                ? ""
                : RiffaLocalization.string("0 matches")
        }
        return String(
            localized: "\(index + 1) of \(count)",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
    }

    private func bookmarkMenuTitle(_ bookmark: TextLineBookmark) -> String {
        let preview = bookmark.preview.isEmpty
            ? RiffaLocalization.string("Empty line")
            : bookmark.preview
        let side = bookmark.side == .left
            ? RiffaLocalization.string("Left")
            : RiffaLocalization.string("Right")
        return String(
            localized: "\(side) line \(bookmark.lineNumber): \(preview)",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
    }

    private func editorNavigationRequest(
        for side: TextComparisonSide
    ) -> TextEditorLineNavigationRequest? {
        guard let request = model.navigationRequest, request.side == side else { return nil }
        return TextEditorLineNavigationRequest(
            id: request.id,
            lineNumber: request.lineNumber
        )
    }

    private var pathBar: some View {
        RiffaComparisonPathBar {
            FilePathButton(
                title: "Left file",
                url: model.leftURL
            ) {
                model.chooseFile(for: .left)
            }
            .riffaResourceDropTarget(
                role: .left,
                acceptedKind: .regularFileFollowingFinalSymbolicLink
            ) {
                model.replaceInput(with: $0, for: .left)
            }

            Button {
                model.swapSides()
            } label: {
                Label("Swap left and right", systemImage: "arrow.left.arrow.right")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.riffaTertiary)
            .help("Swap left and right")
            .accessibilityLabel("Swap left and right files")
            .disabled(model.leftDocument == nil && model.rightDocument == nil)

            FilePathButton(
                title: "Right file",
                url: model.rightURL
            ) {
                model.chooseFile(for: .right)
            }
            .riffaResourceDropTarget(
                role: .right,
                acceptedKind: .regularFileFollowingFinalSymbolicLink
            ) {
                model.replaceInput(with: $0, for: .right)
            }
        }
    }

    private var externalChangeBanner: some View {
        VStack(spacing: 0) {
            ForEach(model.sidesWithExternalChanges) { side in
                if let change = model.externalChange(for: side) {
                    HStack(spacing: 10) {
                        Image(systemName: externalChangeSymbol(change))
                            .foregroundStyle(theme.warning)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: externalChangeTitle(change, side: side))
                                .font(.subheadline.weight(.semibold))
                            Text(verbatim: externalChangeDetail(side: side))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Reload") {
                            model.reloadAfterExternalChange(for: side)
                        }
                        .help("Reload through Riffa's bounded text decoder")
                        Button("Keep Current") {
                            model.keepCurrentAfterExternalChange(for: side)
                        }
                        .help("Keep the current comparison or draft and review the file later")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(theme.warning.opacity(0.1))
                    .accessibilityElement(children: .contain)
                }
            }
        }
    }

    private var bookmarkNoticeBanner: some View {
        HStack(spacing: 9) {
            Image(systemName: "bookmark.slash")
                .foregroundStyle(theme.warning)
            Text(verbatim: model.bookmarkNotice ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Dismiss") { model.bookmarkNotice = nil }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 32)
        .background(theme.warning.opacity(0.08))
        .accessibilityElement(children: .contain)
    }

    private func externalChangeTitle(
        _ change: TextExternalFileChangeKind,
        side: TextCompareModel.Side
    ) -> String {
        let name = (side == .left ? model.leftURL : model.rightURL)?.lastPathComponent
            ?? String(
                localized: "The \(RiffaLocalization.string(side.rawValue).lowercased()) file",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        switch change {
        case .changed:
            return String(
                localized: "\(name) changed outside Riffa",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case .moved:
            return String(
                localized: "\(name) was moved or renamed",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case .deleted:
            return String(
                localized: "\(name) was deleted",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case .unavailable:
            return String(
                localized: "\(name) is unavailable",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
    }

    private func externalChangeDetail(side: TextCompareModel.Side) -> String {
        if model.hasUnsavedDraft(for: side) {
            return RiffaLocalization.string(
                "Your in-memory edits are preserved. Saving over the original remains protected by its content fingerprint."
            )
        }
        return RiffaLocalization.string(
            "Reload to compare the current file, or keep this version and review the change later."
        )
    }

    private func externalChangeSymbol(_ change: TextExternalFileChangeKind) -> String {
        switch change {
        case .changed: "arrow.triangle.2.circlepath"
        case .moved: "arrowshape.turn.up.right"
        case .deleted: "trash"
        case .unavailable: "exclamationmark.triangle.fill"
        }
    }

    @ViewBuilder
    private func diffContent(_ result: TextDiffResult) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                paneHeading("LEFT", systemImage: "arrow.left", url: model.leftURL)
                    .frame(maxWidth: .infinity)
                Divider()
                paneHeading("RIGHT", systemImage: "arrow.right", url: model.rightURL)
                    .frame(maxWidth: .infinity)
            }
            .frame(height: 34)
            .background(theme.surface(.one))

            Divider()

            HStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView([.vertical, .horizontal]) {
                        LazyVStack(spacing: 0) {
                            ForEach(result.alignedLines, id: \.offset) { line in
                                TextDiffRow(
                                    line: line,
                                    isSearchMatch: model.isSearchMatch(line),
                                    leftBookmarked: line.left.map {
                                        model.isBookmarked(side: .left, lineNumber: $0.lineNumber)
                                    } ?? false,
                                    rightBookmarked: line.right.map {
                                        model.isBookmarked(side: .right, lineNumber: $0.lineNumber)
                                    } ?? false,
                                    toggleLeftBookmark: line.left.map { value in
                                        { model.toggleBookmark(side: .left, lineNumber: value.lineNumber) }
                                    },
                                    toggleRightBookmark: line.right.map { value in
                                        { model.toggleBookmark(side: .right, lineNumber: value.lineNumber) }
                                    }
                                )
                                .id(line.offset)
                            }
                        }
                    }
                    .onChange(of: model.navigationRequest) { _, request in
                        guard let request else { return }
                        withAnimation(.easeInOut(duration: 0.18)) {
                            proxy.scrollTo(request.alignedOffset, anchor: .center)
                        }
                    }
                }
                Divider()
                TextDifferenceOverviewView(
                    overview: model.diffOverview,
                    selectedHunkIndex: model.currentHunkIndex,
                    selectHunk: model.selectDifference(at:)
                )
                .frame(width: 30)
            }

            Divider()
            statisticsBar(result)
        }
    }

    private func editorContent(_ result: TextDiffResult) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                paneHeading(
                    "LEFT — EDITING IN MEMORY",
                    systemImage: "arrow.left",
                    url: model.leftURL
                )
                    .frame(maxWidth: .infinity)
                Divider()
                paneHeading(
                    "RIGHT — EDITING IN MEMORY",
                    systemImage: "arrow.right",
                    url: model.rightURL
                )
                    .frame(maxWidth: .infinity)
            }
            .frame(height: 34)
            .background(theme.surface(.one))
            Divider()
            HStack(spacing: 0) {
                HSplitView {
                    TextCompareNavigableEditor(
                        text: $model.leftDraft,
                        selectedLineNumber: $model.leftSelectedLineNumber,
                        navigationRequest: editorNavigationRequest(for: .left),
                        editorAccessibilityLabel: "Editable left text"
                    )
                    TextCompareNavigableEditor(
                        text: $model.rightDraft,
                        selectedLineNumber: $model.rightSelectedLineNumber,
                        navigationRequest: editorNavigationRequest(for: .right),
                        editorAccessibilityLabel: "Editable right text"
                    )
                }
                Divider()
                TextDifferenceOverviewView(
                    overview: model.diffOverview,
                    selectedHunkIndex: model.currentHunkIndex,
                    selectHunk: model.selectDifference(at:)
                )
                .frame(width: 30)
            }
            Divider()
            statisticsBar(result)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Choose two text files", systemImage: "doc.text.magnifyingglass")
        } description: {
            Text("Riffa keeps the comparison on this Mac and preserves line endings.")
        } actions: {
            HStack {
                Button("Choose Left") { model.chooseFile(for: .left) }
                    .buttonStyle(
                        RiffaButtonStyle(model.leftURL == nil ? .primary : .secondary)
                    )
                Button("Choose Right") { model.chooseFile(for: .right) }
                    .buttonStyle(
                        RiffaButtonStyle(
                            model.leftURL != nil && model.rightURL == nil
                                ? .primary
                                : .secondary
                        )
                    )
                Button("Load Demo") { model.loadDemo() }
                    .buttonStyle(.riffaTertiary)
            }
        }
    }

    private func paneHeading(
        _ title: String,
        systemImage: String,
        url: URL?
    ) -> some View {
        HStack {
            Image(systemName: systemImage)
                .foregroundStyle(theme.inkSubtle)
                .accessibilityHidden(true)
            Text(LocalizedStringKey(title))
                .font(.caption.weight(.bold))
                .foregroundStyle(theme.inkMuted)
            Spacer()
            if let url {
                Text(verbatim: url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(theme.inkSubtle)
                    .lineLimit(1)
            } else {
                Text(verbatim: RiffaLocalization.string("No file"))
                    .font(.caption)
                    .foregroundStyle(theme.inkSubtle)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
    }

    private func statisticsBar(_ result: TextDiffResult) -> some View {
        HStack(spacing: 14) {
            DifferenceBadge(
                title: "\(result.statistics.modifiedLineCount) modified",
                color: theme.warning
            )
            DifferenceBadge(
                title: "\(result.statistics.deletedLineCount) deleted",
                color: theme.danger
            )
            DifferenceBadge(
                title: "\(result.statistics.insertedLineCount) inserted",
                color: theme.success
            )
            Spacer()
            if result.hasDifferences {
                Text("Difference \((model.currentHunkIndex ?? 0) + 1) of \(result.hunks.count)")
            } else {
                Label("Files match", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(theme.success)
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(theme.surface(.one))
    }
}

private struct TextDiffRow: View {
    let line: AlignedDiffLine
    let isSearchMatch: Bool
    let leftBookmarked: Bool
    let rightBookmarked: Bool
    let toggleLeftBookmark: (() -> Void)?
    let toggleRightBookmark: (() -> Void)?
    @Environment(\.riffaTheme) private var theme
    @Environment(\.accessibilityDifferentiateWithoutColor)
    private var differentiateWithoutColor

    var body: some View {
        HStack(spacing: 0) {
            LineCell(
                value: line.left,
                color: leftColor,
                sideName: RiffaLocalization.string("Left").lowercased(),
                isBookmarked: leftBookmarked,
                toggleBookmark: toggleLeftBookmark
            )
                .frame(width: 520)
            Divider()
            LineCell(
                value: line.right,
                color: rightColor,
                sideName: RiffaLocalization.string("Right").lowercased(),
                isBookmarked: rightBookmarked,
                toggleBookmark: toggleRightBookmark
            )
                .frame(width: 520)
        }
        .frame(height: 25)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.28)
        }
        .overlay {
            if isSearchMatch {
                Rectangle().stroke(theme.warning.opacity(0.85), lineWidth: 1.5)
            }
        }
        .overlay {
            if differentiateWithoutColor, line.kind != .unchanged {
                Image(systemName: differenceSymbol)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(theme.ink)
                    .frame(width: 16, height: 16)
                    .background(theme.surface(.four), in: Circle())
                    .overlay {
                        Circle().strokeBorder(theme.hairlineStrong)
                    }
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityDescription)
    }

    private var leftColor: Color {
        let strongOpacity = theme.usesIncreasedContrast ? 0.24 : 0.14
        let modifiedOpacity = theme.usesIncreasedContrast ? 0.22 : 0.12
        return switch line.kind {
        case .deleted: theme.danger.opacity(strongOpacity)
        case .modified: theme.warning.opacity(modifiedOpacity)
        case .inserted: .secondary.opacity(0.035)
        case .unchanged: .clear
        }
    }

    private var rightColor: Color {
        let strongOpacity = theme.usesIncreasedContrast ? 0.24 : 0.14
        let modifiedOpacity = theme.usesIncreasedContrast ? 0.22 : 0.12
        return switch line.kind {
        case .inserted: theme.success.opacity(strongOpacity)
        case .modified: theme.warning.opacity(modifiedOpacity)
        case .deleted: .secondary.opacity(0.035)
        case .unchanged: .clear
        }
    }

    private var differenceSymbol: String {
        switch line.kind {
        case .inserted: "plus"
        case .deleted: "minus"
        case .modified: "pencil"
        case .unchanged: "equal"
        }
    }

    private var accessibilityDescription: String {
        let left: String
        if let value = line.left {
            left = String(
                localized: "Left line \(value.lineNumber), \(value.line.content)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        } else {
            left = RiffaLocalization.string("No left line")
        }

        let right: String
        if let value = line.right {
            right = String(
                localized: "Right line \(value.lineNumber), \(value.line.content)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        } else {
            right = RiffaLocalization.string("No right line")
        }

        let kind: String
        switch line.kind {
        case .inserted: kind = RiffaLocalization.string("Inserted")
        case .deleted: kind = RiffaLocalization.string("Deleted")
        case .modified: kind = RiffaLocalization.string("Modified")
        case .unchanged: kind = RiffaLocalization.string("Unchanged")
        }

        if isSearchMatch {
            return String(
                localized: "\(kind), current search match, \(left), \(right)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
        return String(
            localized: "\(kind), \(left), \(right)",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
    }
}

private struct LineCell: View {
    let value: DiffLineValue?
    let color: Color
    let sideName: String
    let isBookmarked: Bool
    let toggleBookmark: (() -> Void)?
    @Environment(\.riffaTheme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            if let value, let toggleBookmark {
                Button(action: toggleBookmark) {
                    Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(
                            isBookmarked ? theme.accent : theme.inkSubtle
                        )
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(bookmarkHelp(lineNumber: value.lineNumber))
                .accessibilityLabel(bookmarkLabel(lineNumber: value.lineNumber))
            } else {
                Color.clear.frame(width: 24, height: 24)
            }

            Text(value.map { String($0.lineNumber) } ?? "")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 36, alignment: .trailing)
                .padding(.trailing, 8)

            Rectangle()
                .fill(.separator.opacity(0.5))
                .frame(width: 1)

            Text(value?.line.content ?? "")
                .font(.system(size: 12.5, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
        }
        .background(color)
    }

    private func bookmarkHelp(lineNumber: Int) -> String {
        let action = isBookmarked
            ? RiffaLocalization.string("Remove")
            : RiffaLocalization.string("Add")
        return String(
            localized: "\(action) bookmark on \(sideName) line \(lineNumber)",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
    }

    private func bookmarkLabel(lineNumber: Int) -> String {
        let action = isBookmarked
            ? RiffaLocalization.string("Remove")
            : RiffaLocalization.string("Add")
        return String(
            localized: "\(action) bookmark, \(sideName) line \(lineNumber)",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
    }
}

private struct TextDifferenceOverviewView: View {
    let overview: TextDiffOverview
    let selectedHunkIndex: Int?
    let selectHunk: (Int) -> Void
    @Environment(\.riffaTheme) private var theme
    @Environment(\.accessibilityDifferentiateWithoutColor)
    private var differentiateWithoutColor

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(theme.surface(.one))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(theme.hairline)
                    }

                if overview.alignedLineCount > 0 {
                    ForEach(overview.markers) { marker in
                        markerButton(marker, height: geometry.size.height)
                    }
                }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 6)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            String(
                localized: "Difference overview, \(overview.hunkCount) differences",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        )
        .help("Bounded overview of the published difference hunks")
    }

    private func markerButton(
        _ marker: TextDiffOverviewMarker,
        height: CGFloat
    ) -> some View {
        let usableHeight = max(1, height - 12)
        let total = max(1, overview.alignedLineCount)
        let rawHeight = usableHeight * CGFloat(marker.alignedRange.count) / CGFloat(total)
        let markerHeight = min(usableHeight, max(4, rawHeight))
        let top = usableHeight * CGFloat(marker.alignedRange.start) / CGFloat(total)
        let selected = selectedHunkIndex.map {
            ($0 >= marker.firstHunkIndex) && ($0 <= marker.lastHunkIndex)
        } ?? false

        return Button {
            selectHunk(marker.targetHunkIndex)
        } label: {
            RoundedRectangle(cornerRadius: 2)
                .fill(markerColor(marker.kind))
                .overlay {
                    ZStack {
                        if differentiateWithoutColor {
                            Image(systemName: markerSymbol(marker.kind))
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(theme.ink)
                                .accessibilityHidden(true)
                        }
                        if selected || theme.usesIncreasedContrast {
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(
                                    selected ? theme.ink : theme.hairlineStrong,
                                    lineWidth: selected ? 1.5 : 1
                                )
                        }
                    }
                }
        }
        .buttonStyle(.plain)
        .frame(width: 20, height: markerHeight)
        .offset(x: 0, y: min(max(0, top), max(0, usableHeight - markerHeight)))
        .help(markerAccessibilityLabel(marker))
        .accessibilityLabel(markerAccessibilityLabel(marker))
        .accessibilityHint("Activate to navigate to this difference region")
    }

    private func markerColor(_ kind: TextDiffOverviewKind) -> Color {
        switch kind {
        case .inserted: theme.success.opacity(0.82)
        case .deleted: theme.danger.opacity(0.82)
        case .modified: theme.warning.opacity(0.88)
        case .mixed: theme.secure.opacity(0.78)
        }
    }

    private func markerSymbol(_ kind: TextDiffOverviewKind) -> String {
        switch kind {
        case .inserted: "plus"
        case .deleted: "minus"
        case .modified: "pencil"
        case .mixed: "asterisk"
        }
    }

    private func markerAccessibilityLabel(_ marker: TextDiffOverviewMarker) -> String {
        let kind = RiffaLocalization.string(marker.kind.rawValue.capitalized)
        let first = marker.firstHunkIndex + 1
        let last = marker.lastHunkIndex + 1
        if first == last {
            return String(
                localized: "\(kind) difference \(first)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
        return String(
            localized: "\(kind) differences \(first) through \(last)",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
    }
}

private struct FilePathButton: View {
    let title: String
    let url: URL?
    let action: () -> Void

    var body: some View {
        RiffaResourcePathButton(
            title: title,
            url: url,
            emptyTitle: "Choose a file…",
            systemImage: "doc",
            accessibilityHint: "Choose a text file",
            action: action
        )
        .accessibilityValue(
            url?.path(percentEncoded: false)
                ?? RiffaLocalization.string("No file selected")
        )
    }
}

private struct DifferenceBadge: View {
    let title: LocalizedStringKey
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title)
        }
        .foregroundStyle(.secondary)
    }
}
