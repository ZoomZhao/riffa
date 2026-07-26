import AppKit
import Foundation
import RiffaCore
import SwiftUI

@MainActor
final class TextMergeModel: ObservableObject {
    enum InputSide: String, CaseIterable, Hashable, Identifiable, Sendable {
        case base = "Base"
        case left = "Left"
        case right = "Right"

        var id: Self { self }
    }

    typealias Resolution = TextMergeConflictResolution

    @Published private(set) var baseURL: URL?
    @Published private(set) var leftURL: URL?
    @Published private(set) var rightURL: URL?
    @Published private(set) var result: ThreeWayMergeResult?
    @Published private(set) var resolutions: [Int: Resolution] = [:]
    @Published private(set) var outputText = ""
    @Published var errorMessage: String?
    @Published private(set) var hasUnsavedMergeWork = false
    @Published private(set) var externalChanges: [InputSide: TextExternalFileChangeKind] = [:]
    @Published private(set) var historyLimitMessage: String?

    private var baseText: String?
    private var leftText: String?
    private var rightText: String?
    private var baseDecodedDocument: DecodedTextDocument?
    private var leftDecodedDocument: DecodedTextDocument?
    private var rightDecodedDocument: DecodedTextDocument?
    private var baseBackingURL: URL?
    private var leftBackingURL: URL?
    private var rightBackingURL: URL?
    private var baseLoadTask: Task<Void, Never>?
    private var leftLoadTask: Task<Void, Never>?
    private var rightLoadTask: Task<Void, Never>?
    private var baseLoadGeneration = 0
    private var leftLoadGeneration = 0
    private var rightLoadGeneration = 0
    private let documentStore = DecodedTextDocumentStore()
    private var editHistory = TextMergeEditHistory(
        initialDraft: TextMergeDraft(outputText: "", resolutions: [:])
    )
    private var cleanDraft = TextMergeDraft(outputText: "", resolutions: [:])
    private var draftDocumentGeneration = 0
    private var externalChangeStates: [InputSide: TextExternalChangeCoordinationState] = [
        .base: .init(),
        .left: .init(),
        .right: .init()
    ]
    private var fileChangeMonitors: [InputSide: LocalFileChangeMonitor] = [:]

    private struct ReloadDraftSnapshot: Equatable {
        let outputText: String
        let resolutions: [Int: Resolution]
        let hasUnsavedMergeWork: Bool

        var draft: TextMergeDraft {
            TextMergeDraft(outputText: outputText, resolutions: resolutions)
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.outputText.utf8.elementsEqual(rhs.outputText.utf8)
                && lhs.resolutions == rhs.resolutions
                && lhs.hasUnsavedMergeWork == rhs.hasUnsavedMergeWork
        }
    }

    var unresolvedConflictCount: Int {
        guard let result else { return 0 }
        return result.conflicts.reduce(into: 0) { count, conflict in
            if resolutions[conflict.id, default: .unresolved] == .unresolved {
                count += 1
            }
        }
    }

    var resolvedConflictCount: Int {
        (result?.conflicts.count ?? 0) - unresolvedConflictCount
    }

    var canSave: Bool {
        result != nil && unresolvedConflictCount == 0
    }

    var canUndo: Bool { editHistory.canUndo }
    var canRedo: Bool { editHistory.canRedo }

    var undoTitle: String {
        undoCommandTitle.localized(language: RiffaLocalization.selectedLanguage)
    }

    var undoCommandTitle: RiffaUndoRedoTitle {
        guard let action = editHistory.nextUndoAction else {
            return .undoMergeEdit
        }
        return .undo(Self.editActionTitle(action))
    }

    var redoTitle: String {
        redoCommandTitle.localized(language: RiffaLocalization.selectedLanguage)
    }

    var redoCommandTitle: RiffaUndoRedoTitle {
        guard let action = editHistory.nextRedoAction else {
            return .redoMergeEdit
        }
        return .redo(Self.editActionTitle(action))
    }

    var outputFormatDescription: String {
        Self.formatDescription(preferredOutputDocument?.format ?? .utf8)
    }

    var outputEncodedByteCount: Int {
        guard let document = preferredOutputDocument?.replacingText(with: outputText),
              let data = try? document.encodedData() else {
            return outputText.utf8.count
        }
        return data.count
    }

    var sidesWithExternalChanges: [InputSide] {
        InputSide.allCases.filter { externalChanges[$0] != nil }
    }

    func externalChange(for side: InputSide) -> TextExternalFileChangeKind? {
        externalChanges[side]
    }

    func url(for side: InputSide) -> URL? {
        switch side {
        case .base: baseURL
        case .left: leftURL
        case .right: rightURL
        }
    }

    func chooseFile(for side: InputSide) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let sideTitle = RiffaLocalization.string(side.rawValue)
        panel.title = String(
            localized: "Choose \(sideTitle) Text File",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
        panel.prompt = RiffaLocalization.string("Choose")

        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url: url, for: side)
    }

    func reloadAfterExternalChange(for side: InputSide) {
        guard let url = backingURL(for: side) else {
            keepCurrentAfterExternalChange(for: side)
            return
        }

        let state = externalChangeStates[side, default: .init()]
        if state.reloadSafety(hasUnsavedEdits: hasUnsavedMergeWork)
            == .requiresDiscardConfirmation,
           !confirmDiscardMergeWorkAndReload(side: side, fileURL: url) {
            return
        }
        load(url: url, for: side, externalReloadSnapshot: currentReloadDraftSnapshot)
    }

    func keepCurrentAfterExternalChange(for side: InputSide) {
        var state = externalChangeStates[side, default: .init()]
        state.keepCurrent()
        externalChangeStates[side] = state
        publishExternalChange(for: side)
    }

    func openInitial(_ urls: [URL], options _: [String: String] = [:]) {
        guard !urls.isEmpty else { return }
        guard urls.count == 3 else {
            errorMessage = RiffaLocalization.string(
                "Text Merge requires exactly three files in Base, Left, Right order."
            )
            return
        }

        for (side, url) in zip(
            [InputSide.base, .left, .right],
            urls.map(\.standardizedFileURL)
        ) {
            load(url: url, for: side)
        }
    }

    func loadDemo() {
        invalidateAllLoads()
        stopAllFileChangeMonitoring()
        for side in InputSide.allCases {
            establishExternalBaseline(for: side)
        }
        baseURL = URL(fileURLWithPath: "/Demo/preferences-base.txt")
        leftURL = URL(fileURLWithPath: "/Demo/preferences-left.txt")
        rightURL = URL(fileURLWithPath: "/Demo/preferences-right.txt")

        baseDecodedDocument = Self.defaultDecodedDocument(text: """
        product=Riffa
        appearance=navy
        safety=preview
        updates=manual
        """)
        leftDecodedDocument = Self.defaultDecodedDocument(text: """
        product=Riffa Desktop
        appearance=navy
        safety=preview
        updates=automatic
        """)
        rightDecodedDocument = Self.defaultDecodedDocument(text: """
        product=Riffa for Mac
        appearance=ocean
        safety=preview
        updates=manual
        """)
        baseText = baseDecodedDocument?.text
        leftText = leftDecodedDocument?.text
        rightText = rightDecodedDocument?.text
        baseBackingURL = nil
        leftBackingURL = nil
        rightBackingURL = nil

        errorMessage = nil
        mergeIfReady()
    }

    func resolve(conflictID: Int, using resolution: Resolution) {
        guard let result, result.conflicts.contains(where: { $0.id == conflictID }) else {
            return
        }
        var updatedResolutions = resolutions
        updatedResolutions[conflictID] = resolution
        let draft = TextMergeDraft(
            outputText: renderedOutput(result, resolutions: updatedResolutions),
            resolutions: updatedResolutions
        )
        recordDraft(draft, action: .conflictResolution(conflictID: conflictID))
    }

    func editOutput(_ text: String) {
        recordDraft(
            TextMergeDraft(outputText: text, resolutions: resolutions),
            action: .manualOutputEdit
        )
    }

    func undo() {
        guard let draft = editHistory.undo() else { return }
        publishDraft(draft)
    }

    func redo() {
        guard let draft = editHistory.redo() else { return }
        publishDraft(draft)
    }

    func saveOutput() {
        guard let result else {
            errorMessage = RiffaLocalization.string(
                "Choose Base, Left, and Right files before saving."
            )
            return
        }

        guard unresolvedConflictCount == 0 else {
            errorMessage = String(
                localized: "Resolve all \(unresolvedConflictCount) remaining conflicts before saving.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
            return
        }

        let panel = NSSavePanel()
        panel.title = RiffaLocalization.string("Save Merged Text")
        panel.prompt = RiffaLocalization.string("Save")
        panel.nameFieldStringValue = suggestedOutputName
        let resultDescription = result.hasConflicts
            ? RiffaLocalization.string("The selected conflict resolutions")
            : RiffaLocalization.string("The automatically merged result")
        panel.message = String(
            localized: "\(resultDescription) will use \(outputFormatDescription) for a new file. Overwriting an input preserves that input's encoding and BOM and is blocked if it changed externally.",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = outputText
        let overwrittenSide = matchingInputSide(for: url)
        let sourceDocument = overwrittenSide.flatMap { decodedDocument(for: $0) }
            ?? preferredOutputDocument
            ?? Self.defaultDecodedDocument(text: text)
        let outputDocument = sourceDocument.replacingText(with: text)
        let destinationURL = overwrittenSide.flatMap { backingURL(for: $0) } ?? url
        let saveSnapshot = currentReloadDraftSnapshot
        let saveDocumentGeneration = draftDocumentGeneration

        Task { [weak self] in
            guard let self else { return }
            do {
                let fingerprint: DecodedTextFileFingerprint
                if overwrittenSide != nil {
                    fingerprint = try await documentStore.save(
                        outputDocument,
                        to: destinationURL,
                        ifContentsMatch: sourceDocument.fingerprint
                    )
                } else {
                    fingerprint = try await documentStore.save(outputDocument, to: destinationURL)
                }

                var resetFromSavedInput = false
                if let overwrittenSide,
                   decodedDocument(for: overwrittenSide) == sourceDocument,
                   backingURL(for: overwrittenSide) == destinationURL {
                    let savedDocument = DecodedTextDocument(
                        text: text,
                        format: sourceDocument.format,
                        fingerprint: fingerprint
                    )
                    if draftDocumentGeneration == saveDocumentGeneration,
                       currentReloadDraftSnapshot == saveSnapshot {
                        installSavedDocument(savedDocument, for: overwrittenSide)
                        mergeIfReady()
                        resetFromSavedInput = true
                    } else {
                        // The selected snapshot was written, but newer editor
                        // work appeared while I/O was in flight. Refresh only
                        // the write fingerprint and watcher; never replace the
                        // newer merge draft.
                        installSavedBaselineOnly(savedDocument, for: overwrittenSide)
                    }
                }
                if !resetFromSavedInput,
                   draftDocumentGeneration == saveDocumentGeneration {
                    markCleanDraft(saveSnapshot.draft)
                }
                errorMessage = nil
            } catch {
                errorMessage = saveFailureMessage(error, fileURL: destinationURL)
            }
        }
    }

    private var suggestedOutputName: String {
        let sourceURL = leftURL ?? rightURL ?? baseURL
        guard let sourceURL else {
            return RiffaLocalization.string("Merged.txt")
        }

        let stem = sourceURL.deletingPathExtension().lastPathComponent
        let pathExtension = sourceURL.pathExtension
        if pathExtension.isEmpty {
            return String(
                localized: "\(stem)-merged.txt",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
        return String(
            localized: "\(stem)-merged.\(pathExtension)",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
    }

    private func load(
        url: URL,
        for side: InputSide,
        externalReloadSnapshot: ReloadDraftSnapshot? = nil
    ) {
        invalidateLoad(for: side)
        errorMessage = nil
        let generation = loadGeneration(for: side)
        let store = documentStore
        let task = Task { [weak self] in
            do {
                let document = try await store.load(from: url)
                try Task.checkCancellation()
                guard let self, loadGeneration(for: side) == generation else { return }
                if let externalReloadSnapshot,
                   currentReloadDraftSnapshot != externalReloadSnapshot {
                    errorMessage = String(
                        localized: "The merge draft changed while \(url.lastPathComponent) was reloading. Riffa kept the newer work; choose Reload again when ready.",
                        bundle: RiffaLocalization.localizedBundle,
                        locale: RiffaLocalization.locale
                    )
                    clearLoadTask(for: side, generation: generation)
                    return
                }
                installLoadedDocument(document, from: url, for: side)
                mergeIfReady()
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

    private func mergeIfReady() {
        guard let baseText, let leftText, let rightText else {
            result = nil
            resetDraft(TextMergeDraft(outputText: "", resolutions: [:]))
            return
        }

        let merged = ThreeWayMergeEngine().merge(
            base: baseText,
            left: leftText,
            right: rightText
        )
        result = merged
        let initialResolutions = Dictionary(
            uniqueKeysWithValues: merged.conflicts.map { ($0.id, Resolution.unresolved) }
        )
        resetDraft(
            TextMergeDraft(
                outputText: renderedOutput(merged, resolutions: initialResolutions),
                resolutions: initialResolutions
            )
        )
    }

    private func renderedOutput(
        _ result: ThreeWayMergeResult,
        resolutions: [Int: Resolution]
    ) -> String {
        result.segments.reduce(into: "") { output, segment in
            switch segment {
            case let .merged(text):
                output += text
            case let .conflict(conflict):
                switch resolutions[conflict.id, default: .unresolved] {
                case .left:
                    output += conflict.leftText
                case .base:
                    output += conflict.baseText
                case .right:
                    output += conflict.rightText
                case .unresolved:
                    let unresolved = ThreeWayMergeResult(
                        segments: [.conflict(conflict)],
                        conflicts: [conflict],
                        preferredLineEnding: result.preferredLineEnding
                    )
                    output += unresolved.renderedText()
                }
            }
        }
    }

    private var preferredOutputDocument: DecodedTextDocument? {
        leftDecodedDocument ?? rightDecodedDocument ?? baseDecodedDocument
    }

    private var currentReloadDraftSnapshot: ReloadDraftSnapshot {
        ReloadDraftSnapshot(
            outputText: outputText,
            resolutions: resolutions,
            hasUnsavedMergeWork: hasUnsavedMergeWork
        )
    }

    private func recordDraft(
        _ draft: TextMergeDraft,
        action: TextMergeEditAction
    ) {
        let outcome = editHistory.record(draft, action: action)
        publishDraft(editHistory.currentDraft)
        if outcome == .historyResetOversized {
            historyLimitMessage = RiffaLocalization.string(
                "This edit exceeded the bounded Undo history. The edit was kept, but earlier Undo and Redo steps were cleared."
            )
        }
    }

    private func resetDraft(_ draft: TextMergeDraft) {
        draftDocumentGeneration &+= 1
        editHistory.reset(to: draft)
        cleanDraft = draft
        historyLimitMessage = nil
        publishDraft(draft)
    }

    private func publishDraft(_ draft: TextMergeDraft) {
        outputText = draft.outputText
        resolutions = draft.resolutions
        hasUnsavedMergeWork = draft != cleanDraft
    }

    private func markCleanDraft(_ draft: TextMergeDraft) {
        cleanDraft = draft
        hasUnsavedMergeWork = editHistory.currentDraft != cleanDraft
    }

    private func decodedDocument(for side: InputSide) -> DecodedTextDocument? {
        switch side {
        case .base: baseDecodedDocument
        case .left: leftDecodedDocument
        case .right: rightDecodedDocument
        }
    }

    private func backingURL(for side: InputSide) -> URL? {
        switch side {
        case .base: baseBackingURL
        case .left: leftBackingURL
        case .right: rightBackingURL
        }
    }

    private func matchingInputSide(for destination: URL) -> InputSide? {
        for side in [InputSide.left, .right, .base] {
            if let inputURL = backingURL(for: side),
               Self.sameFileLocation(destination, inputURL) {
                return side
            }
        }
        return nil
    }

    private func installLoadedDocument(
        _ document: DecodedTextDocument,
        from url: URL,
        for side: InputSide
    ) {
        switch side {
        case .base:
            baseURL = url
            baseBackingURL = url
            baseDecodedDocument = document
            baseText = document.text
        case .left:
            leftURL = url
            leftBackingURL = url
            leftDecodedDocument = document
            leftText = document.text
        case .right:
            rightURL = url
            rightBackingURL = url
            rightDecodedDocument = document
            rightText = document.text
        }
        establishExternalBaseline(for: side)
        startMonitoring(side)
    }

    private func installSavedDocument(
        _ document: DecodedTextDocument,
        for side: InputSide
    ) {
        switch side {
        case .base:
            baseDecodedDocument = document
            baseText = document.text
        case .left:
            leftDecodedDocument = document
            leftText = document.text
        case .right:
            rightDecodedDocument = document
            rightText = document.text
        }
        establishExternalBaseline(for: side)
        startMonitoring(side)
    }

    private func installSavedBaselineOnly(
        _ document: DecodedTextDocument,
        for side: InputSide
    ) {
        switch side {
        case .base: baseDecodedDocument = document
        case .left: leftDecodedDocument = document
        case .right: rightDecodedDocument = document
        }
        establishExternalBaseline(for: side)
        startMonitoring(side)
        hasUnsavedMergeWork = editHistory.currentDraft != cleanDraft
    }

    private func invalidateLoad(for side: InputSide) {
        switch side {
        case .base:
            baseLoadTask?.cancel()
            baseLoadTask = nil
            baseLoadGeneration &+= 1
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
        for side in InputSide.allCases {
            invalidateLoad(for: side)
        }
    }

    private func loadGeneration(for side: InputSide) -> Int {
        switch side {
        case .base: baseLoadGeneration
        case .left: leftLoadGeneration
        case .right: rightLoadGeneration
        }
    }

    private func setLoadTask(_ task: Task<Void, Never>, for side: InputSide) {
        switch side {
        case .base: baseLoadTask = task
        case .left: leftLoadTask = task
        case .right: rightLoadTask = task
        }
    }

    private func clearLoadTask(for side: InputSide, generation: Int) {
        guard loadGeneration(for: side) == generation else { return }
        switch side {
        case .base: baseLoadTask = nil
        case .left: leftLoadTask = nil
        case .right: rightLoadTask = nil
        }
    }

    private func startMonitoring(_ side: InputSide) {
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

    private func stopMonitoring(_ side: InputSide) {
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
        for side: InputSide
    ) {
        var state = externalChangeStates[side, default: .init()]
        state.observe(change)
        externalChangeStates[side] = state
        publishExternalChange(for: side)
    }

    private func establishExternalBaseline(for side: InputSide) {
        var state = externalChangeStates[side, default: .init()]
        state.establishBaseline()
        externalChangeStates[side] = state
        publishExternalChange(for: side)
    }

    private func publishExternalChange(for side: InputSide) {
        externalChanges[side] = externalChangeStates[side]?.pendingChange
    }

    private func confirmDiscardMergeWorkAndReload(
        side: InputSide,
        fileURL: URL
    ) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = RiffaLocalization.string(
            "Discard unsaved merge work?"
        )
        let sideTitle = RiffaLocalization.string(side.rawValue)
        alert.informativeText = String(
            localized: "Reloading the \(sideTitle) input \(fileURL.lastPathComponent) recomputes the merge and discards current resolutions or output edits. Save the result first if you want to keep them.",
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
                localized: "\(fileURL.lastPathComponent) changed outside Riffa, so the merged result was not written. Reload that input and merge again.",
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

    private static func editActionTitle(
        _ action: TextMergeEditAction
    ) -> RiffaUndoRedoTitle.Action {
        switch action {
        case .manualOutputEdit:
            .editMergedOutput
        case let .conflictResolution(conflictID):
            if conflictID == Int.max {
                .resolveConflict(number: nil)
            } else {
                .resolveConflict(number: conflictID + 1)
            }
        }
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

struct TextMergeView: View {
    @StateObject private var model = TextMergeModel()
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
            pathBar
            if !model.sidesWithExternalChanges.isEmpty {
                RiffaHairline()
                externalChangeBanner
            }

            if let result = model.result {
                mergeContent(result)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Text Merge")
        .background(theme.canvas)
        .focusedSceneValue(\.riffaUndoRedoActions, undoRedoActions)
        .task(id: ComparisonInitialLoad(urls: initialURLs, options: initialOptions)) {
            model.openInitial(initialURLs, options: initialOptions)
        }
        .alert(
            "Text merge error",
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
    }

    private var undoRedoActions: RiffaUndoRedoActions {
        RiffaUndoRedoActions(
            undoTitle: model.undoCommandTitle,
            redoTitle: model.redoCommandTitle,
            canUndo: model.canUndo,
            canRedo: model.canRedo,
            undo: { model.undo() },
            redo: { model.redo() }
        )
    }

    private var header: some View {
        RiffaComparisonHeader(
            title: "Text Merge",
            subtitle: "Three-way merge against a common base"
        ) {
            SessionSaveButton(
                request: SessionSaveRequest(
                    kind: .textMerge,
                    urls: [model.baseURL, model.leftURL, model.rightURL].compactMap { $0 }
                ),
                errorMessage: $model.errorMessage
            )

            if let result = model.result {
                if result.hasConflicts {
                    Label(
                        "\(model.unresolvedConflictCount) unresolved",
                        systemImage: model.unresolvedConflictCount == 0
                            ? "checkmark.circle.fill"
                            : "exclamationmark.triangle.fill"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(
                        model.unresolvedConflictCount == 0 ? theme.success : theme.warning
                    )
                } else {
                    Label("Merged automatically", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.success)
                }
            }

            Button("Load Demo") {
                model.loadDemo()
            }
            .buttonStyle(.riffaTertiary)

            Button {
                model.saveOutput()
            } label: {
                Label("Save Result…", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.riffaPrimary)
            .disabled(!model.canSave)
            .help(
                model.unresolvedConflictCount > 0
                    ? RiffaLocalization.string(
                        "Resolve every conflict before saving"
                    )
                    : RiffaLocalization.string(
                        "Save using the preferred input encoding and BOM"
                    )
            )
        }
    }

    private var pathBar: some View {
        RiffaComparisonPathBar {
            MergeFileButton(
                title: "Base file",
                url: model.url(for: .base),
                symbol: "circle.dashed"
            ) {
                model.chooseFile(for: .base)
            }

            MergeFileButton(
                title: "Left file",
                url: model.url(for: .left),
                symbol: "arrow.left"
            ) {
                model.chooseFile(for: .left)
            }

            MergeFileButton(
                title: "Right file",
                url: model.url(for: .right),
                symbol: "arrow.right"
            ) {
                model.chooseFile(for: .right)
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
                            Text(externalChangeTitle(change, side: side))
                                .font(.subheadline.weight(.semibold))
                            Text(externalChangeDetail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Reload") {
                            model.reloadAfterExternalChange(for: side)
                        }
                        .help("Reload through Riffa's bounded text decoder and recompute the merge")
                        Button("Keep Current") {
                            model.keepCurrentAfterExternalChange(for: side)
                        }
                        .help("Keep the current merge work and review the input later")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(theme.warning.opacity(0.1))
                    .accessibilityElement(children: .contain)
                }
            }
        }
    }

    private func externalChangeTitle(
        _ change: TextExternalFileChangeKind,
        side: TextMergeModel.InputSide
    ) -> String {
        let sideTitle = RiffaLocalization.string(side.rawValue).lowercased()
        let name = model.url(for: side)?.lastPathComponent
            ?? String(
                localized: "The \(sideTitle) file",
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

    private var externalChangeDetail: String {
        if model.hasUnsavedMergeWork {
            return RiffaLocalization.string(
                "Current resolutions and output edits are preserved. Save the result first or confirm before reloading."
            )
        }
        return RiffaLocalization.string(
            "Reload to recompute from the current input, or keep this merge and review the change later."
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

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Choose three text files", systemImage: "arrow.triangle.branch")
        } description: {
            Text("Riffa combines Left and Right changes relative to Base, entirely on this Mac.")
        } actions: {
            HStack {
                Button("Choose Base") { model.chooseFile(for: .base) }
                    .buttonStyle(.riffaPrimary)
                Button("Choose Left") { model.chooseFile(for: .left) }
                    .buttonStyle(.riffaSecondary)
                Button("Choose Right") { model.chooseFile(for: .right) }
                    .buttonStyle(.riffaSecondary)
                Button("Load Demo") { model.loadDemo() }
                    .buttonStyle(.riffaTertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func mergeContent(_ result: ThreeWayMergeResult) -> some View {
        HSplitView {
            conflictsPane(result)
                .frame(minWidth: 340, idealWidth: 430, maxWidth: 560)

            outputPane(result)
                .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func conflictsPane(_ result: ThreeWayMergeResult) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("CONFLICTS")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                if result.hasConflicts {
                    Text("\(model.resolvedConflictCount) of \(result.conflicts.count) resolved")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(theme.surface(.one))

            Divider()

            if result.conflicts.isEmpty {
                ContentUnavailableView {
                    Label("No conflicts", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(theme.success)
                } description: {
                    Text("Left and Right changes were combined automatically.")
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(result.conflicts) { conflict in
                            MergeConflictCard(
                                conflict: conflict,
                                resolution: Binding(
                                    get: {
                                        model.resolutions[conflict.id, default: .unresolved]
                                    },
                                    set: { model.resolve(conflictID: conflict.id, using: $0) }
                                )
                            )
                        }
                    }
                    .padding(12)
                }
            }
        }
        .background(theme.canvas)
    }

    private func outputPane(_ result: ThreeWayMergeResult) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("MERGED OUTPUT")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .disabled(!model.canUndo)
                .help(model.undoTitle)
                .accessibilityLabel(model.undoTitle)
                .accessibilityHint("Restores the previous merged output and conflict choices")

                Button {
                    model.redo()
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                }
                .buttonStyle(.borderless)
                .disabled(!model.canRedo)
                .help(model.redoTitle)
                .accessibilityLabel(model.redoTitle)
                .accessibilityHint("Reapplies the next merged output and conflict choices")

                Text("\(model.outputFormatDescription) when saved")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(theme.surface(.one))

            Divider()

            BoundedMergeTextEditor(
                text: Binding(
                    get: { model.outputText },
                    set: { model.editOutput($0) }
                ),
                accessibilityLabel: RiffaLocalization.string(
                    "Editable merged output"
                ),
                accessibilityHint: RiffaLocalization.string(
                    "Resolve every conflict, then edit or save the merged text. Undo and Redo also restore conflict choices"
                )
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()

            HStack(spacing: 12) {
                if result.hasConflicts {
                    Label(
                        "\(model.unresolvedConflictCount) unresolved",
                        systemImage: model.unresolvedConflictCount == 0
                            ? "checkmark.circle.fill"
                            : "exclamationmark.triangle"
                    )
                    .foregroundStyle(
                        model.unresolvedConflictCount == 0
                            ? theme.success
                            : theme.warning
                    )
                } else {
                    Label("Ready to save", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(theme.success)
                }
                if let historyLimitMessage = model.historyLimitMessage {
                    Label("Undo history reset", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                        .foregroundStyle(theme.warning)
                        .lineLimit(1)
                        .help(historyLimitMessage)
                        .accessibilityLabel("Undo history notice")
                        .accessibilityValue(historyLimitMessage)
                }
                Spacer()
                Text("\(model.outputEncodedByteCount) encoded bytes")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(theme.surface(.one))
        }
    }
}

private struct BoundedMergeTextEditor: NSViewRepresentable {
    @Binding var text: String
    let accessibilityLabel: String
    let accessibilityHint: String
    @Environment(\.riffaTheme) private var theme

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

        textView.delegate = context.coordinator
        textView.string = text
        textView.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        textView.textColor = theme.nsInk
        textView.backgroundColor = theme.nsCanvas
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.usesFindPanel = true
        textView.setAccessibilityLabel(accessibilityLabel)
        textView.setAccessibilityHelp(accessibilityHint)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = theme.nsCanvas
        applyTheme(to: scrollView, textView: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        applyTheme(to: scrollView, textView: textView)
        textView.setAccessibilityLabel(accessibilityLabel)
        textView.setAccessibilityHelp(accessibilityHint)
        guard !textView.string.utf8.elementsEqual(text.utf8) else { return }

        let selectedRanges = textView.selectedRanges
        context.coordinator.isInstallingModelText = true
        textView.string = text
        textView.selectedRanges = Self.clampedRanges(selectedRanges, for: text)
        context.coordinator.isInstallingModelText = false
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

    private static func clampedRanges(_ ranges: [NSValue], for text: String) -> [NSValue] {
        let utf16Length = (text as NSString).length
        return ranges.map { value in
            let range = value.rangeValue
            let location = min(range.location, utf16Length)
            let length = min(range.length, utf16Length - location)
            return NSValue(range: NSRange(location: location, length: length))
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: BoundedMergeTextEditor
        var isInstallingModelText = false

        init(parent: BoundedMergeTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isInstallingModelText,
                  let textView = notification.object as? NSTextView,
                  !parent.text.utf8.elementsEqual(textView.string.utf8) else { return }
            parent.text = textView.string
        }
    }
}

private struct MergeFileButton: View {
    let title: String
    let url: URL?
    let symbol: String
    let action: () -> Void

    var body: some View {
        RiffaResourcePathButton(
            title: title,
            url: url,
            emptyTitle: "Choose a file…",
            systemImage: symbol,
            accessibilityHint: "Choose a text file",
            action: action
        )
        .accessibilityValue(
            url?.path(percentEncoded: false)
                ?? RiffaLocalization.string("No file selected")
        )
    }
}

private struct MergeConflictCard: View {
    let conflict: ThreeWayMergeConflict
    @Binding var resolution: TextMergeModel.Resolution
    @Environment(\.riffaTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Conflict \(conflict.id + 1)", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.warning)
                Spacer()
                RiffaStatusBadge(
                    verbatim: resolution == .unresolved
                        ? RiffaLocalization.string("Unresolved")
                        : RiffaLocalization.string("Resolved"),
                    systemImage: resolution == .unresolved
                        ? "exclamationmark.triangle"
                        : "checkmark.circle",
                    tone: resolution == .unresolved ? .warning : .success
                )
                Text(rangeDescription(conflict.baseRange))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            MergeConflictVersion(
                title: "LEFT",
                text: conflict.leftText,
                range: conflict.leftRange,
                systemImage: "arrow.left"
            )
            MergeConflictVersion(
                title: "BASE",
                text: conflict.baseText,
                range: conflict.baseRange,
                systemImage: "circle.dashed"
            )
            MergeConflictVersion(
                title: "RIGHT",
                text: conflict.rightText,
                range: conflict.rightRange,
                systemImage: "arrow.right"
            )

            Picker("Resolution for conflict \(conflict.id + 1)", selection: $resolution) {
                ForEach(TextMergeModel.Resolution.allCases) { option in
                    Text(LocalizedStringKey(option.rawValue)).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityHint("Choose which version to place in the merged output")
        }
        .padding(12)
        .background(theme.surface(.one), in: RoundedRectangle(cornerRadius: RiffaRadius.lg))
        .overlay {
            RoundedRectangle(cornerRadius: RiffaRadius.lg)
                .strokeBorder(
                    resolution == .unresolved
                        ? theme.hairlineStrong
                        : theme.success.opacity(theme.usesIncreasedContrast ? 1 : 0.65),
                    lineWidth: theme.usesIncreasedContrast ? 2 : 1
                )
        }
        .accessibilityElement(children: .contain)
    }

    private func rangeDescription(_ range: DiffLineRange) -> String {
        if range.count == 0 {
            return String(
                localized: "at base line \(range.start + 1)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
        if range.count == 1 {
            return String(
                localized: "base line \(range.start + 1)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
        return String(
            localized: "base lines \(range.start + 1)–\(range.end)",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
    }
}

private struct MergeConflictVersion: View {
    let title: String
    let text: String
    let range: DiffLineRange
    let systemImage: String
    @Environment(\.riffaTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: systemImage)
                    .foregroundStyle(theme.inkSubtle)
                Text(verbatim: localizedTitle)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(theme.inkMuted)
                Spacer()
                Text(lineDescription)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Text(
                verbatim: text.isEmpty
                    ? RiffaLocalization.string("∅  Empty")
                    : text
            )
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(text.isEmpty ? .secondary : .primary)
                .lineLimit(5)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(7)
                .background(theme.surface(.two), in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(theme.hairline)
                }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var localizedTitle: String {
        RiffaLocalization.string(title)
    }

    private var accessibilityLabel: String {
        let displayedText = text.isEmpty
            ? RiffaLocalization.string("empty")
            : text
        return String(
            localized: "\(localizedTitle), \(lineDescription), \(displayedText)",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
    }

    private var lineDescription: String {
        if range.count == 0 {
            return String(
                localized: "insertion at \(range.start + 1)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
        if range.count == 1 {
            return String(
                localized: "line \(range.start + 1)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
        return String(
            localized: "lines \(range.start + 1)–\(range.end)",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
    }
}
