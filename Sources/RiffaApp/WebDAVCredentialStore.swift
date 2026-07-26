import Foundation
import RiffaCore
import Security

struct WebDAVStoredSecret: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private let storage: String

    init(_ storage: String) {
        self.storage = storage
    }

    func resolve() -> String { storage }

    var description: String { "<redacted WebDAV stored secret>" }
    var debugDescription: String { description }
}

enum WebDAVCredentialReadResult: Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    case found(WebDAVStoredSecret)
    case notFound

    var description: String {
        switch self {
        case .found: "<WebDAV credential found>"
        case .notFound: "<WebDAV credential not found>"
        }
    }

    var debugDescription: String { description }
}

enum WebDAVCredentialAvailability: Equatable, Sendable {
    case saved
    case notSaved
}

enum WebDAVCredentialSaveResult: Sendable {
    case created
    case updated
}

enum WebDAVCredentialDeleteResult: Sendable {
    case deleted
    case notFound
}

struct WebDAVCredentialStoreError: Error, Hashable, Sendable, LocalizedError,
    CustomStringConvertible, CustomDebugStringConvertible
{
    enum Operation: String, Hashable, Sendable {
        case read
        case save
        case delete
    }

    enum Code: String, Hashable, Sendable {
        case emptySecret
        case invalidStoredSecret
        case keychainFailure
    }

    let operation: Operation
    let code: Code
    let status: OSStatus?

    init(operation: Operation, code: Code, status: OSStatus? = nil) {
        self.operation = operation
        self.code = code
        self.status = status
    }

    var errorDescription: String? {
        switch code {
        case .emptySecret:
            RiffaLocalization.string(
                "The credential secret is empty and was not saved."
            )
        case .invalidStoredSecret:
            RiffaLocalization.string(
                "The saved WebDAV credential is not valid UTF-8."
            )
        case .keychainFailure:
            keychainFailureDescription
        }
    }

    var description: String {
        errorDescription
            ?? RiffaLocalization.string("The Keychain operation failed.")
    }
    var debugDescription: String { description }

    private var keychainFailureDescription: String {
        let operationTitle = switch operation {
        case .read: RiffaLocalization.string("read")
        case .save: RiffaLocalization.string("save")
        case .delete: RiffaLocalization.string("delete")
        }
        if let status {
            return String(
                localized: "The Keychain \(operationTitle) operation failed (status \(status)).",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
        return String(
            localized: "The Keychain \(operationTitle) operation failed.",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
    }
}

/// Exact-item Keychain access for WebDAV credentials.
///
/// This store never enumerates generic-password items. The caller must supply a
/// deterministic, secret-free identity for every operation.
struct WebDAVCredentialStore: Sendable {
    static let service = "dev.riffa.Riffa.webdav"

    func availability(
        for identity: WebDAVCredentialIdentity
    ) throws -> WebDAVCredentialAvailability {
        var query = exactItemQuery(for: identity)
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return .saved
        case errSecItemNotFound:
            return .notSaved
        default:
            throw WebDAVCredentialStoreError(
                operation: .read,
                code: .keychainFailure,
                status: status
            )
        }
    }

    func read(
        for identity: WebDAVCredentialIdentity
    ) throws -> WebDAVCredentialReadResult {
        var query = exactItemQuery(for: identity)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let value = String(data: data, encoding: .utf8) else {
                throw WebDAVCredentialStoreError(
                    operation: .read,
                    code: .invalidStoredSecret
                )
            }
            return .found(WebDAVStoredSecret(value))
        case errSecItemNotFound:
            return .notFound
        default:
            throw WebDAVCredentialStoreError(
                operation: .read,
                code: .keychainFailure,
                status: status
            )
        }
    }

    func save(
        _ secret: String,
        for identity: WebDAVCredentialIdentity
    ) throws -> WebDAVCredentialSaveResult {
        guard !secret.isEmpty else {
            throw WebDAVCredentialStoreError(operation: .save, code: .emptySecret)
        }
        let data = Data(secret.utf8)
        let query = exactItemQuery(for: identity)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
        ]

        var status = SecItemUpdate(
            query as CFDictionary,
            attributes as CFDictionary
        )
        if status == errSecSuccess {
            return .updated
        }
        guard status == errSecItemNotFound else {
            throw WebDAVCredentialStoreError(
                operation: .save,
                code: .keychainFailure,
                status: status
            )
        }

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrSynchronizable as String] = false
        status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecSuccess {
            return .created
        }

        // Another process/window may have created the same exact item between
        // our update and add. Resolve that one narrow race without broadening
        // the query.
        if status == errSecDuplicateItem {
            status = SecItemUpdate(
                query as CFDictionary,
                attributes as CFDictionary
            )
            if status == errSecSuccess {
                return .updated
            }
        }
        throw WebDAVCredentialStoreError(
            operation: .save,
            code: .keychainFailure,
            status: status
        )
    }

    func delete(
        for identity: WebDAVCredentialIdentity
    ) throws -> WebDAVCredentialDeleteResult {
        let status = SecItemDelete(exactItemQuery(for: identity) as CFDictionary)
        switch status {
        case errSecSuccess:
            return .deleted
        case errSecItemNotFound:
            return .notFound
        default:
            throw WebDAVCredentialStoreError(
                operation: .delete,
                code: .keychainFailure,
                status: status
            )
        }
    }

    private func exactItemQuery(
        for identity: WebDAVCredentialIdentity
    ) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: identity.account,
        ]
    }
}
