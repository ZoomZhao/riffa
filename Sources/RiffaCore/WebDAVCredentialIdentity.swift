import Foundation

/// Authentication forms that can have a secret stored outside `RiffaCore`.
///
/// The enum deliberately contains no credential material. Persistent secret
/// storage is an application concern (Keychain on macOS).
public enum WebDAVCredentialAuthenticationMode: String, Codable, Hashable, Sendable {
    case basic
    case bearer
}

public struct WebDAVCredentialIdentityError: Error, Hashable, Codable, Sendable, LocalizedError {
    public enum Code: String, Codable, Hashable, Sendable {
        case invalidBaseURL
        case insecureTransport
        case usernameRequired
        case usernameNotAllowed
    }

    public let code: Code

    public init(code: Code) {
        self.code = code
    }

    public var errorDescription: String? {
        switch code {
        case .invalidBaseURL:
            "The WebDAV credential URL is invalid."
        case .insecureTransport:
            "Stored WebDAV credentials require HTTPS."
        case .usernameRequired:
            "A username is required for Basic authentication."
        case .usernameNotAllowed:
            "Bearer authentication does not use a username."
        }
    }
}

/// A deterministic, secret-free identity for one stored WebDAV credential.
///
/// This type is safe to persist as Keychain metadata. It never accepts or
/// stores a password/token, and its textual descriptions are redacted to keep
/// future additions from accidentally becoming loggable.
public struct WebDAVCredentialIdentity: Hashable, Codable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    public let baseURL: URL
    public let authenticationMode: WebDAVCredentialAuthenticationMode
    public let username: String?
    public let account: String

    public init(
        baseURL: URL,
        authenticationMode: WebDAVCredentialAuthenticationMode,
        username: String? = nil
    ) throws {
        let normalizedBaseURL = try Self.normalize(baseURL)
        let normalizedUsername: String?
        switch authenticationMode {
        case .basic:
            guard let username, !username.isEmpty else {
                throw WebDAVCredentialIdentityError(code: .usernameRequired)
            }
            normalizedUsername = username.precomposedStringWithCanonicalMapping
        case .bearer:
            guard username == nil || username?.isEmpty == true else {
                throw WebDAVCredentialIdentityError(code: .usernameNotAllowed)
            }
            normalizedUsername = nil
        }

        self.baseURL = normalizedBaseURL
        self.authenticationMode = authenticationMode
        self.username = normalizedUsername
        account = Self.makeAccount(
            baseURL: normalizedBaseURL,
            mode: authenticationMode,
            username: normalizedUsername
        )
    }

    public var description: String { "<redacted WebDAV credential identity>" }
    public var debugDescription: String { description }

    private enum CodingKeys: String, CodingKey {
        case baseURL
        case authenticationMode
        case username
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            baseURL: container.decode(URL.self, forKey: .baseURL),
            authenticationMode: container.decode(
                WebDAVCredentialAuthenticationMode.self,
                forKey: .authenticationMode
            ),
            username: container.decodeIfPresent(String.self, forKey: .username)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(authenticationMode, forKey: .authenticationMode)
        try container.encodeIfPresent(username, forKey: .username)
    }

    private static func normalize(_ input: URL) throws -> URL {
        guard var components = URLComponents(
            url: input.absoluteURL,
            resolvingAgainstBaseURL: false
        ), let scheme = components.scheme?.lowercased(),
           let host = components.host?.lowercased(), !host.isEmpty,
           components.user == nil, components.password == nil,
           components.query == nil, components.fragment == nil else {
            throw WebDAVCredentialIdentityError(code: .invalidBaseURL)
        }
        guard scheme == "https" else {
            if scheme == "http" {
                throw WebDAVCredentialIdentityError(code: .insecureTransport)
            }
            throw WebDAVCredentialIdentityError(code: .invalidBaseURL)
        }

        var decodedPathComponents: [String] = []
        for encodedComponent in components.percentEncodedPath
            .split(separator: "/", omittingEmptySubsequences: true)
        {
            guard let decoded = String(encodedComponent).removingPercentEncoding,
                  decoded != ".", decoded != "..",
                  !decoded.contains("/"), !decoded.contains("\\"),
                  !decoded.contains("\0") else {
                throw WebDAVCredentialIdentityError(code: .invalidBaseURL)
            }
            decodedPathComponents.append(
                decoded.precomposedStringWithCanonicalMapping
            )
        }

        components.scheme = scheme
        components.host = host
        if components.port == 443 {
            components.port = nil
        }
        components.path = "/" + decodedPathComponents.joined(separator: "/")
        if components.path != "/" {
            components.path += "/"
        }

        guard let normalized = components.url else {
            throw WebDAVCredentialIdentityError(code: .invalidBaseURL)
        }
        return normalized
    }

    private static func makeAccount(
        baseURL: URL,
        mode: WebDAVCredentialAuthenticationMode,
        username: String?
    ) -> String {
        // Length-prefixed fields avoid delimiter ambiguity while remaining
        // deterministic across launches and releases.
        let url = baseURL.absoluteString
        let user = username ?? ""
        return "v1:\(mode.rawValue.utf8.count):\(mode.rawValue)"
            + ":\(url.utf8.count):\(url)"
            + ":\(user.utf8.count):\(user)"
    }
}
