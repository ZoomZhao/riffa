import Foundation
import SwiftUI

/// A semantic, stable localization key for custom Undo and Redo commands.
///
/// Focused values can outlive the locale in which a concrete `String` was
/// created. Keeping the operation and action separate lets `Commands` resolve
/// the title with its current in-app language preference on every update.
enum RiffaUndoRedoTitle {
    enum Action {
        case editMergedOutput
        case resolveConflict(number: Int?)
    }

    case undoMergeEdit
    case redoMergeEdit
    case undo(Action)
    case redo(Action)

    func localized(language: RiffaLanguage) -> String {
        switch self {
        case .undoMergeEdit:
            RiffaLocalization.string("Undo Merge Edit", language: language)
        case .redoMergeEdit:
            RiffaLocalization.string("Redo Merge Edit", language: language)
        case let .undo(action):
            Self.formatted(
                RiffaLocalization.string("Undo %@", language: language),
                argument: action.localized(language: language),
                language: language
            )
        case let .redo(action):
            Self.formatted(
                RiffaLocalization.string("Redo %@", language: language),
                argument: action.localized(language: language),
                language: language
            )
        }
    }

    private static func formatted(
        _ format: String,
        argument: String,
        language: RiffaLanguage
    ) -> String {
        String(
            format: format,
            locale: RiffaLocalization.locale(for: language),
            arguments: [argument]
        )
    }
}

private extension RiffaUndoRedoTitle.Action {
    func localized(language: RiffaLanguage) -> String {
        switch self {
        case .editMergedOutput:
            RiffaLocalization.string("Edit Merged Output", language: language)
        case .resolveConflict(nil):
            RiffaLocalization.string("Resolve Conflict", language: language)
        case let .resolveConflict(number?):
            String(
                format: RiffaLocalization.string(
                    "Resolve Conflict %lld",
                    language: language
                ),
                locale: RiffaLocalization.locale(for: language),
                arguments: [Int64(number)]
            )
        }
    }
}

@MainActor
struct RiffaUndoRedoActions {
    let undoTitle: RiffaUndoRedoTitle
    let redoTitle: RiffaUndoRedoTitle
    let canUndo: Bool
    let canRedo: Bool
    let undo: () -> Void
    let redo: () -> Void
}

private struct RiffaUndoRedoActionsKey: FocusedValueKey {
    typealias Value = RiffaUndoRedoActions
}

private struct RiffaSessionSelectionKey: FocusedValueKey {
    typealias Value = Binding<SessionKind?>
}

extension FocusedValues {
    var riffaSessionSelection: Binding<SessionKind?>? {
        get { self[RiffaSessionSelectionKey.self] }
        set { self[RiffaSessionSelectionKey.self] = newValue }
    }

    var riffaUndoRedoActions: RiffaUndoRedoActions? {
        get { self[RiffaUndoRedoActionsKey.self] }
        set { self[RiffaUndoRedoActionsKey.self] = newValue }
    }
}

struct RiffaSessionCommands: Commands {
    @FocusedValue(\.riffaSessionSelection) private var selection
    @FocusedValue(\.riffaUndoRedoActions) private var riffaUndoRedoActions
    @Environment(\.openWindow) private var openWindow
    @Environment(\.undoManager) private var undoManager
    @AppStorage(RiffaUserDefaultsKey.language)
    private var languageRawValue = RiffaLanguage.defaultValue.rawValue

    private var language: RiffaLanguage {
        RiffaLanguage(rawValue: languageRawValue) ?? .defaultValue
    }

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button {
                if let riffaUndoRedoActions {
                    riffaUndoRedoActions.undo()
                } else {
                    undoManager?.undo()
                }
            } label: {
                Text(
                    verbatim: riffaUndoRedoActions?.undoTitle.localized(
                        language: language
                    )
                        ?? localized("Undo")
                )
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!(riffaUndoRedoActions?.canUndo ?? undoManager?.canUndo ?? false))

            Button {
                if let riffaUndoRedoActions {
                    riffaUndoRedoActions.redo()
                } else {
                    undoManager?.redo()
                }
            } label: {
                Text(
                    verbatim: riffaUndoRedoActions?.redoTitle.localized(
                        language: language
                    )
                        ?? localized("Redo")
                )
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!(riffaUndoRedoActions?.canRedo ?? undoManager?.canRedo ?? false))
        }

        CommandMenu(Text(verbatim: localized("Session"))) {
            Button {
                openWindow(id: "session-library")
            } label: {
                commandLabel(
                    "Session Library…",
                    systemImage: "rectangle.stack"
                )
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])

            Button {
                openWindow(id: "resource-tools")
            } label: {
                commandLabel("Resource Tools…", systemImage: "archivebox")
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])

            Divider()
            sessionButton("Home", symbol: "house", shortcut: "0", kind: nil)
            Divider()
            sessionButton(.folderCompare, shortcut: "1")
            sessionButton(.textCompare, shortcut: "2")
            sessionButton(.textMerge, shortcut: "3")
            sessionButton(.folderSync, shortcut: "4")
            sessionButton(.hexCompare, shortcut: "5")
            sessionButton(.imageCompare, shortcut: "6")
            sessionButton(.tableCompare, shortcut: "7")
            sessionButton(.mediaCompare, shortcut: "8")
            sessionButton(.folderMerge, shortcut: "9")
            sessionButton(.textPatch)
            sessionButton(.pdfCompare)
            sessionButton(.officeCompare)
            sessionButton(.archiveCompare)
            sessionButton(.metadataCompare)
            sessionButton(.versionCompare)
        }
    }

    private func localized(_ key: String) -> String {
        RiffaLocalization.string(key, language: language)
    }

    private func commandLabel(
        _ titleKey: String,
        systemImage: String
    ) -> some View {
        Label {
            Text(verbatim: localized(titleKey))
        } icon: {
            Image(systemName: systemImage)
        }
    }

    private func sessionButton(
        _ titleKey: String,
        symbol: String,
        shortcut: KeyEquivalent,
        kind: SessionKind?
    ) -> some View {
        Button {
            selection?.wrappedValue = kind
        } label: {
            commandLabel(titleKey, systemImage: symbol)
        }
        .keyboardShortcut(shortcut, modifiers: .command)
        .disabled(selection == nil)
    }

    @ViewBuilder
    private func sessionButton(
        _ kind: SessionKind,
        shortcut: KeyEquivalent? = nil
    ) -> some View {
        let button = Button {
            selection?.wrappedValue = kind
        } label: {
            Label {
                Text(verbatim: kind.localizedTitle(language: language))
            } icon: {
                Image(systemName: kind.symbol)
            }
        }
        .disabled(selection == nil)

        if let shortcut {
            button.keyboardShortcut(shortcut, modifiers: .command)
        } else {
            button
        }
    }
}
