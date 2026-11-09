import CellarCore
import Foundation

public struct NpmProvider<Locator: Locating, Runner: CommandRunning>: PackageProvider {
    public let id: ProviderID = .npm
    public let displayName = "npm"
    private let locator: Locator
    private let runner: Runner

    public init(locator: Locator, runner: Runner) {
        self.locator = locator
        self.runner = runner
    }

    public func availability() async -> ProviderAvailability {
        await ProviderProbe.availability(binary: "npm", locator: locator, runner: runner)
    }

    public func installed() async throws -> [InstalledPackage] {
        let npm = try binary()
        var packages = try await listed(npm, arguments: ["ls", "--global", "--depth=0", "--json"], summary: "Paquetes globales de npm")
        let root = try await modulesRoot(npm)
        packages = packages.map { package in
            var copy = package
            copy.location = JSPaths.packageDirectory(modules: root, name: package.name).path
            return copy
        }
        return packages
    }

    public func search(_ query: String) async throws -> [RemotePackage] {
        try await RegistryClient.search(query, provider: id, kind: .globalPackage, locator: locator, runner: runner)
    }

    public func details(_ package: InstalledPackage) async throws -> PackageDetails {
        if let location = package.location, let details = JSPaths.details(at: URL(fileURLWithPath: location, isDirectory: true)) {
            return details
        }
        return PackageDetails(summary: package.summary, location: package.location)
    }

    public func upgrades() async throws -> [PackageUpgrade] {
        let npm = try binary()
        let data = try await json(npm, arguments: ["outdated", "--global", "--json"], summary: "Actualizaciones globales de npm")
        return try JSUpgrades.parse(data, provider: id)
    }

    public func planInstall(_ package: PackageRef) -> PlannedCommand? {
        plan(package.name, arguments: ["install", "--global", package.name], summary: "Instalar \(package.name) con npm")
    }

    public func planUninstall(_ package: InstalledPackage) -> PlannedCommand? {
        plan(package.name, arguments: ["uninstall", "--global", package.name], summary: "Desinstalar \(package.name) con npm")
    }

    public func planUpgrade(_ package: InstalledPackage?) -> PlannedCommand? {
        guard let package else { return nil }
        return planUpgradeList([package])
    }

    /// `npm update -g` reconstruye el árbol global entero. Si cualquier otro
    /// paquete tiene una dependencia `workspace:*` (un enlace de monorepo),
    /// npm 11 aborta con EUNSUPPORTEDPROTOCOL y no actualiza nada.
    /// `npm install -g <nombre>@latest` solo reinstala el paquete pedido.
    /// Varios nombres en el mismo `install` siguen siendo una transacción:
    /// un EACCES en la caché aborta el proceso y el resto no se instala.
    /// “Actualizar todo” usa `planUpgradeCommands`, un install por paquete.
    public func planUpgradeList(_ packages: [InstalledPackage]) -> PlannedCommand? {
        let names = packages.map(\.name).filter(PackageName.isValid).sorted()
        guard !names.isEmpty, let npm = locator.locate("npm") else { return nil }
        let summary = names.count == 1
            ? "Actualizar \(names[0]) con npm"
            : "Actualizar \(names.count) paquetes globales de npm"
        return ToolCommand.make(
            binary: npm,
            arguments: ["install", "--global"] + names.map { "\($0)@latest" },
            summary: summary
        )
    }

    private func binary() throws -> String {
        guard let path = locator.locate("npm") else {
            throw ProviderFailure(provider: id, message: "npm no está instalado")
        }
        return path
    }

    private func plan(_ name: String, arguments: [String], summary: String) -> PlannedCommand? {
        guard PackageName.isValid(name), let npm = locator.locate("npm") else { return nil }
        return ToolCommand.make(binary: npm, arguments: arguments, summary: summary)
    }

    private func listed(_ npm: String, arguments: [String], summary: String) async throws -> [InstalledPackage] {
        let data = try await json(npm, arguments: arguments, summary: summary)
        return try DependencyJSON.packages(from: data, provider: id)
    }

    private func modulesRoot(_ npm: String) async throws -> URL {
        let result = await runner.collect(ToolCommand.make(binary: npm, arguments: ["root", "--global"], summary: "Raíz global de npm"))
        let path = try CommandText.stdout(from: result, provider: id).trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else {
            throw ProviderFailure(provider: id, message: "raíz global de npm no válida")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func json(_ npm: String, arguments: [String], summary: String) async throws -> Data {
        let result = await runner.collect(ToolCommand.make(binary: npm, arguments: arguments, summary: summary))
        return try CommandJSON.data(from: result, provider: id, acceptNonZero: true)
    }
}

public struct PnpmProvider<Locator: Locating, Runner: CommandRunning>: PackageProvider {
    public let id: ProviderID = .pnpm
    public let displayName = "pnpm"
    private let locator: Locator
    private let runner: Runner

    public init(locator: Locator, runner: Runner) {
        self.locator = locator
        self.runner = runner
    }

    public func availability() async -> ProviderAvailability {
        await ProviderProbe.availability(binary: "pnpm", locator: locator, runner: runner)
    }

    public func installed() async throws -> [InstalledPackage] {
        let pnpm = try binary()
        let result = await runner.collect(ToolCommand.make(
            binary: pnpm,
            arguments: ["list", "--global", "--depth", "0", "--json"],
            summary: "Paquetes globales de pnpm"
        ))
        let data = try CommandJSON.data(from: result, provider: id, acceptNonZero: true)
        return try DependencyJSON.packages(from: data, provider: id)
    }

    public func search(_ query: String) async throws -> [RemotePackage] {
        try await RegistryClient.search(query, provider: id, kind: .globalPackage, locator: locator, runner: runner)
    }

    public func details(_ package: InstalledPackage) async throws -> PackageDetails {
        if let location = package.location, let details = JSPaths.details(at: URL(fileURLWithPath: location, isDirectory: true)) {
            return details
        }
        return PackageDetails(summary: package.summary, location: package.location)
    }

    public func upgrades() async throws -> [PackageUpgrade] {
        let pnpm = try binary()
        let result = await runner.collect(ToolCommand.make(
            binary: pnpm,
            arguments: ["outdated", "--global", "--json"],
            summary: "Actualizaciones globales de pnpm"
        ))
        let data = try CommandJSON.data(from: result, provider: id, acceptNonZero: true)
        return try JSUpgrades.parse(data, provider: id)
    }

    public func planInstall(_ package: PackageRef) -> PlannedCommand? {
        plan(package.name, arguments: ["add", "--global", package.name], summary: "Instalar \(package.name) con pnpm")
    }

    public func planUninstall(_ package: InstalledPackage) -> PlannedCommand? {
        plan(package.name, arguments: ["remove", "--global", package.name], summary: "Desinstalar \(package.name) con pnpm")
    }

    public func planUpgrade(_ package: InstalledPackage?) -> PlannedCommand? {
        guard let pnpm = locator.locate("pnpm") else { return nil }
        if let package {
            guard PackageName.isValid(package.name) else { return nil }
            return ToolCommand.make(
                binary: pnpm,
                arguments: ["update", "--global", package.name],
                summary: "Actualizar \(package.name) con pnpm"
            )
        }
        return ToolCommand.make(binary: pnpm, arguments: ["update", "--global"], summary: "Actualizar paquetes globales de pnpm")
    }

    private func binary() throws -> String {
        guard let path = locator.locate("pnpm") else {
            throw ProviderFailure(provider: id, message: "pnpm no está instalado")
        }
        return path
    }

    private func plan(_ name: String, arguments: [String], summary: String) -> PlannedCommand? {
        guard PackageName.isValid(name), let pnpm = locator.locate("pnpm") else { return nil }
        return ToolCommand.make(binary: pnpm, arguments: arguments, summary: summary)
    }
}

enum RegistryClient {
    static func search(
        _ query: String,
        provider: ProviderID,
        kind: PackageKind,
        locator: any Locating,
        runner: any CommandRunning
    ) async throws -> [RemotePackage] {
        guard let text = SearchText.normalize(query) else {
            throw ProviderFailure(provider: provider, message: "La búsqueda tiene caracteres no válidos")
        }
        guard let curl = locator.locate("curl") else {
            throw ProviderFailure(provider: provider, message: "curl no está instalado")
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encoded = text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
        let url = "https://registry.npmjs.org/-/v1/search?text=\(encoded)&size=15"
        let result = await runner.collect(ToolCommand.make(
            binary: curl,
            arguments: ["-fsSL", "--max-time", "20", url],
            summary: "Buscar \(text) en el registro npm"
        ))
        let data = try CommandJSON.data(from: result, provider: provider, acceptNonZero: false)
        return try RegistrySearch.parse(data, provider: provider, kind: kind)
    }
}
