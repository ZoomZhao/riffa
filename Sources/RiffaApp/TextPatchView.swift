import AppKit
import Foundation
import RiffaCore
import SwiftUI
import UniformTypeIdentifiers

private struct TextPatchHunkSummary: Identifiable, Sendable {
    let id: Int
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
    let heading: String?
    let additions: Int
    let deletions: Int
}

private struct TextPatchRecordSummary: Identifiable, Sendable {
    let id: Int
    let oldLabel: String
    let newLabel: String
    let hunkCount: Int
    let additions: Int
    let deletions: Int
    let hunks: [TextPatchHunkSummary]
}

private struct LoadedTextPatch: Sendable {
    let sourcePreview: String
    let sourcePreviewWasTruncated: Bool
    let patch: UnifiedPatch
    let records: [TextPatchRecordSummary]
}

private struct AppliedTextPatchPreview: Sendable {
    let text: String
    let lineCount: Int
}

private enum TextPatchSessionError: Error, LocalizedError {
    case emptyPatch
    case recordSelectionRequired
    case selectedRecordUnavailable
    case targetUnavailable

    var errorDescription: String? {
        switch self {
        case .emptyPatch:
            RiffaLocalization.string(
                "The unified diff does not contain a file record."
            )
        case .recordSelectionRequired:
            RiffaLocalization.string(
                "Choose the patch file record that belongs to the target. Riffa will not infer it from a path label."
            )
        case .selectedRecordUnavailable:
            RiffaLocalization.string(
                "The selected patch file record is no longer available. Choose it again."
            )
        case .targetUnavailable:
            RiffaLocalization.string(
                "Choose a target text file before building the patched preview."
            )
        }
    }
}

private actor TextPatchWorker {
    private static let patchByteLimit = 16 * 1_024 * 1_024
    private static let targetByteLimit = 32 * 1_024 * 1_024
    private static let sourcePreviewCharacterLimit = 100_000

    private let patchReader = BoundedLocalFileReader(
        limits: .init(maximumByteCount: patchByteLimit)
    )
    private let targetReader = BoundedLocalFileReader(
        limits: .init(maximumByteCount: targetByteLimit)
    )
    private let patchDocumentStore = DecodedTextDocumentStore(
        limits: .init(maximumByteCount: UInt64(patchByteLimit))
    )
    private let targetDocumentStore = DecodedTextDocumentStore(
        limits: .init(maximumByteCount: UInt64(targetByteLimit))
    )

    func loadPatch(from url: URL) throws -> LoadedTextPatch {
        let data = try patchReader.read(url: url)
        try Task.checkCancellation()
        let document = try patchDocumentStore.decode(data)
        let patch = try UnifiedPatchParser(
            maximumLineCount: 500_000,
            maximumLineUTF8ByteCount: 256 * 1_024
        ).parse(document.text)
        guard !patch.files.isEmpty else { throw TextPatchSessionError.emptyPatch }
        try Task.checkCancellation()

        let records = patch.files.map { file in
            var additions = 0
            var deletions = 0
            let hunks = file.hunks.map { hunk in
                var hunkAdditions = 0
                var hunkDeletions = 0
                for line in hunk.lines {
                    switch line.kind {
                    case .addition: hunkAdditions += 1
                    case .deletion: hunkDeletions += 1
                    case .context: break
                    }
                }
                additions += hunkAdditions
                deletions += hunkDeletions
                return TextPatchHunkSummary(
                    id: hunk.index,
                    oldStart: hunk.oldRange.start,
                    oldCount: hunk.oldRange.count,
                    newStart: hunk.newRange.start,
                    newCount: hunk.newRange.count,
                    heading: hunk.sectionHeading,
                    additions: hunkAdditions,
                    deletions: hunkDeletions
                )
            }
            return TextPatchRecordSummary(
                id: file.index,
                oldLabel: file.oldLabel,
                newLabel: file.newLabel,
                hunkCount: file.hunks.count,
                additions: additions,
                deletions: deletions,
                hunks: hunks
            )
        }
        let previewPrefix = document.text.prefix(Self.sourcePreviewCharacterLimit + 1)
        let previewWasTruncated = previewPrefix.count > Self.sourcePreviewCharacterLimit
        return LoadedTextPatch(
            sourcePreview: String(previewPrefix.prefix(Self.sourcePreviewCharacterLimit)),
            sourcePreviewWasTruncated: previewWasTruncated,
            patch: patch,
            records: records
        )
    }

    func loadTarget(from url: URL) throws -> DecodedTextDocument {
        let data = try targetReader.read(url: url)
        try Task.checkCancellation()
        return try targetDocumentStore.decode(data)
    }

    func apply(
        file: UnifiedPatchFile,
        to target: DecodedTextDocument
    ) throws -> AppliedTextPatchPreview {
        let output = try UnifiedPatchApplier().apply(
            file,
            to: TextDocument(text: target.text)
        )
        try Task.checkCancellation()
        return AppliedTextPatchPreview(text: output.text, lineCount: output.lines.count)
    }

    func saveAs(
        text: String,
        basedOn target: DecodedTextDocument,
        to url: URL
    ) async throws -> DecodedTextFileFingerprint {
        try await targetDocumentStore.save(target.replacingText(with: text), to: url)
    }

    func saveInPlace(
        text: String,
        target: DecodedTextDocument,
        to url: URL
    ) async throws -> DecodedTextFileFingerprint {
        try await targetDocumentStore.save(
            target.replacingText(with: text),
            to: url,
            ifContentsMatch: target.fingerprint
        )
    }
}

private let textPatchWorker = TextPatchWorker()

@MainActor
private final class TextPatchModel: ObservableObject {
    @Published private(set) var patchURL: URL?
    @Published private(set) var targetURL: URL?
    @Published private(set) var patchText = ""
    @Published private(set) var patchSourcePreviewWasTruncated = false
    @Published private(set) var patch: UnifiedPatch?
    @Published private(set) var records: [TextPatchRecordSummary] = []
    @Published private(set) var targetDocument: DecodedTextDocument?
    @Published private(set) var selectedFileIndex: Int?
    @Published var outputDraft = ""
    @Published private(set) var outputLineCount: Int?
    @Published private(set) var isLoadingPatch = false
    @Published private(set) var isLoadingTarget = false
    @Published private(set) var isApplying = false
    @Published private(set) var isSaving = false
    @Published var errorMessage: String?
    @Published private(set) var statusMessage: String?

    private var patchTask: Task<Void, Never>?
    private var targetTask: Task<Void, Never>?
    private var applyTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var saveToken: UUID?
    private var savedOutputDraft: String?

    var selectedRecord: TextPatchRecordSummary? {
        guard let selectedFileIndex else { return nil }
        return records.first { $0.id == selectedFileIndex }
    }

    var hasPreview: Bool { outputLineCount != nil }

    var hasEditedPreview: Bool {
        guard hasPreview, let savedOutputDraft else { return false }
        return outputDraft != savedOutputDraft
    }

    var canBuildPreview: Bool {
        patch != nil && selectedFileIndex != nil && targetDocument != nil
            && !isLoadingPatch && !isLoadingTarget && !isApplying && !isSaving
    }

    var selectedFileOption: Int64 {
        Int64(selectedFileIndex ?? -1)
    }

    func choosePatch(accessRegistry: SecurityScopedAccessRegistry) {
        guard !isSaving else {
            reportSaveInProgress()
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = RiffaLocalization.string("Choose Unified Diff")
        panel.message = RiffaLocalization.string(
            "Choose a bounded .patch or .diff file. Multi-file patches require an explicit file-record selection."
        )
        panel.prompt = RiffaLocalization.string("Choose")
        panel.allowedContentTypes = ["patch", "diff"].compactMap {
            UTType(filenameExtension: $0)
        }
        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
        do {
            let url = try accessRegistry.registerIncomingURL(selectedURL)
            setPatch(url)
        } catch {
            errorMessage = String(
                localized: "Could not preserve sandbox access for \(selectedURL.lastPathComponent). Re-select the patch file.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
    }

    func chooseTarget(accessRegistry: SecurityScopedAccessRegistry) {
        guard !isSaving else {
            reportSaveInProgress()
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = RiffaLocalization.string("Choose Target Text File")
        panel.message = RiffaLocalization.string(
            "The target is read with a strict byte limit. It is not modified until you explicitly confirm Apply to Target."
        )
        panel.prompt = RiffaLocalization.string("Choose")
        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
        do {
            let url = try accessRegistry.registerIncomingURL(selectedURL)
            setTarget(url)
        } catch {
            errorMessage = String(
                localized: "Could not preserve sandbox access for \(selectedURL.lastPathComponent). Re-select the target file.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
    }

    func setPatch(_ url: URL) {
        guard canInvalidatePreview() else { return }
        loadPatch(
            from: url.standardizedFileURL,
            preferredFileIndex: nil
        )
    }

    func setTarget(_ url: URL) {
        guard canInvalidatePreview() else { return }
        loadTarget(from: url.standardizedFileURL)
    }

    func openInitial(_ urls: [URL], options: [String: String]) {
        guard canInvalidatePreview() else { return }
        patchTask?.cancel()
        targetTask?.cancel()
        applyTask?.cancel()
        let preferredIndex = options.riffaInteger(for: "selectedFileIndex").flatMap(Int.init(exactly:))
        if let patchURL = urls.first {
            loadPatch(
                from: patchURL,
                preferredFileIndex: preferredIndex.flatMap { $0 >= 0 ? $0 : nil }
            )
        }
        if urls.count > 1 { loadTarget(from: urls[1]) }
    }

    func selectFileRecord(_ fileIndex: Int?) {
        guard fileIndex != selectedFileIndex else { return }
        guard canInvalidatePreview() else { return }
        selectedFileIndex = fileIndex
        invalidatePreview()
    }

    func buildPreview() {
        guard canInvalidatePreview() else { return }
        guard let patch else {
            errorMessage = RiffaLocalization.string(
                "Choose a unified diff before building a preview."
            )
            return
        }
        guard let selectedFileIndex else {
            errorMessage = TextPatchSessionError.recordSelectionRequired.localizedDescription
            return
        }
        guard let file = patch.files.first(where: { $0.index == selectedFileIndex }) else {
            errorMessage = TextPatchSessionError.selectedRecordUnavailable.localizedDescription
            return
        }
        guard let targetDocument else {
            errorMessage = TextPatchSessionError.targetUnavailable.localizedDescription
            return
        }

        invalidatePreview()
        isApplying = true
        statusMessage = nil
        errorMessage = nil
        applyTask = Task { [weak self] in
            do {
                let preview = try await textPatchWorker.apply(file: file, to: targetDocument)
                try Task.checkCancellation()
                guard let self,
                      self.selectedFileIndex == selectedFileIndex,
                      self.targetDocument == targetDocument
                else { return }
                self.outputDraft = preview.text
                self.savedOutputDraft = preview.text
                self.outputLineCount = preview.lineCount
                self.isApplying = false
                self.statusMessage = RiffaLocalization.string(
                    "Every hunk validated. Review or edit the in-memory result before saving."
                )
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.isApplying = false
                self.invalidatePreview()
                self.errorMessage = String(
                    localized: "The selected patch record does not apply cleanly to the target: \(error.localizedDescription)",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
            }
        }
    }

    func saveAs() {
        guard hasPreview, let targetDocument, !isSaving else {
            if isSaving { reportSaveInProgress() }
            return
        }
        let panel = NSSavePanel()
        panel.title = RiffaLocalization.string("Save Patched Text As")
        panel.prompt = RiffaLocalization.string("Save")
        panel.message = String(
            localized: "The output keeps the target's \(Self.formatDescription(targetDocument.format)) encoding.",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
        panel.nameFieldStringValue = suggestedOutputName
        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }
        guard !Self.sameFileLocation(destinationURL, targetURL) else {
            errorMessage = RiffaLocalization.string(
                "Use Apply to Target to replace the original file. That action requires explicit confirmation and an external-change check."
            )
            return
        }

        let output = outputDraft
        beginSave {
            try await textPatchWorker.saveAs(
                text: output,
                basedOn: targetDocument,
                to: destinationURL
            )
        } success: { _ in
            self.savedOutputDraft = output
            self.statusMessage = String(
                localized: "Saved the reviewed output as \(destinationURL.lastPathComponent).",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        } failurePrefix: {
            String(
                localized: "Could not save \(destinationURL.lastPathComponent)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
    }

    func applyToTarget() {
        guard !isSaving else {
            reportSaveInProgress()
            return
        }
        guard hasPreview,
              let targetURL,
              let targetDocument,
              confirmInPlaceApply(targetURL: targetURL, format: targetDocument.format)
        else { return }
        let output = outputDraft

        beginSave {
            try await textPatchWorker.saveInPlace(
                text: output,
                target: targetDocument,
                to: targetURL
            )
        } success: { fingerprint in
            self.savedOutputDraft = output
            self.targetDocument = DecodedTextDocument(
                text: output,
                format: targetDocument.format,
                fingerprint: fingerprint
            )
            self.statusMessage = String(
                localized: "Applied the reviewed output to \(targetURL.lastPathComponent).",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        } failurePrefix: {
            String(
                localized: "Could not replace \(targetURL.lastPathComponent)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
    }

    private func loadPatch(from url: URL, preferredFileIndex: Int?) {
        patchTask?.cancel()
        applyTask?.cancel()
        patchURL = url.standardizedFileURL
        patch = nil
        patchText = ""
        patchSourcePreviewWasTruncated = false
        records = []
        selectedFileIndex = nil
        invalidatePreview()
        isLoadingPatch = true
        statusMessage = nil
        errorMessage = nil

        patchTask = Task { [weak self] in
            do {
                let loaded = try await textPatchWorker.loadPatch(from: url)
                try Task.checkCancellation()
                guard let self, self.patchURL == url.standardizedFileURL else { return }
                self.patchText = loaded.sourcePreview
                self.patchSourcePreviewWasTruncated = loaded.sourcePreviewWasTruncated
                self.patch = loaded.patch
                self.records = loaded.records
                if loaded.records.count == 1 {
                    self.selectedFileIndex = loaded.records[0].id
                } else if let preferredFileIndex,
                          loaded.records.contains(where: { $0.id == preferredFileIndex }) {
                    self.selectedFileIndex = preferredFileIndex
                } else {
                    self.selectedFileIndex = nil
                }
                self.isLoadingPatch = false
                self.statusMessage = loaded.records.count == 1
                    ? RiffaLocalization.string(
                        "Loaded one patch file record."
                    )
                    : String(
                        localized: "Loaded \(loaded.records.count) file records. Choose the exact record for the target.",
                        bundle: RiffaLocalization.localizedBundle,
                        locale: RiffaLocalization.locale
                    )
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.isLoadingPatch = false
                self.errorMessage = String(
                    localized: "Could not load \(url.lastPathComponent): \(error.localizedDescription)",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
            }
        }
    }

    private func loadTarget(from url: URL) {
        targetTask?.cancel()
        applyTask?.cancel()
        targetURL = url.standardizedFileURL
        targetDocument = nil
        invalidatePreview()
        isLoadingTarget = true
        statusMessage = nil
        errorMessage = nil

        targetTask = Task { [weak self] in
            do {
                let document = try await textPatchWorker.loadTarget(from: url)
                try Task.checkCancellation()
                guard let self, self.targetURL == url.standardizedFileURL else { return }
                self.targetDocument = document
                self.isLoadingTarget = false
                self.statusMessage = RiffaLocalization.string(
                    "Loaded the target without modifying it."
                )
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.isLoadingTarget = false
                self.errorMessage = String(
                    localized: "Could not load \(url.lastPathComponent): \(error.localizedDescription)",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
            }
        }
    }

    private func beginSave(
        operation: @escaping @Sendable () async throws -> DecodedTextFileFingerprint,
        success: @escaping @MainActor (DecodedTextFileFingerprint) -> Void,
        failurePrefix: @escaping @MainActor () -> String
    ) {
        guard !isSaving else {
            reportSaveInProgress()
            return
        }
        let token = UUID()
        saveToken = token
        isSaving = true
        errorMessage = nil
        saveTask = Task { [weak self] in
            do {
                let fingerprint = try await operation()
                try Task.checkCancellation()
                guard let self, self.saveToken == token else { return }
                self.isSaving = false
                self.saveToken = nil
                self.saveTask = nil
                success(fingerprint)
            } catch is CancellationError {
                guard let self, self.saveToken == token else { return }
                self.isSaving = false
                self.saveToken = nil
                self.saveTask = nil
            } catch {
                guard let self,
                      !Task.isCancelled,
                      self.saveToken == token
                else { return }
                self.isSaving = false
                self.saveToken = nil
                self.saveTask = nil
                if let documentError = error as? DecodedTextDocumentError,
                   documentError.code == .externalModification {
                    self.errorMessage = RiffaLocalization.string(
                        "The target changed outside Riffa, so it was not overwritten. Reload it and build the preview again."
                    )
                } else {
                    self.errorMessage = String(
                        localized: "\(failurePrefix()): \(error.localizedDescription)",
                        bundle: RiffaLocalization.localizedBundle,
                        locale: RiffaLocalization.locale
                    )
                }
            }
        }
    }

    private func invalidatePreview() {
        applyTask?.cancel()
        outputDraft = ""
        savedOutputDraft = nil
        outputLineCount = nil
        isApplying = false
    }

    private func canInvalidatePreview() -> Bool {
        guard !isSaving else {
            reportSaveInProgress()
            return false
        }
        return !hasEditedPreview || confirmDiscardEditedPreview()
    }

    private func reportSaveInProgress() {
        errorMessage = RiffaLocalization.string(
            "Wait for the current save to finish before changing inputs or drafts."
        )
    }

    private func confirmDiscardEditedPreview() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = RiffaLocalization.string(
            "Discard edited patched output?"
        )
        alert.informativeText = RiffaLocalization.string(
            "Changing an input or patch record discards edits made to the in-memory patched output."
        )
        alert.addButton(withTitle: RiffaLocalization.string("Discard Draft"))
        alert.addButton(withTitle: RiffaLocalization.string("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private var suggestedOutputName: String {
        guard let targetURL else {
            return RiffaLocalization.string("patched-output.txt")
        }
        let stem = targetURL.deletingPathExtension().lastPathComponent
        let fileExtension = targetURL.pathExtension
        if fileExtension.isEmpty {
            return String(
                localized: "\(stem)-patched.txt",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
        return String(
            localized: "\(stem)-patched.\(fileExtension)",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
    }

    private func confirmInPlaceApply(
        targetURL: URL,
        format: DecodedTextDocumentFormat
    ) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(
            localized: "Apply reviewed output to \(targetURL.lastPathComponent)?",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
        alert.informativeText = String(
            localized: "This atomically replaces the target using its \(Self.formatDescription(format)) representation. Riffa will refuse the write if the target's contents changed after loading.",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
        alert.addButton(
            withTitle: RiffaLocalization.string("Apply to Target")
        )
        alert.addButton(withTitle: RiffaLocalization.string("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func sameFileLocation(_ first: URL, _ second: URL?) -> Bool {
        guard let second else { return false }
        return first.standardizedFileURL.resolvingSymlinksInPath()
            == second.standardizedFileURL.resolvingSymlinksInPath()
    }

    static func formatDescription(_ format: DecodedTextDocumentFormat) -> String {
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

struct TextPatchView: View {
    @EnvironmentObject private var securityScopedAccessRegistry: SecurityScopedAccessRegistry
    @StateObject private var model = TextPatchModel()
    @Environment(\.riffaTheme) private var theme
    private let initialURLs: [URL]
    private let initialOptions: [String: String]

    init(initialURLs: [URL] = [], initialOptions: [String: String] = [:]) {
        self.initialURLs = initialURLs
        self.initialOptions = initialOptions
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            pathBar

            if model.isLoadingPatch || model.isLoadingTarget || model.isApplying {
                ProgressView(progressLabel)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.canvas)
            } else if model.patch != nil || model.targetDocument != nil {
                workspace
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Text Patch")
        .background(theme.canvas)
        .riffaWindowDropZones([
            RiffaDropZone(
                role: .patch,
                acceptedKind: .regularFileFollowingFinalSymbolicLink
            ) {
                model.setPatch($0)
            },
            RiffaDropZone(
                role: .target,
                acceptedKind: .regularFileFollowingFinalSymbolicLink
            ) {
                model.setTarget($0)
            }
        ])
        .alert(
            "Text patch error",
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
            title: "Text Patch",
            subtitle: "Strict unified-diff review and guarded application"
        ) {
            SessionSaveButton(
                request: SessionSaveRequest(
                    kind: .textPatch,
                    urls: [model.patchURL, model.targetURL].compactMap { $0 },
                    options: ["selectedFileIndex": .integer(model.selectedFileOption)]
                ),
                errorMessage: $model.errorMessage
            )

            Button {
                model.buildPreview()
            } label: {
                Label("Build Preview", systemImage: "doc.text.magnifyingglass")
            }
            .buttonStyle(.riffaSecondary)
                .disabled(!model.canBuildPreview)

            Button {
                model.saveAs()
            } label: {
                Label("Save As…", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.riffaSecondary)
                .disabled(!model.hasPreview || model.isSaving)

            Button(role: .destructive) {
                model.applyToTarget()
            } label: {
                Label("Apply to Target…", systemImage: "checkmark.shield")
            }
            .buttonStyle(.riffaPrimary)
                .disabled(!model.hasPreview || model.isSaving)
        }
    }

    private var pathBar: some View {
        RiffaComparisonPathBar {
            RiffaResourcePathButton(
                title: "Patch file",
                url: model.patchURL,
                emptyTitle: "Choose a unified diff…",
                systemImage: "doc.badge.arrow.up",
                accessibilityHint: "Choose the unified diff to review"
            ) {
                model.choosePatch(accessRegistry: securityScopedAccessRegistry)
            }
            .riffaResourceDropTarget(
                role: .patch,
                acceptedKind: .regularFileFollowingFinalSymbolicLink
            ) {
                model.setPatch($0)
            }

            Image(systemName: "arrow.right")
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(theme.inkTertiary)
                .accessibilityHidden(true)

            RiffaResourcePathButton(
                title: "Target root",
                url: model.targetURL,
                emptyTitle: "Choose the target text…",
                systemImage: "doc.text",
                accessibilityHint: "Choose the local text file to patch"
            ) {
                model.chooseTarget(accessRegistry: securityScopedAccessRegistry)
            }
            .riffaResourceDropTarget(
                role: .target,
                acceptedKind: .regularFileFollowingFinalSymbolicLink
            ) {
                model.setTarget($0)
            }
        }
    }

    private var workspace: some View {
        VStack(spacing: 0) {
            if let status = model.statusMessage {
                RiffaStatusBar {
                    Label(status, systemImage: "checkmark.shield")
                        .foregroundStyle(theme.inkMuted)
                    Spacer()
                    RiffaStatusBadge(
                        "Read-only preview",
                        systemImage: "eye",
                        tone: .secure
                    )
                }
            }

            HSplitView {
                recordSidebar
                    .frame(minWidth: 280, idealWidth: 340, maxWidth: 440)
                previewArea
                    .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(theme.canvas)
        }
    }

    private var recordSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            RiffaPaneHeader(
                "Patch file records",
                subtitle: String(
                    localized: "\(model.records.count) files",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                ),
                systemImage: "list.bullet.rectangle"
            ) {
                RiffaStatusBadge(
                    "\(model.records.count)",
                    systemImage: "doc.on.doc",
                    tone: .neutral
                )
            }

            if model.records.count > 1, model.selectedFileIndex == nil {
                Label(
                    "Select the exact record; labels are never matched automatically.",
                    systemImage: "cursorarrow.click.2"
                )
                .riffaText(.caption)
                .foregroundStyle(theme.warning)
                .padding(RiffaSpacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.warning.opacity(0.08))
            }

            List(selection: Binding(
                get: { model.selectedFileIndex },
                set: { model.selectFileRecord($0) }
            )) {
                ForEach(model.records) { record in
                    VStack(alignment: .leading, spacing: RiffaSpacing.xxs) {
                        Text(record.newLabel)
                            .riffaText(.bodySmall)
                            .foregroundStyle(theme.ink)
                            .lineLimit(1)
                        Text("from \(record.oldLabel)")
                            .riffaText(.caption)
                            .foregroundStyle(theme.inkSubtle)
                            .lineLimit(1)
                        HStack(spacing: RiffaSpacing.xs) {
                            Text("\(record.hunkCount) hunks")
                            Text("+\(record.additions)")
                                .foregroundStyle(theme.success)
                            Text("−\(record.deletions)")
                                .foregroundStyle(theme.danger)
                        }
                        .riffaText(.mono)
                    }
                    .tag(record.id)
                    .padding(.vertical, RiffaSpacing.xxs)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        String(
                            localized: "\(record.newLabel), \(record.hunkCount) hunks, \(record.additions) additions, \(record.deletions) deletions",
                            bundle: RiffaLocalization.localizedBundle,
                            locale: RiffaLocalization.locale
                        )
                    )
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(theme.surface(.one))

            if let record = model.selectedRecord {
                RiffaPaneHeader(
                    "Hunks",
                    subtitle: String(
                        localized: "\(record.hunkCount) in selected file",
                        bundle: RiffaLocalization.localizedBundle,
                        locale: RiffaLocalization.locale
                    ),
                    systemImage: "list.number"
                )
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: RiffaSpacing.xs) {
                        ForEach(record.hunks) { hunk in
                            VStack(alignment: .leading, spacing: RiffaSpacing.xxs) {
                                Text("@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@")
                                    .riffaText(.mono)
                                    .foregroundStyle(theme.ink)
                                if let heading = hunk.heading, !heading.isEmpty {
                                    Text(heading)
                                        .riffaText(.caption)
                                        .foregroundStyle(theme.inkSubtle)
                                        .lineLimit(2)
                                }
                                Text("+\(hunk.additions)  −\(hunk.deletions)")
                                    .riffaText(.mono)
                                    .foregroundStyle(theme.inkMuted)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(RiffaSpacing.xs)
                            .background(
                                theme.surface(.two),
                                in: RoundedRectangle(cornerRadius: RiffaRadius.md)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: RiffaRadius.md)
                                    .strokeBorder(theme.hairline, lineWidth: 1)
                            }
                        }
                    }
                    .padding(RiffaSpacing.sm)
                }
                .frame(minHeight: 120, idealHeight: 220, maxHeight: 300)
            }
        }
        .background(theme.surface(.one))
    }

    private var previewArea: some View {
        VSplitView {
            VStack(alignment: .leading, spacing: 0) {
                RiffaPaneHeader(
                    "Unified Preview",
                    subtitle: "Patch source — read only",
                    systemImage: "doc.text.magnifyingglass"
                ) {
                    if model.patchSourcePreviewWasTruncated {
                        RiffaStatusBadge(
                            "Preview limited",
                            systemImage: "ellipsis",
                            tone: .warning
                        )
                        .help("Preview limited to 100,000 characters")
                    }
                }

                ScrollView([.horizontal, .vertical]) {
                    Text(
                        verbatim: model.patchText.isEmpty
                            ? RiffaLocalization.string(
                                "Choose a unified diff to inspect its source."
                            )
                            : model.patchText
                    )
                        .riffaText(.mono)
                        .foregroundStyle(theme.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(RiffaSpacing.sm)
                }
                .background(theme.canvas)
            }
            .frame(minHeight: 180)

            VStack(alignment: .leading, spacing: 0) {
                RiffaPaneHeader(
                    "Patched output",
                    subtitle: "Editable in-memory result",
                    systemImage: "square.and.pencil"
                ) {
                    if let count = model.outputLineCount {
                        RiffaStatusBadge(
                            "\(count) lines",
                            systemImage: "line.3.horizontal",
                            tone: .neutral
                        )
                    }
                }

                if model.hasPreview {
                    TextEditor(text: $model.outputDraft)
                        .riffaText(.mono)
                        .foregroundStyle(theme.ink)
                        .scrollContentBackground(.hidden)
                        .padding(RiffaSpacing.xxs)
                        .background(theme.canvas)
                } else {
                    RiffaEmptyState(
                        title: "No patched output",
                        description: "Choose the exact patch record and target, "
                            + "then build a strictly validated preview.",
                        systemImage: "doc.text.magnifyingglass"
                    ) {
                        EmptyView()
                    }
                }
            }
            .frame(minHeight: 220)
        }
    }

    private var emptyState: some View {
        RiffaEmptyState(
            title: "Choose a patch and target",
            description: "Riffa parses bounded unified diffs, validates every "
                + "hunk in memory, and writes only after you review the result.",
            systemImage: SessionKind.textPatch.symbol
        ) {
            HStack {
                Button("Choose Patch…") {
                    model.choosePatch(accessRegistry: securityScopedAccessRegistry)
                }
                .buttonStyle(.riffaPrimary)
                Button("Choose Target…") {
                    model.chooseTarget(accessRegistry: securityScopedAccessRegistry)
                }
                .buttonStyle(.riffaSecondary)
            }
        }
    }

    private var progressLabel: String {
        if model.isApplying {
            return RiffaLocalization.string("Validating every patch hunk…")
        }
        if model.isLoadingPatch {
            return RiffaLocalization.string(
                "Reading and parsing the bounded unified diff…"
            )
        }
        return RiffaLocalization.string(
            "Reading and decoding the bounded target…"
        )
    }
}
