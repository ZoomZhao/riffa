import CryptoKit
import Foundation
import Testing
@testable import RiffaCore

@Suite("Encoding-preserving decoded text documents")
struct DecodedTextDocumentTests {
    @Test("UTF-8 with and without a BOM round-trips byte for byte")
    func UTF8RoundTrip() throws {
        let store = DecodedTextDocumentStore()
        let payload = Data("alpha\r\n中文 😀\n".utf8)

        let plain = try store.decode(payload)
        #expect(plain.format == .utf8)
        #expect(plain.format.encoding == .utf8)
        #expect(plain.format.byteOrderMark == .none)
        #expect(plain.text == "alpha\r\n中文 😀\n")
        #expect(try plain.encodedData() == payload)

        let markedBytes = Data([0xEF, 0xBB, 0xBF]) + payload
        let marked = try store.decode(markedBytes)
        #expect(marked.format == .utf8WithByteOrderMark)
        #expect(marked.format.encoding == .utf8)
        #expect(marked.format.byteOrderMark == .utf8)
        #expect(marked.text == plain.text)
        #expect(try marked.encodedData() == markedBytes)
    }

    @Test("UTF-16 LE and BE BOM documents preserve exact code units")
    func UTF16RoundTrip() throws {
        let store = DecodedTextDocumentStore()
        let text = "A😀\r\n水"
        let littleEndian = Data([
            0xFF, 0xFE,
            0x41, 0x00,
            0x3D, 0xD8, 0x00, 0xDE,
            0x0D, 0x00, 0x0A, 0x00,
            0x34, 0x6C
        ])
        let bigEndian = Data([
            0xFE, 0xFF,
            0x00, 0x41,
            0xD8, 0x3D, 0xDE, 0x00,
            0x00, 0x0D, 0x00, 0x0A,
            0x6C, 0x34
        ])

        let littleDocument = try store.decode(littleEndian)
        #expect(littleDocument.text == text)
        #expect(littleDocument.format == .utf16LittleEndianWithByteOrderMark)
        #expect(littleDocument.format.encoding == .utf16LittleEndian)
        #expect(littleDocument.format.byteOrderMark == .utf16LittleEndian)
        #expect(try littleDocument.encodedData() == littleEndian)

        let bigDocument = try store.decode(bigEndian)
        #expect(bigDocument.text == text)
        #expect(bigDocument.format == .utf16BigEndianWithByteOrderMark)
        #expect(bigDocument.format.encoding == .utf16BigEndian)
        #expect(bigDocument.format.byteOrderMark == .utf16BigEndian)
        #expect(try bigDocument.encodedData() == bigEndian)
    }

    @Test("Malformed UTF-8 is rejected without replacement characters", arguments: [
        Data([0x80]),
        Data([0xC0, 0xAF]),
        Data([0xE0, 0x80, 0x80]),
        Data([0xED, 0xA0, 0x80]),
        Data([0xF4, 0x90, 0x80, 0x80]),
        Data([0xF0, 0x9F, 0x98])
    ])
    func invalidUTF8(data: Data) {
        assertDecodeFailure(data, code: .invalidEncoding)
    }

    @Test("Malformed UTF-16 is rejected", arguments: [
        Data([0xFF, 0xFE, 0x41]),
        Data([0xFF, 0xFE, 0x00, 0xD8]),
        Data([0xFF, 0xFE, 0x00, 0xDC]),
        Data([0xFE, 0xFF, 0xD8, 0x00, 0x00, 0x41])
    ])
    func invalidUTF16(data: Data) {
        assertDecodeFailure(data, code: .invalidEncoding)
    }

    @Test("UTF-32 BOMs are classified as unsupported")
    func unsupportedUTF32() {
        assertDecodeFailure(Data([0x00, 0x00, 0xFE, 0xFF, 0, 0, 0, 0x41]), code: .unsupportedEncoding)
        assertDecodeFailure(Data([0xFF, 0xFE, 0x00, 0x00, 0x41, 0, 0, 0]), code: .unsupportedEncoding)
    }

    @Test("Fingerprints are path-free, content-aware Codable DTOs")
    func fingerprintDTO() throws {
        let data = Data("same".utf8)
        let fingerprint = DecodedTextFileFingerprint(data: data, modificationTimeNanoseconds: 123)
        let expectedDigest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

        #expect(fingerprint.byteCount == 4)
        #expect(fingerprint.sha256 == expectedDigest)
        #expect(fingerprint.modificationTimeNanoseconds == 123)
        #expect(fingerprint.hasSameContents(as: .init(
            byteCount: 4,
            sha256: expectedDigest,
            modificationTimeNanoseconds: 999
        )))

        let encoded = try JSONEncoder().encode(fingerprint)
        let json = String(decoding: encoded, as: UTF8.self)
        #expect(!json.contains("/"))
        #expect(try JSONDecoder().decode(DecodedTextFileFingerprint.self, from: encoded) == fingerprint)
    }

    @Test("Public value types satisfy strict Sendable and Codable boundaries")
    func sendableAndCodable() async throws {
        func requireSendable<T: Sendable>(_: T.Type) {}
        requireSendable(DecodedTextEncoding.self)
        requireSendable(DecodedTextByteOrderMark.self)
        requireSendable(DecodedTextDocumentFormat.self)
        requireSendable(DecodedTextFileFingerprint.self)
        requireSendable(DecodedTextExternalModification.self)
        requireSendable(DecodedTextDocument.self)
        requireSendable(DecodedTextDocumentLimits.self)
        requireSendable(DecodedTextDocumentError.self)
        requireSendable(DecodedTextDocumentStore.self)

        let document = try DecodedTextDocumentStore().decode(Data("跨任务".utf8))
        let copied = await Task.detached { @Sendable in document }.value
        let encoded = try JSONEncoder().encode(copied)
        #expect(try JSONDecoder().decode(DecodedTextDocument.self, from: encoded) == document)
    }

    @Test("Data and file loads enforce the configured byte bound")
    func byteLimits() async throws {
        let store = DecodedTextDocumentStore(limits: .init(maximumByteCount: 3, readChunkByteCount: 2))
        do {
            _ = try store.decode(Data("four".utf8))
            Issue.record("Expected an in-memory byte-limit error")
        } catch let error as DecodedTextDocumentError {
            #expect(error.code == .byteLimitExceeded)
            #expect(error.operation == .decode)
            #expect(error.byteCount == 4)
            #expect(error.byteLimit == 3)
        }

        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("bounded.txt")
        try Data("four".utf8).write(to: file)
        do {
            _ = try await store.load(from: file)
            Issue.record("Expected an on-disk byte-limit error")
        } catch let error as DecodedTextDocumentError {
            #expect(error.code == .byteLimitExceeded)
            #expect(error.operation == .read)
            #expect(error.byteLimit == 3)
        }
    }

    @Test("Loading and re-reading distinguishes metadata and content edits")
    func externalModificationDetection() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("watched.txt")
        let bytes = Data([0xEF, 0xBB, 0xBF]) + Data("abc".utf8)
        try bytes.write(to: file)

        let store = DecodedTextDocumentStore(limits: .init(readChunkByteCount: 2))
        let document = try await store.load(from: file)
        #expect(document.format == .utf8WithByteOrderMark)
        let initialChange = try await store.externalModification(of: file, comparedTo: document.fingerprint)
        #expect(initialChange == .unchanged)

        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 3_600)],
            ofItemAtPath: file.path
        )
        let metadataChange = try await store.externalModification(of: file, comparedTo: document.fingerprint)
        #expect(metadataChange == .metadataOnly)

        let changed = Data([0xEF, 0xBB, 0xBF]) + Data("xyz".utf8)
        try changed.write(to: file)
        let contentChange = try await store.externalModification(of: file, comparedTo: document.fingerprint)
        #expect(contentChange == .contentsChanged)
    }

    @Test("Atomic save preserves original bytes and refreshes the fingerprint")
    func saveRoundTrip() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.txt")
        let destination = directory.appendingPathComponent("destination.txt")
        let bytes = Data([
            0xFE, 0xFF,
            0x00, 0x41,
            0xD8, 0x3D, 0xDE, 0x00,
            0x00, 0x0A
        ])
        try bytes.write(to: source)

        let store = DecodedTextDocumentStore()
        let document = try await store.load(from: source)
        let savedFingerprint = try await store.save(document, to: destination)
        let savedBytes = try Data(contentsOf: destination)

        #expect(savedBytes == bytes)
        #expect(savedFingerprint.hasSameContents(as: DecodedTextFileFingerprint(data: bytes)))
        #expect(try await store.load(from: destination).format == .utf16BigEndianWithByteOrderMark)
    }

    @Test("Optimistic save refuses a content conflict without overwriting it")
    func optimisticSave() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("conflict.txt")
        try Data("first".utf8).write(to: file)

        let store = DecodedTextDocumentStore()
        let document = try await store.load(from: file).replacingText(with: "mine")
        try Data("other".utf8).write(to: file)

        do {
            _ = try await store.save(document, to: file, ifContentsMatch: document.fingerprint)
            Issue.record("Expected an external-modification error")
        } catch let error as DecodedTextDocumentError {
            #expect(error.code == .externalModification)
            #expect(error.operation == .write)
        }
        #expect(try Data(contentsOf: file) == Data("other".utf8))
    }

    @Test("A cancelled task exits before decoding")
    func cancellation() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try DecodedTextDocumentStore().decode(Data("ignored".utf8))
        }
        do {
            _ = try await task.value
            Issue.record("Expected CancellationError")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Errors are stable DTOs and do not disclose file paths")
    func redactedErrors() async throws {
        let secretPath = "/private/tmp/decoded-text-secret-\(UUID().uuidString)/missing.txt"
        do {
            _ = try await DecodedTextDocumentStore().load(from: URL(fileURLWithPath: secretPath))
            Issue.record("Expected a read error")
        } catch let error as DecodedTextDocumentError {
            #expect(error.code == .ioFailure)
            #expect(error.operation == .read)
            #expect(!(error.errorDescription ?? "").contains(secretPath))

            let encoded = try JSONEncoder().encode(error)
            #expect(!String(decoding: encoded, as: UTF8.self).contains(secretPath))
            #expect(try JSONDecoder().decode(DecodedTextDocumentError.self, from: encoded) == error)
        }
    }

    private func assertDecodeFailure(
        _ data: Data,
        code: DecodedTextDocumentError.Code
    ) {
        do {
            _ = try DecodedTextDocumentStore().decode(data)
            Issue.record("Expected decoding to fail")
        } catch let error as DecodedTextDocumentError {
            #expect(error.code == code)
            #expect(error.operation == .decode)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RiffaDecodedTextTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
