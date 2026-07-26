import Foundation
import Testing
@testable import RiffaCore

@Suite("WebDAV credential identity")
struct WebDAVCredentialIdentityTests {
    @Test("Equivalent HTTPS collection URLs normalize to one account")
    func normalizesBaseURL() throws {
        let first = try WebDAVCredentialIdentity(
            baseURL: #require(URL(string: "HTTPS://EXAMPLE.test:443/dav")),
            authenticationMode: .basic,
            username: "reader"
        )
        let second = try WebDAVCredentialIdentity(
            baseURL: #require(URL(string: "https://example.test//dav/")),
            authenticationMode: .basic,
            username: "reader"
        )

        #expect(first == second)
        #expect(first.account == second.account)
        #expect(first.baseURL.absoluteString == "https://example.test/dav/")
    }

    @Test("Basic usernames and authentication modes identify different items")
    func separatesUsersAndModes() throws {
        let url = try #require(URL(string: "https://example.test/dav/"))
        let alice = try WebDAVCredentialIdentity(
            baseURL: url,
            authenticationMode: .basic,
            username: "alice"
        )
        let bob = try WebDAVCredentialIdentity(
            baseURL: url,
            authenticationMode: .basic,
            username: "bob"
        )
        let bearer = try WebDAVCredentialIdentity(
            baseURL: url,
            authenticationMode: .bearer
        )

        #expect(alice.account != bob.account)
        #expect(alice.account != bearer.account)
        #expect(bearer.username == nil)
    }

    @Test("Identity values and descriptions contain no credential secret")
    func containsNoSecret() throws {
        let secret = "never-store-this-credential"
        let identity = try WebDAVCredentialIdentity(
            baseURL: #require(URL(string: "https://example.test/dav/")),
            authenticationMode: .basic,
            username: "reader"
        )
        let encoded = try JSONEncoder().encode(identity)
        let decoded = try JSONDecoder().decode(
            WebDAVCredentialIdentity.self,
            from: encoded
        )
        let representations = [
            identity.account,
            identity.description,
            identity.debugDescription,
            String(decoding: encoded, as: UTF8.self),
        ]

        #expect(representations.allSatisfy { !$0.contains(secret) })
        #expect(identity.description == "<redacted WebDAV credential identity>")
        #expect(decoded == identity)
    }

    @Test("Invalid, unsafe, and non-HTTPS URLs fail closed")
    func rejectsInvalidURLs() throws {
        let cases: [(String, WebDAVCredentialIdentityError.Code)] = [
            ("http://example.test/dav/", .insecureTransport),
            ("ftp://example.test/dav/", .invalidBaseURL),
            ("https://user:password@example.test/dav/", .invalidBaseURL),
            ("https://example.test/dav/?token=value", .invalidBaseURL),
            ("https://example.test/dav/%2e%2e/", .invalidBaseURL),
        ]

        for (value, expectedCode) in cases {
            do {
                _ = try WebDAVCredentialIdentity(
                    baseURL: #require(URL(string: value)),
                    authenticationMode: .bearer
                )
                Issue.record("Expected URL to be rejected: \(value)")
            } catch let error as WebDAVCredentialIdentityError {
                #expect(error.code == expectedCode)
            }
        }
    }

    @Test("Authentication-specific usernames are validated")
    func validatesUsernames() throws {
        let url = try #require(URL(string: "https://example.test/dav/"))
        #expect(throws: WebDAVCredentialIdentityError.self) {
            try WebDAVCredentialIdentity(
                baseURL: url,
                authenticationMode: .basic
            )
        }
        #expect(throws: WebDAVCredentialIdentityError.self) {
            try WebDAVCredentialIdentity(
                baseURL: url,
                authenticationMode: .bearer,
                username: "unused"
            )
        }
    }
}
