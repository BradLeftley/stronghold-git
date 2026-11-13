import Foundation

/// The captured result of one `git` invocation.
public struct GitCommandResult: Sendable {
    public let arguments: [String]
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data

    public var succeeded: Bool { exitCode == 0 }
    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }

    /// Throws `GitError.commandFailed` unless git exited with status 0.
    @discardableResult
    public func checked() throws -> GitCommandResult {
        guard succeeded else {
            throw GitError.commandFailed(arguments: arguments, exitCode: exitCode, stderr: Redactor.redact(stderrString))
        }
        return self
    }
}

/// Runs the system `git` and captures its output.
///
/// Every call is non-interactive: git never prompts on a terminal, never opens a pager or editor, and
/// prints messages in the C locale so errors can be matched reliably. Output is captured as raw bytes and
/// parsed by the engine's NUL-aware parsers.
public struct GitRunner: Sendable {
    public let executableURL: URL
    /// Extra environment variables, applied on top of the process environment and the engine defaults.
    public var environment: [String: String]
    /// Configuration passed with `-c` on every call, so a user's config can't change output formats.
    public var configOverrides: [String: String]

    /// Defaults that make git safe to drive from a GUI.
    public static let defaultEnvironment: [String: String] = [
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_PAGER": "cat",
        "PAGER": "cat",
        "GIT_EDITOR": "true",
        "GIT_OPTIONAL_LOCKS": "0",
        "LC_ALL": "C",
        "LANG": "C",
    ]

    public static let defaultConfigOverrides: [String: String] = [
        "core.quotepath": "false",
        "color.ui": "false",
        "core.pager": "cat",
        "log.showSignature": "false",
        "diff.noprefix": "false",
        "diff.mnemonicprefix": "false",
        "diff.external": "",
        "status.relativePaths": "false",
    ]

    public init(executableURL: URL, environment: [String: String] = [:],
                configOverrides: [String: String] = GitRunner.defaultConfigOverrides) {
        self.executableURL = executableURL
        self.environment = environment
        self.configOverrides = configOverrides
    }

    /// A runner for the git found by `GitLocator`, or nil if none is installed.
    public static func system(preferredPath: String? = nil, environment: [String: String] = [:]) -> GitRunner? {
        GitLocator.locate(preferredPath: preferredPath).map { GitRunner(executableURL: $0, environment: environment) }
    }

    /// The version of the git this runner uses.
    public func version() async throws -> GitVersion {
        let result = try await run(["--version"], in: nil).checked()
        guard let version = GitVersion(parsing: result.stdoutString) else {
            throw GitError.unexpectedOutput("git --version: \(result.stdoutString)")
        }
        return version
    }

    /// The full argument list passed to the executable for `arguments`.
    func fullArguments(_ arguments: [String]) -> [String] {
        configOverrides.sorted { $0.key < $1.key }.flatMap { ["-c", "\($0.key)=\($0.value)"] } + arguments
    }

    /// The environment the child process gets.
    func processEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // Never inherit a repository selection from whoever launched us.
        for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_PREFIX", "GIT_ASKPASS", "SSH_ASKPASS"] {
            env.removeValue(forKey: key)
        }
        env.merge(Self.defaultEnvironment) { _, new in new }
        env.merge(environment) { _, new in new }
        return env
    }

    /// Runs git and returns its output. It does not throw for a non-zero exit status; call
    /// `checked()` on the result for that. It throws `GitError.launchFailed` if git can't start and
    /// `CancellationError` if the task is cancelled (the git process is terminated).
    ///
    /// `onStandardError` receives stderr as it arrives, one chunk per line or carriage-return update, which
    /// is how git reports progress for fetch, pull and push (pass `--progress` to get it without a terminal).
    public func run(_ arguments: [String], in directory: URL?, input: Data? = nil,
                    onStandardError: (@Sendable (String) -> Void)? = nil) async throws -> GitCommandResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = fullArguments(arguments)
        process.environment = processEnvironment()
        if let directory { process.currentDirectoryURL = directory }

        let control = ProcessControl(process)
        let result: GitCommandResult = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        try Self.execute(process, control: control, arguments: arguments, input: input,
                                         onStandardError: onStandardError)
                    })
                }
            }
        } onCancel: {
            control.cancel()
        }
        if control.wasCancelled { throw CancellationError() }
        return result
    }

    private static func execute(_ process: Process, control: ProcessControl, arguments: [String],
                                input: Data?, onStandardError: (@Sendable (String) -> Void)?) throws -> GitCommandResult {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = input == nil ? nil : Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe ?? FileHandle.nullDevice

        guard control.launch() else { throw CancellationError() }
        do {
            try process.run()
        } catch {
            control.finished()
            throw GitError.launchFailed(error.localizedDescription)
        }
        control.terminateIfCancelled()

        // Drain stderr and write stdin on other threads so a full pipe can never deadlock us.
        let group = DispatchGroup()
        let stderrBox = DataBox()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            if let onStandardError {
                stderrBox.data = readStreaming(stderrPipe.fileHandleForReading, onChunk: onStandardError)
            } else {
                stderrBox.data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            }
            group.leave()
        }
        if let stdinPipe, let input {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let handle = stdinPipe.fileHandleForWriting
                try? handle.write(contentsOf: input)
                try? handle.close()
                group.leave()
            }
        }
        let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        control.finished()
        return GitCommandResult(arguments: arguments, exitCode: process.terminationStatus,
                                stdout: stdout, stderr: stderrBox.data)
    }
}

/// Reads a pipe to the end, reporting each line (ended by `\n` or `\r`) as soon as it is complete.
private func readStreaming(_ handle: FileHandle, onChunk: (String) -> Void) -> Data {
    var all = Data()
    var pending = Data()
    func flush(final: Bool) {
        while let index = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let line = pending[pending.startIndex..<index]
            pending = Data(pending[(index + 1)...])
            if !line.isEmpty { onChunk(String(decoding: line, as: UTF8.self)) }
        }
        if final, !pending.isEmpty {
            onChunk(String(decoding: pending, as: UTF8.self))
            pending = Data()
        }
    }
    while true {
        let data = handle.availableData
        if data.isEmpty { break }
        all.append(data)
        pending.append(data)
        flush(final: false)
    }
    flush(final: true)
    return all
}

/// Coordinates launching and cancelling a process across threads.
private final class ProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var cancelled = false
    private var running = false

    init(_ process: Process) { self.process = process }

    var wasCancelled: Bool { lock.withLock { cancelled } }

    /// Returns false if cancellation already happened, in which case the process must not start.
    func launch() -> Bool {
        lock.withLock {
            guard !cancelled else { return false }
            running = true
            return true
        }
    }

    func finished() { lock.withLock { running = false } }

    /// Covers a cancel that arrived between `launch()` and the process actually starting.
    func terminateIfCancelled() {
        lock.withLock {
            if cancelled, process.isRunning { process.terminate() }
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            if running, process.isRunning { process.terminate() }
        }
    }
}

private final class DataBox: @unchecked Sendable {
    var data = Data()
}
