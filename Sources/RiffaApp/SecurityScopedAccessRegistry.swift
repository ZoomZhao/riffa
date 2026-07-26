import Combine
import Foundation

/// Keeps sandbox extensions alive for as long as the app is running. A URL is
/// started at most once, even when several saved sessions reference it.
@MainActor
final class SecurityScopedAccessRegistry: ObservableObject {
    private struct Access {
        let url: URL
        let didStart: Bool
    }

    private var accesses: [String: Access] = [:]

    /// Registers a URL delivered by Finder, Launch Services, or an open panel.
    /// Such URLs may already be accessible without a new sandbox extension, so
    /// a `false` result is retained as a harmless no-op instead of rejected.
    func registerIncomingURL(_ url: URL) throws -> URL {
        guard url.isFileURL else {
            throw SecurityScopedAccessError.notAFileURL
        }
        return try register(url, requiresStartedAccess: false)
    }

    /// Resolves an app-scoped bookmark without presenting UI, rejects stale
    /// bookmarks, and starts the sandbox extension before returning its URL.
    func resolveAndRegisterBookmark(_ bookmarkData: Data) throws -> URL {
        guard !bookmarkData.isEmpty else {
            throw SecurityScopedAccessError.invalidBookmark
        }

        var isStale = false
        let resolvedURL: URL
        do {
            resolvedURL = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw SecurityScopedAccessError.resolutionFailed(
                reason: error.localizedDescription
            )
        }

        guard !isStale else {
            throw SecurityScopedAccessError.staleBookmark
        }
        guard resolvedURL.isFileURL else {
            throw SecurityScopedAccessError.notAFileURL
        }
        return try register(resolvedURL, requiresStartedAccess: true)
    }

    private func register(
        _ url: URL,
        requiresStartedAccess: Bool
    ) throws -> URL {
        // Start and stop access on the exact URL returned by macOS. Creating a
        // standardized URL first can discard the security-scope attachment.
        let key = url.standardizedFileURL.path
        if let existing = accesses[key] {
            if !requiresStartedAccess || existing.didStart {
                return existing.url
            }

            // A previous non-scoped incoming URL is not enough to satisfy a
            // bookmark reopen. Upgrade the entry using the resolved URL.
            let didStart = url.startAccessingSecurityScopedResource()
            guard didStart else {
                throw SecurityScopedAccessError.accessDenied(path: key)
            }
            accesses[key] = Access(url: url, didStart: true)
            return url
        }

        let didStart = url.startAccessingSecurityScopedResource()
        if requiresStartedAccess, !didStart {
            throw SecurityScopedAccessError.accessDenied(path: key)
        }
        accesses[key] = Access(url: url, didStart: didStart)
        return url
    }

    deinit {
        for access in accesses.values where access.didStart {
            access.url.stopAccessingSecurityScopedResource()
        }
    }
}

enum SecurityScopedAccessError: Error, LocalizedError {
    case invalidBookmark
    case resolutionFailed(reason: String)
    case staleBookmark
    case notAFileURL
    case accessDenied(path: String)

    var errorDescription: String? {
        switch self {
        case .invalidBookmark:
            RiffaLocalization.string(
                "The saved security bookmark is empty or invalid."
            )
        case let .resolutionFailed(reason):
            String(
                localized: "macOS could not resolve the saved security bookmark: \(reason)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case .staleBookmark:
            RiffaLocalization.string(
                "The saved security bookmark is stale. Re-select the resource and save the session again."
            )
        case .notAFileURL:
            RiffaLocalization.string(
                "The security bookmark did not resolve to a local file URL."
            )
        case let .accessDenied(path):
            String(
                localized: "macOS denied security-scoped access to \(path). Re-select the resource and save the session again.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
    }
}
