import Foundation

public enum CommandDefaults {
    /// Package-manager commands run outside the user's project so a tool that
    /// walks upward looking for package.json cannot target that project.
    public static let isolatedDirectory = "/private/tmp"
}

public struct PlannedCommand: Sendable, Equatable {
    public var argv: [String]
    public var summary: String
    public var environment: [String: String]
    public var workingDirectory: String?

    public init(
        argv: [String],
        summary: String,
        environment: [String: String] = [:],
        workingDirectory: String? = nil
    ) {
        self.argv = argv
        self.summary = summary
        self.environment = environment
        self.workingDirectory = workingDirectory
    }

    public var display: String {
        argv.map(Self.quote).joined(separator: " ")
    }

    private static func quote(_ arg: String) -> String {
        let needsQuotes = arg.isEmpty || arg.contains { $0.isWhitespace || $0 == "\"" || $0 == "'" }
        guard needsQuotes else { return arg }
        let escaped = arg
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

public enum OperationEvent: Sendable, Equatable {
    case started
    case stdout(String)
    case stderr(String)
    case finished(Int32)
    case failed(String)
}

public struct UpgradeStep: Equatable, Sendable {
    public var summary: String
    public var failed: Bool
    public var output: String

    public init(summary: String, failed: Bool, output: String) {
        self.summary = summary
        self.failed = failed
        self.output = output
    }
}

public struct UpgradeBatchReport: Equatable, Sendable {
    public var succeededSummaries: [String]
    public var failedSummaries: [String]
    public var cacheHint: String?

    public var notice: String {
        let total = succeededSummaries.count + failedSummaries.count
        if total == 0 { return "" }
        if failedSummaries.isEmpty {
            if let only = succeededSummaries.first, succeededSummaries.count == 1 {
                return "Listo · \(only)"
            }
            return "Listo · \(succeededSummaries.count) actualizaciones"
        }
        if succeededSummaries.isEmpty {
            if failedSummaries.count == 1 { return "Falló · \(failedSummaries[0])" }
            return "Fallaron las \(failedSummaries.count) actualizaciones"
        }
        return "Actualizadas \(succeededSummaries.count) de \(total). Las demás siguen pendientes."
    }
}

public enum UpgradeBatch {
    public static let cacheHint = "npm no puede escribir en ~/.npm (EACCES). Hay entradas de la caché que son de root, a menudo por un sudo npm. Los demás paquetes se intentan igual. En Terminal: sudo chown -R \"$(whoami)\" ~/.npm"

    public static func report(_ steps: [UpgradeStep]) -> UpgradeBatchReport {
        UpgradeBatchReport(
            succeededSummaries: steps.filter { !$0.failed }.map(\.summary),
            failedSummaries: steps.filter(\.failed).map(\.summary),
            cacheHint: steps.contains { $0.failed && isCachePermission($0.output) } ? cacheHint : nil
        )
    }

    /// EACCES sobre la caché de npm, no un permiso cualquiera de un paquete.
    public static func isCachePermission(_ text: String) -> Bool {
        let lower = text.lowercased()
        guard lower.contains("eacces") else { return false }
        return lower.contains("_cacache") || lower.contains(".npm")
    }
}

public struct CommandResult: Sendable, Equatable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32?
    public var failure: String?

    public init(stdout: String = "", stderr: String = "", exitCode: Int32? = nil, failure: String? = nil) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.failure = failure
    }

    public var succeeded: Bool { failure == nil && exitCode == 0 }
}

public protocol CommandRunning: Sendable {
    func run(_ command: PlannedCommand) -> AsyncStream<OperationEvent>
}

extension CommandRunning {
    public func collect(_ command: PlannedCommand) async -> CommandResult {
        var result = CommandResult()
        for await event in run(command) {
            if Task.isCancelled {
                result.failure = result.failure ?? "cancelado"
                break
            }
            switch event {
            case .started:
                break
            case .stdout(let text):
                result.stdout += text
            case .stderr(let text):
                result.stderr += text
            case .finished(let code):
                result.exitCode = code
            case .failed(let message):
                result.failure = message
            }
        }
        return result
    }
}

public struct ProcessCommandRunner: CommandRunning {
    /// Direct runner refuses shells. AllowlistedShellRunner opts in after the command matches the catalog.
    public var allowShell: Bool

    public init(allowShell: Bool = false) {
        self.allowShell = allowShell
    }

    public func run(_ command: PlannedCommand) -> AsyncStream<OperationEvent> {
        let launch = Launch()
        let allowShell = self.allowShell
        return AsyncStream { continuation in
            continuation.onTermination = { _ in
                launch.cancel()
            }
            DispatchQueue.global(qos: .userInitiated).async {
                Self.execute(command, allowShell: allowShell, launch: launch, continuation: continuation)
            }
        }
    }

    private static func execute(
        _ command: PlannedCommand,
        allowShell: Bool,
        launch: Launch,
        continuation: AsyncStream<OperationEvent>.Continuation
    ) {
        defer { launch.finish(continuation) }
        continuation.yield(.started)
        guard let executable = command.argv.first, !executable.isEmpty else {
            continuation.yield(.failed("comando vacío"))
            return
        }
        if !allowShell && isShell(executable) {
            continuation.yield(.failed("rechazado: el ejecutor directo no corre un shell"))
            return
        }
        guard executable.contains("/"), FileManager.default.isExecutableFile(atPath: executable) else {
            continuation.yield(.failed("no se puede ejecutar \(executable)"))
            return
        }
        if launch.isCancelled {
            continuation.yield(.failed("cancelado"))
            return
        }

        let process = launch.process
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(command.argv.dropFirst())
        process.environment = environment(overlay: command.environment)
        if let directory = command.workingDirectory,
           FileManager.default.fileExists(atPath: directory) {
            process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            continuation.yield(.failed(error.localizedDescription))
            return
        }

        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            pump(stdout.fileHandleForReading) { continuation.yield(.stdout($0)) }
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            pump(stderr.fileHandleForReading) { continuation.yield(.stderr($0)) }
            group.leave()
        }
        process.waitUntilExit()
        group.wait()
        continuation.yield(.finished(process.terminationStatus))
    }

    private static func environment(overlay: [String: String]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = BinaryLocator.mergedSearchPaths(path: env["PATH"] ?? "").joined(separator: ":")
        for (key, value) in overlay {
            env[key] = value
        }
        return env
    }

    private static func pump(_ handle: FileHandle, yield: (String) -> Void) {
        while true {
            let data = handle.availableData
            if data.isEmpty { break }
            let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
            if !text.isEmpty { yield(text) }
        }
    }

    private static func isShell(_ executable: String) -> Bool {
        let name = (executable as NSString).lastPathComponent
        return name == "zsh" || name == "bash" || name == "sh" || name == "dash"
    }
}

private final class Launch: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    private var cancelled = false
    private var finished = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        if process.isRunning { process.terminate() }
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func finish(_ continuation: AsyncStream<OperationEvent>.Continuation) {
        lock.lock()
        let shouldFinish = !finished
        finished = true
        lock.unlock()
        if shouldFinish { continuation.finish() }
    }
}
