import Foundation

/// Resolves dynamic and AppKit-facing strings using the same in-app language
/// preference that SwiftUI receives through its `Locale` environment.
///
/// SwiftUI literal labels localize automatically. Use this helper only when an
/// API requires a concrete `String`, such as `NSOpenPanel`, `NSAlert`, a
/// `LocalizedError`, or a title that has already passed through a model.
enum RiffaLocalization {
    static var selectedLanguage: RiffaLanguage {
        let rawValue = UserDefaults.standard.string(
            forKey: RiffaUserDefaultsKey.language
        )
        return rawValue.flatMap(RiffaLanguage.init(rawValue:))
            ?? .defaultValue
    }

    static var locale: Locale {
        locale(for: selectedLanguage)
    }

    /// The localization sub-bundle for the selected in-app language.
    ///
    /// Passing only a `Locale` to `String(localized:)` does not override the
    /// localization chosen for the process's main bundle at launch. Dynamic
    /// interpolation sites therefore use this bundle together with `locale`.
    static var localizedBundle: Bundle {
        bundle(for: selectedLanguage, in: .main)
    }

    static func locale(for language: RiffaLanguage) -> Locale {
        language.locale ?? .autoupdatingCurrent
    }

    static func string(
        _ key: String,
        language: RiffaLanguage? = nil,
        bundle: Bundle = .main
    ) -> String {
        let requestedLanguage = language ?? selectedLanguage
        let localizedBundle = Self.bundle(
            for: requestedLanguage,
            in: bundle
        )
        return String(
            localized: String.LocalizationValue(key),
            bundle: localizedBundle,
            locale: locale(for: requestedLanguage)
        )
    }

    static func bundle(
        for language: RiffaLanguage,
        in bundle: Bundle
    ) -> Bundle {
        guard language != .system,
              let localizationURL = bundle.url(
                  forResource: language.rawValue,
                  withExtension: "lproj"
              ),
              let localizedBundle = Bundle(url: localizationURL) else {
            return bundle
        }
        return localizedBundle
    }
}
