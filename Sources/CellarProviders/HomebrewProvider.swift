import CellarCore
import Foundation

public struct HomebrewProvider<Locator: Locating, Runner: CommandRunning>: PackageProvider {
    public let id: ProviderID = .homebrew
    public let displayName = "Homebrew"
    private let locator: Locator
    private let runner: Runner

    public init(locator: Locator, runner: Runner) {
        self.locator = locator
        self.runner = runner
    }

    public func availability() async -> ProviderAvailability {
        await ProviderProbe.availability(binary: "brew", locator: locator, runner: runner, environment: BrewEnv.read)
    }

    public func installed() async throws -> [InstalledPackage] {
        let brew = try binary()
        // Si fallan las fórmulas el error sale tal cual, sin parciales.
        let formulae = try await list(brew, kind: .formula, arguments: ["list", "--formula", "--versions"])
        do {
            let casks = try await list(brew, kind: .cask, arguments: ["list", "--cask", "--versions"])
            return formulae + casks
        } catch let failure as ProviderFailure {
            // Un cask de un tap sin confiar no debe tirar las fórmulas ya leídas.
            throw ProviderFailure(provider: failure.provider, message: failure.message, partial: formulae)
        } catch {
            throw ProviderFailure(provider: id, message: error.localizedDescription, partial: formulae)
        }
    }

    public func search(_ query: String) async throws -> [RemotePackage] {
        guard let text = SearchText.normalize(query) else {
            throw ProviderFailure(provider: id, message: "La búsqueda tiene caracteres no válidos")
        }
        let brew = try binary()
        let formulae = try await search(brew, text: text, kind: .formula, flag: "--formula")
        let casks = try await search(brew, text: text, kind: .cask, flag: "--cask")
        return formulae + casks
    }

    public func details(_ package: InstalledPackage) async throws -> PackageDetails {
        guard PackageName.isValid(package.name) else {
            throw ProviderFailure(provider: id, message: "Nombre no válido")
        }
        let brew = try binary()
        let flag = package.kind == .cask ? "--cask" : "--formula"
        let result = await runner.collect(ToolCommand.make(
            binary: brew,
            arguments: ["info", "--json=v2", flag, "--", package.name],
            summary: "Ficha de \(package.name)",
            environment: BrewEnv.read
        ))
        let data = try CommandJSON.data(from: result, provider: id, acceptNonZero: false)
        return try HomebrewJSON.details(from: data, kind: package.kind, provider: id)
    }

    public func upgrades() async throws -> [PackageUpgrade] {
        let brew = try binary()
        let result = await runner.collect(ToolCommand.make(
            binary: brew,
            arguments: ["outdated", "--json=v2"],
            summary: "Paquetes de Homebrew con actualización",
            environment: BrewEnv.mutate
        ))
        let data = try CommandJSON.data(from: result, provider: id, acceptNonZero: false)
        return try HomebrewJSON.upgrades(from: data, provider: id)
    }

    public func planInstall(_ package: PackageRef) -> PlannedCommand? {
        guard PackageName.isValid(package.name), let brew = locator.locate("brew") else { return nil }
        let flag = package.kind == .cask ? "--cask" : "--formula"
        return ToolCommand.make(
            binary: brew,
            arguments: ["install", flag, "--", package.name],
            summary: "Instalar \(package.name) con Homebrew",
            environment: BrewEnv.mutate
        )
    }

    public func planUninstall(_ package: InstalledPackage) -> PlannedCommand? {
        guard PackageName.isValid(package.name), let brew = locator.locate("brew") else { return nil }
        let flag = package.kind == .cask ? "--cask" : "--formula"
        return ToolCommand.make(
            binary: brew,
            arguments: ["uninstall", flag, "--", package.name],
            summary: "Desinstalar \(package.name) con Homebrew",
            environment: BrewEnv.mutate
        )
    }

    public func planUpgrade(_ package: InstalledPackage?) -> PlannedCommand? {
        guard let brew = locator.locate("brew") else { return nil }
        if let package {
            guard PackageName.isValid(package.name) else { return nil }
            let flag = package.kind == .cask ? "--cask" : "--formula"
            return ToolCommand.make(
                binary: brew,
                arguments: ["upgrade", flag, "--", package.name],
                summary: "Actualizar \(package.name) con Homebrew",
                environment: BrewEnv.mutate
            )
        }
        return ToolCommand.make(
            binary: brew,
            arguments: ["upgrade"],
            summary: "Actualizar fórmulas y casks desactualizados",
            environment: BrewEnv.mutate
        )
    }

    private func binary() throws -> String {
        guard let path = locator.locate("brew") else {
            throw ProviderFailure(provider: id, message: "Homebrew no está instalado")
        }
        return path
    }

    private func list(_ brew: String, kind: PackageKind, arguments: [String]) async throws -> [InstalledPackage] {
        let result = await runner.collect(ToolCommand.make(
            binary: brew,
            arguments: arguments,
            summary: "Listar \(kind == .cask ? "casks" : "fórmulas")",
            environment: BrewEnv.read
        ))
        let text = try CommandText.stdout(from: result, provider: id)
        return HomebrewList.parse(text, kind: kind, provider: id)
    }

    private func search(_ brew: String, text: String, kind: PackageKind, flag: String) async throws -> [RemotePackage] {
        let result = await runner.collect(ToolCommand.make(
            binary: brew,
            arguments: ["search", flag, "--", text],
            summary: "Buscar \(text) en Homebrew",
            environment: BrewEnv.read
        ))
        let output = try CommandText.stdout(from: result, provider: id)
        return HomebrewList.parseSearch(output, kind: kind, provider: id)
    }
}

enum BrewEnv {
    static let read = ["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_COLOR": "0", "HOMEBREW_NO_ENV_HINTS": "1"]
    static let mutate = ["HOMEBREW_COLOR": "0", "HOMEBREW_NO_ENV_HINTS": "1", "CI": "1"]
}

enum HomebrewList {
    static func parse(_ text: String, kind: PackageKind, provider: ProviderID) -> [InstalledPackage] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let name = parts.first, PackageName.isValid(name) else { return nil }
            let version = parts.dropFirst().joined(separator: ", ")
            return InstalledPackage(
                name: name,
                version: version.isEmpty ? "desconocida" : version,
                provider: provider,
                kind: kind
            )
        }
    }

    static func parseSearch(_ text: String, kind: PackageKind, provider: ProviderID) -> [RemotePackage] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let name = raw.trimmingCharacters(in: .whitespaces)
            guard PackageName.isValid(name) else { return nil }
            return RemotePackage(name: name, version: "", summary: "", provider: provider, kind: kind)
        }
    }
}

enum HomebrewJSON {
    static func details(from data: Data, kind: PackageKind, provider: ProviderID) throws -> PackageDetails {
        let root = try object(data, provider: provider)
        if kind == .cask {
            let cask = rows(root["casks"]).first ?? [:]
            return PackageDetails(
                summary: cask["desc"] as? String ?? "",
                homepage: cask["homepage"] as? String
            )
        }
        let formula = rows(root["formulae"]).first ?? [:]
        return PackageDetails(
            summary: formula["desc"] as? String ?? "",
            homepage: formula["homepage"] as? String,
            dependencies: formula["dependencies"] as? [String] ?? [],
            pinned: formula["pinned"] as? Bool ?? false
        )
    }

    static func upgrades(from data: Data, provider: ProviderID) throws -> [PackageUpgrade] {
        let root = try object(data, provider: provider)
        return read(rows(root["formulae"]), kind: .formula, provider: provider)
            + read(rows(root["casks"]), kind: .cask, provider: provider)
    }

    private static func rows(_ value: Any?) -> [[String: Any]] {
        guard let array = value as? [Any] else { return [] }
        return array.compactMap { $0 as? [String: Any] }
    }

    private static func object(_ data: Data, provider: ProviderID) throws -> [String: Any] {
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ProviderFailure(provider: provider, message: "JSON de Homebrew no reconocido")
            }
            return object
        } catch let failure as ProviderFailure {
            throw failure
        } catch {
            throw ProviderFailure(provider: provider, message: "JSON de Homebrew no válido")
        }
    }

    private static func read(_ rows: [[String: Any]], kind: PackageKind, provider: ProviderID) -> [PackageUpgrade] {
        rows.compactMap { row in
            guard let name = row["name"] as? String, PackageName.isValid(name) else { return nil }
            let installed: String
            if let versions = row["installed_versions"] as? [Any] {
                installed = versions.compactMap { $0 as? String }.joined(separator: ", ")
            } else if let version = row["installed_versions"] as? String {
                installed = version
            } else {
                installed = ""
            }
            let available = row["current_version"] as? String ?? ""
            guard !available.isEmpty, available != installed else { return nil }
            return PackageUpgrade(
                name: name,
                provider: provider,
                kind: kind,
                installedVersion: installed,
                availableVersion: available,
                pinned: row["pinned"] as? Bool ?? false
            )
        }
    }
}
