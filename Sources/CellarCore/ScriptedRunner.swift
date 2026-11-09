import Foundation

public final class ScriptedRunner: CommandRunning, @unchecked Sendable {
    public struct Script: Sendable, Equatable {
        public var stdout: String
        public var stderr: String
        public var exitCode: Int32
        public var failure: String?

        public init(stdout: String = "", stderr: String = "", exitCode: Int32 = 0, failure: String? = nil) {
            self.stdout = stdout
            self.stderr = stderr
            self.exitCode = exitCode
            self.failure = failure
        }
    }

    private let lock = NSLock()
    private var scripts: [String: Script]
    private var ranArgv: [[String]] = []

    public init(scripts: [String: Script] = [:]) {
        self.scripts = scripts
    }

    public func set(_ script: Script, for argv: [String]) {
        lock.lock()
        scripts[Self.key(argv)] = script
        lock.unlock()
    }

    public var ran: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return ranArgv
    }

    public func run(_ command: PlannedCommand) -> AsyncStream<OperationEvent> {
        let key = Self.key(command.argv)
        let basenameKey = Self.key(Self.basenameArgv(command.argv))
        lock.lock()
        ranArgv.append(command.argv)
        let script = scripts[key] ?? scripts[basenameKey]
        lock.unlock()
        return AsyncStream { continuation in
            continuation.yield(.started)
            guard let script else {
                continuation.yield(.failed("sin guion para \(command.argv.joined(separator: " "))"))
                continuation.finish()
                return
            }
            if let failure = script.failure {
                continuation.yield(.failed(failure))
                continuation.finish()
                return
            }
            if !script.stdout.isEmpty { continuation.yield(.stdout(script.stdout)) }
            if !script.stderr.isEmpty { continuation.yield(.stderr(script.stderr)) }
            continuation.yield(.finished(script.exitCode))
            continuation.finish()
        }
    }

    private static func basenameArgv(_ argv: [String]) -> [String] {
        guard let first = argv.first else { return argv }
        var copy = argv
        copy[0] = (first as NSString).lastPathComponent
        return copy
    }

    private static func key(_ argv: [String]) -> String {
        argv.joined(separator: "\u{0}")
    }
}
