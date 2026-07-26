import AppKit
import Foundation
import RiffaCore
import SwiftUI

@MainActor
private final class TableCompareModel: ObservableObject {
    enum Side: String, CaseIterable, Identifiable, Hashable {
        case left = "Left"
        case right = "Right"

        var id: Self { self }
        var opposite: Self { self == .left ? .right : .left }
        var localizedTitle: String {
            RiffaLocalization.string(rawValue)
        }
    }

    nonisolated private static let maximumFileByteCount = 32 * 1_024 * 1_024
    nonisolated private static let maximumDisplayedRowCount = 20_000
    nonisolated static let maximumEditableFieldCount = 128
    nonisolated private static let parsingLimits = try! DelimitedTextParsingLimits(
        maximumInputUTF8ByteCount: maximumFileByteCount,
        maximumCharacterCount: 8 * 1_024 * 1_024,
        maximumRowCount: 100_000,
        maximumFieldCountPerRow: 1_024,
        maximumTotalFieldCount: 1_000_000,
        maximumFieldUTF8ByteCount: 1 * 1_024 * 1_024,
        maximumDiagnosticCount: 2_000
    )
    nonisolated private static let serializationLimits = try! DelimitedTextSerializationLimits(
        maximumRowCount: 100_000,
        maximumFieldCountPerRow: 1_024,
        maximumTotalFieldCount: 1_000_000,
        maximumFieldUTF8ByteCount: 1 * 1_024 * 1_024,
        maximumOutputUTF8ByteCount: maximumFileByteCount
    )

    enum DelimiterChoice: String, CaseIterable, Identifiable {
        case comma = "Comma"
        case tab = "Tab"
        case semicolon = "Semicolon"
        case pipe = "Pipe"
        var id: Self { self }
        var character: Character {
            switch self {
            case .comma: ","
            case .tab: "\t"
            case .semicolon: ";"
            case .pipe: "|"
            }
        }
    }

    @Published private(set) var leftURL: URL?
    @Published private(set) var rightURL: URL?
    @Published private(set) var result: TableComparisonResult?
    @Published private(set) var delimiter: DelimiterChoice = .comma
    @Published var alignByKey = false { didSet { compareIfReady() } }
    @Published var keyColumns = "0" { didSet { scheduleCompare() } }
    @Published var ignoreCase = false { didSet { compareIfReady() } }
    @Published var ignoreWhitespace = false { didSet { compareIfReady() } }
    @Published var showDifferencesOnly = false
    @Published var editSide: Side = .right
    @Published var selectedRowID: Int?
    @Published private(set) var dirtySides: Set<Side> = []
    @Published private(set) var loadingSides: Set<Side> = []
    @Published private(set) var savingSides: Set<Side> = []
    @Published var errorMessage: String?

    private let documentStore = DecodedTextDocumentStore(
        limits: .init(maximumByteCount: UInt64(maximumFileByteCount))
    )
    private var leftDocument: DecodedTextDocument?
    private var rightDocument: DecodedTextDocument?
    private var leftRows: [[String]]?
    private var rightRows: [[String]]?
    private var leftDiagnostics: [TableDiagnostic] = []
    private var rightDiagnostics: [TableDiagnostic] = []
    private var leftLineEnding: DelimitedTextLineEnding = .lineFeed
    private var rightLineEnding: DelimitedTextLineEnding = .lineFeed
    private var leftTerminatesLastRecord = false
    private var rightTerminatesLastRecord = false
    private var loadTasks: [Side: Task<Void, Never>] = [:]
    private var loadTokens: [Side: UUID] = [:]
    private var saveTasks: [Side: Task<Void, Never>] = [:]
    private var saveTokens: [Side: UUID] = [:]
    private var draftTokens = Dictionary(
        uniqueKeysWithValues: Side.allCases.map { ($0, UUID()) }
    )
    private var comparisonDebounceTask: Task<Void, Never>?

    var visibleRows: [TableComparisonRow] {
        guard let result else { return [] }
        if showDifferencesOnly {
            return Array(
                result.rows.lazy
                    .filter { $0.status != .same }
                    .prefix(Self.maximumDisplayedRowCount)
            )
        }
        return Array(result.rows.prefix(Self.maximumDisplayedRowCount))
    }

    var filteredRowCount: Int {
        guard let result else { return 0 }
        return showDifferencesOnly
            ? result.rows.reduce(into: 0) { if $1.status != .same { $0 += 1 } }
            : result.rows.count
    }

    var hasHiddenRows: Bool { filteredRowCount > visibleRows.count }

    var selectedRow: TableComparisonRow? {
        guard let selectedRowID, let result else { return nil }
        return result.rows.first { $0.id == selectedRowID }
    }

    var selectedFields: [String] {
        guard let row = selectedRow,
              let physicalIndex = physicalRowIndex(for: editSide, comparisonRow: row),
              let rows = rows(for: editSide),
              rows.indices.contains(physicalIndex)
        else { return [] }
        return rows[physicalIndex]
    }

    var unsafeEditingReason: String? {
        guard let result else { return nil }
        if result.diagnostics.contains(where: { Self.parserDiagnosticCodes.contains($0.code) }) {
            return RiffaLocalization.string(
                "Editing and Save As are disabled because malformed quoting would make rewriting lossy."
            )
        }
        if result.statistics.duplicateKeyRowCount > 0 {
            return RiffaLocalization.string(
                "Editing and Save As are disabled while composite keys are duplicated."
            )
        }
        return nil
    }

    var canEditSelectedCells: Bool {
        guard unsafeEditingReason == nil, let row = selectedRow else { return false }
        return row.left != nil
            && row.right != nil
            && (row.status == .same || row.status == .modified)
    }

    func canCopySelectedRow(from side: Side) -> Bool {
        guard unsafeEditingReason == nil, let row = selectedRow else { return false }
        return physicalRowIndex(for: side, comparisonRow: row) != nil
    }

    func canSaveOutput(for side: Side) -> Bool {
        unsafeEditingReason == nil
            && document(for: side) != nil
            && rows(for: side) != nil
            && !loadingSides.contains(side)
            && !savingSides.contains(side)
    }

    func chooseFile(for side: Side) {
        guard ensureNoSaveInProgress() else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = side == .left
            ? RiffaLocalization.string("Choose Left Delimited File")
            : RiffaLocalization.string("Choose Right Delimited File")
        panel.prompt = RiffaLocalization.string("Choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        replaceInput(with: url, for: side)
    }

    func replaceInput(with url: URL, for side: Side) {
        guard ensureNoSaveInProgress() else { return }
        let sideTitle = RiffaLocalization.string(side.rawValue).lowercased()
        guard !dirtySides.contains(side) || confirmDiscardDrafts(
            message: String(
                localized: "Choosing another \(sideTitle) file discards its edited output draft.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        ) else { return }
        load(url: url, for: side)
    }

    func openInitial(_ urls: [URL], options: [String: String] = [:]) {
        guard ensureNoSaveInProgress() else { return }
        guard dirtySides.isEmpty || confirmDiscardDrafts(
            message: RiffaLocalization.string(
                "Opening another saved table session discards the current output drafts."
            )
        ) else { return }
        let restoredDelimiter = options["delimiter"].flatMap(DelimiterChoice.init(rawValue:))
        if let restoredDelimiter {
            delimiter = restoredDelimiter
        }
        if let value = options.riffaBoolean(for: "alignByKey") {
            alignByKey = value
        }
        if let value = options["keyColumns"] {
            keyColumns = value
        }
        if let value = options.riffaBoolean(for: "ignoreCase") {
            ignoreCase = value
        }
        if let value = options.riffaBoolean(for: "ignoreWhitespace") {
            ignoreWhitespace = value
        }
        if let value = options.riffaBoolean(for: "showDifferencesOnly") {
            showDifferencesOnly = value
        }
        if let first = urls.first {
            if restoredDelimiter == nil {
                switch first.pathExtension.lowercased() {
                case "tsv", "tab": delimiter = .tab
                case "psv": delimiter = .pipe
                default: break
                }
            }
            load(url: first, for: .left)
        }
        if urls.count > 1 { load(url: urls[1], for: .right) }
    }

    func loadDemo() {
        guard ensureNoSaveInProgress() else { return }
        guard dirtySides.isEmpty || confirmDiscardDrafts(
            message: RiffaLocalization.string(
                "Loading the demo discards the current output drafts."
            )
        ) else { return }
        cancelLoads()
        let leftText = """
        id,name,notes,price
        1,Riffa Basic,"Local, fast",9
        2,Riffa Pro,"Merge and report",19
        4,Legacy,"Retire soon",5
        """
        let rightText = """
        id,name,notes,price
        1,Riffa Basic,"Local, fast",9
        2,Riffa Pro,"Merge, sync, and report",21
        3,Riffa Team,"Shared rules",39
        """
        leftURL = URL(fileURLWithPath: "/Demo/catalog-v1.csv")
        rightURL = URL(fileURLWithPath: "/Demo/catalog-v2.csv")
        delimiter = .comma
        alignByKey = true
        keyColumns = "0"
        do {
            let left = try makeDraft(from: Self.demoDocument(leftText))
            let right = try makeDraft(from: Self.demoDocument(rightText))
            leftDocument = Self.demoDocument(leftText)
            rightDocument = Self.demoDocument(rightText)
            apply(left, to: .left)
            apply(right, to: .right)
            dirtySides.removeAll()
            errorMessage = nil
            compareIfReady()
        } catch {
            errorMessage = String(
                localized: "Could not load the table demo: \(error.localizedDescription)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
    }

    func swapSides() {
        guard ensureNoSaveInProgress() else { return }
        // Draft arrays, encoding metadata, diagnostics, and dirty markers move
        // together, so swapping never silently discards an edit.
        cancelLoads()
        (leftURL, rightURL) = (rightURL, leftURL)
        (leftDocument, rightDocument) = (rightDocument, leftDocument)
        (leftRows, rightRows) = (rightRows, leftRows)
        (leftDiagnostics, rightDiagnostics) = (rightDiagnostics, leftDiagnostics)
        (leftLineEnding, rightLineEnding) = (rightLineEnding, leftLineEnding)
        (leftTerminatesLastRecord, rightTerminatesLastRecord) = (
            rightTerminatesLastRecord,
            leftTerminatesLastRecord
        )
        dirtySides = Set(dirtySides.map(\.opposite))
        refreshDraftToken(for: .left)
        refreshDraftToken(for: .right)
        editSide = editSide.opposite
        selectedRowID = nil
        compareIfReady()
    }

    func requestDelimiterChange(_ choice: DelimiterChoice) {
        guard choice != delimiter else { return }
        guard ensureNoSaveInProgress() else { return }
        guard dirtySides.isEmpty || confirmDiscardDrafts(
            message: RiffaLocalization.string(
                "Changing the delimiter reparses both inputs and discards all edited output drafts."
            )
        ) else { return }

        let previousDelimiter = delimiter
        do {
            delimiter = choice
            let newLeft = try leftDocument.map(makeDraft)
            let newRight = try rightDocument.map(makeDraft)
            if let newLeft { apply(newLeft, to: .left) }
            if let newRight { apply(newRight, to: .right) }
            dirtySides.removeAll()
            selectedRowID = nil
            errorMessage = nil
            compareIfReady()
        } catch {
            delimiter = previousDelimiter
            let delimiterTitle = RiffaLocalization.string(
                choice.rawValue
            ).lowercased()
            errorMessage = String(
                localized: "Could not reparse with \(delimiterTitle) delimiter: \(error.localizedDescription)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
    }

    func applySelectedFields(_ fields: [String]) {
        guard canEditSelectedCells,
              let row = selectedRow,
              let physicalIndex = physicalRowIndex(for: editSide, comparisonRow: row),
              var draftRows = rows(for: editSide),
              draftRows.indices.contains(physicalIndex)
        else { return }
        draftRows[physicalIndex] = fields
        if let reason = validateCandidateRows(draftRows, side: editSide) {
            errorMessage = reason
            return
        }
        setRows(draftRows, for: editSide)
        dirtySides.insert(editSide)
        errorMessage = nil
        compareIfReady(preferredSelection: (editSide, physicalIndex))
    }

    func selectedField(at columnIndex: Int) -> String {
        let fields = selectedFields
        return fields.indices.contains(columnIndex) ? fields[columnIndex] : ""
    }

    func copySelectedRow(from source: Side) {
        guard canCopySelectedRow(from: source),
              let comparisonRow = selectedRow,
              let sourceIndex = physicalRowIndex(for: source, comparisonRow: comparisonRow),
              let sourceRows = rows(for: source),
              sourceRows.indices.contains(sourceIndex),
              var destinationRows = rows(for: source.opposite)
        else { return }

        let copied = sourceRows[sourceIndex]
        let destinationIndex: Int
        if let existingIndex = physicalRowIndex(
            for: source.opposite,
            comparisonRow: comparisonRow
        ), destinationRows.indices.contains(existingIndex) {
            destinationRows[existingIndex] = copied
            destinationIndex = existingIndex
        } else {
            guard destinationRows.count < Self.serializationLimits.maximumRowCount else {
                errorMessage = RiffaLocalization.string(
                    "The destination side has reached the row limit."
                )
                return
            }
            destinationRows.append(copied)
            destinationIndex = destinationRows.count - 1
        }
        if let reason = validateCandidateRows(destinationRows, side: source.opposite) {
            errorMessage = reason
            return
        }
        setRows(destinationRows, for: source.opposite)
        dirtySides.insert(source.opposite)
        editSide = source.opposite
        compareIfReady(preferredSelection: (source.opposite, destinationIndex))
    }

    func appendEmptyRow(to side: Side) {
        guard unsafeEditingReason == nil, var draftRows = rows(for: side) else { return }
        guard draftRows.count < Self.serializationLimits.maximumRowCount else {
            errorMessage = String(
                localized: "The \(side.localizedTitle.lowercased()) side has reached the row limit.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
            return
        }
        let widestRow = draftRows.lazy.map(\.count).max()
            ?? rows(for: side.opposite)?.lazy.map(\.count).max()
            ?? 1
        let fieldCount = max(
            1,
            min(widestRow, Self.serializationLimits.maximumFieldCountPerRow)
        )
        draftRows.append(Array(repeating: "", count: fieldCount))
        let newIndex = draftRows.count - 1
        if let reason = validateCandidateRows(draftRows, side: side) {
            errorMessage = reason
            return
        }
        setRows(draftRows, for: side)
        dirtySides.insert(side)
        editSide = side
        compareIfReady(preferredSelection: (side, newIndex))
    }

    func discardAllDrafts() {
        guard ensureNoSaveInProgress() else { return }
        do {
            if let leftDocument { apply(try makeDraft(from: leftDocument), to: .left) }
            if let rightDocument { apply(try makeDraft(from: rightDocument), to: .right) }
            dirtySides.removeAll()
            selectedRowID = nil
            errorMessage = nil
            compareIfReady()
        } catch {
            errorMessage = String(
                localized: "Could not restore the input tables: \(error.localizedDescription)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
    }

    func saveOutputAs(for side: Side) {
        guard canSaveOutput(for: side),
              let sourceDocument = document(for: side),
              let draftRows = rows(for: side)
        else { return }

        let panel = NSSavePanel()
        let sideTitle = RiffaLocalization.string(side.rawValue)
        panel.title = String(
            localized: "Save \(sideTitle) Table Output As",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
        panel.prompt = RiffaLocalization.string("Save Output")
        let sourceURL = url(for: side)
        let baseName = sourceURL?.deletingPathExtension().lastPathComponent ?? "Riffa-Table"
        let sourceExtension = sourceURL?.pathExtension ?? ""
        let fileExtension = sourceExtension.isEmpty ? defaultFileExtension : sourceExtension
        panel.nameFieldStringValue = "\(baseName)-edited.\(fileExtension)"
        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }

        if [leftURL, rightURL].compactMap({ $0 }).contains(where: {
            Self.urlsReferToSameFile($0, destinationURL)
        }) {
            errorMessage = RiffaLocalization.string(
                "Save Output As cannot overwrite either original input. Choose a different destination."
            )
            return
        }

        let serialized: String
        do {
            serialized = try DelimitedTextSerializer(
                delimiter: delimiter.character,
                lineEnding: lineEnding(for: side),
                terminatesLastRecord: terminatesLastRecord(for: side),
                limits: Self.serializationLimits
            ).serialize(rows: draftRows)
        } catch {
            errorMessage = String(
                localized: "Could not serialize the \(side.localizedTitle.lowercased()) output: \(error.localizedDescription)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
            return
        }

        let outputDocument = DecodedTextDocument(
            text: serialized,
            format: sourceDocument.format,
            fingerprint: sourceDocument.fingerprint
        )
        let saveToken = UUID()
        let savedDraftToken = draftTokens[side]
        saveTokens[side] = saveToken
        savingSides.insert(side)
        errorMessage = nil
        saveTasks[side] = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await documentStore.save(outputDocument, to: destinationURL)
                try Task.checkCancellation()
                guard saveTokens[side] == saveToken else { return }
                if draftTokens[side] == savedDraftToken {
                    dirtySides.remove(side)
                }
            } catch is CancellationError {
                // The matching token is cleaned up below.
            } catch {
                guard saveTokens[side] == saveToken else { return }
                errorMessage = String(
                    localized: "Could not save table output: \(error.localizedDescription)",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
            }
            guard saveTokens[side] == saveToken else { return }
            saveTokens[side] = nil
            saveTasks[side] = nil
            savingSides.remove(side)
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
            "Export Table Comparison Report"
        )
        panel.prompt = RiffaLocalization.string("Export")
        panel.nameFieldStringValue = "Riffa-Table-Report.\(fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let report = try SpecializedComparisonReportGenerator().generate(
                table: result,
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

    private func load(url: URL, for side: Side) {
        loadTasks[side]?.cancel()
        let token = UUID()
        let replacedDraftToken = draftTokens[side]
        loadTokens[side] = token
        loadingSides.insert(side)
        loadTasks[side] = Task { [weak self] in
            guard let self else { return }
            do {
                let document = try await documentStore.load(from: url)
                try Task.checkCancellation()
                let draft = try makeDraft(from: document)
                guard loadTokens[side] == token else { return }
                guard draftTokens[side] == replacedDraftToken else {
                    errorMessage = RiffaLocalization.string(
                        "The input was not replaced because its output draft changed while the file was loading."
                    )
                    loadingSides.remove(side)
                    loadTasks[side] = nil
                    return
                }
                setURL(url, for: side)
                setDocument(document, for: side)
                apply(draft, to: side)
                dirtySides.remove(side)
                selectedRowID = nil
                errorMessage = nil
                compareIfReady()
            } catch is CancellationError {
                // A newer file selection owns this side now.
            } catch {
                guard loadTokens[side] == token else { return }
                errorMessage = String(
                    localized: "Could not read \(url.lastPathComponent): \(error.localizedDescription)",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
            }
            if loadTokens[side] == token {
                loadingSides.remove(side)
                loadTasks[side] = nil
            }
        }
    }

    private func compareIfReady(preferredSelection: (Side, Int)? = nil) {
        comparisonDebounceTask?.cancel()
        comparisonDebounceTask = nil
        guard let leftRows, let rightRows else {
            result = nil
            selectedRowID = nil
            return
        }
        let alignment: TableRowAlignment
        if alignByKey {
            let columns = keyColumns
                .split(separator: ",", omittingEmptySubsequences: true)
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            alignment = .keyColumns(columns)
        } else {
            alignment = .rowNumber
        }
        result = TableComparisonEngine(
            options: TableComparisonOptions(
                alignment: alignment,
                ignoreCase: ignoreCase,
                ignoreWhitespace: ignoreWhitespace
            )
        ).compare(
            left: Self.makeParsedTable(
                rows: leftRows,
                diagnostics: leftDiagnostics,
                delimiter: delimiter.character
            ),
            right: Self.makeParsedTable(
                rows: rightRows,
                diagnostics: rightDiagnostics,
                delimiter: delimiter.character
            )
        )

        if let preferredSelection, let result {
            selectedRowID = result.rows.first { row in
                physicalRowIndex(
                    for: preferredSelection.0,
                    comparisonRow: row
                ) == preferredSelection.1
            }?.id
        } else if let selectedRowID,
                  result?.rows.contains(where: { $0.id == selectedRowID }) != true {
            self.selectedRowID = nil
        }
    }

    private func scheduleCompare() {
        comparisonDebounceTask?.cancel()
        comparisonDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.compareIfReady()
        }
    }

    private func validateCandidateRows(_ candidateRows: [[String]], side: Side) -> String? {
        let alignment: TableRowAlignment
        if alignByKey {
            let pieces = keyColumns.split(separator: ",", omittingEmptySubsequences: false)
            let columns = pieces.compactMap {
                Int($0.trimmingCharacters(in: .whitespaces))
            }
            guard columns.count == pieces.count else {
                return RiffaLocalization.string(
                    "Enter unique, non-negative key-column indices before editing rows."
                )
            }
            alignment = .keyColumns(columns)
        } else {
            alignment = .rowNumber
        }

        do {
            try TableDraftValidator(
                limits: Self.serializationLimits,
                alignment: alignment,
                ignoreCase: ignoreCase,
                ignoreWhitespace: ignoreWhitespace
            ).validate(rows: candidateRows)
            return nil
        } catch let error as TableDraftValidationError {
            let detail = Self.tableDraftValidationMessage(error)
            if let rowIndex = error.rowIndex {
                return String(
                    localized: "The \(side.localizedTitle.lowercased()) edit was not applied. Row \(rowIndex + 1). \(detail)",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
            }
            return String(
                localized: "The \(side.localizedTitle.lowercased()) edit was not applied. \(detail)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        } catch {
            return String(
                localized: "The \(side.localizedTitle.lowercased()) edit was not applied: \(error.localizedDescription)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
    }

    private static func tableDraftValidationMessage(
        _ error: TableDraftValidationError
    ) -> String {
        switch error.code {
        case .rowLimitExceeded:
            RiffaLocalization.string("The edited table exceeds the row limit.")
        case .emptyRow:
            RiffaLocalization.string(
                "Each edited row must contain at least one field."
            )
        case .fieldCountPerRowExceeded:
            RiffaLocalization.string(
                "An edited row exceeds the per-row field limit."
            )
        case .totalFieldLimitExceeded:
            RiffaLocalization.string(
                "The edited table exceeds the total-field limit."
            )
        case .fieldUTF8ByteLimitExceeded:
            RiffaLocalization.string(
                "An edited field exceeds the UTF-8 byte limit."
            )
        case .invalidKeyColumns:
            RiffaLocalization.string(
                "Key columns must be unique non-negative indices."
            )
        case .missingKeyColumn:
            RiffaLocalization.string(
                "An edited row does not contain every configured key column."
            )
        case .duplicateKey:
            RiffaLocalization.string(
                "The edit would create a duplicate composite key."
            )
        case .arithmeticOverflow:
            RiffaLocalization.string(
                "Edited-table size arithmetic overflowed."
            )
        }
    }

    private func makeDraft(from document: DecodedTextDocument) throws -> ParsedDraft {
        let parsed = try DelimitedTextParser(delimiter: delimiter.character).parse(
            document.text,
            limits: Self.parsingLimits
        )
        return ParsedDraft(
            rows: parsed.rows.map { $0.fields.map(\.value) },
            diagnostics: parsed.diagnostics,
            lineEnding: Self.detectLineEnding(in: document.text),
            terminatesLastRecord: Self.hasFinalRecordTerminator(document.text)
        )
    }

    private func apply(_ draft: ParsedDraft, to side: Side) {
        setRows(draft.rows, for: side)
        switch side {
        case .left:
            leftDiagnostics = draft.diagnostics
            leftLineEnding = draft.lineEnding
            leftTerminatesLastRecord = draft.terminatesLastRecord
        case .right:
            rightDiagnostics = draft.diagnostics
            rightLineEnding = draft.lineEnding
            rightTerminatesLastRecord = draft.terminatesLastRecord
        }
    }

    private func rows(for side: Side) -> [[String]]? {
        side == .left ? leftRows : rightRows
    }

    private func setRows(_ rows: [[String]]?, for side: Side) {
        switch side {
        case .left: leftRows = rows
        case .right: rightRows = rows
        }
        refreshDraftToken(for: side)
    }

    private func document(for side: Side) -> DecodedTextDocument? {
        side == .left ? leftDocument : rightDocument
    }

    private func setDocument(_ document: DecodedTextDocument?, for side: Side) {
        switch side {
        case .left: leftDocument = document
        case .right: rightDocument = document
        }
    }

    private func url(for side: Side) -> URL? { side == .left ? leftURL : rightURL }

    private func setURL(_ url: URL?, for side: Side) {
        switch side {
        case .left: leftURL = url
        case .right: rightURL = url
        }
    }

    private func lineEnding(for side: Side) -> DelimitedTextLineEnding {
        side == .left ? leftLineEnding : rightLineEnding
    }

    private func terminatesLastRecord(for side: Side) -> Bool {
        side == .left ? leftTerminatesLastRecord : rightTerminatesLastRecord
    }

    private func physicalRowIndex(
        for side: Side,
        comparisonRow: TableComparisonRow
    ) -> Int? {
        side == .left ? comparisonRow.left?.index : comparisonRow.right?.index
    }

    private func confirmDiscardDrafts(message: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = RiffaLocalization.string(
            "Discard edited table output?"
        )
        alert.informativeText = message
        alert.addButton(withTitle: RiffaLocalization.string("Discard Draft"))
        alert.addButton(withTitle: RiffaLocalization.string("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func ensureNoSaveInProgress() -> Bool {
        guard savingSides.isEmpty else {
            errorMessage = RiffaLocalization.string(
                "Wait for the current save to finish before changing inputs or drafts."
            )
            return false
        }
        return true
    }

    private func refreshDraftToken(for side: Side) {
        draftTokens[side] = UUID()
    }

    private func cancelLoads() {
        loadTasks.values.forEach { $0.cancel() }
        loadTasks.removeAll()
        loadTokens.removeAll()
        loadingSides.removeAll()
    }

    private static func makeParsedTable(
        rows: [[String]],
        diagnostics: [TableDiagnostic],
        delimiter: Character
    ) -> ParsedTable {
        let tableRows = rows.enumerated().map { rowIndex, values in
            let rowLocation = TableSourceLocation(
                offset: rowIndex,
                line: rowIndex + 1,
                column: 1
            )
            return TableRow(
                index: rowIndex,
                fields: values.enumerated().map { columnIndex, value in
                    TableField(
                        value: value,
                        columnIndex: columnIndex,
                        location: TableSourceLocation(
                            offset: rowIndex,
                            line: rowIndex + 1,
                            column: columnIndex + 1
                        )
                    )
                },
                location: rowLocation
            )
        }
        return ParsedTable(
            rows: tableRows,
            diagnostics: diagnostics,
            delimiter: delimiter
        )
    }

    private static func detectLineEnding(in text: String) -> DelimitedTextLineEnding {
        for character in text {
            switch character {
            case "\r\n": return .carriageReturnLineFeed
            case "\r": return .carriageReturn
            case "\n": return .lineFeed
            default: continue
            }
        }
        return .lineFeed
    }

    private static func hasFinalRecordTerminator(_ text: String) -> Bool {
        text.hasSuffix("\r\n") || text.hasSuffix("\r") || text.hasSuffix("\n")
    }

    private static func demoDocument(_ text: String) -> DecodedTextDocument {
        let data = Data(text.utf8)
        return DecodedTextDocument(
            text: text,
            format: .utf8,
            fingerprint: DecodedTextFileFingerprint(data: data)
        )
    }

    private static func urlsReferToSameFile(_ left: URL, _ right: URL) -> Bool {
        let normalizedLeft = left.standardizedFileURL.resolvingSymlinksInPath()
        let normalizedRight = right.standardizedFileURL.resolvingSymlinksInPath()
        if normalizedLeft.path == normalizedRight.path { return true }

        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        let leftID = try? normalizedLeft.resourceValues(forKeys: keys).fileResourceIdentifier
        let rightID = try? normalizedRight.resourceValues(forKeys: keys).fileResourceIdentifier
        guard let leftID, let rightID else { return false }
        return String(describing: leftID) == String(describing: rightID)
    }

    private var defaultFileExtension: String {
        switch delimiter {
        case .comma, .semicolon: "csv"
        case .tab: "tsv"
        case .pipe: "psv"
        }
    }

    private static let parserDiagnosticCodes: Set<TableDiagnosticCode> = [
        .invalidDelimiter,
        .unexpectedQuote,
        .unexpectedCharacterAfterClosingQuote,
        .unterminatedQuotedField
    ]

    private struct ParsedDraft {
        let rows: [[String]]
        let diagnostics: [TableDiagnostic]
        let lineEnding: DelimitedTextLineEnding
        let terminatesLastRecord: Bool
    }
}

struct TableCompareView: View {
    @StateObject private var model = TableCompareModel()
    @Environment(\.riffaTheme) private var theme
    @FocusState private var keyColumnsFocused: Bool
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
            controlBar
            pathBar
            if let result = model.result {
                resultContent(result)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Table Compare")
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
        .alert(
            "Table comparison error",
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
            title: "Table Compare",
            subtitle: "Delimited data with composite-key row alignment"
        ) {
            SessionSaveButton(
                request: SessionSaveRequest(
                    kind: .tableComparison,
                    urls: [model.leftURL, model.rightURL].compactMap { $0 },
                    options: [
                        "delimiter": .string(model.delimiter.rawValue),
                        "alignByKey": .boolean(model.alignByKey),
                        "keyColumns": .string(model.keyColumns),
                        "ignoreCase": .boolean(model.ignoreCase),
                        "ignoreWhitespace": .boolean(model.ignoreWhitespace),
                        "showDifferencesOnly": .boolean(model.showDifferencesOnly)
                    ]
                ),
                errorMessage: $model.errorMessage
            )
            if !model.dirtySides.isEmpty {
                RiffaStatusBadge(
                    "Edited",
                    systemImage: "pencil.circle.fill",
                    tone: .warning
                )
                    .help("One or more output drafts differ from their inputs")
            }

            Menu {
                Button("HTML…") { model.saveReport(format: .html) }
                Button("Plain Text…") { model.saveReport(format: .plainText) }
                Button("JSON…") { model.saveReport(format: .json) }
            } label: {
                Label("Export Report", systemImage: "square.and.arrow.up")
            }
            .labelStyle(.iconOnly)
            .accessibilityLabel("Export table comparison report")
            .accessibilityHint("Choose HTML, plain text, or JSON")
            .help("Export comparison report")
            .disabled(model.result == nil)
        }
    }

    private var controlBar: some View {
        RiffaComparisonControlBar {
            Picker(
                "Delimiter",
                selection: Binding(
                    get: { model.delimiter },
                    set: { model.requestDelimiterChange($0) }
                )
            ) {
                ForEach(TableCompareModel.DelimiterChoice.allCases) {
                    Text(LocalizedStringKey($0.rawValue)).tag($0)
                }
            }
            .frame(width: 118)
            Toggle("Key columns", isOn: $model.alignByKey).toggleStyle(.checkbox)
            if model.alignByKey {
                TextField("0,1", text: $model.keyColumns)
                    .textFieldStyle(.plain)
                    .riffaText(.mono)
                    .foregroundStyle(theme.ink)
                    .padding(.horizontal, RiffaSpacing.xs)
                    .frame(width: 78)
                    .frame(minHeight: 36)
                    .background(
                        theme.surface(.two),
                        in: RoundedRectangle(cornerRadius: RiffaRadius.md)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: RiffaRadius.md)
                            .strokeBorder(
                                keyColumnsFocused ? theme.focusRing : theme.hairline,
                                lineWidth: keyColumnsFocused ? theme.focusRingWidth : 1
                            )
                    }
                    .focused($keyColumnsFocused)
                    .help("Zero-based key column indices separated by commas")
                    .accessibilityLabel("Zero-based key columns")
                    .accessibilityHint("Enter comma-separated column indices")
            }
            Toggle("Case", isOn: $model.ignoreCase).toggleStyle(.checkbox).help("Ignore case")
            Toggle("Whitespace", isOn: $model.ignoreWhitespace).toggleStyle(.checkbox).help("Ignore whitespace")
            Toggle("Differences", isOn: $model.showDifferencesOnly).toggleStyle(.checkbox)

            if let result = model.result {
                RiffaStatusBadge(
                    "Δ \(differenceCount(result)) differences",
                    systemImage: RiffaIcon.notEqual,
                    tone: result.statistics.totalRowCount == result.statistics.sameRowCount
                        ? .neutral
                        : .warning
                )
            }
        }
    }

    private var pathBar: some View {
        RiffaComparisonPathBar {
            TablePathButton(
                title: RiffaLocalization.string("Left table"),
                url: model.leftURL,
                isDirty: model.dirtySides.contains(.left),
                isLoading: model.loadingSides.contains(.left)
            ) { model.chooseFile(for: .left) }
            .riffaResourceDropTarget(
                role: .left,
                acceptedKind: .regularFileFollowingFinalSymbolicLink
            ) {
                model.replaceInput(with: $0, for: .left)
            }

            Button {
                model.swapSides()
            } label: {
                Label("Swap tables", systemImage: "arrow.left.arrow.right")
            }
                .labelStyle(.iconOnly)
                .buttonStyle(.riffaIcon)
                .accessibilityLabel("Swap table inputs")
                .accessibilityHint("Exchanges the left and right delimited files")
                .help("Swap left and right")
                .disabled(model.leftURL == nil && model.rightURL == nil)

            TablePathButton(
                title: RiffaLocalization.string("Right table"),
                url: model.rightURL,
                isDirty: model.dirtySides.contains(.right),
                isLoading: model.loadingSides.contains(.right)
            ) { model.chooseFile(for: .right) }
            .riffaResourceDropTarget(
                role: .right,
                acceptedKind: .regularFileFollowingFinalSymbolicLink
            ) {
                model.replaceInput(with: $0, for: .right)
            }
        }
    }

    private func resultContent(_ result: TableComparisonResult) -> some View {
        VStack(spacing: 0) {
            if !result.diagnostics.isEmpty {
                HStack(spacing: 8) {
                    RiffaStatusBadge(
                        "Parser warning",
                        systemImage: "exclamationmark.triangle.fill",
                        tone: .warning
                    )
                    Text(diagnosticSummary(result.diagnostics))
                        .riffaText(.caption)
                        .foregroundStyle(theme.inkMuted)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, RiffaSpacing.sm)
                .padding(.vertical, RiffaSpacing.xs)
                .background(theme.surface(.two))
                .overlay(alignment: .bottom) {
                    RiffaHairline()
                }
            }

            Table(model.visibleRows, selection: $model.selectedRowID) {
                TableColumn("Status") { row in TableRowStatusLabel(status: row.status) }
                    .width(min: 95, ideal: 112, max: 130)
                TableColumn("Key / Row") { row in
                    Text(keyPreview(row))
                        .font(.system(.body, design: .monospaced))
                }
                .width(min: 100, ideal: 150)
                TableColumn("Left") { row in
                    Text(rowPreview(row, side: .left))
                        .font(.system(.caption, design: .monospaced)).lineLimit(2)
                }
                .width(min: 240, ideal: 380)
                TableColumn("Right") { row in
                    Text(rowPreview(row, side: .right))
                        .font(.system(.caption, design: .monospaced)).lineLimit(2)
                }
                .width(min: 240, ideal: 380)
                TableColumn("Cells") { row in
                    Text(cellSummary(row))
                        .riffaText(.caption)
                        .foregroundStyle(theme.inkSubtle)
                }
                .width(min: 100, ideal: 140)
            }
            .background(theme.canvas)

            editorPanel

            RiffaStatusBar {
                RiffaStatusBadge(
                    "Δ \(result.statistics.modifiedRowCount) modified",
                    systemImage: "pencil",
                    tone: result.statistics.modifiedRowCount > 0 ? .warning : .neutral
                )
                RiffaStatusBadge(
                    "− \(result.statistics.leftOnlyRowCount) left only",
                    systemImage: "minus",
                    tone: result.statistics.leftOnlyRowCount > 0 ? .danger : .neutral
                )
                RiffaStatusBadge(
                    "+ \(result.statistics.rightOnlyRowCount) right only",
                    systemImage: "plus",
                    tone: result.statistics.rightOnlyRowCount > 0 ? .success : .neutral
                )
                if result.statistics.duplicateKeyRowCount > 0 {
                    RiffaStatusBadge(
                        "! \(result.statistics.duplicateKeyRowCount) duplicate keys",
                        systemImage: "exclamationmark.triangle",
                        tone: .warning
                    )
                }
                Spacer()
                if model.hasHiddenRows {
                    Label(
                        "Showing first \(model.visibleRows.count) of \(model.filteredRowCount) filtered rows",
                        systemImage: "rectangle.stack.badge.minus"
                    )
                } else {
                    Text("\(model.visibleRows.count) of \(result.statistics.totalRowCount) rows")
                }
            }
        }
    }

    private var editorPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            RiffaPaneHeader(
                "Edit Output",
                subtitle: editorSubtitle,
                systemImage: "tablecells.badge.ellipsis"
            ) {
                Picker("Side", selection: $model.editSide) {
                    ForEach(TableCompareModel.Side.allCases) { side in
                        Text(LocalizedStringKey(side.rawValue)).tag(side)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                .accessibilityHint("Chooses which output draft is edited")
            }

            HStack(spacing: RiffaSpacing.xs) {
                Button("Left → Right") { model.copySelectedRow(from: .left) }
                    .buttonStyle(.riffaSecondary)
                    .accessibilityLabel("Copy selected row from left to right")
                    .accessibilityHint("Replaces or inserts the right output row")
                    .disabled(!model.canCopySelectedRow(from: .left))
                Button("Right → Left") { model.copySelectedRow(from: .right) }
                    .buttonStyle(.riffaSecondary)
                    .accessibilityLabel("Copy selected row from right to left")
                    .accessibilityHint("Replaces or inserts the left output row")
                    .disabled(!model.canCopySelectedRow(from: .right))
                Button("Append Empty Row") { model.appendEmptyRow(to: model.editSide) }
                    .buttonStyle(.riffaSecondary)
                    .accessibilityHint("Adds a blank row to the selected output draft")
                    .disabled(model.unsafeEditingReason != nil)
                Spacer()
                Button {
                    model.saveOutputAs(for: model.editSide)
                } label: {
                    Label(
                        "Save \(model.editSide.localizedTitle) Output As…",
                        systemImage: "square.and.arrow.down"
                    )
                }
                .buttonStyle(.riffaPrimary)
                .accessibilityHint("Writes the selected output draft to a new local file")
                .disabled(!model.canSaveOutput(for: model.editSide))
            }
            .padding(.horizontal, RiffaSpacing.sm)

            if let unsafeReason = model.unsafeEditingReason {
                HStack(spacing: 8) {
                    Image(systemName: "lock.trianglebadge.exclamationmark.fill")
                        .foregroundStyle(theme.danger)
                    Text(unsafeReason)
                        .foregroundStyle(theme.inkSubtle)
                    Spacer()
                    if !model.dirtySides.isEmpty {
                        Button("Discard Drafts", role: .destructive) {
                            model.discardAllDrafts()
                        }
                    }
                }
                .riffaText(.caption)
                .padding(.horizontal, RiffaSpacing.sm)
            } else if model.canEditSelectedCells {
                TableSelectedRowEditor(model: model)
                    .id("\(model.selectedRowID ?? -1)-\(model.editSide.rawValue)")
            } else {
                Text("Select a matched row to edit its \(model.editSide.localizedTitle) cells. Row-copy actions also support one-sided rows.")
                    .riffaText(.caption)
                    .foregroundStyle(theme.inkSubtle)
                    .padding(.horizontal, RiffaSpacing.sm)
            }
        }
        .padding(.bottom, RiffaSpacing.xs)
        .frame(maxHeight: 190)
        .background(theme.surface(.one))
        .overlay(alignment: .top) {
            RiffaHairline()
        }
    }

    private var emptyState: some View {
        RiffaEmptyState(
            title: "Choose two delimited files",
            description: "Riffa parses CSV, TSV, semicolon, and pipe-delimited text without uploading it.",
            systemImage: "tablecells"
        ) {
            HStack(spacing: RiffaSpacing.xs) {
                Button("Choose Left") {
                    model.chooseFile(for: .left)
                }
                .buttonStyle(.riffaSecondary)
                .accessibilityLabel("Choose left table")
                .accessibilityHint("Opens a local delimited-file picker")

                Button("Choose Right") {
                    model.chooseFile(for: .right)
                }
                .buttonStyle(.riffaSecondary)
                .accessibilityLabel("Choose right table")
                .accessibilityHint("Opens a local delimited-file picker")

                Button("Load Demo") {
                    model.loadDemo()
                }
                .buttonStyle(.riffaPrimary)
                .accessibilityHint("Creates two temporary sample tables")
            }
        }
    }

    private var editorSubtitle: String {
        let side = model.editSide.localizedTitle
        guard let row = model.selectedRow else {
            return String(
                localized: "\(side) draft · no row selected",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
        let status = RiffaLocalization.string(row.status.rawValue)
        return String(
            localized: "\(side) draft · \(statusNotation(row.status)) \(status)",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
    }

    private func differenceCount(_ result: TableComparisonResult) -> Int {
        result.statistics.modifiedRowCount
            + result.statistics.leftOnlyRowCount
            + result.statistics.rightOnlyRowCount
    }

    private func statusNotation(_ status: TableRowStatus) -> String {
        switch status {
        case .same: "✓"
        case .modified: "Δ"
        case .leftOnly: "−"
        case .rightOnly: "+"
        case .duplicateKey: "!"
        case .error: "×"
        }
    }

    private func cellSummary(_ row: TableComparisonRow) -> String {
        let changed = row.cells.lazy
            .filter { $0.status != .same && $0.status != .ignored }
            .prefix(64)
        guard !changed.isEmpty else {
            return row.status == .same
                ? RiffaLocalization.string("All match")
                : "—"
        }
        return changed.map {
            let status = RiffaLocalization.string($0.status.rawValue)
            return String(
                localized: "C\($0.columnIndex + 1) \(status)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }.joined(separator: ", ")
    }

    private func keyPreview(_ row: TableComparisonRow) -> String {
        guard let values = row.keyValues else { return String(row.offset + 1) }
        let joined = values.prefix(8).map { String($0.prefix(128)) }.joined(separator: " · ")
        return String(joined.prefix(1_024)) + (values.count > 8 ? " …" : "")
    }

    private func rowPreview(
        _ comparisonRow: TableComparisonRow,
        side: TableCompareModel.Side
    ) -> String {
        let row = side == .left ? comparisonRow.left : comparisonRow.right
        guard let row else { return "—" }
        let joined = row.fields.prefix(64)
            .map { String($0.value.prefix(256)) }
            .joined(separator: " │ ")
        let bounded = String(joined.prefix(4_096))
        return bounded + (row.fields.count > 64 || joined.count > 4_096 ? " …" : "")
    }

    private func diagnosticSummary(_ diagnostics: [TableDiagnostic]) -> String {
        let first = diagnostics[0]
        let message = String(first.message.prefix(512))
        if diagnostics.count == 1 {
            return String(
                localized: "\(message) (line \(first.location.line), column \(first.location.column))",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
        return String(
            localized: "\(diagnostics.count) diagnostics. First: \(message) (line \(first.location.line), column \(first.location.column))",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
    }
}

private struct TableSelectedRowEditor: View {
    @ObservedObject var model: TableCompareModel
    @Environment(\.riffaTheme) private var theme
    @FocusState private var focusedColumn: Int?
    @State private var fields: [String]
    private let originalFields: [String]

    init(model: TableCompareModel) {
        self.model = model
        let fields = model.selectedFields
        originalFields = fields
        _fields = State(initialValue: fields)
    }

    var body: some View {
        let visibleFieldCount = min(
            fields.count,
            TableCompareModel.maximumEditableFieldCount
        )
        HStack(alignment: .bottom, spacing: 10) {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(0..<visibleFieldCount, id: \.self) { columnIndex in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Column \(columnIndex + 1)")
                                .riffaText(.caption)
                                .foregroundStyle(theme.inkSubtle)
                            TextField(
                                "Value",
                                text: $fields[columnIndex],
                                axis: .vertical
                            )
                            .textFieldStyle(.plain)
                            .riffaText(.bodySmall)
                            .foregroundStyle(theme.ink)
                            .padding(RiffaSpacing.xs)
                            .frame(width: 190)
                            .background(
                                theme.surface(.two),
                                in: RoundedRectangle(cornerRadius: RiffaRadius.md)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: RiffaRadius.md)
                                    .strokeBorder(
                                        focusedColumn == columnIndex
                                            ? theme.focusRing
                                            : theme.hairline,
                                        lineWidth: focusedColumn == columnIndex
                                            ? theme.focusRingWidth
                                            : 1
                                    )
                            }
                            .focused($focusedColumn, equals: columnIndex)
                            .lineLimit(1...3)
                            .accessibilityLabel(
                                String(
                                    localized: "Column \(columnIndex + 1) value",
                                    bundle: RiffaLocalization.localizedBundle,
                                    locale: RiffaLocalization.locale
                                )
                            )
                        }
                    }
                    if fields.count > visibleFieldCount {
                        Text("Only the first \(visibleFieldCount) fields are editable on screen.")
                            .riffaText(.caption)
                            .foregroundStyle(theme.inkSubtle)
                            .frame(width: 180)
                    }
                }
            }
            .scrollIndicators(.visible)

            Button("Reset") { fields = originalFields }
                .buttonStyle(.riffaTertiary)
                .accessibilityHint("Restores the selected row fields")
                .disabled(fields == originalFields)
            Button("Apply Cells") { model.applySelectedFields(fields) }
                .buttonStyle(.riffaPrimary)
                .accessibilityHint("Applies edits to the in-memory output draft")
                .disabled(fields == originalFields)
        }
        .padding(.horizontal, RiffaSpacing.sm)
    }
}

private struct TableRowStatusLabel: View {
    let status: TableRowStatus
    @Environment(\.riffaTheme) private var theme

    var body: some View {
        Label {
            Text(verbatim: "\(notation) \(title)")
        } icon: {
            Image(systemName: symbol)
        }
            .riffaText(.caption)
            .foregroundStyle(color)
            .accessibilityLabel(
                String(
                    localized: "\(title), \(notation)",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
            )
    }

    private var title: String {
        RiffaLocalization.string(status.rawValue)
    }
    private var notation: String {
        switch status {
        case .same: "✓"
        case .modified: "Δ"
        case .leftOnly: "−"
        case .rightOnly: "+"
        case .duplicateKey: "!"
        case .error: "×"
        }
    }
    private var symbol: String {
        switch status {
        case .same: "checkmark.circle"
        case .modified: "pencil"
        case .leftOnly: "minus.circle"
        case .rightOnly: "plus.circle"
        case .duplicateKey: "key.horizontal.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }
    private var color: Color {
        switch status {
        case .same: theme.success
        case .modified, .duplicateKey: theme.warning
        case .leftOnly, .error: theme.danger
        case .rightOnly: theme.success
        }
    }
}

private struct TablePathButton: View {
    let title: String
    let url: URL?
    let isDirty: Bool
    let isLoading: Bool
    let action: () -> Void
    @Environment(\.riffaTheme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: RiffaSpacing.xs) {
                Image(systemName: "tablecells")
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(theme.inkSubtle)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: title)
                        .riffaText(.caption)
                        .foregroundStyle(theme.inkSubtle)
                    if let url {
                        Text(verbatim: url.path(percentEncoded: false))
                            .riffaText(.mono)
                            .foregroundStyle(theme.inkMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text(
                            verbatim: RiffaLocalization.string(
                                "Choose a delimited file…"
                            )
                        )
                        .riffaText(.mono)
                        .foregroundStyle(theme.inkSubtle)
                        .lineLimit(1)
                    }
                }
                Spacer(minLength: RiffaSpacing.xs)
                if isLoading {
                        ProgressView()
                        .controlSize(.small)
                        .tint(theme.accent)
                        .accessibilityLabel(
                            String(
                                localized: "Loading \(title.lowercased())",
                                bundle: RiffaLocalization.localizedBundle,
                                locale: RiffaLocalization.locale
                            )
                        )
                } else if isDirty {
                    RiffaStatusBadge(
                        "Edited",
                        systemImage: "pencil.circle.fill",
                        tone: .warning
                    )
                } else {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(theme.inkTertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, RiffaSpacing.sm)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(
                theme.surface(.one),
                in: RoundedRectangle(cornerRadius: RiffaRadius.md)
            )
            .overlay {
                RoundedRectangle(cornerRadius: RiffaRadius.md)
                    .strokeBorder(theme.hairline, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: RiffaRadius.md))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Choose a local delimited table")
    }

    private var accessibilityLabel: String {
        let resource = url?.path(percentEncoded: false)
            ?? RiffaLocalization.string("no table selected")
        return String(
            localized: "\(title), \(resource)",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
    }
}
