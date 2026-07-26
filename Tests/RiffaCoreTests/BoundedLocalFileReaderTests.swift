import Darwin
import Foundation
import Testing
@testable import RiffaCore

@Suite("Bounded local file reader")
struct BoundedLocalFileReaderTests {
    @Test("Regular files are read exactly across small chunks")
    func readsRegularFile() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "payload.bin")
            let expected = Data((0..<251).map { UInt8($0) })
            try expected.write(to: url)

            let reader = BoundedLocalFileReader(
                limits: .init(maximumByteCount: 251, chunkByteCount: 7)
            )
            #expect(try reader.read(url: url) == expected)
        }
    }

    @Test("The byte ceiling is checked before bulk allocation")
    func rejectsOversizeFile() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "oversize.bin")
            try Data(repeating: 0x41, count: 33).write(to: url)
            let reader = BoundedLocalFileReader(
                limits: .init(maximumByteCount: 32, chunkByteCount: 8)
            )

            #expect(throws: BoundedLocalFileReadError.fileTooLarge(
                actualByteCount: 33,
                limit: 32
            )) {
                try reader.read(url: url)
            }
        }
    }

    @Test("Directories and invalid limits fail structurally")
    func rejectsInvalidInputs() throws {
        try withTemporaryDirectory { directory in
            #expect(throws: BoundedLocalFileReadError.notRegularFile) {
                try BoundedLocalFileReader(
                    limits: .init(maximumByteCount: 32)
                ).read(url: directory)
            }
            #expect(throws: BoundedLocalFileReadError.invalidLimits) {
                try BoundedLocalFileReader(
                    limits: .init(maximumByteCount: 0)
                ).read(url: directory.appending(path: "missing"))
            }

            let fifo = directory.appending(path: "pipe")
            let result = fifo.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return Darwin.mkfifo(path, 0o600)
            }
            #expect(result == 0)
            #expect(throws: BoundedLocalFileReadError.notRegularFile) {
                try BoundedLocalFileReader(
                    limits: .init(maximumByteCount: 32)
                ).read(url: fifo)
            }
        }
    }

    @Test("A symbolic link resolves once to a regular descriptor")
    func readsSymbolicLinkTarget() throws {
        try withTemporaryDirectory { directory in
            let target = directory.appending(path: "target.txt")
            let link = directory.appending(path: "link.txt")
            try Data("Riffa".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(
                at: link,
                withDestinationURL: target
            )

            let data = try BoundedLocalFileReader(
                limits: .init(maximumByteCount: 32)
            ).read(url: link)
            #expect(String(decoding: data, as: UTF8.self) == "Riffa")
        }
    }

    @Test("Errors never embed the source locator")
    func errorPrivacy() throws {
        try withTemporaryDirectory { directory in
            let secretName = "private-project-7f2a.bin"
            let url = directory.appending(path: secretName)
            try Data(repeating: 0, count: 2).write(to: url)
            do {
                _ = try BoundedLocalFileReader(
                    limits: .init(maximumByteCount: 1)
                ).read(url: url)
                Issue.record("Expected an oversize error")
            } catch {
                #expect(!error.localizedDescription.contains(secretName))
                #expect(!error.localizedDescription.contains(directory.path))
            }
        }
    }

    private func withTemporaryDirectory(
        _ body: (URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "RiffaBoundedRead-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}
