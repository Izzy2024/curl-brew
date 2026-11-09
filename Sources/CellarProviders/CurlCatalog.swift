import CellarCore
import Foundation

public struct CurlInstaller: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var summary: String
    public var command: String
    public var docsURL: String
    public var binary: String?
    public var homeRelativeFile: String?
    /// Absolute paths, or paths starting with `~/`, checked before `binary`.
    public var probePaths: [String]
    public var uninstallCommand: String?

    public init(
        id: String,
        name: String,
        summary: String,
        command: String,
        docsURL: String,
        binary: String? = nil,
        homeRelativeFile: String? = nil,
        probePaths: [String] = [],
        uninstallCommand: String? = nil
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.command = command
        self.docsURL = docsURL
        self.binary = binary
        self.homeRelativeFile = homeRelativeFile
        self.probePaths = probePaths
        self.uninstallCommand = uninstallCommand
    }
}

public enum CurlPresence: Hashable, Sendable {
    case missing
    case installed(path: String, version: String?)
}

public struct CurlInstallerStatus: Identifiable, Hashable, Sendable {
    public var id: String { installer.id }
    public var installer: CurlInstaller
    public var presence: CurlPresence

    public init(installer: CurlInstaller, presence: CurlPresence) {
        self.installer = installer
        self.presence = presence
    }
}

public enum CurlCatalog {
    public static let entries: [CurlInstaller] = [
        CurlInstaller(
            id: "homebrew",
            name: "Homebrew",
            summary: "Gestor de paquetes del sistema en macOS.",
            command: #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#,
            docsURL: "https://brew.sh",
            binary: "brew"
        ),
        CurlInstaller(
            id: "bun",
            name: "Bun",
            summary: "Runtime y gestor de paquetes JavaScript.",
            command: "curl -fsSL https://bun.com/install | bash",
            docsURL: "https://bun.sh/docs/installation",
            binary: "bun"
        ),
        CurlInstaller(
            id: "pnpm",
            name: "pnpm",
            summary: "Gestor de paquetes JavaScript con almacén compartido.",
            command: "curl -fsSL https://get.pnpm.io/install.sh | sh -",
            docsURL: "https://pnpm.io/installation",
            binary: "pnpm"
        ),
        CurlInstaller(
            id: "nvm",
            name: "nvm",
            summary: "Varias versiones de Node.js por usuario. Es una función del shell, no un binario.",
            command: "curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.41.0/install.sh | bash",
            docsURL: "https://github.com/nvm-sh/nvm",
            homeRelativeFile: ".nvm/nvm.sh"
        ),
        CurlInstaller(
            id: "rustup",
            name: "rustup",
            summary: "Instalador de Rust y Cargo.",
            command: "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh",
            docsURL: "https://rustup.rs",
            binary: "rustup"
        ),
        CurlInstaller(
            id: "uv",
            name: "uv",
            summary: "Gestor de Python y de herramientas pipx.",
            command: "curl -LsSf https://astral.sh/uv/install.sh | sh",
            docsURL: "https://docs.astral.sh/uv/getting-started/installation/",
            binary: "uv"
        ),
        CurlInstaller(
            id: "deno",
            name: "Deno",
            summary: "Runtime de JavaScript y TypeScript.",
            command: "curl -fsSL https://deno.land/install.sh | sh",
            docsURL: "https://docs.deno.com/runtime/getting_started/installation/",
            binary: "deno"
        ),
        CurlInstaller(
            id: "volta",
            name: "Volta",
            summary: "Versiones fijadas de Node, npm y pnpm por proyecto.",
            command: "curl https://get.volta.sh | bash",
            docsURL: "https://docs.volta.sh/guide/getting-started",
            binary: "volta"
        ),
        CurlInstaller(
            id: "nix",
            name: "Nix",
            summary: "Gestor de paquetes declarativo y reproducible.",
            command: "curl --proto '=https' --tlsv1.2 -L https://nixos.org/nix/install | sh",
            docsURL: "https://nixos.org/download/",
            binary: "nix"
        ),
        CurlInstaller(
            id: "sdkman",
            name: "SDKMAN!",
            summary: "Versiones de SDKs de la JVM. Es una función del shell, no un binario.",
            command: "curl -s \"https://get.sdkman.io\" | bash",
            docsURL: "https://sdkman.io/install",
            homeRelativeFile: ".sdkman/bin/sdkman-init.sh"
        ),
        CurlInstaller(
            id: "magpie",
            name: "Magpie",
            summary: "Lo instala el curl de usemagpie.ai: magpie.app en /Applications (o en ~/Applications) y el comando en ~/.local/bin. Los ajustes quedan en ~/.config/magpie.",
            command: "curl -fsSL https://usemagpie.ai/install.sh | sh",
            docsURL: "https://usemagpie.ai",
            binary: "magpie",
            probePaths: [
                "/Applications/magpie.app/Contents/MacOS/magpie",
                "~/Applications/magpie.app/Contents/MacOS/magpie",
                "~/.local/bin/magpie",
            ],
            uninstallCommand: "curl -fsSL https://usemagpie.ai/install.sh | sh -s -- --uninstall"
        ),
    ]

    public static var commands: Set<String> {
        Set(entries.flatMap { [$0.command, $0.uninstallCommand].compactMap { $0 } })
    }

    public static func plan(for installer: CurlInstaller) -> PlannedCommand? {
        guard let known = entries.first(where: { $0.id == installer.id }),
              known.command == installer.command,
              known.command.contains("curl"),
              !known.command.contains("\n"),
              !known.command.contains("\r") else { return nil }
        return PlannedCommand(
            argv: ["/bin/zsh", "-lc", known.command],
            summary: "Ejecutar el instalador oficial de \(known.name)",
            workingDirectory: NSHomeDirectory()
        )
    }

    public static func planUninstall(for installer: CurlInstaller) -> PlannedCommand? {
        guard let known = entries.first(where: { $0.id == installer.id }),
              let command = known.uninstallCommand,
              command == installer.uninstallCommand,
              command.contains("curl"),
              !command.contains("\n"),
              !command.contains("\r") else { return nil }
        return PlannedCommand(
            argv: ["/bin/zsh", "-lc", command],
            summary: "Quitar \(known.name) con su desinstalador oficial",
            workingDirectory: NSHomeDirectory()
        )
    }

    static func expandHome(_ path: String, home: String) -> String {
        if path == "~" { return home }
        guard path.hasPrefix("~/") else { return path }
        return (home as NSString).appendingPathComponent(String(path.dropFirst(2)))
    }

    static func firstExecutable(_ paths: [String], home: String, isExecutable: (String) -> Bool) -> String? {
        for path in paths {
            let expanded = expandHome(path, home: home)
            if isExecutable(expanded) { return expanded }
        }
        return nil
    }

    static func bundleVersion(executablePath: String) -> String? {
        let executable = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath()
        let macos = executable.deletingLastPathComponent()
        guard macos.lastPathComponent == "MacOS" else { return nil }
        let contents = macos.deletingLastPathComponent()
        guard contents.lastPathComponent == "Contents" else { return nil }
        let plist = contents.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return object["CFBundleShortVersionString"] as? String
    }

    public static func status(
        locator: any Locating,
        runner: any CommandRunning,
        home: String = NSHomeDirectory()
    ) async -> [CurlInstallerStatus] {
        var results: [CurlInstallerStatus] = []
        for entry in entries {
            if let path = firstExecutable(entry.probePaths, home: home, isExecutable: {
                FileManager.default.isExecutableFile(atPath: $0)
            }) {
                let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                results.append(CurlInstallerStatus(
                    installer: entry,
                    presence: .installed(path: resolved, version: bundleVersion(executablePath: resolved))
                ))
                continue
            }
            if let relative = entry.homeRelativeFile {
                let path = (home as NSString).appendingPathComponent(relative)
                if FileManager.default.fileExists(atPath: path) {
                    results.append(CurlInstallerStatus(installer: entry, presence: .installed(path: path, version: nil)))
                } else {
                    results.append(CurlInstallerStatus(installer: entry, presence: .missing))
                }
                continue
            }
            guard let binary = entry.binary, let path = locator.locate(binary) else {
                results.append(CurlInstallerStatus(installer: entry, presence: .missing))
                continue
            }
            let result = await runner.collect(ToolCommand.make(
                binary: path,
                arguments: ["--version"],
                summary: "Versión de \(entry.name)"
            ))
            let version = result.succeeded
                ? result.stdout.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) }
                : nil
            results.append(CurlInstallerStatus(installer: entry, presence: .installed(path: path, version: version)))
        }
        return results
    }
}

public struct AllowlistedShellRunner<Inner: CommandRunning>: CommandRunning {
    public static var rejected: String { "rechazado: el comando no está en la lista blanca" }
    public let allowed: Set<String>
    private let inner: Inner

    public init(allowed: Set<String>, inner: Inner) {
        self.allowed = allowed
        self.inner = inner
    }

    public func run(_ command: PlannedCommand) -> AsyncStream<OperationEvent> {
        let script = command.argv.count == 3 ? command.argv[2] : ""
        guard command.argv.count == 3,
              command.argv[0] == "/bin/zsh",
              command.argv[1] == "-lc",
              !script.contains("\n"),
              !script.contains("\r"),
              allowed.contains(script) else {
            return AsyncStream { continuation in
                continuation.yield(.failed(Self.rejected))
                continuation.finish()
            }
        }
        return inner.run(command)
    }
}
