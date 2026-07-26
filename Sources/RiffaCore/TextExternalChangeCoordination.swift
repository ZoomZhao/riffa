import Foundation

/// A path-free description of what happened to a loaded local text resource.
///
/// File-system observers are advisory: an atomic replacement is reported as
/// `changed`, while a rename is only reported as `moved` when the original
/// location no longer names a file. The document fingerprint remains the
/// authority before an in-place save.
public enum TextExternalFileChangeKind: String, CaseIterable, Hashable, Codable, Sendable {
    case changed
    case moved
    case deleted
    case unavailable

    fileprivate var precedence: Int {
        switch self {
        case .changed: 0
        case .moved: 1
        case .deleted: 2
        case .unavailable: 3
        }
    }
}

public enum TextExternalReloadSafety: String, Hashable, Codable, Sendable {
    case safeToReload
    case requiresDiscardConfirmation
}

/// Small value-type state machine shared by Text Compare and Text Merge.
/// It deliberately stores no URL or file contents, so it is safe to persist in
/// diagnostics without disclosing a local path or retaining a draft.
public struct TextExternalChangeCoordinationState: Hashable, Codable, Sendable {
    public private(set) var pendingChange: TextExternalFileChangeKind?

    public init(pendingChange: TextExternalFileChangeKind? = nil) {
        self.pendingChange = pendingChange
    }

    /// Coalesces a burst while retaining the event that needs the strongest
    /// user attention.
    public mutating func observe(_ change: TextExternalFileChangeKind) {
        guard let pendingChange else {
            self.pendingChange = change
            return
        }
        if change.precedence >= pendingChange.precedence {
            self.pendingChange = change
        }
    }

    /// Dismisses the current notice without claiming that the on-disk file is
    /// the new baseline. The original fingerprint therefore still protects a
    /// later in-place save.
    public mutating func keepCurrent() {
        pendingChange = nil
    }

    /// Called only after a bounded reload or successful in-place save has
    /// installed a fresh document fingerprint.
    public mutating func establishBaseline() {
        pendingChange = nil
    }

    public func reloadSafety(hasUnsavedEdits: Bool) -> TextExternalReloadSafety {
        hasUnsavedEdits ? .requiresDiscardConfirmation : .safeToReload
    }
}
