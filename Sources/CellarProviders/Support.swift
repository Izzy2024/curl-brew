import CellarCore
import Foundation

enum ToolCommand {
    static func make(
        binary: String,
        arguments: [String],
        summary: String,
        environment: [String: String] = [:]
    ) -> PlannedCommand {
        PlannedCommand(
            argv: [binary] + arguments,
            summary: summary,
            environment: environment,
            workingDirectory: CommandDefaults.isolatedDirectory
        )
    }
}

enum CommandText {
    static func stdout(from result: CommandResult, provider: ProviderID) throws -> String {
        if let failure = result.failure {
            throw ProviderFailure(provider: provider, message: failure)
        }
        guard result.exitCode == 0 else {
            throw ProviderFailure(provider: provider, message: failureMessage(result))
        }
        return result.stdout
    }

    static func failureMessage(_ result: CommandResult) -> String {
        let detail = strippingANSISequences(from: result.stderr)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !detail.isEmpty { return detail }
        return "el comando terminó con código \(result.exitCode ?? -1)"
    }

    /// Elimina las secuencias CSI (`ESC [` … byte final entre `0x40` y `0x7E`)
    /// que Homebrew colorea en stderr. Si la secuencia está incompleta, se
    /// conserva tal cual.
    private static func strippingANSISequences(from text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var output = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            guard scalars[index] == "\u{001B}",
                  index + 1 < scalars.count,
                  scalars[index + 1] == "["
            else {
                output.append(scalars[index])
                index += 1
                continue
            }
            var end = index + 2
            while end < scalars.count, !(0x40...0x7E).contains(scalars[end].value) {
                end += 1
            }
            if end < scalars.count {
                index = end + 1
            } else {
                output.append(scalars[index])
                index += 1
            }
        }
        return String(output)
    }
}

enum CommandJSON {
    static func data(from result: CommandResult, provider: ProviderID, acceptNonZero: Bool) throws -> Data {
        if let failure = result.failure {
            throw ProviderFailure(provider: provider, message: failure)
        }
        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if result.exitCode == 0 || acceptNonZero { return Data("{}".utf8) }
            throw ProviderFailure(provider: provider, message: CommandText.failureMessage(result))
        }
        let data = Data(result.stdout.utf8)
        do {
            _ = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ProviderFailure(provider: provider, message: CommandText.failureMessage(result))
        }
        if !acceptNonZero, result.exitCode != 0 {
            throw ProviderFailure(provider: provider, message: CommandText.failureMessage(result))
        }
        return data
    }
}

enum ProviderProbe {
    static func availability(
        binary: String,
        locator: any Locating,
        runner: any CommandRunning,
        environment: [String: String] = [:]
    ) async -> ProviderAvailability {
        guard let path = locator.locate(binary) else {
            return .missing(expectedBinary: binary)
        }
        let result = await runner.collect(ToolCommand.make(
            binary: path,
            arguments: ["--version"],
            summary: "Versión de \(binary)",
            environment: environment
        ))
        if let failure = result.failure { return .failed(message: failure) }
        guard result.exitCode == 0 else {
            return .failed(message: CommandText.failureMessage(result))
        }
        let version = result.stdout.split(whereSeparator: \.isNewline).first
            .map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        return .available(version: version, binary: path)
    }
}

enum JSPaths {
    static func packageDirectory(modules: URL, name: String) -> URL {
        name.split(separator: "/").reduce(modules) { url, part in
            url.appendingPathComponent(String(part))
        }
    }

    static func version(in directory: URL) -> String? {
        guard let object = json(in: directory), let version = object["version"] as? String, !version.isEmpty else {
            return nil
        }
        return version
    }

    static func details(at directory: URL) -> PackageDetails? {
        guard let object = json(in: directory) else { return nil }
        let dependencies = (object["dependencies"] as? [String: Any])?.keys.sorted() ?? []
        return PackageDetails(
            summary: object["description"] as? String ?? "",
            homepage: object["homepage"] as? String,
            location: directory.path,
            dependencies: dependencies
        )
    }

    private static func json(in directory: URL) -> [String: Any]? {
        let url = directory.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

enum DependencyJSON {
    static func packages(from data: Data, provider: ProviderID) throws -> [InstalledPackage] {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ProviderFailure(provider: provider, message: "JSON de paquetes no válido")
        }
        var found: [String: InstalledPackage] = [:]
        func take(_ object: [String: Any]) {
            let modules = (object["path"] as? String).map {
                URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("node_modules", isDirectory: true)
            }
            guard let dependencies = object["dependencies"] as? [String: Any] else { return }
            for name in dependencies.keys {
                guard PackageName.isValid(name) else { continue }
                let version = version(of: dependencies[name])
                let directory = modules.map { JSPaths.packageDirectory(modules: $0, name: name) }
                found[name] = InstalledPackage(
                    name: name,
                    version: version.isEmpty ? "desconocida" : version,
                    provider: provider,
                    kind: .globalPackage,
                    location: directory?.path
                )
            }
        }
        if let object = json as? [String: Any] {
            take(object)
        } else if let array = json as? [Any] {
            for case let object as [String: Any] in array { take(object) }
        } else {
            throw ProviderFailure(provider: provider, message: "JSON de paquetes no reconocido")
        }
        return found.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func version(of value: Any?) -> String {
        if let spec = value as? [String: Any], let version = spec["version"] as? String { return version }
        if let version = value as? String { return version }
        return ""
    }
}

enum JSUpgrades {
    static func parse(_ data: Data, provider: ProviderID) throws -> [PackageUpgrade] {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ProviderFailure(provider: provider, message: "JSON de actualizaciones no válido")
        }
        if let array = json as? [Any] {
            return array.compactMap { item -> PackageUpgrade? in
                guard let object = item as? [String: Any] else { return nil }
                return make(name: name(in: object), object: object, provider: provider)
            }.sorted { $0.name < $1.name }
        }
        if let object = json as? [String: Any] {
            if object["current"] != nil || object["latest"] != nil { return [] }
            return object.compactMap { name, value in
                guard let spec = value as? [String: Any] else { return nil }
                return make(name: name, object: spec, provider: provider)
            }.sorted { $0.name < $1.name }
        }
        throw ProviderFailure(provider: provider, message: "JSON de actualizaciones no reconocido")
    }

    private static func name(in object: [String: Any]) -> String? {
        (object["packageName"] as? String) ?? (object["pkgName"] as? String) ?? (object["name"] as? String)
    }

    private static func make(name: String?, object: [String: Any], provider: ProviderID) -> PackageUpgrade? {
        guard let name, PackageName.isValid(name) else { return nil }
        let current = (object["current"] as? String) ?? (object["installed"] as? String) ?? ""
        let latest = (object["latest"] as? String) ?? (object["wanted"] as? String) ?? ""
        guard !latest.isEmpty, latest != current else { return nil }
        return PackageUpgrade(
            name: name,
            provider: provider,
            kind: .globalPackage,
            installedVersion: current,
            availableVersion: latest
        )
    }
}

enum RegistrySearch {
    static func parse(_ data: Data, provider: ProviderID, kind: PackageKind) throws -> [RemotePackage] {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ProviderFailure(provider: provider, message: "La búsqueda no devolvió JSON")
        }
        guard let root = json as? [String: Any], let objects = root["objects"] as? [Any] else {
            throw ProviderFailure(provider: provider, message: "Respuesta de búsqueda no reconocida")
        }
        return objects.compactMap { item in
            guard let object = item as? [String: Any],
                  let package = object["package"] as? [String: Any],
                  let name = package["name"] as? String,
                  PackageName.isValid(name) else { return nil }
            return RemotePackage(
                name: name,
                version: package["version"] as? String ?? "",
                summary: package["description"] as? String ?? "",
                provider: provider,
                kind: kind
            )
        }
    }
}
