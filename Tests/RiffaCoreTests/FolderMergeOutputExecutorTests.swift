import Foundation
import Testing
@testable import RiffaCore

@Test("Default dry-run is write-free and a clean plan materializes into a new output root")
func folderMergeOutputDryRunAndMaterialization() async throws {
    let sandbox = try FolderMergeOutputSandbox()
    defer { sandbox.remove() }
    try sandbox.write("unchanged", to: "docs/unchanged.txt", on: .allSources)
    try sandbox.write("base", to: "docs/edited.txt", on: [.base, .right])
    try sandbox.write("left", to: "docs/edited.txt", on: [.left])
    try sandbox.write("right addition", to: "right.txt", on: [.right])
    try sandbox.write("deleted", to: "deleted.txt", on: [.base])
    let analysis = await sandbox.analyze()
    #expect(!analysis.plan.hasConflicts)

    let dryRun = FolderMergeOutputExecutor().execute(
        plan: analysis.plan,
        baseRoot: sandbox.base,
        leftRoot: sandbox.left,
        rightRoot: sandbox.right,
        outputRoot: sandbox.output,
        backupRoot: sandbox.backup
    )

    #expect(dryRun.status == .dryRun)
    #expect(dryRun.itemResults.allSatisfy { $0.status == .planned })
    #expect(!FileManager.default.fileExists(atPath: sandbox.output.path))
    #expect(!FileManager.default.fileExists(atPath: sandbox.backup.path))

    let execution = FolderMergeOutputExecutor().execute(
        plan: analysis.plan,
        baseRoot: sandbox.base,
        leftRoot: sandbox.left,
        rightRoot: sandbox.right,
        outputRoot: sandbox.output,
        backupRoot: sandbox.backup,
        options: .init(dryRun: false)
    )

    #expect(execution.status == .completed)
    #expect(try sandbox.read("docs/unchanged.txt", from: sandbox.output) == "unchanged")
    #expect(try sandbox.read("docs/edited.txt", from: sandbox.output) == "left")
    #expect(try sandbox.read("right.txt", from: sandbox.output) == "right addition")
    #expect(!FileManager.default.fileExists(atPath: sandbox.output.appending(path: "deleted.txt").path))
    #expect(try sandbox.read("docs/edited.txt", from: sandbox.left) == "left")
    #expect(!FileManager.default.fileExists(atPath: sandbox.backup.path))
}

@Test("Every conflict needs an explicit resolution and the selected side is materialized")
func folderMergeOutputRequiresConflictResolution() async throws {
    let sandbox = try FolderMergeOutputSandbox()
    defer { sandbox.remove() }
    try sandbox.write("base", to: "conflict.txt", on: [.base])
    try sandbox.write("LEFT", to: "conflict.txt", on: [.left])
    try sandbox.write("RIGHT", to: "conflict.txt", on: [.right])
    let analysis = await sandbox.analyze()
    #expect(analysis.plan.hasConflicts)

    let refused = FolderMergeOutputExecutor().execute(
        plan: analysis.plan,
        baseRoot: sandbox.base,
        leftRoot: sandbox.left,
        rightRoot: sandbox.right,
        outputRoot: sandbox.output,
        backupRoot: sandbox.backup,
        options: .init(dryRun: false)
    )
    #expect(refused.status == .refused)
    #expect(refused.issues.contains { $0.code == .unresolvedConflict })
    #expect(!FileManager.default.fileExists(atPath: sandbox.output.path))

    let resolved = FolderMergeOutputExecutor().execute(
        plan: analysis.plan,
        resolutions: ["conflict.txt": .useRight],
        baseRoot: sandbox.base,
        leftRoot: sandbox.left,
        rightRoot: sandbox.right,
        outputRoot: sandbox.output,
        backupRoot: sandbox.backup,
        options: .init(dryRun: false)
    )
    #expect(resolved.status == .completed)
    #expect(try sandbox.read("conflict.txt", from: sandbox.output) == "RIGHT")
    #expect(resolved.itemResults.first?.resolution == .useRight)
}

@Test("Preflight checks every source before creating the output root")
func folderMergeOutputPreflightsWholePlan() throws {
    let sandbox = try FolderMergeOutputSandbox()
    defer { sandbox.remove() }
    try sandbox.write("good", to: "good.txt", on: [.left])
    let plan = FolderMergePlan(actions: [
        outputCopyAction("good.txt", source: .left),
        outputCopyAction("missing.txt", source: .right)
    ])

    let log = FolderMergeOutputExecutor().execute(
        plan: plan,
        baseRoot: sandbox.base,
        leftRoot: sandbox.left,
        rightRoot: sandbox.right,
        outputRoot: sandbox.output,
        backupRoot: sandbox.backup,
        options: .init(dryRun: false)
    )

    #expect(log.status == .refused)
    #expect(log.issues.contains { $0.code == .missingSource && $0.actionIndex == 1 })
    #expect(!FileManager.default.fileExists(atPath: sandbox.output.path))
    #expect(!FileManager.default.fileExists(atPath: sandbox.backup.path))
}

@Test("Existing output replacements and omissions are moved to the external backup root")
func folderMergeOutputBacksUpOldOutput() throws {
    let sandbox = try FolderMergeOutputSandbox(createOutput: true)
    defer { sandbox.remove() }
    try sandbox.write("new", to: "replace.txt", on: [.left])
    try sandbox.write("old", to: "replace.txt", on: [.output])
    try sandbox.write("obsolete", to: "obsolete.txt", on: [.output])
    let plan = FolderMergePlan(actions: [
        outputCopyAction("replace.txt", source: .left),
        FolderMergeAction(
            kind: .omit,
            outputRelativePath: "obsolete.txt",
            status: .bothDeleted,
            reason: "test omission"
        )
    ])

    let log = FolderMergeOutputExecutor().execute(
        plan: plan,
        baseRoot: sandbox.base,
        leftRoot: sandbox.left,
        rightRoot: sandbox.right,
        outputRoot: sandbox.output,
        backupRoot: sandbox.backup,
        options: .init(dryRun: false)
    )

    #expect(log.status == .completed)
    #expect(try sandbox.read("replace.txt", from: sandbox.output) == "new")
    #expect(!FileManager.default.fileExists(atPath: sandbox.output.appending(path: "obsolete.txt").path))
    #expect(try sandbox.read("output/replace.txt", from: sandbox.backup) == "old")
    #expect(try sandbox.read("output/obsolete.txt", from: sandbox.backup) == "obsolete")
}

@Test("A later failure restores replaced output and leaves no finalized backup")
func folderMergeOutputRollsBack() throws {
    let sandbox = try FolderMergeOutputSandbox(createOutput: true)
    defer { sandbox.remove() }
    try sandbox.write("new", to: "a.txt", on: [.left])
    try sandbox.write("old", to: "a.txt", on: [.output])
    try sandbox.write("later", to: "z.txt", on: [.left])
    let plan = FolderMergePlan(actions: [
        outputCopyAction("a.txt", source: .left),
        outputCopyAction("z.txt", source: .left)
    ])

    let log = FolderMergeOutputExecutor(testingFailureAtActionIndex: 1).execute(
        plan: plan,
        baseRoot: sandbox.base,
        leftRoot: sandbox.left,
        rightRoot: sandbox.right,
        outputRoot: sandbox.output,
        backupRoot: sandbox.backup,
        options: .init(dryRun: false)
    )

    #expect(log.status == .failedRolledBack)
    #expect(log.rollbackAttempted)
    #expect(log.rollbackSucceeded == true)
    #expect(log.itemResults[0].status == .rolledBack)
    #expect(log.itemResults[1].status == .failed)
    #expect(try sandbox.read("a.txt", from: sandbox.output) == "old")
    #expect(!FileManager.default.fileExists(atPath: sandbox.output.appending(path: "z.txt").path))
    #expect(!FileManager.default.fileExists(atPath: sandbox.backup.appending(path: "output/a.txt").path))
}

@Test("Traversal and intermediate symbolic-link escapes are rejected without writes")
func folderMergeOutputRejectsMaliciousPaths() throws {
    let traversalSandbox = try FolderMergeOutputSandbox()
    defer { traversalSandbox.remove() }
    try traversalSandbox.write("source", to: "source.txt", on: [.left])
    let traversalAction = FolderMergeAction(
        kind: .copyFromLeft,
        outputRelativePath: "../escaped.txt",
        source: .left,
        sourceRelativePath: "source.txt",
        status: .leftChanged,
        reason: "malicious"
    )
    let traversalLog = FolderMergeOutputExecutor().execute(
        plan: FolderMergePlan(actions: [traversalAction]),
        baseRoot: traversalSandbox.base,
        leftRoot: traversalSandbox.left,
        rightRoot: traversalSandbox.right,
        outputRoot: traversalSandbox.output,
        backupRoot: traversalSandbox.backup,
        options: .init(dryRun: false)
    )
    #expect(traversalLog.status == .refused)
    #expect(traversalLog.issues.contains { $0.code == .invalidRelativePath })
    #expect(!FileManager.default.fileExists(atPath: traversalSandbox.root.appending(path: "escaped.txt").path))

    let unsafeSourceAction = FolderMergeAction(
        kind: .copyFromLeft,
        outputRelativePath: "safe.txt",
        source: .left,
        sourceRelativePath: "../source.txt",
        status: .leftChanged,
        reason: "malicious source"
    )
    let unsafeSourceLog = FolderMergeOutputExecutor().execute(
        plan: FolderMergePlan(actions: [unsafeSourceAction]),
        baseRoot: traversalSandbox.base,
        leftRoot: traversalSandbox.left,
        rightRoot: traversalSandbox.right,
        outputRoot: traversalSandbox.output,
        backupRoot: traversalSandbox.backup,
        options: .init(dryRun: false)
    )
    #expect(unsafeSourceLog.status == .refused)
    #expect(unsafeSourceLog.issues.contains { $0.code == .invalidRelativePath })
    #expect(!FileManager.default.fileExists(atPath: traversalSandbox.output.path))

    let symlinkSandbox = try FolderMergeOutputSandbox(createOutput: true)
    defer { symlinkSandbox.remove() }
    try symlinkSandbox.write("source", to: "source.txt", on: [.left])
    try FileManager.default.createSymbolicLink(
        at: symlinkSandbox.output.appending(path: "linked"),
        withDestinationURL: symlinkSandbox.outside
    )
    let symlinkAction = FolderMergeAction(
        kind: .copyFromLeft,
        outputRelativePath: "linked/escaped.txt",
        source: .left,
        sourceRelativePath: "source.txt",
        status: .leftChanged,
        reason: "symlink escape"
    )
    let symlinkLog = FolderMergeOutputExecutor().execute(
        plan: FolderMergePlan(actions: [symlinkAction]),
        baseRoot: symlinkSandbox.base,
        leftRoot: symlinkSandbox.left,
        rightRoot: symlinkSandbox.right,
        outputRoot: symlinkSandbox.output,
        backupRoot: symlinkSandbox.backup,
        options: .init(dryRun: false)
    )
    #expect(symlinkLog.status == .refused)
    #expect(symlinkLog.issues.contains { $0.code == .symbolicLinkTraversal })
    #expect(!FileManager.default.fileExists(atPath: symlinkSandbox.outside.appending(path: "escaped.txt").path))
}

@Test("Output and backup roots must remain independent of all three sources")
func folderMergeOutputRejectsOverlappingRoots() throws {
    let sandbox = try FolderMergeOutputSandbox()
    defer { sandbox.remove() }
    try sandbox.write("source", to: "source.txt", on: [.left])
    let plan = FolderMergePlan(actions: [outputCopyAction("source.txt", source: .left)])
    let nestedOutput = sandbox.left.appending(path: "generated", directoryHint: .isDirectory)

    let log = FolderMergeOutputExecutor().execute(
        plan: plan,
        baseRoot: sandbox.base,
        leftRoot: sandbox.left,
        rightRoot: sandbox.right,
        outputRoot: nestedOutput,
        backupRoot: sandbox.backup,
        options: .init(dryRun: false)
    )

    #expect(log.status == .refused)
    #expect(log.issues.contains { $0.code == .overlappingRoots })
    #expect(!FileManager.default.fileExists(atPath: nestedOutput.path))
}

private func outputCopyAction(_ path: String, source: FolderMergeSource) -> FolderMergeAction {
    let kind: FolderMergeAction.Kind
    switch source {
    case .base:
        kind = .copyFromBase
    case .left:
        kind = .copyFromLeft
    case .right:
        kind = .copyFromRight
    }
    return FolderMergeAction(
        kind: kind,
        outputRelativePath: path,
        source: source,
        sourceRelativePath: path,
        status: source == .left ? .leftChanged : source == .right ? .rightChanged : .unchanged,
        reason: "test copy"
    )
}

private struct FolderMergeOutputSandbox {
    enum Location: Hashable, CaseIterable {
        case base
        case left
        case right
        case output
    }

    let root: URL
    let base: URL
    let left: URL
    let right: URL
    let output: URL
    let backup: URL
    let outside: URL

    init(createOutput: Bool = false) throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "RiffaFolderMergeOutputTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        base = root.appending(path: "base", directoryHint: .isDirectory)
        left = root.appending(path: "left", directoryHint: .isDirectory)
        right = root.appending(path: "right", directoryHint: .isDirectory)
        output = root.appending(path: "output", directoryHint: .isDirectory)
        backup = root.appending(path: "backup", directoryHint: .isDirectory)
        outside = root.appending(path: "outside", directoryHint: .isDirectory)
        for directory in [base, left, right, outside] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        if createOutput {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func analyze() async -> FolderMergeResult {
        await FolderMerge().analyze(baseURL: base, leftURL: left, rightURL: right)
    }

    func write(_ contents: String, to path: String, on locations: Set<Location>) throws {
        for location in locations {
            let file = url(for: location).appending(path: path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: file)
        }
    }

    func read(_ path: String, from root: URL) throws -> String {
        String(decoding: try Data(contentsOf: root.appending(path: path)), as: UTF8.self)
    }

    private func url(for location: Location) -> URL {
        switch location {
        case .base:
            base
        case .left:
            left
        case .right:
            right
        case .output:
            output
        }
    }
}

private extension Set<FolderMergeOutputSandbox.Location> {
    static var allSources: Self { [.base, .left, .right] }
}
