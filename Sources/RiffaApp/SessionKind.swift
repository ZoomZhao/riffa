import Foundation
import SwiftUI

enum SessionKind: String, CaseIterable, Identifiable, Hashable {
    case folderCompare
    case folderMerge
    case folderSync
    case textCompare
    case textMerge
    case textPatch
    case hexCompare
    case mediaCompare
    case imageCompare
    case pdfCompare
    case officeCompare
    case archiveCompare
    case metadataCompare
    case versionCompare
    case tableCompare

    var id: Self { self }

    /// A localization key for SwiftUI views.
    ///
    /// Keeping the key intact lets SwiftUI resolve it again whenever the
    /// window's locale environment changes.
    var titleKey: LocalizedStringKey {
        LocalizedStringKey(titleLocalizationKey)
    }

    /// A localization key for SwiftUI views.
    var subtitleKey: LocalizedStringKey {
        LocalizedStringKey(subtitleLocalizationKey)
    }

    /// Concrete text for APIs that cannot accept a `LocalizedStringKey`.
    var title: String {
        localizedTitle()
    }

    /// Concrete text for APIs that cannot accept a `LocalizedStringKey`.
    var subtitle: String {
        localizedSubtitle()
    }

    func localizedTitle(
        language: RiffaLanguage? = nil,
        bundle: Bundle = .main
    ) -> String {
        RiffaLocalization.string(
            titleLocalizationKey,
            language: language,
            bundle: bundle
        )
    }

    func localizedSubtitle(
        language: RiffaLanguage? = nil,
        bundle: Bundle = .main
    ) -> String {
        RiffaLocalization.string(
            subtitleLocalizationKey,
            language: language,
            bundle: bundle
        )
    }

    var titleLocalizationKey: String {
        switch self {
        case .folderCompare: "Folder Compare"
        case .folderMerge: "Folder Merge"
        case .folderSync: "Folder Sync"
        case .textCompare: "Text Compare"
        case .textMerge: "Text Merge"
        case .textPatch: "Text Patch"
        case .hexCompare: "Hex Compare"
        case .mediaCompare: "Media Compare"
        case .imageCompare: "Image Compare"
        case .pdfCompare: "PDF Compare"
        case .officeCompare: "Office Compare"
        case .archiveCompare: "Archive Compare"
        case .metadataCompare: "Metadata Compare"
        case .versionCompare: "Version Compare"
        case .tableCompare: "Table Compare"
        }
    }

    var subtitleLocalizationKey: String {
        switch self {
        case .folderCompare:
            "Inspect two directory trees"
        case .folderMerge:
            "Reconcile three folder trees"
        case .folderSync:
            "Preview safe copy and delete plans"
        case .textCompare:
            "Aligned lines and inline changes"
        case .textMerge:
            "Resolve three-way text changes"
        case .textPatch:
            "Review and safely apply unified diffs"
        case .hexCompare:
            "Compare large binary files"
        case .mediaCompare:
            "Inspect audio and video metadata"
        case .imageCompare:
            "Overlay pixels and highlight changes"
        case .pdfCompare:
            "Review pages, text, and document metadata"
        case .officeCompare:
            "Compare DOCX, XLSX, PPTX, and ODS package content"
        case .archiveCompare:
            "Compare ZIP and TAR contents without extracting"
        case .metadataCompare:
            "Compare safe file-system attributes"
        case .versionCompare:
            "Inspect versions, architectures, and signatures"
        case .tableCompare:
            "Match rows, keys, and worksheets"
        }
    }

    var symbol: String {
        switch self {
        case .folderCompare: "folder.badge.questionmark"
        case .folderMerge: "arrow.triangle.merge"
        case .folderSync: "arrow.triangle.2.circlepath"
        case .textCompare: "doc.text.magnifyingglass"
        case .textMerge: "arrow.triangle.branch"
        case .textPatch: "doc.badge.arrow.up"
        case .hexCompare: "number.square"
        case .mediaCompare: "waveform"
        case .imageCompare: "photo.on.rectangle.angled"
        case .pdfCompare: "doc.richtext"
        case .officeCompare: "doc.on.doc"
        case .archiveCompare: "archivebox"
        case .metadataCompare: "list.bullet.rectangle"
        case .versionCompare: "clock.arrow.circlepath"
        case .tableCompare: "tablecells"
        }
    }

}
