import AppKit
import Darwin
import Foundation
import RiffaCore

struct RiffaCommandLine {
    private static let maximumTextInputByteCount = 64 * 1_024 * 1_024
    private static let maximumHexInputByteCount = 32 * 1_024 * 1_024
    private static let maximumArchiveInputByteCount = 256 * 1_024 * 1_024
    private static let syncModeCLIValues = [
        "update-left",
        "update-right",
        "update-both",
        "mirror-left-to-right",
        "mirror-right-to-left",
    ]

    static func main() async {
        let operation = Task {
            try await run(arguments: Array(CommandLine.arguments.dropFirst()))
        }
        Darwin.signal(SIGINT, SIG_IGN)
        Darwin.signal(SIGTERM, SIG_IGN)
        let interruptSource = DispatchSource.makeSignalSource(
            signal: SIGINT,
            queue: .global(qos: .userInitiated)
        )
        let terminationSource = DispatchSource.makeSignalSource(
            signal: SIGTERM,
            queue: .global(qos: .userInitiated)
        )
        interruptSource.setEventHandler { operation.cancel() }
        terminationSource.setEventHandler { operation.cancel() }
        interruptSource.resume()
        terminationSource.resume()

        let exitCode: Int32
        do {
            exitCode = try await operation.value
        } catch is CancellationError {
            writeError("riffa: error: operation cancelled")
            exitCode = 2
        } catch let error as CLIError {
            writeError("riffa: error: \(error.message)")
            if error.showsUsageHint {
                writeError("Try 'riffa --help' for usage.")
            }
            exitCode = 2
        } catch {
            writeError("riffa: error: \(error.localizedDescription)")
            exitCode = 2
        }

        interruptSource.cancel()
        terminationSource.cancel()
        Darwin.exit(exitCode)
    }

    private static func run(arguments: [String]) async throws -> Int32 {
        guard let first = arguments.first else {
            printHelp()
            return 2
        }

        switch first {
        case "--help", "-h", "help":
            printHelp()
            return 0
        case "--version", "-V":
            print("riffa \(RiffaCore.version)")
            return 0
        case "--gui":
            let parsed = try parseOpenCommand(
                arguments: Array(arguments.dropFirst())
            )
            if parsed.requestsHelp {
                printOpenHelp()
                return 0
            }
            return try await runOpen(parsed)
        case "open", "gui":
            let parsed = try parseOpenCommand(
                arguments: Array(arguments.dropFirst())
            )
            if parsed.requestsHelp {
                printOpenHelp()
                return 0
            }
            return try await runOpen(parsed)
        case "text":
            let parsed = try parseCommand(
                arguments: Array(arguments.dropFirst()),
                allowedOptions: ["--ignore-case", "--ignore-whitespace", "--strict-line-endings", "--json"]
            )
            if parsed.requestsHelp {
                printTextHelp()
                return 0
            }
            return try runText(parsed)
        case "folder":
            let parsed = try parseFolderCommand(
                arguments: Array(arguments.dropFirst())
            )
            if parsed.requestsHelp {
                printFolderHelp()
                return 0
            }
            return try await runFolder(parsed)
        case "sync":
            let parsed = try parseSyncCommand(
                arguments: Array(arguments.dropFirst())
            )
            if parsed.requestsHelp {
                printSyncHelp()
                return 0
            }
            return try await runSync(parsed)
        case "hex":
            let parsed = try parseCommand(
                arguments: Array(arguments.dropFirst()),
                allowedOptions: ["--json"]
            )
            if parsed.requestsHelp {
                printHexHelp()
                return 0
            }
            return try runHex(parsed)
        case "pdf":
            let parsed = try parseCommand(
                arguments: Array(arguments.dropFirst()),
                allowedOptions: ["--json"]
            )
            if parsed.requestsHelp {
                printPDFHelp()
                return 0
            }
            return try runPDF(parsed)
        case "metadata":
            let parsed = try parseCommand(
                arguments: Array(arguments.dropFirst()),
                allowedOptions: ["--json"]
            )
            if parsed.requestsHelp {
                printMetadataHelp()
                return 0
            }
            return try runMetadata(parsed)
        case "version":
            let parsed = try parseCommand(
                arguments: Array(arguments.dropFirst()),
                allowedOptions: ["--json"]
            )
            if parsed.requestsHelp {
                printVersionHelp()
                return 0
            }
            return try runVersion(parsed)
        case "office":
            let parsed = try parseCommand(
                arguments: Array(arguments.dropFirst()),
                allowedOptions: ["--json"]
            )
            if parsed.requestsHelp {
                printOfficeHelp()
                return 0
            }
            return try runOffice(parsed)
        case "archive-compare":
            let parsed = try parseCommand(
                arguments: Array(arguments.dropFirst()),
                allowedOptions: [
                    "--no-content", "--mtime", "--permissions", "--compression", "--json"
                ]
            )
            if parsed.requestsHelp {
                printArchiveCompareHelp()
                return 0
            }
            return try runArchiveCompare(parsed)
        case "merge":
            let parsed = try parseMergeCommand(arguments: Array(arguments.dropFirst()))
            if parsed.requestsHelp {
                printMergeHelp()
                return 0
            }
            return try runMerge(parsed)
        case "table":
            let parsed = try parseCommand(
                arguments: Array(arguments.dropFirst()),
                allowedOptions: [
                    "--tsv", "--semicolon", "--pipe", "--key-first",
                    "--ignore-case", "--ignore-whitespace", "--json"
                ]
            )
            if parsed.requestsHelp {
                printTableHelp()
                return 0
            }
            return try runTable(parsed)
        case "patch":
            let parsed = try parseCommand(
                arguments: Array(arguments.dropFirst()),
                allowedOptions: ["--strict-line-endings"]
            )
            if parsed.requestsHelp {
                printPatchHelp()
                return 0
            }
            return try runPatch(parsed)
        case "patch-apply":
            let parsed = try parseCommand(
                arguments: Array(arguments.dropFirst()),
                allowedOptions: []
            )
            if parsed.requestsHelp {
                printPatchApplyHelp()
                return 0
            }
            return try runPatchApply(parsed)
        case "snapshot-create":
            let parsed = try parseCommand(
                arguments: Array(arguments.dropFirst()),
                allowedOptions: []
            )
            if parsed.requestsHelp {
                printSnapshotCreateHelp()
                return 0
            }
            return try await runSnapshotCreate(parsed)
        case "snapshot-compare":
            let parsed = try parseCommand(
                arguments: Array(arguments.dropFirst()),
                allowedOptions: ["--json"]
            )
            if parsed.requestsHelp {
                printSnapshotCompareHelp()
                return 0
            }
            return try await runSnapshotCompare(parsed)
        case "snapshot-diff":
            let parsed = try parseCommand(
                arguments: Array(arguments.dropFirst()),
                allowedOptions: ["--json"]
            )
            if parsed.requestsHelp {
                printSnapshotDiffHelp()
                return 0
            }
            return try await runSnapshotDiff(parsed)
        case "archive-list":
            let parsed = try parseSingleCommand(
                arguments: Array(arguments.dropFirst()),
                allowedOptions: ["--json"]
            )
            if parsed.requestsHelp {
                printArchiveListHelp()
                return 0
            }
            return try runArchiveList(parsed)
        case "archive-read":
            let parsed = try parseCommand(
                arguments: Array(arguments.dropFirst()),
                allowedOptions: []
            )
            if parsed.requestsHelp {
                printArchiveReadHelp()
                return 0
            }
            return try runArchiveRead(parsed)
        default:
            // A bare pair/triple of paths is intentionally accepted for
            // external diff/merge integrations. Git-compatible tools such as
            // SourceGit can then configure `riffa "$LOCAL" "$REMOTE"`
            // without needing a Riffa-specific subcommand.
            if arguments.count >= 2, arguments.count <= 3,
               !first.hasPrefix("-") {
                let parsed = try parseOpenCommand(arguments: arguments)
                return try await runOpen(parsed)
            }
            throw CLIError("unknown command '\(first)'")
        }
    }

    private static func parseOpenCommand(
        arguments: [String]
    ) throws -> ParsedOpenCommand {
        var paths: [String] = []
        var requestsHelp = false
        var acceptsOptions = true

        for argument in arguments {
            if acceptsOptions, argument == "--" {
                acceptsOptions = false
            } else if acceptsOptions, argument == "--help" || argument == "-h" {
                requestsHelp = true
            } else if acceptsOptions, argument.hasPrefix("-") {
                throw CLIError("unknown option '\(argument)'")
            } else {
                paths.append(argument)
            }
        }

        if requestsHelp {
            return ParsedOpenCommand(paths: [], requestsHelp: true)
        }
        guard paths.count == 2 || paths.count == 3 else {
            throw CLIError(
                "expected two comparison paths or three merge paths; received \(paths.count)"
            )
        }
        return ParsedOpenCommand(paths: paths, requestsHelp: false)
    }

    private static func parseMergeCommand(arguments: [String]) throws -> ParsedMergeCommand {
        var paths: [String] = []
        var options: Set<String> = []
        var acceptsOptions = true
        var requestsHelp = false

        for argument in arguments {
            if acceptsOptions, argument == "--" {
                acceptsOptions = false
            } else if acceptsOptions, argument == "--help" || argument == "-h" {
                requestsHelp = true
            } else if acceptsOptions, argument.hasPrefix("-") {
                guard argument == "--json" else {
                    throw CLIError("unknown option '\(argument)'")
                }
                options.insert(argument)
            } else {
                paths.append(argument)
            }
        }

        if requestsHelp {
            return ParsedMergeCommand(basePath: "", leftPath: "", rightPath: "", options: options, requestsHelp: true)
        }
        guard paths.count == 3 else {
            throw CLIError("expected BASE, LEFT, and RIGHT paths; received \(paths.count)")
        }
        return ParsedMergeCommand(
            basePath: paths[0],
            leftPath: paths[1],
            rightPath: paths[2],
            options: options,
            requestsHelp: false
        )
    }

    private static func parseCommand(
        arguments: [String],
        allowedOptions: Set<String>
    ) throws -> ParsedCommand {
        var paths: [String] = []
        var options: Set<String> = []
        var acceptsOptions = true
        var requestsHelp = false

        for argument in arguments {
            if acceptsOptions, argument == "--" {
                acceptsOptions = false
                continue
            }

            if acceptsOptions, argument == "--help" || argument == "-h" {
                requestsHelp = true
                continue
            }

            if acceptsOptions, argument.hasPrefix("-") {
                guard allowedOptions.contains(argument) else {
                    throw CLIError("unknown option '\(argument)'")
                }
                options.insert(argument)
            } else {
                paths.append(argument)
            }
        }

        if requestsHelp {
            return ParsedCommand(leftPath: "", rightPath: "", options: options, requestsHelp: true)
        }
        guard paths.count == 2 else {
            throw CLIError("expected LEFT and RIGHT paths; received \(paths.count)")
        }
        return ParsedCommand(
            leftPath: paths[0],
            rightPath: paths[1],
            options: options,
            requestsHelp: false
        )
    }

    private static func parseFolderCommand(
        arguments: [String]
    ) throws -> ParsedFolderCommand {
        var paths: [String] = []
        var options: Set<String> = []
        var includePatterns: [String] = []
        var excludePatterns: [String] = []
        var acceptsOptions = true
        var requestsHelp = false
        let flags: Set<String> = [
            "--contents", "--ignore-mtime", "--ignore-path-case", "--json"
        ]

        for argument in arguments {
            if acceptsOptions, argument == "--" {
                acceptsOptions = false
                continue
            }
            if acceptsOptions, argument == "--help" || argument == "-h" {
                requestsHelp = true
                continue
            }
            if acceptsOptions, argument.hasPrefix("--include=") {
                includePatterns.append(String(argument.dropFirst("--include=".count)))
                continue
            }
            if acceptsOptions, argument.hasPrefix("--exclude=") {
                excludePatterns.append(String(argument.dropFirst("--exclude=".count)))
                continue
            }
            if acceptsOptions, argument.hasPrefix("-") {
                guard flags.contains(argument) else {
                    throw CLIError("unknown option '\(argument)'")
                }
                options.insert(argument)
            } else {
                paths.append(argument)
            }
        }

        if requestsHelp {
            return ParsedFolderCommand(
                leftPath: "",
                rightPath: "",
                options: options,
                includePatterns: includePatterns,
                excludePatterns: excludePatterns,
                requestsHelp: true
            )
        }
        guard paths.count == 2 else {
            throw CLIError("expected LEFT and RIGHT paths; received \(paths.count)")
        }
        return ParsedFolderCommand(
            leftPath: paths[0],
            rightPath: paths[1],
            options: options,
            includePatterns: includePatterns,
            excludePatterns: excludePatterns,
            requestsHelp: false
        )
    }

    private static func parseSyncCommand(
        arguments: [String]
    ) throws -> ParsedSyncCommand {
        var paths: [String] = []
        var modeValue: String?
        var backupPath: String?
        var confirmationValue: String?
        var apply = false
        var allowHighRisk = false
        var emitsJSON = false
        var acceptsOptions = true
        var requestsHelp = false

        func assignUnique(_ value: String, to destination: inout String?, option: String) throws {
            guard destination == nil else {
                throw CLIError("option '\(option)' may be specified only once")
            }
            guard !value.isEmpty else {
                throw CLIError("option '\(option)' requires a non-empty value")
            }
            destination = value
        }

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if acceptsOptions, argument == "--" {
                acceptsOptions = false
            } else if acceptsOptions, argument == "--help" || argument == "-h" {
                requestsHelp = true
            } else if acceptsOptions, argument == "--apply" {
                apply = true
            } else if acceptsOptions, argument == "--allow-high-risk" {
                allowHighRisk = true
            } else if acceptsOptions, argument == "--json" {
                emitsJSON = true
            } else if acceptsOptions, argument == "--mode"
                        || argument == "--backup"
                        || argument == "--confirm" {
                guard index + 1 < arguments.count else {
                    throw CLIError("option '\(argument)' requires a value")
                }
                index += 1
                let value = arguments[index]
                switch argument {
                case "--mode":
                    try assignUnique(value, to: &modeValue, option: argument)
                case "--backup":
                    try assignUnique(value, to: &backupPath, option: argument)
                default:
                    try assignUnique(value, to: &confirmationValue, option: argument)
                }
            } else if acceptsOptions, argument.hasPrefix("--mode=") {
                try assignUnique(
                    String(argument.dropFirst("--mode=".count)),
                    to: &modeValue,
                    option: "--mode"
                )
            } else if acceptsOptions, argument.hasPrefix("--backup=") {
                try assignUnique(
                    String(argument.dropFirst("--backup=".count)),
                    to: &backupPath,
                    option: "--backup"
                )
            } else if acceptsOptions, argument.hasPrefix("--confirm=") {
                try assignUnique(
                    String(argument.dropFirst("--confirm=".count)),
                    to: &confirmationValue,
                    option: "--confirm"
                )
            } else if acceptsOptions, argument.hasPrefix("-") {
                throw CLIError("unknown option '\(argument)'")
            } else {
                paths.append(argument)
            }
            index += 1
        }

        if requestsHelp {
            return ParsedSyncCommand(
                leftPath: "",
                rightPath: "",
                mode: .updateRight,
                modeValue: "update-right",
                backupPath: nil,
                apply: false,
                allowHighRisk: false,
                emitsJSON: emitsJSON,
                requestsHelp: true
            )
        }
        guard paths.count == 2 else {
            throw CLIError("expected LEFT and RIGHT paths; received \(paths.count)")
        }
        guard let modeValue else {
            throw CLIError("option '--mode MODE' is required")
        }
        guard let mode = folderSyncMode(forCLIValue: modeValue) else {
            throw CLIError(
                "invalid sync mode '\(modeValue)'; expected \(syncModeCLIValues.joined(separator: ", "))"
            )
        }

        if apply {
            guard let backupPath else {
                throw CLIError("option '--backup DIR' is required with '--apply'")
            }
            guard confirmationValue == modeValue else {
                throw CLIError(
                    "option '--confirm \(modeValue)' must repeat the exact mode when applying"
                )
            }
            return ParsedSyncCommand(
                leftPath: paths[0],
                rightPath: paths[1],
                mode: mode,
                modeValue: modeValue,
                backupPath: backupPath,
                apply: true,
                allowHighRisk: allowHighRisk,
                emitsJSON: emitsJSON,
                requestsHelp: false
            )
        }

        guard backupPath == nil else {
            throw CLIError("option '--backup' is valid only with '--apply'")
        }
        guard confirmationValue == nil else {
            throw CLIError("option '--confirm' is valid only with '--apply'")
        }
        guard !allowHighRisk else {
            throw CLIError("option '--allow-high-risk' is valid only with '--apply'")
        }
        return ParsedSyncCommand(
            leftPath: paths[0],
            rightPath: paths[1],
            mode: mode,
            modeValue: modeValue,
            backupPath: nil,
            apply: false,
            allowHighRisk: false,
            emitsJSON: emitsJSON,
            requestsHelp: false
        )
    }

    private static func parseSingleCommand(
        arguments: [String],
        allowedOptions: Set<String>
    ) throws -> ParsedSingleCommand {
        var paths: [String] = []
        var options: Set<String> = []
        var acceptsOptions = true
        var requestsHelp = false

        for argument in arguments {
            if acceptsOptions, argument == "--" {
                acceptsOptions = false
            } else if acceptsOptions, argument == "--help" || argument == "-h" {
                requestsHelp = true
            } else if acceptsOptions, argument.hasPrefix("-") {
                guard allowedOptions.contains(argument) else {
                    throw CLIError("unknown option '\(argument)'")
                }
                options.insert(argument)
            } else {
                paths.append(argument)
            }
        }

        if requestsHelp {
            return ParsedSingleCommand(path: "", options: options, requestsHelp: true)
        }
        guard paths.count == 1 else {
            throw CLIError("expected one path; received \(paths.count)")
        }
        return ParsedSingleCommand(path: paths[0], options: options, requestsHelp: false)
    }

    private static func runText(_ command: ParsedCommand) throws -> Int32 {
        let leftURL = fileURL(for: command.leftPath)
        let rightURL = fileURL(for: command.rightPath)
        let leftText = try readUTF8File(at: leftURL)
        let rightText = try readUTF8File(at: rightURL)

        let options = TextDiffOptions(
            ignoreCase: command.options.contains("--ignore-case"),
            ignoreWhitespace: command.options.contains("--ignore-whitespace"),
            ignoreLineEndingStyle: !command.options.contains("--strict-line-endings")
        )
        let result = TextDiffEngine(options: options).compare(
            TextDocument(text: leftText),
            to: TextDocument(text: rightText)
        )

        if command.options.contains("--json") {
            try emitJSON(
                TextComparisonDTO(
                    left: leftURL.path,
                    right: rightURL.path,
                    result: result
                )
            )
        } else {
            printTextResult(result, left: leftURL.path, right: rightURL.path)
        }

        return result.hasDifferences ? 1 : 0
    }

    private static func runOpen(_ command: ParsedOpenCommand) async throws -> Int32 {
        let urls = command.paths.map(fileURL(for:))
        guard let applicationURL = riffaApplicationURL() else {
            throw CLIError(
                "could not find Riffa.app; install Riffa.app or pass the CLI from the Riffa distribution",
                showsUsageHint: false
            )
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await NSWorkspace.shared.open(
                urls,
                withApplicationAt: applicationURL,
                configuration: configuration
            )
        } catch {
            throw CLIError(
                "could not open Riffa.app: \(error.localizedDescription)",
                showsUsageHint: false
            )
        }
        return 0
    }

    private static func riffaApplicationURL() -> URL? {
        let workspace = NSWorkspace.shared
        if let url = workspace.urlForApplication(
            withBundleIdentifier: "dev.riffa.Riffa"
        ) {
            return url
        }

        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            .standardizedFileURL
        let siblingURL = executableURL
            .deletingLastPathComponent()
            .appendingPathComponent("Riffa.app", isDirectory: true)
        if FileManager.default.isReadableFile(atPath: siblingURL.path) {
            return siblingURL
        }

        let applicationsURL = URL(fileURLWithPath: "/Applications/Riffa.app")
        if FileManager.default.isReadableFile(atPath: applicationsURL.path) {
            return applicationsURL
        }
        return nil
    }

    private static func runFolder(_ command: ParsedFolderCommand) async throws -> Int32 {
        let leftURL = fileURL(for: command.leftPath)
        let rightURL = fileURL(for: command.rightPath)
        let pathRules = try FolderPathRules(
            isEnabled: !command.includePatterns.isEmpty || !command.excludePatterns.isEmpty,
            includePatterns: command.includePatterns,
            excludePatterns: command.excludePatterns,
            isCaseSensitive: !command.options.contains("--ignore-path-case")
        )
        let options = FolderComparisonOptions(
            compareModificationDates: !command.options.contains("--ignore-mtime"),
            compareFileContents: command.options.contains("--contents"),
            pathRules: pathRules
        )
        let result = await FolderComparison().compare(
            leftURL: leftURL,
            rightURL: rightURL,
            options: options
        )

        if command.options.contains("--json") {
            try emitJSON(
                FolderComparisonDTO(
                    left: leftURL.path,
                    right: rightURL.path,
                    nodes: result
                )
            )
        } else {
            printFolderResult(result, left: leftURL.path, right: rightURL.path)
        }

        let issues = result.flatMap(\.issues)
        if !issues.isEmpty || result.contains(where: { $0.status == .error }) {
            for issue in issues {
                writeError("riffa: error: \(issue.path): \(issue.message)")
            }
            if issues.isEmpty {
                writeError("riffa: error: folder comparison failed")
            }
            return 2
        }
        return result.allSatisfy { $0.status == .same } ? 0 : 1
    }

    private static func runSync(_ command: ParsedSyncCommand) async throws -> Int32 {
        let leftURL = fileURL(for: command.leftPath)
        let rightURL = fileURL(for: command.rightPath)

        try Task.checkCancellation()
        let nodes = await FolderComparison().compare(
            leftURL: leftURL,
            rightURL: rightURL,
            options: FolderComparisonOptions(
                compareModificationDates: false,
                compareFileContents: true
            )
        )
        try Task.checkCancellation()

        let plan = FolderSyncPlanner().plan(nodes: nodes, mode: command.mode)
        let comparisonFailed = nodes.contains { node in
            node.status == .error || !node.issues.isEmpty
        }
        let planBlocked = comparisonFailed || plan.summary.hasConflicts

        guard command.apply else {
            let status = planBlocked ? "blocked" : "ready"
            if command.emitsJSON {
                try emitJSON(
                    FolderSyncReportDTO(
                        mode: command.modeValue,
                        operation: "dry-run",
                        status: status,
                        plan: plan,
                        execution: nil
                    )
                )
            } else {
                printFolderSyncReport(
                    plan: plan,
                    mode: command.modeValue,
                    operation: "dry-run",
                    status: status,
                    execution: nil
                )
            }
            if comparisonFailed {
                printFolderSyncComparisonFailures(nodes)
            }
            if planBlocked { return 2 }
            return plan.summary.actionableCount == 0 ? 0 : 1
        }

        guard !planBlocked else {
            if command.emitsJSON {
                try emitJSON(
                    FolderSyncReportDTO(
                        mode: command.modeValue,
                        operation: "apply",
                        status: "blocked",
                        plan: plan,
                        execution: nil
                    )
                )
            } else {
                printFolderSyncReport(
                    plan: plan,
                    mode: command.modeValue,
                    operation: "apply",
                    status: "blocked",
                    execution: nil
                )
            }
            if comparisonFailed {
                printFolderSyncComparisonFailures(nodes)
            } else {
                writeError("riffa: error: synchronization plan contains conflicts")
            }
            return 2
        }

        if plan.summary.hasHighRiskActions, !command.allowHighRisk {
            if command.emitsJSON {
                try emitJSON(
                    FolderSyncReportDTO(
                        mode: command.modeValue,
                        operation: "apply",
                        status: "blocked",
                        plan: plan,
                        execution: nil
                    )
                )
            } else {
                printFolderSyncReport(
                    plan: plan,
                    mode: command.modeValue,
                    operation: "apply",
                    status: "blocked",
                    execution: nil
                )
            }
            writeError(
                "riffa: error: this plan contains high-risk actions; review the plan and add '--allow-high-risk' to apply it"
            )
            return 2
        }

        guard plan.summary.actionableCount > 0 else {
            if command.emitsJSON {
                try emitJSON(
                    FolderSyncReportDTO(
                        mode: command.modeValue,
                        operation: "apply",
                        status: "completed",
                        plan: plan,
                        execution: nil
                    )
                )
            } else {
                printFolderSyncReport(
                    plan: plan,
                    mode: command.modeValue,
                    operation: "apply",
                    status: "completed",
                    execution: nil
                )
            }
            return 0
        }

        guard let backupPath = command.backupPath else {
            throw CLIError("internal error: apply request has no backup directory", showsUsageHint: false)
        }
        try Task.checkCancellation()
        let log = try await JournaledLocalFolderSyncExecutor(
            journalDirectoryURL: JournaledLocalFolderSyncExecutor
                .defaultApplicationJournalDirectoryURL
        ).execute(
            plan: plan,
            leftRoot: leftURL,
            rightRoot: rightURL,
            backupRoot: fileURL(for: backupPath),
            options: LocalFolderSyncExecutionOptions(
                dryRun: false,
                allowHighRisk: command.allowHighRisk
            )
        )

        if command.emitsJSON {
            try emitJSON(
                FolderSyncReportDTO(
                    mode: command.modeValue,
                    operation: "apply",
                    status: log.status.rawValue,
                    plan: plan,
                    execution: log
                )
            )
        } else {
            printFolderSyncReport(
                plan: plan,
                mode: command.modeValue,
                operation: "apply",
                status: log.status.rawValue,
                execution: log
            )
        }
        if log.status != .completed {
            for issue in log.issues {
                let path = minimalRelativePath(issue.path).map { " at '\($0)'" } ?? ""
                writeError("riffa: error: \(issue.code.rawValue)\(path)")
            }
            return 2
        }
        return 0
    }

    private static func runHex(_ command: ParsedCommand) throws -> Int32 {
        let leftURL = fileURL(for: command.leftPath)
        let rightURL = fileURL(for: command.rightPath)
        let leftData = try readDataFile(
            at: leftURL,
            maximumByteCount: maximumHexInputByteCount
        )
        let rightData = try readDataFile(
            at: rightURL,
            maximumByteCount: maximumHexInputByteCount
        )
        let result = HexComparisonEngine().compare(left: leftData, right: rightData)

        if command.options.contains("--json") {
            try emitJSON(HexComparisonDTO(left: leftURL.path, right: rightURL.path, result: result))
        } else {
            print("Hex: \(leftURL.path) ↔ \(rightURL.path)")
            print("left \(result.leftByteCount) bytes, right \(result.rightByteCount) bytes, \(result.differingBytePositionCount) differing positions")
            for difference in result.differences {
                print(
                    String(
                        format: "@0x%08X left=%d right=%d",
                        difference.startOffset,
                        difference.leftCount,
                        difference.rightCount
                    )
                )
            }
        }
        return result.hasDifferences ? 1 : 0
    }

    private static func runPDF(_ command: ParsedCommand) throws -> Int32 {
        let leftURL = fileURL(for: command.leftPath)
        let rightURL = fileURL(for: command.rightPath)
        let result: PDFComparisonResult
        do {
            result = try PDFComparisonEngine().compare(
                leftURL: leftURL,
                rightURL: rightURL
            )
        } catch let error as PDFComparisonError {
            throw CLIError(error.localizedDescription, showsUsageHint: false)
        } catch {
            throw CLIError(
                "PDF comparison failed: \(error.localizedDescription)",
                showsUsageHint: false
            )
        }

        if command.options.contains("--json") {
            try emitJSON(
                PDFComparisonDTO(
                    left: leftURL.path,
                    right: rightURL.path,
                    result: result
                )
            )
        } else {
            printPDFResult(result, left: leftURL.path, right: rightURL.path)
        }
        return result.hasDifferences ? 1 : 0
    }

    private static func runMetadata(_ command: ParsedCommand) throws -> Int32 {
        let leftURL = fileURL(for: command.leftPath)
        let rightURL = fileURL(for: command.rightPath)
        let result: LocalMetadataComparisonResult
        do {
            result = try LocalMetadataComparisonEngine().compare(
                leftURL: leftURL,
                rightURL: rightURL
            )
        } catch let error as LocalMetadataComparisonError {
            throw CLIError(error.localizedDescription, showsUsageHint: false)
        } catch {
            throw CLIError(
                "metadata comparison failed: \(error.localizedDescription)",
                showsUsageHint: false
            )
        }

        if command.options.contains("--json") {
            try emitJSON(
                LocalMetadataComparisonDTO(
                    left: leftURL.path,
                    right: rightURL.path,
                    result: result
                )
            )
        } else {
            printMetadataResult(result, left: leftURL.path, right: rightURL.path)
        }
        return result.hasDifferences ? 1 : 0
    }

    private static func runVersion(_ command: ParsedCommand) throws -> Int32 {
        let leftURL = fileURL(for: command.leftPath)
        let rightURL = fileURL(for: command.rightPath)
        let result: VersionComparisonResult
        do {
            result = try VersionComparisonEngine().compare(
                leftURL: leftURL,
                rightURL: rightURL
            )
        } catch let error as VersionComparisonError {
            throw CLIError(error.localizedDescription, showsUsageHint: false)
        } catch {
            throw CLIError(
                "version comparison failed: \(error.localizedDescription)",
                showsUsageHint: false
            )
        }

        if command.options.contains("--json") {
            try emitJSON(
                VersionComparisonDTO(
                    left: leftURL.path,
                    right: rightURL.path,
                    result: result
                )
            )
        } else {
            printVersionResult(result, left: leftURL.path, right: rightURL.path)
        }
        return result.hasDifferences ? 1 : 0
    }

    private static func runOffice(_ command: ParsedCommand) throws -> Int32 {
        let leftURL = fileURL(for: command.leftPath)
        let rightURL = fileURL(for: command.rightPath)
        let limits = OpenXMLComparisonLimits.default
        let result: OpenXMLComparisonResult
        do {
            let leftData = try readDataFile(
                at: leftURL,
                maximumByteCount: limits.maxArchiveByteCount
            )
            let rightData = try readDataFile(
                at: rightURL,
                maximumByteCount: limits.maxArchiveByteCount
            )
            result = try OpenXMLComparisonEngine(limits: limits).compare(
                left: leftData,
                right: rightData
            )
        } catch let error as CLIError {
            throw error
        } catch let error as OpenXMLComparisonError {
            throw CLIError(error.localizedDescription, showsUsageHint: false)
        } catch {
            throw CLIError(
                "Office package comparison failed: \(error.localizedDescription)",
                showsUsageHint: false
            )
        }

        let leftLabel = leftURL.lastPathComponent
        let rightLabel = rightURL.lastPathComponent
        if command.options.contains("--json") {
            try emitJSON(
                SpecializedComparisonReportGenerator().document(
                    for: result,
                    leftLabel: leftLabel,
                    rightLabel: rightLabel
                )
            )
        } else {
            printOpenXMLResult(
                result,
                leftLabel: leftLabel,
                rightLabel: rightLabel
            )
        }
        return result.hasDifferences ? 1 : 0
    }

    private static func runArchiveCompare(_ command: ParsedCommand) throws -> Int32 {
        let leftURL = fileURL(for: command.leftPath)
        let rightURL = fileURL(for: command.rightPath)
        let limits = ArchiveComparisonLimits.default
        let options: ArchiveComparisonOptions
        let result: ArchiveComparisonResult
        do {
            options = try ArchiveComparisonOptions(
                limits: limits,
                compareContent: !command.options.contains("--no-content"),
                compareModificationDate: command.options.contains("--mtime"),
                comparePermissions: command.options.contains("--permissions"),
                compareCompression: command.options.contains("--compression")
            )
            let leftData = try readDataFile(
                at: leftURL,
                maximumByteCount: limits.archiveLimits.maxArchiveByteCount
            )
            let rightData = try readDataFile(
                at: rightURL,
                maximumByteCount: limits.archiveLimits.maxArchiveByteCount
            )
            result = try ArchiveComparisonEngine().compare(
                left: leftData,
                right: rightData,
                options: options
            )
        } catch let error as CLIError {
            throw error
        } catch let error as ArchiveComparisonError {
            throw CLIError(error.localizedDescription, showsUsageHint: false)
        } catch let error as ArchiveResourceError {
            throw CLIError(error.localizedDescription, showsUsageHint: false)
        } catch {
            throw CLIError(
                "archive comparison failed: \(error.localizedDescription)",
                showsUsageHint: false
            )
        }

        let leftLabel = leftURL.lastPathComponent
        let rightLabel = rightURL.lastPathComponent
        let reports = SpecializedComparisonReportGenerator()
        if command.options.contains("--json") {
            try emitJSON(
                reports.document(
                    for: result,
                    leftLabel: leftLabel,
                    rightLabel: rightLabel
                )
            )
        } else {
            let report = try reports.generate(
                archive: result,
                format: .plainText,
                leftLabel: leftLabel,
                rightLabel: rightLabel
            )
            FileHandle.standardOutput.write(Data(report.utf8))
        }
        return result.hasDifferences ? 1 : 0
    }

    private static func runMerge(_ command: ParsedMergeCommand) throws -> Int32 {
        let baseURL = fileURL(for: command.basePath)
        let leftURL = fileURL(for: command.leftPath)
        let rightURL = fileURL(for: command.rightPath)
        let result = ThreeWayMergeEngine().merge(
            base: try readUTF8File(at: baseURL),
            left: try readUTF8File(at: leftURL),
            right: try readUTF8File(at: rightURL)
        )

        if command.options.contains("--json") {
            try emitJSON(
                MergeComparisonDTO(
                    base: baseURL.path,
                    left: leftURL.path,
                    right: rightURL.path,
                    result: result
                )
            )
        } else {
            FileHandle.standardOutput.write(Data(result.renderedText().utf8))
        }
        return result.hasConflicts ? 1 : 0
    }

    private static func runTable(_ command: ParsedCommand) throws -> Int32 {
        let delimiterFlags = ["--tsv", "--semicolon", "--pipe"].filter(command.options.contains)
        guard delimiterFlags.count <= 1 else {
            throw CLIError("choose at most one delimiter option")
        }
        let delimiter: Character = switch delimiterFlags.first {
        case "--tsv": "\t"
        case "--semicolon": ";"
        case "--pipe": "|"
        default: ","
        }
        let leftURL = fileURL(for: command.leftPath)
        let rightURL = fileURL(for: command.rightPath)
        let options = TableComparisonOptions(
            alignment: command.options.contains("--key-first") ? .keyColumns([0]) : .rowNumber,
            ignoreCase: command.options.contains("--ignore-case"),
            ignoreWhitespace: command.options.contains("--ignore-whitespace")
        )
        let parsingLimits = try DelimitedTextParsingLimits(
            maximumInputUTF8ByteCount: 32 * 1_024 * 1_024,
            maximumCharacterCount: 8 * 1_024 * 1_024,
            maximumRowCount: 100_000,
            maximumFieldCountPerRow: 1_024,
            maximumTotalFieldCount: 1_000_000,
            maximumFieldUTF8ByteCount: 1 * 1_024 * 1_024,
            maximumDiagnosticCount: 2_000
        )
        let result: TableComparisonResult
        do {
            result = try TableComparisonEngine(options: options).compare(
                leftText: try readUTF8File(at: leftURL),
                rightText: try readUTF8File(at: rightURL),
                delimiter: delimiter,
                parsingLimits: parsingLimits
            )
        } catch let error as DelimitedTextParsingError {
            throw CLIError(
                "table parsing failed: \(error.localizedDescription)",
                showsUsageHint: false
            )
        }

        if command.options.contains("--json") {
            try emitJSON(TableComparisonDTO(left: leftURL.path, right: rightURL.path, result: result))
        } else {
            print("Table: \(leftURL.path) ↔ \(rightURL.path)")
            for row in result.rows where row.status != .same {
                let key = row.keyValues?.joined(separator: "|") ?? String(row.offset + 1)
                print("\(row.status.rawValue.padding(toLength: 14, withPad: " ", startingAt: 0)) \(key)")
            }
        }

        if !result.diagnostics.isEmpty || result.statistics.errorRowCount > 0 {
            for diagnostic in result.diagnostics {
                writeError(
                    "riffa: error: line \(diagnostic.location.line), column \(diagnostic.location.column): \(diagnostic.message)"
                )
            }
            return 2
        }
        return result.hasDifferences ? 1 : 0
    }

    private static func runPatch(_ command: ParsedCommand) throws -> Int32 {
        let oldURL = fileURL(for: command.leftPath)
        let newURL = fileURL(for: command.rightPath)
        let result = TextDiffEngine(
            options: TextDiffOptions(
                ignoreLineEndingStyle: !command.options.contains("--strict-line-endings")
            )
        ).compare(
            TextDocument(text: try readUTF8File(at: oldURL)),
            to: TextDocument(text: try readUTF8File(at: newURL))
        )
        let patch = try UnifiedDiffGenerator(contextLineCount: 3).generate(
            from: result,
            oldLabel: "a/\(oldURL.lastPathComponent)",
            newLabel: "b/\(newURL.lastPathComponent)"
        )
        FileHandle.standardOutput.write(Data(patch.utf8))
        return result.hasDifferences ? 1 : 0
    }

    private static func runPatchApply(_ command: ParsedCommand) throws -> Int32 {
        let patchURL = fileURL(for: command.leftPath)
        let sourceURL = fileURL(for: command.rightPath)
        let patch = try UnifiedPatchParser().parse(try readUTF8File(at: patchURL))
        guard patch.files.count == 1, let file = patch.files.first else {
            throw CLIError("patch-apply requires exactly one file section", showsUsageHint: false)
        }
        let source = TextDocument(text: try readUTF8File(at: sourceURL))
        let output = try UnifiedPatchApplier().apply(file, to: source)
        FileHandle.standardOutput.write(Data(output.text.utf8))
        return 0
    }

    private static func runSnapshotCreate(_ command: ParsedCommand) async throws -> Int32 {
        let folderURL = fileURL(for: command.leftPath)
        let snapshotURL = fileURL(for: command.rightPath)
        do {
            let snapshot = try await FolderSnapshotCapture().capture(folderAt: folderURL)
            try await FolderSnapshotStore(fileURL: snapshotURL).save(snapshot)
            print("Snapshot: \(snapshot.entries.count) entries, \(snapshot.issues.count) issues → \(snapshotURL.path)")
            return snapshot.issues.isEmpty ? 0 : 1
        } catch {
            throw CLIError("snapshot creation failed: \(String(describing: error))", showsUsageHint: false)
        }
    }

    private static func runSnapshotCompare(_ command: ParsedCommand) async throws -> Int32 {
        let snapshotURL = fileURL(for: command.leftPath)
        let folderURL = fileURL(for: command.rightPath)
        do {
            let snapshot = try await FolderSnapshotStore(fileURL: snapshotURL).load()
            let result = try await FolderSnapshotComparator().compare(
                snapshot: snapshot,
                toLiveFolderAt: folderURL
            )
            try printSnapshotComparison(result, json: command.options.contains("--json"))
            return result.hasDifferences ? 1 : 0
        } catch {
            throw CLIError("snapshot comparison failed: \(String(describing: error))", showsUsageHint: false)
        }
    }

    private static func runSnapshotDiff(_ command: ParsedCommand) async throws -> Int32 {
        do {
            async let left = FolderSnapshotStore(fileURL: fileURL(for: command.leftPath)).load()
            async let right = FolderSnapshotStore(fileURL: fileURL(for: command.rightPath)).load()
            let result = FolderSnapshotComparator().compare(left: try await left, right: try await right)
            try printSnapshotComparison(result, json: command.options.contains("--json"))
            return result.hasDifferences ? 1 : 0
        } catch {
            throw CLIError("snapshot diff failed: \(String(describing: error))", showsUsageHint: false)
        }
    }

    private static func printSnapshotComparison(
        _ result: FolderSnapshotComparisonResult,
        json: Bool
    ) throws {
        if json {
            try emitJSON(result)
            return
        }
        let changed = result.rows.filter { $0.status != .same }
        print("Snapshot comparison: \(changed.count) differences across \(result.rows.count) entries")
        for row in changed {
            print("\(row.status.rawValue.padding(toLength: 13, withPad: " ", startingAt: 0)) \(row.relativePath)")
        }
    }

    private static func runArchiveList(_ command: ParsedSingleCommand) throws -> Int32 {
        let archiveURL = fileURL(for: command.path)
        do {
            let provider = try ArchiveResourceProvider(
                data: readDataFile(
                    at: archiveURL,
                    maximumByteCount: maximumArchiveInputByteCount
                )
            )
            if command.options.contains("--json") {
                try emitJSON(provider.list().map(ArchiveEntryDTO.init))
            } else {
                print("Archive: \(archiveURL.path) [\(provider.format.rawValue)]")
                for entry in provider.list() {
                    print("\(entry.kind.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)) \(entry.uncompressedByteCount)\t\(entry.path)")
                }
            }
            return 0
        } catch {
            throw CLIError("archive listing failed: \(error.localizedDescription)", showsUsageHint: false)
        }
    }

    private static func runArchiveRead(_ command: ParsedCommand) throws -> Int32 {
        let archiveURL = fileURL(for: command.leftPath)
        do {
            let provider = try ArchiveResourceProvider(
                data: readDataFile(
                    at: archiveURL,
                    maximumByteCount: maximumArchiveInputByteCount
                )
            )
            FileHandle.standardOutput.write(try provider.read(command.rightPath))
            return 0
        } catch {
            throw CLIError("archive read failed: \(error.localizedDescription)", showsUsageHint: false)
        }
    }

    private static func readUTF8File(at url: URL) throws -> String {
        do {
            let data = try BoundedLocalFileReader(
                limits: .init(maximumByteCount: maximumTextInputByteCount)
            ).read(url: url)
            guard let text = String(data: data, encoding: .utf8) else {
                throw CLIError("'\(url.path)' is not valid UTF-8", showsUsageHint: false)
            }
            return text
        } catch let error as CLIError {
            throw error
        } catch {
            throw CLIError(
                "cannot read '\(url.path)': \(error.localizedDescription)",
                showsUsageHint: false
            )
        }
    }

    private static func readDataFile(
        at url: URL,
        maximumByteCount: Int
    ) throws -> Data {
        do {
            return try BoundedLocalFileReader(
                limits: .init(maximumByteCount: maximumByteCount)
            ).read(url: url)
        } catch {
            throw CLIError(
                "cannot read '\(url.path)': \(error.localizedDescription)",
                showsUsageHint: false
            )
        }
    }

    private static func fileURL(for argument: String) -> URL {
        let expanded = (argument as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appending(path: expanded)
            .standardizedFileURL
    }

    private static func printTextResult(_ result: TextDiffResult, left: String, right: String) {
        let statistics = result.statistics
        print("Text: \(left) ↔ \(right)")
        print(
            "unchanged \(statistics.unchangedLineCount), "
                + "inserted \(statistics.insertedLineCount), "
                + "deleted \(statistics.deletedLineCount), "
                + "modified \(statistics.modifiedLineCount)"
        )

        for line in result.alignedLines where line.kind != .unchanged {
            switch line.kind {
            case .inserted:
                if let right = line.right {
                    print("+ R\(right.lineNumber): \(right.line.content)")
                }
            case .deleted:
                if let left = line.left {
                    print("- L\(left.lineNumber): \(left.line.content)")
                }
            case .modified:
                let leftNumber = line.left.map { "L\($0.lineNumber)" } ?? "L-"
                let rightNumber = line.right.map { "R\($0.lineNumber)" } ?? "R-"
                let leftText = line.left?.line.content ?? ""
                let rightText = line.right?.line.content ?? ""
                let endingNote = line.hasLineEndingDifference ? " [line ending]" : ""
                print("~ \(leftNumber) → \(rightNumber): \(leftText) → \(rightText)\(endingNote)")
            case .unchanged:
                break
            }
        }
    }

    private static func printFolderResult(_ result: [PairNode], left: String, right: String) {
        print("Folder: \(left) ↔ \(right)")
        for node in result {
            print("\(folderStatusName(node.status).padding(toLength: 13, withPad: " ", startingAt: 0)) \(node.relativePath)")
        }
    }

    private static func printPDFResult(
        _ result: PDFComparisonResult,
        left: String,
        right: String
    ) {
        print("PDF: \(left) ↔ \(right)")
        print(
            "pages \(result.leftDocument.pageCount) ↔ \(result.rightDocument.pageCount), "
                + "same \(result.statistics.samePageCount), "
                + "changed \(result.statistics.changedPageCount), "
                + "left-only \(result.statistics.leftOnlyPageCount), "
                + "right-only \(result.statistics.rightOnlyPageCount)"
        )

        for metadata in result.metadataComparison.rows where metadata.status != .same {
            print("metadata \(metadata.status.rawValue): \(metadata.displayName)")
        }
        for page in result.pages where page.status != .same {
            let detail = page.differences.map(\.rawValue).joined(separator: ",")
            if detail.isEmpty {
                print("page \(page.pageNumber): \(page.status.rawValue)")
            } else {
                print("page \(page.pageNumber): \(page.status.rawValue) [\(detail)]")
            }
        }
    }

    private static func printMetadataResult(
        _ result: LocalMetadataComparisonResult,
        left: String,
        right: String
    ) {
        let statistics = result.comparison.statistics
        print("Metadata: \(left) ↔ \(right)")
        print(
            "fields \(statistics.totalCount), "
                + "same \(statistics.sameCount), "
                + "different \(statistics.differentCount), "
                + "left-only \(statistics.leftOnlyCount), "
                + "right-only \(statistics.rightOnlyCount)"
        )
        for row in result.comparison.rows where row.status != .same {
            let leftValue = metadataCLIValue(row.left)
            let rightValue = metadataCLIValue(row.right)
            print("\(row.status.rawValue): \(row.displayName): \(leftValue) → \(rightValue)")
        }
    }

    private static func printVersionResult(
        _ result: VersionComparisonResult,
        left: String,
        right: String
    ) {
        print("Version: \(left) ↔ \(right)")
        print(
            "fields \(result.statistics.totalFieldCount), "
                + "same \(result.statistics.sameFieldCount), "
                + "different \(result.statistics.differentFieldCount)"
        )
        print(versionSnapshotSummary("left", result.left))
        print(versionSnapshotSummary("right", result.right))
        for field in result.fields where field.status == .different {
            print(
                "different: \(field.field.rawValue): "
                    + "\(versionCLIValue(field.left)) → \(versionCLIValue(field.right))"
            )
        }
    }

    private static func versionSnapshotSummary(
        _ side: String,
        _ snapshot: VersionResourceSnapshot
    ) -> String {
        let version = snapshot.shortVersionString ?? "—"
        let build = snapshot.bundleVersion.map { " build \($0)" } ?? ""
        let architectures = snapshot.architectures.isEmpty
            ? "none"
            : snapshot.architectures.map(\.displayName).joined(separator: ",")
        return "\(side): \(snapshot.displayName) [\(snapshot.kind.rawValue)] version \(version)\(build), architectures \(architectures), signature \(snapshot.codeSignature.status.rawValue)"
    }

    private static func versionCLIValue(_ value: VersionComparisonValue) -> String {
        switch value {
        case let .string(value): return value
        case let .integer(value): return String(value)
        case let .strings(values): return values.isEmpty ? "—" : values.joined(separator: ",")
        case .null: return "—"
        }
    }

    private static func printOpenXMLResult(
        _ result: OpenXMLComparisonResult,
        leftLabel: String,
        rightLabel: String
    ) {
        let statistics = result.statistics
        print(
            "Office: \(leftLabel) [\(result.left.documentType.rawValue)] "
                + "↔ \(rightLabel) [\(result.right.documentType.rawValue)]"
        )
        print(
            "rows \(statistics.totalCount), "
                + "same \(statistics.sameCount), "
                + "different \(statistics.differentCount), "
                + "left-only \(statistics.leftOnlyCount), "
                + "right-only \(statistics.rightOnlyCount)"
        )
        for row in result.rows {
            print(
                "\(row.status.rawValue): \(row.key): "
                    + "\(openXMLCLIValue(row.left)) ↔ \(openXMLCLIValue(row.right))"
            )
        }
    }

    private static func openXMLCLIValue(_ value: OpenXMLComparisonValue?) -> String {
        guard let value else { return "—" }
        var components = [
            value.itemKind.rawValue,
            "items=\(value.itemCount)",
        ]
        if let byteCount = value.byteCount {
            components.append("bytes=\(byteCount)")
        }
        components.append("sha256=\(value.sha256)")
        return components.joined(separator: ",")
    }

    private static func metadataCLIValue(_ field: MetadataField?) -> String {
        guard let value = field?.value else { return "—" }
        switch value {
        case let .string(value): return value
        case let .integer(value): return String(value)
        case let .decimal(value): return NSDecimalNumber(decimal: value).stringValue
        case let .boolean(value): return value ? "true" : "false"
        case let .date(value): return ISO8601DateFormatter().string(from: value)
        case let .data(value): return "\(value.byteCount) bytes / sha256:\(value.sha256)"
        case .null: return "null"
        }
    }

    private static func folderSyncMode(forCLIValue value: String) -> FolderSyncMode? {
        switch value {
        case "update-left": .updateLeft
        case "update-right": .updateRight
        case "update-both": .updateBoth
        case "mirror-left-to-right": .mirrorLeftToRight
        case "mirror-right-to-left": .mirrorRightToLeft
        default: nil
        }
    }

    private static func printFolderSyncReport(
        plan: FolderSyncPlan,
        mode: String,
        operation: String,
        status: String,
        execution: LocalFolderSyncExecutionLog?
    ) {
        print("Folder sync \(operation) (\(mode)): \(status)")
        print(
            "Actions: \(plan.summary.actionableCount) actionable, "
                + "\(plan.summary.conflictCount) conflicts, "
                + "\(plan.summary.highRiskCount) high-risk"
        )

        let resultStatuses = Dictionary(
            uniqueKeysWithValues: (execution?.itemResults ?? []).map {
                ($0.actionIndex, $0.status.rawValue)
            }
        )
        let visibleActions = plan.actions.enumerated().filter { _, action in
            action.kind != .noOp
        }
        if visibleActions.isEmpty {
            print("  No changes.")
            return
        }
        for (index, action) in visibleActions {
            let source = folderSyncEndpoint(
                side: action.sourceSide,
                path: action.sourceRelativePath
            )
            let target = folderSyncEndpoint(
                side: action.targetSide,
                path: action.targetRelativePath
            )
            let result = resultStatuses[index].map { " {\($0)}" } ?? ""
            print(
                "  [\(action.risk.rawValue)] \(action.kind.rawValue) "
                    + "\(source) -> \(target) (\(action.reason.rawValue))\(result)"
            )
        }
    }

    private static func folderSyncEndpoint(
        side: FolderSyncSide?,
        path: String?
    ) -> String {
        guard let side, let path = minimalRelativePath(path) else { return "-" }
        return "\(side.rawValue):\(path)"
    }

    private static func printFolderSyncComparisonFailures(_ nodes: [PairNode]) {
        let paths = Set(nodes.compactMap { node -> String? in
            guard node.status == .error || !node.issues.isEmpty else { return nil }
            return minimalRelativePath(node.relativePath)
        }).sorted()
        if paths.isEmpty {
            writeError("riffa: error: folder comparison failed")
        } else {
            for path in paths {
                writeError("riffa: error: folder comparison failed at '\(path)'")
            }
        }
    }

    private static func minimalRelativePath(_ path: String?) -> String? {
        cliMinimalRelativePath(path)
    }

    private static func emitJSON<Value: Encodable>(_ value: Value) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            let data = try encoder.encode(value)
            guard let string = String(data: data, encoding: .utf8) else {
                throw CLIError("could not encode JSON output", showsUsageHint: false)
            }
            print(string)
        } catch let error as CLIError {
            throw error
        } catch {
            throw CLIError("could not encode JSON output: \(error.localizedDescription)", showsUsageHint: false)
        }
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private static func printHelp() {
        print(
            """
            Riffa \(RiffaCore.version) — compare and merge files and folders

            USAGE
              riffa open LEFT RIGHT
              riffa open BASE LEFT RIGHT
              riffa LEFT RIGHT
              riffa BASE LEFT RIGHT
              riffa text LEFT RIGHT [--ignore-case] [--ignore-whitespace] [--strict-line-endings] [--json]
              riffa folder LEFT RIGHT [--contents] [--ignore-mtime] [--json]
              riffa sync LEFT RIGHT --mode MODE [--json]
              riffa hex LEFT RIGHT [--json]
              riffa pdf LEFT RIGHT [--json]
              riffa metadata LEFT RIGHT [--json]
              riffa version LEFT RIGHT [--json]
              riffa office LEFT RIGHT [--json]
              riffa archive-compare LEFT RIGHT [--no-content] [--mtime] [--permissions] [--compression] [--json]
              riffa merge BASE LEFT RIGHT [--json]
              riffa table LEFT RIGHT [--tsv|--semicolon|--pipe] [--key-first] [--json]
              riffa patch OLD NEW [--strict-line-endings]
              riffa patch-apply PATCH SOURCE
              riffa snapshot-create FOLDER SNAPSHOT
              riffa snapshot-compare SNAPSHOT FOLDER [--json]
              riffa snapshot-diff LEFT_SNAPSHOT RIGHT_SNAPSHOT [--json]
              riffa archive-list ARCHIVE [--json]
              riffa archive-read ARCHIVE ENTRY
              riffa --help
              riffa --version

            EXIT STATUS
              0  Riffa was launched, inputs are the same, or an apply completed successfully
              1  A read-only command found actionable differences
              2  Invalid arguments, a blocked plan, or an operation error
            """
        )
    }

    private static func printOpenHelp() {
        print(
            """
            USAGE
              riffa open LEFT RIGHT
              riffa open BASE LEFT RIGHT
              riffa LEFT RIGHT
              riffa BASE LEFT RIGHT

            Open a two-way comparison or three-way merge in Riffa.app.
            The bare-path form is intended for Git external diff/merge tools.
            """
        )
    }

    private static func printTextHelp() {
        print(
            """
            USAGE
              riffa text LEFT RIGHT [OPTIONS]

            OPTIONS
              --ignore-case          Ignore letter case
              --ignore-whitespace    Ignore whitespace differences
              --strict-line-endings  Treat LF, CRLF, and CR as different
              --json                 Emit structured JSON
              --help                 Show this help
            """
        )
    }

    private static func printFolderHelp() {
        print(
            """
            USAGE
              riffa folder LEFT RIGHT [OPTIONS]

            OPTIONS
              --contents          Compare regular files byte by byte
              --ignore-mtime      Ignore modification-date differences
              --include=GLOB      Include a slash-separated relative-path glob; repeatable
              --exclude=GLOB      Exclude a relative-path glob after includes; repeatable
              --ignore-path-case  Match path rules without letter-case distinctions
              --json              Emit structured JSON
              --help              Show this help

            PATH RULES
              Patterns match the complete relative path. * and ? never cross /;
              ** may cross /. Backslash escapes the next character. With no
              --include option, all paths are included; exclusions always win.
            """
        )
    }

    private static func printSyncHelp() {
        print(
            """
            USAGE
              riffa sync LEFT RIGHT --mode MODE [--json]
              riffa sync LEFT RIGHT --mode MODE --apply --backup DIR --confirm MODE [--allow-high-risk] [--json]

            MODES
              update-left           Copy right-side additions and changes to the left
              update-right          Copy left-side additions and changes to the right
              update-both           Copy unique entries both ways; divergent pairs block apply
              mirror-left-to-right  Make the right side match the left, including deletions
              mirror-right-to-left  Make the left side match the right, including deletions

            OPTIONS
              --mode MODE         Required synchronization direction
              --json              Emit a stable report containing relative paths only
              --apply             Opt into file-system changes; otherwise this is a dry-run
              --backup DIR        Independent backup root required by --apply
              --confirm MODE      Repeat the exact --mode value to confirm its direction
              --allow-high-risk   Required to apply a plan containing deletions or other high-risk actions
              --help              Show this help

            SAFETY
              Apply uses whole-plan preflight, backups, rollback, and an operation journal.
              Dry-run performs bounded content comparison and logical planning only; it never writes.
              File-system preflight runs after the apply gates. The backup root must be outside both synchronized roots.
              SIGINT and SIGTERM request cooperative cancellation and transactional rollback.
              CLI rename detection is not enabled; mirror plans use copy/delete actions.

            EXIT STATUS
              0  No action is needed, or apply completed successfully
              1  Dry-run found one or more safely actionable changes
              2  Invalid arguments, comparison errors, conflicts, refusal, or execution failure
            """
        )
    }

    private static func printHexHelp() {
        print(
            """
            USAGE
              riffa hex LEFT RIGHT [OPTIONS]

            OPTIONS
              --json  Emit structured JSON
              --help  Show this help
            """
        )
    }

    private static func printPDFHelp() {
        print(
            """
            USAGE
              riffa pdf LEFT RIGHT [OPTIONS]

            Compares PDF metadata, page labels, media-box dimensions, rotation,
            and extracted page text. Pages are aligned by page number.

            OPTIONS
              --json  Emit the portable structured comparison
              --help  Show this help
            """
        )
    }

    private static func printMetadataHelp() {
        print(
            """
            USAGE
              riffa metadata LEFT RIGHT [OPTIONS]

            Compares the selected local directory entries without reading file
            bodies or recursively traversing directories. Symbolic links are
            reported as links and never followed. Extended-attribute values are
            represented only by bounded byte counts and SHA-256 digests.

            OPTIONS
              --json  Emit the portable structured comparison
              --help  Show this help
            """
        )
    }

    private static func printVersionHelp() {
        print(
            """
            USAGE
              riffa version LEFT RIGHT [OPTIONS]

            Statically compares regular files or macOS bundles. Riffa reports
            version fields, Mach-O architectures, executable SHA-256 digests,
            and code-signature summaries without launching either input.

            OPTIONS
              --json  Emit the portable structured comparison
              --help  Show this help
            """
        )
    }

    private static func printOfficeHelp() {
        print(
            """
            USAGE
              riffa office LEFT RIGHT [OPTIONS]

            Compares validated Office package contents. Macro-free DOCX, XLSX, and
            PPTX are identified from OPC declarations; ODS is identified from its
            ZIP mimetype, manifest, and content.xml declarations. File-name
            extensions are not trusted. Inputs use fixed archive and XML limits.

            OPTIONS
              --json  Emit the stable report DTO without local paths or raw package bytes
              --help  Show this help
            """
        )
    }

    private static func printArchiveCompareHelp() {
        print(
            """
            USAGE
              riffa archive-compare LEFT RIGHT [OPTIONS]

            Compares ZIP or TAR entries without extracting to disk or following
            symbolic links. Formats are identified from the archive bytes, not
            from file-name extensions. Inputs and member reads are strictly bounded.

            OPTIONS
              --no-content   Compare kinds and sizes without hashing matching files
              --mtime        Include member modification dates
              --permissions  Include member permission bits
              --compression  Include storage compression differences
              --json         Emit the stable portable report without local paths or raw bytes
              --help         Show this help
            """
        )
    }

    private static func printMergeHelp() {
        print(
            """
            USAGE
              riffa merge BASE LEFT RIGHT [OPTIONS]

            The merged text is written to stdout. Unresolved regions use diff3 markers.

            OPTIONS
              --json  Emit the structured result instead of merged text
              --help  Show this help
            """
        )
    }

    private static func printTableHelp() {
        print(
            """
            USAGE
              riffa table LEFT RIGHT [OPTIONS]

            OPTIONS
              --tsv                Use a tab delimiter instead of comma
              --semicolon          Use a semicolon delimiter
              --pipe               Use a pipe delimiter
              --key-first          Align by the first column instead of row number
              --ignore-case        Ignore string case
              --ignore-whitespace  Ignore all string whitespace
              --json               Emit structured JSON
              --help               Show this help
            """
        )
    }

    private static func printPatchHelp() {
        print(
            """
            USAGE
              riffa patch OLD NEW [OPTIONS]

            Writes a standard single-file unified diff to stdout without modifying either input.

            OPTIONS
              --strict-line-endings  Treat LF, CRLF, and CR as different
              --help                 Show this help
            """
        )
    }

    private static func printPatchApplyHelp() {
        print(
            """
            USAGE
              riffa patch-apply PATCH SOURCE

            Validates every hunk atomically, then writes the patched text to stdout.
            The source file is never modified.
            """
        )
    }

    private static func printSnapshotCreateHelp() {
        print("USAGE\n  riffa snapshot-create FOLDER SNAPSHOT\n\nCaptures metadata and SHA-256 digests without storing file contents or the absolute source path.")
    }

    private static func printSnapshotCompareHelp() {
        print("USAGE\n  riffa snapshot-compare SNAPSHOT FOLDER [--json]\n\nCompares a stored snapshot with a live local folder.")
    }

    private static func printSnapshotDiffHelp() {
        print("USAGE\n  riffa snapshot-diff LEFT_SNAPSHOT RIGHT_SNAPSHOT [--json]")
    }

    private static func printArchiveListHelp() {
        print("USAGE\n  riffa archive-list ARCHIVE [--json]\n\nSafely lists ZIP or TAR entries without extracting them.")
    }

    private static func printArchiveReadHelp() {
        print("USAGE\n  riffa archive-read ARCHIVE ENTRY\n\nValidates and writes one regular archive member to stdout. Links are never followed.")
    }
}

private struct FolderSyncReportDTO: Encodable {
    let kind = "folder-sync"
    let schemaVersion = 1
    let mode: String
    let operation: String
    let status: String
    let summary: FolderSyncSummaryDTO
    let actions: [FolderSyncActionDTO]
    let execution: FolderSyncExecutionDTO?

    init(
        mode: String,
        operation: String,
        status: String,
        plan: FolderSyncPlan,
        execution: LocalFolderSyncExecutionLog?
    ) {
        self.mode = mode
        self.operation = operation
        self.status = status
        summary = FolderSyncSummaryDTO(plan.summary)
        let itemStatuses = Dictionary(
            uniqueKeysWithValues: (execution?.itemResults ?? []).map {
                ($0.actionIndex, $0.status.rawValue)
            }
        )
        actions = plan.actions.enumerated().map { index, action in
            FolderSyncActionDTO(
                index: index,
                action: action,
                resultStatus: itemStatuses[index]
            )
        }
        self.execution = execution.map(FolderSyncExecutionDTO.init)
    }
}

private struct FolderSyncSummaryDTO: Encodable {
    let total: Int
    let actionable: Int
    let copies: Int
    let createdDirectories: Int
    let deletions: Int
    let moves: Int
    let replacements: Int
    let conflicts: Int
    let noOperations: Int
    let highRisk: Int

    init(_ summary: FolderSyncSummary) {
        total = summary.totalCount
        actionable = summary.actionableCount
        copies = summary.copyCount
        createdDirectories = summary.createDirectoryCount
        deletions = summary.deleteCount
        moves = summary.moveCount
        replacements = summary.replaceCount
        conflicts = summary.conflictCount
        noOperations = summary.noOpCount
        highRisk = summary.highRiskCount
    }
}

private struct FolderSyncActionDTO: Encodable {
    let index: Int
    let kind: String
    let sourceSide: String?
    let sourcePath: String?
    let targetSide: String?
    let targetPath: String?
    let reason: String
    let risk: String
    let issueCount: Int
    let resultStatus: String?

    init(index: Int, action: FolderSyncAction, resultStatus: String?) {
        self.index = index
        kind = action.kind.rawValue
        sourceSide = action.sourceSide?.rawValue
        sourcePath = cliMinimalRelativePath(action.sourceRelativePath)
        targetSide = action.targetSide?.rawValue
        targetPath = cliMinimalRelativePath(action.targetRelativePath)
        reason = action.reason.rawValue
        risk = action.risk.rawValue
        issueCount = action.issues.count
        self.resultStatus = resultStatus
    }
}

private struct FolderSyncExecutionDTO: Encodable {
    let status: String
    let rollbackAttempted: Bool
    let rollbackSucceeded: Bool?
    let issues: [FolderSyncExecutionIssueDTO]

    init(_ log: LocalFolderSyncExecutionLog) {
        status = log.status.rawValue
        rollbackAttempted = log.rollbackAttempted
        rollbackSucceeded = log.rollbackSucceeded
        issues = log.issues.map(FolderSyncExecutionIssueDTO.init)
    }
}

private struct FolderSyncExecutionIssueDTO: Encodable {
    let code: String
    let actionIndex: Int?
    let relativePath: String?

    init(_ issue: LocalFolderSyncExecutionIssue) {
        code = issue.code.rawValue
        actionIndex = issue.actionIndex
        relativePath = cliMinimalRelativePath(issue.path)
    }
}

private func cliMinimalRelativePath(_ path: String?) -> String? {
    guard let path, !path.isEmpty, !path.hasPrefix("/"), !path.utf8.contains(0) else {
        return nil
    }
    if path == "." { return path }
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
        return nil
    }
    return path
}

private struct ParsedCommand: Sendable {
    let leftPath: String
    let rightPath: String
    let options: Set<String>
    let requestsHelp: Bool
}

private struct ParsedOpenCommand: Sendable {
    let paths: [String]
    let requestsHelp: Bool
}

private struct ParsedFolderCommand: Sendable {
    let leftPath: String
    let rightPath: String
    let options: Set<String>
    let includePatterns: [String]
    let excludePatterns: [String]
    let requestsHelp: Bool
}

private struct ParsedSyncCommand: Sendable {
    let leftPath: String
    let rightPath: String
    let mode: FolderSyncMode
    let modeValue: String
    let backupPath: String?
    let apply: Bool
    let allowHighRisk: Bool
    let emitsJSON: Bool
    let requestsHelp: Bool
}

private struct ParsedSingleCommand: Sendable {
    let path: String
    let options: Set<String>
    let requestsHelp: Bool
}

private struct ParsedMergeCommand: Sendable {
    let basePath: String
    let leftPath: String
    let rightPath: String
    let options: Set<String>
    let requestsHelp: Bool
}

private struct CLIError: Error, Sendable {
    let message: String
    let showsUsageHint: Bool

    init(_ message: String, showsUsageHint: Bool = true) {
        self.message = message
        self.showsUsageHint = showsUsageHint
    }
}

private struct TextComparisonDTO: Encodable {
    let kind = "text"
    let left: String
    let right: String
    let identical: Bool
    let statistics: TextStatisticsDTO
    let lines: [TextLineDTO]

    init(left: String, right: String, result: TextDiffResult) {
        self.left = left
        self.right = right
        identical = !result.hasDifferences
        statistics = TextStatisticsDTO(result.statistics)
        lines = result.alignedLines.map(TextLineDTO.init)
    }
}

private struct TextStatisticsDTO: Encodable {
    let unchanged: Int
    let inserted: Int
    let deleted: Int
    let modified: Int

    init(_ statistics: TextDiffStatistics) {
        unchanged = statistics.unchangedLineCount
        inserted = statistics.insertedLineCount
        deleted = statistics.deletedLineCount
        modified = statistics.modifiedLineCount
    }
}

private struct TextLineDTO: Encodable {
    let status: String
    let leftLine: Int?
    let rightLine: Int?
    let leftText: String?
    let rightText: String?
    let leftLineEnding: String?
    let rightLineEnding: String?
    let hasLineEndingDifference: Bool

    init(_ line: AlignedDiffLine) {
        status = textStatusName(line.kind)
        leftLine = line.left?.lineNumber
        rightLine = line.right?.lineNumber
        leftText = line.left?.line.content
        rightText = line.right?.line.content
        leftLineEnding = line.left.map { lineEndingName($0.line.ending) }
        rightLineEnding = line.right.map { lineEndingName($0.line.ending) }
        hasLineEndingDifference = line.hasLineEndingDifference
    }
}

private struct FolderComparisonDTO: Encodable {
    let kind = "folder"
    let left: String
    let right: String
    let identical: Bool
    let counts: FolderCountsDTO
    let entries: [FolderEntryDTO]

    init(left: String, right: String, nodes: [PairNode]) {
        self.left = left
        self.right = right
        identical = nodes.allSatisfy { $0.status == .same }
        counts = FolderCountsDTO(nodes: nodes)
        entries = nodes.map(FolderEntryDTO.init)
    }
}

private struct FolderCountsDTO: Encodable {
    let same: Int
    let different: Int
    let leftOnly: Int
    let rightOnly: Int
    let typeMismatch: Int
    let error: Int

    init(nodes: [PairNode]) {
        same = nodes.count { $0.status == .same }
        different = nodes.count { $0.status == .different }
        leftOnly = nodes.count { $0.status == .leftOnly }
        rightOnly = nodes.count { $0.status == .rightOnly }
        typeMismatch = nodes.count { $0.status == .typeMismatch }
        error = nodes.count { $0.status == .error }
    }
}

private struct FolderEntryDTO: Encodable {
    let path: String
    let status: String
    let leftKind: String?
    let rightKind: String?
    let issues: [IssueDTO]

    init(_ node: PairNode) {
        path = node.relativePath
        status = folderStatusName(node.status)
        leftKind = node.left?.kind.rawValue
        rightKind = node.right?.kind.rawValue
        issues = node.issues.map(IssueDTO.init)
    }
}

private struct IssueDTO: Encodable {
    let path: String
    let message: String
    let domain: String
    let code: Int

    init(_ issue: ResourceIssue) {
        path = issue.path
        message = issue.message
        domain = issue.domain
        code = issue.code
    }
}

private struct HexComparisonDTO: Encodable {
    let kind = "hex"
    let left: String
    let right: String
    let identical: Bool
    let leftByteCount: Int
    let rightByteCount: Int
    let differingBytePositionCount: Int
    let differences: [HexDifferenceDTO]

    init(left: String, right: String, result: HexComparisonResult) {
        self.left = left
        self.right = right
        identical = !result.hasDifferences
        leftByteCount = result.leftByteCount
        rightByteCount = result.rightByteCount
        differingBytePositionCount = result.differingBytePositionCount
        differences = result.differences.map(HexDifferenceDTO.init)
    }
}

private struct HexDifferenceDTO: Encodable {
    let startOffset: Int
    let leftCount: Int
    let rightCount: Int

    init(_ range: BinaryDifferenceRange) {
        startOffset = range.startOffset
        leftCount = range.leftCount
        rightCount = range.rightCount
    }
}

private struct PDFComparisonDTO: Encodable {
    let kind = "pdf"
    let left: String
    let right: String
    let identical: Bool
    let comparison: PDFComparisonResult

    init(left: String, right: String, result: PDFComparisonResult) {
        self.left = left
        self.right = right
        identical = !result.hasDifferences
        comparison = result
    }
}

private struct LocalMetadataComparisonDTO: Encodable {
    let kind = "metadata"
    let left: String
    let right: String
    let identical: Bool
    let comparison: LocalMetadataComparisonResult

    init(left: String, right: String, result: LocalMetadataComparisonResult) {
        self.left = left
        self.right = right
        identical = !result.hasDifferences
        comparison = result
    }
}

private struct VersionComparisonDTO: Encodable {
    let kind = "version"
    let left: String
    let right: String
    let identical: Bool
    let comparison: VersionComparisonResult

    init(left: String, right: String, result: VersionComparisonResult) {
        self.left = left
        self.right = right
        identical = !result.hasDifferences
        comparison = result
    }
}

private struct MergeComparisonDTO: Encodable {
    let kind = "text-merge"
    let base: String
    let left: String
    let right: String
    let hasConflicts: Bool
    let renderedText: String
    let conflicts: [MergeConflictDTO]

    init(base: String, left: String, right: String, result: ThreeWayMergeResult) {
        self.base = base
        self.left = left
        self.right = right
        hasConflicts = result.hasConflicts
        renderedText = result.renderedText()
        conflicts = result.conflicts.map(MergeConflictDTO.init)
    }
}

private struct MergeConflictDTO: Encodable {
    let id: Int
    let baseStart: Int
    let baseCount: Int
    let leftStart: Int
    let leftCount: Int
    let rightStart: Int
    let rightCount: Int
    let baseText: String
    let leftText: String
    let rightText: String

    init(_ conflict: ThreeWayMergeConflict) {
        id = conflict.id
        baseStart = conflict.baseRange.start
        baseCount = conflict.baseRange.count
        leftStart = conflict.leftRange.start
        leftCount = conflict.leftRange.count
        rightStart = conflict.rightRange.start
        rightCount = conflict.rightRange.count
        baseText = conflict.baseText
        leftText = conflict.leftText
        rightText = conflict.rightText
    }
}

private struct TableComparisonDTO: Encodable {
    let kind = "table"
    let left: String
    let right: String
    let identical: Bool
    let statistics: TableStatisticsDTO
    let rows: [TableRowDTO]
    let diagnostics: [TableDiagnosticDTO]

    init(left: String, right: String, result: TableComparisonResult) {
        self.left = left
        self.right = right
        identical = !result.hasDifferences
        statistics = TableStatisticsDTO(result.statistics)
        rows = result.rows.map(TableRowDTO.init)
        diagnostics = result.diagnostics.map(TableDiagnosticDTO.init)
    }
}

private struct TableStatisticsDTO: Encodable {
    let same: Int
    let modified: Int
    let leftOnly: Int
    let rightOnly: Int
    let duplicateKey: Int
    let error: Int

    init(_ statistics: TableComparisonStatistics) {
        same = statistics.sameRowCount
        modified = statistics.modifiedRowCount
        leftOnly = statistics.leftOnlyRowCount
        rightOnly = statistics.rightOnlyRowCount
        duplicateKey = statistics.duplicateKeyRowCount
        error = statistics.errorRowCount
    }
}

private struct TableRowDTO: Encodable {
    let offset: Int
    let status: String
    let key: [String]?
    let left: [String]?
    let right: [String]?
    let changedColumns: [Int]

    init(_ row: TableComparisonRow) {
        offset = row.offset
        status = row.status.rawValue
        key = row.keyValues
        left = row.left?.fields.map(\.value)
        right = row.right?.fields.map(\.value)
        changedColumns = row.cells.compactMap {
            $0.status == .same || $0.status == .ignored ? nil : $0.columnIndex
        }
    }
}

private struct TableDiagnosticDTO: Encodable {
    let code: String
    let message: String
    let line: Int
    let column: Int
    let side: String?

    init(_ diagnostic: TableDiagnostic) {
        code = diagnostic.code.rawValue
        message = diagnostic.message
        line = diagnostic.location.line
        column = diagnostic.location.column
        side = diagnostic.side?.rawValue
    }
}

private struct ArchiveEntryDTO: Encodable {
    let path: String
    let kind: String
    let uncompressedByteCount: Int
    let compressedByteCount: Int
    let compression: String
    let modificationDate: Date?
    let permissions: UInt16?
    let symbolicLinkDestination: String?

    init(_ entry: ArchiveResourceEntry) {
        path = entry.path
        kind = entry.kind.rawValue
        uncompressedByteCount = entry.uncompressedByteCount
        compressedByteCount = entry.compressedByteCount
        compression = entry.compression.rawValue
        modificationDate = entry.modificationDate
        permissions = entry.permissions
        symbolicLinkDestination = entry.symbolicLinkDestination
    }
}

private func textStatusName(_ status: DiffLineKind) -> String {
    switch status {
    case .unchanged: "same"
    case .inserted: "inserted"
    case .deleted: "deleted"
    case .modified: "modified"
    }
}

private func folderStatusName(_ status: PairNode.Status) -> String {
    switch status {
    case .same: "same"
    case .different: "different"
    case .leftOnly: "left-only"
    case .rightOnly: "right-only"
    case .typeMismatch: "type-mismatch"
    case .error: "error"
    }
}

private func lineEndingName(_ ending: TextLineEnding) -> String {
    switch ending {
    case .none: "none"
    case .lf: "lf"
    case .crlf: "crlf"
    case .cr: "cr"
    }
}

await RiffaCommandLine.main()
