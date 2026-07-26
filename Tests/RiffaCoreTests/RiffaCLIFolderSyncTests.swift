import Foundation
import Testing
@testable import RiffaCore

@Suite("Folder synchronization CLI", .serialized)
struct RiffaCLIFolderSyncTests {
    @Test("Dry-run emits a relative-only JSON plan without writing")
    func dryRunJSONIsStableAndReadOnly() throws {
        let fixture = try CLISyncFixture()
        defer { fixture.remove() }
        try fixture.write("left bytes", to: fixture.left.appending(path: "nested/item.txt"))

        let result = try fixture.run([
            "sync", fixture.left.path, fixture.right.path,
            "--mode", "update-right", "--json",
        ])

        #expect(result.status == 1)
        #expect(result.standardError.isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.right.appending(path: "nested/item.txt").path
        ))
        #expect(!FileManager.default.fileExists(atPath: fixture.backup.path))
        #expect(!result.standardOutput.contains(fixture.root.path))

        let report = try #require(try result.jsonObject() as? [String: Any])
        #expect(report["kind"] as? String == "folder-sync")
        #expect(report["schemaVersion"] as? Int == 1)
        #expect(report["mode"] as? String == "update-right")
        #expect(report["operation"] as? String == "dry-run")
        #expect(report["status"] as? String == "ready")
        let summary = try #require(report["summary"] as? [String: Any])
        #expect(summary["actionable"] as? Int == 2)
        #expect(summary["conflicts"] as? Int == 0)
        let actions = try #require(report["actions"] as? [[String: Any]])
        #expect(actions.map { $0["targetPath"] as? String } == ["nested", "nested/item.txt"])
        #expect(actions.map { $0["kind"] as? String } == ["createDirectory", "copy"])
        #expect(!FileManager.default.fileExists(atPath: fixture.journalDirectory.path))
    }

    @Test("Apply requires backup and exact direction confirmation, then journals completion")
    func applyIsStronglyGatedAndJournaled() throws {
        let fixture = try CLISyncFixture()
        defer { fixture.remove() }
        try fixture.write("source", to: fixture.left.appending(path: "item.txt"))

        let missingBackup = try fixture.run([
            "sync", fixture.left.path, fixture.right.path,
            "--mode", "update-right", "--apply", "--confirm", "update-right",
        ])
        #expect(missingBackup.status == 2)
        #expect(missingBackup.standardError.contains("--backup DIR"))

        let wrongConfirmation = try fixture.run([
            "sync", fixture.left.path, fixture.right.path,
            "--mode", "update-right", "--apply", "--backup", fixture.backup.path,
            "--confirm", "update-left",
        ])
        #expect(wrongConfirmation.status == 2)
        #expect(wrongConfirmation.standardError.contains("--confirm update-right"))
        #expect(!FileManager.default.fileExists(atPath: fixture.right.appending(path: "item.txt").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.journalDirectory.path))

        let applied = try fixture.run([
            "sync", fixture.left.path, fixture.right.path,
            "--mode", "update-right", "--apply", "--backup", fixture.backup.path,
            "--confirm", "update-right", "--json",
        ])
        #expect(applied.status == 0)
        #expect(applied.standardError.isEmpty)
        #expect(try String(
            contentsOf: fixture.right.appending(path: "item.txt"),
            encoding: .utf8
        ) == "source")
        let report = try #require(try applied.jsonObject() as? [String: Any])
        #expect(report["operation"] as? String == "apply")
        #expect(report["status"] as? String == "completed")
        #expect(!applied.standardOutput.contains(fixture.root.path))
        let journalNames = try FileManager.default.contentsOfDirectory(
            atPath: fixture.journalDirectory.path
        )
        #expect(journalNames.contains { $0.hasSuffix(OperationJournalStore.journalFileSuffix) })
    }

    @Test("Mirror deletion requires the independent high-risk gate")
    func mirrorHighRiskGatePreventsUngatedDeletion() throws {
        let fixture = try CLISyncFixture()
        defer { fixture.remove() }
        try fixture.write("target only", to: fixture.right.appending(path: "stale.txt"))

        let refused = try fixture.run([
            "sync", fixture.left.path, fixture.right.path,
            "--mode", "mirror-left-to-right", "--apply",
            "--backup", fixture.backup.path,
            "--confirm", "mirror-left-to-right", "--json",
        ])
        #expect(refused.status == 2)
        #expect(refused.standardError.contains("--allow-high-risk"))
        #expect(FileManager.default.fileExists(atPath: fixture.right.appending(path: "stale.txt").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.journalDirectory.path))

        let applied = try fixture.run([
            "sync", fixture.left.path, fixture.right.path,
            "--mode", "mirror-left-to-right", "--apply",
            "--backup", fixture.backup.path,
            "--confirm", "mirror-left-to-right", "--allow-high-risk", "--json",
        ])
        #expect(applied.status == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.right.appending(path: "stale.txt").path))
        let report = try #require(try applied.jsonObject() as? [String: Any])
        #expect(report["status"] as? String == "completed")
    }

    @Test("Divergent update-both content blocks dry-run and apply without a journal")
    func updateBothConflictFailsClosed() throws {
        let fixture = try CLISyncFixture()
        defer { fixture.remove() }
        try fixture.write("left version", to: fixture.left.appending(path: "item.txt"))
        try fixture.write("right version", to: fixture.right.appending(path: "item.txt"))

        let dryRun = try fixture.run([
            "sync", fixture.left.path, fixture.right.path,
            "--mode", "update-both", "--json",
        ])
        #expect(dryRun.status == 2)
        let dryReport = try #require(try dryRun.jsonObject() as? [String: Any])
        #expect(dryReport["status"] as? String == "blocked")
        #expect(!dryRun.standardOutput.contains(fixture.root.path))

        let apply = try fixture.run([
            "sync", fixture.left.path, fixture.right.path,
            "--mode", "update-both", "--apply",
            "--backup", fixture.backup.path,
            "--confirm", "update-both", "--json",
        ])
        #expect(apply.status == 2)
        let applyReport = try #require(try apply.jsonObject() as? [String: Any])
        #expect(applyReport["status"] as? String == "blocked")
        #expect(!FileManager.default.fileExists(atPath: fixture.backup.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.journalDirectory.path))
        #expect(try String(
            contentsOf: fixture.left.appending(path: "item.txt"),
            encoding: .utf8
        ) == "left version")
        #expect(try String(
            contentsOf: fixture.right.appending(path: "item.txt"),
            encoding: .utf8
        ) == "right version")
    }

    @Test("Help states all safety gates and the rename-detection boundary")
    func helpDocumentsContract() throws {
        let fixture = try CLISyncFixture()
        defer { fixture.remove() }
        let result = try fixture.run(["sync", "--help"])

        #expect(result.status == 0)
        #expect(result.standardOutput.contains("--apply"))
        #expect(result.standardOutput.contains("--backup DIR"))
        #expect(result.standardOutput.contains("--confirm MODE"))
        #expect(result.standardOutput.contains("--allow-high-risk"))
        #expect(result.standardOutput.contains("SIGINT and SIGTERM"))
        #expect(result.standardOutput.contains("CLI rename detection is not enabled"))
    }
}

private struct CLISyncResult {
    let status: Int32
    let standardOutput: String
    let standardError: String

    func jsonObject() throws -> Any {
        try JSONSerialization.jsonObject(with: Data(standardOutput.utf8))
    }
}

private final class CLISyncFixture {
    let root: URL
    let left: URL
    let right: URL
    let backup: URL
    let fixedHome: URL
    let journalDirectory: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "riffa-cli-sync-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        left = root.appending(path: "left", directoryHint: .isDirectory)
        right = root.appending(path: "right", directoryHint: .isDirectory)
        backup = root.appending(path: "backup", directoryHint: .isDirectory)
        fixedHome = root.appending(path: "home", directoryHint: .isDirectory)
        journalDirectory = fixedHome
            .appending(path: "Library/Application Support", directoryHint: .isDirectory)
            .appending(path: "dev.riffa.Riffa", directoryHint: .isDirectory)
            .appending(path: "operation-journals", directoryHint: .isDirectory)
        for directory in [left, right, fixedHome] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
    }

    func write(_ value: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(value.utf8).write(to: url)
    }

    func run(_ arguments: [String]) throws -> CLISyncResult {
        let process = Process()
        process.executableURL = try riffaExecutableURL()
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["CFFIXED_USER_HOME"] = fixedHome.path
        process.environment = environment
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        return CLISyncResult(
            status: process.terminationStatus,
            standardOutput: String(
                decoding: output.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ),
            standardError: String(
                decoding: error.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private func riffaExecutableURL() throws -> URL {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let packageCandidate = packageRoot
            .appending(path: ".build", directoryHint: .isDirectory)
            .appending(path: "debug", directoryHint: .isDirectory)
            .appending(path: "riffa")
        if FileManager.default.isExecutableFile(atPath: packageCandidate.path) {
            return packageCandidate
        }

        var directory = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = directory.appending(path: "riffa")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
            directory.deleteLastPathComponent()
        }
        throw NSError(
            domain: "RiffaCLIFolderSyncTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not locate the built riffa executable."]
        )
    }
}
