import CellarCore
import Foundation

public struct BunProvider<Locator: Locating, Runner: CommandRunning>: PackageProvider {
    public let id: ProviderID = .bun
    public let displayName = "bun"
    private let locator: Locator
    private let runner: Runner
    private let globalRoot: URL

    public init(locator: Locator, runner: Runner, globalRoot: URL? = nil) {
        self.locator = locator
        self.runner = runner
        self.globalRoot = globalRoot ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".bun/install/global", isDirectory: true)
    }

    public func availability() async -> ProviderAvailability {
        await ProviderProbe.availability(binary: "bun", locator: locator, runner: runner)
    }

    public func installed() async throws -> [InstalledPackage] {
        guard locator.locate("bun") != nil else {
            throw ProviderFailure(provider: id, message: "Bun no está instalado")
        }
        let manifest = globalRoot.appendingPathComponent("package.json")
        guard FileManager.default.fileExists(atPath: manifest.path) else { return [] }
        let data: Data
        do {
            data = try Data(contentsOf: manifest)
        } catch {
            throw ProviderFailure(provider: id, message: "No se pudo leer \(manifest.path)")
        }
        let object: [String: Any]
        do {
            object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        } catch {
            throw ProviderFailure(provider: id, message: "package.json global de Bun no es JSON")
        }
        let dependencies = object["dependencies"] as? [String: Any] ?? [:]
        let modules = globalRoot.appendingPathComponent("node_modules", isDirectory: true)
        return dependencies.keys.sorted().compactMap { name in
            guard PackageName.isValid(name) else { return nil }
            let directory = JSPaths.packageDirectory(modules: modules, name: name)
            let range = dependencies[name] as? String ?? ""
            let version = JSPaths.version(in: directory) ?? (range.isEmpty ? "desconocida" : range)
            return InstalledPackage(
                name: name,
                version: version,
                provider: id,
                kind: .globalPackage,
                location: directory.path
            )
        }
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

    /// `bun outdated --global` walks parent directories and can report an unrelated project.
    /// Inventory comes from the global package.json. Upgrade still runs `bun update --global`.
    public func upgrades() async throws -> [PackageUpgrade] { [] }

    public func planInstall(_ package: PackageRef) -> PlannedCommand? {
        plan(package.name, arguments: ["add", "--global", package.name], summary: "Instalar \(package.name) con bun")
    }

    public func planUninstall(_ package: InstalledPackage) -> PlannedCommand? {
        plan(package.name, arguments: ["remove", "--global", package.name], summary: "Desinstalar \(package.name) con bun")
    }

    public func planUpgrade(_ package: InstalledPackage?) -> PlannedCommand? {
        guard let bun = locator.locate("bun") else { return nil }
        if let package {
            guard PackageName.isValid(package.name) else { return nil }
            return ToolCommand.make(
                binary: bun,
                arguments: ["update", "--global", package.name],
                summary: "Actualizar \(package.name) con bun"
            )
        }
        return ToolCommand.make(binary: bun, arguments: ["update", "--global"], summary: "Actualizar paquetes globales de bun")
    }

    private func plan(_ name: String, arguments: [String], summary: String) -> PlannedCommand? {
        guard PackageName.isValid(name), let bun = locator.locate("bun") else { return nil }
        return ToolCommand.make(binary: bun, arguments: arguments, summary: summary)
    }
}
