import Foundation

public struct ProviderID: Hashable, Sendable, Codable, RawRepresentable, ExpressibleByStringLiteral {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }
}

extension ProviderID {
    public static let homebrew = ProviderID("homebrew")
    public static let npm = ProviderID("npm")
    public static let pnpm = ProviderID("pnpm")
    public static let bun = ProviderID("bun")
}

public enum PackageKind: String, Hashable, Sendable, Codable, CaseIterable {
    case formula
    case cask
    case globalPackage
    case tool
}

public enum PackageIdentity {
    public static func make(provider: ProviderID, kind: PackageKind, name: String) -> String {
        "\(provider.rawValue)\t\(kind.rawValue)\t\(name)"
    }
}

public struct PackageRef: Hashable, Sendable {
    public var name: String
    public var kind: PackageKind

    public init(name: String, kind: PackageKind) {
        self.name = name
        self.kind = kind
    }
}

public struct InstalledPackage: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var version: String
    public var provider: ProviderID
    public var kind: PackageKind
    public var summary: String
    public var location: String?

    public init(
        name: String,
        version: String,
        provider: ProviderID,
        kind: PackageKind,
        summary: String = "",
        location: String? = nil
    ) {
        self.id = PackageIdentity.make(provider: provider, kind: kind, name: name)
        self.name = name
        self.version = version
        self.provider = provider
        self.kind = kind
        self.summary = summary
        self.location = location
    }
}

public struct RemotePackage: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var version: String
    public var summary: String
    public var provider: ProviderID
    public var kind: PackageKind

    public init(name: String, version: String, summary: String, provider: ProviderID, kind: PackageKind) {
        self.id = PackageIdentity.make(provider: provider, kind: kind, name: name)
        self.name = name
        self.version = version
        self.summary = summary
        self.provider = provider
        self.kind = kind
    }

    public var ref: PackageRef { PackageRef(name: name, kind: kind) }
}

public struct PackageUpgrade: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var provider: ProviderID
    public var kind: PackageKind
    public var installedVersion: String
    public var availableVersion: String
    public var pinned: Bool

    public init(
        name: String,
        provider: ProviderID,
        kind: PackageKind,
        installedVersion: String,
        availableVersion: String,
        pinned: Bool = false
    ) {
        self.id = PackageIdentity.make(provider: provider, kind: kind, name: name)
        self.name = name
        self.provider = provider
        self.kind = kind
        self.installedVersion = installedVersion
        self.availableVersion = availableVersion
        self.pinned = pinned
    }
}

public struct PackageDetails: Hashable, Sendable {
    public var summary: String
    public var homepage: String?
    public var location: String?
    public var dependencies: [String]
    public var pinned: Bool

    public init(
        summary: String = "",
        homepage: String? = nil,
        location: String? = nil,
        dependencies: [String] = [],
        pinned: Bool = false
    ) {
        self.summary = summary
        self.homepage = homepage
        self.location = location
        self.dependencies = dependencies
        self.pinned = pinned
    }
}

public enum ProviderAvailability: Hashable, Sendable {
    case available(version: String, binary: String)
    case missing(expectedBinary: String)
    case failed(message: String)
}

public struct ProviderFailure: Error, Equatable, LocalizedError, Sendable {
    public var provider: ProviderID
    public var message: String
    /// Paquetes que sí se pudieron leer antes del fallo, para que el inventario
    /// pueda mostrar lo parcial en vez de quedarse vacío.
    public var partial: [InstalledPackage]

    public init(provider: ProviderID, message: String, partial: [InstalledPackage] = []) {
        self.provider = provider
        self.message = message
        self.partial = partial
    }

    public var errorDescription: String? { message }
}

public enum PackageName {
    public static func isValid(_ name: String) -> Bool {
        guard (1...200).contains(name.count), let first = name.first, first != "-", first != "." else {
            return false
        }
        if name.contains("..") || name.contains("//") { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789@._+/-")
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

public enum SearchText {
    public static func normalize(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...80).contains(trimmed.count) else { return nil }
        let controls = CharacterSet.controlCharacters
        guard trimmed.unicodeScalars.allSatisfy({ !controls.contains($0) }) else { return nil }
        return trimmed
    }
}

public protocol PackageProvider: Sendable {
    var id: ProviderID { get }
    var displayName: String { get }
    func availability() async -> ProviderAvailability
    func installed() async throws -> [InstalledPackage]
    func search(_ query: String) async throws -> [RemotePackage]
    func details(_ package: InstalledPackage) async throws -> PackageDetails
    func upgrades() async throws -> [PackageUpgrade]
    func planInstall(_ package: PackageRef) -> PlannedCommand?
    func planUninstall(_ package: InstalledPackage) -> PlannedCommand?
    func planUpgrade(_ package: InstalledPackage?) -> PlannedCommand?
    /// Un solo comando para toda la lista. En npm eso es una transacción:
    /// si un paquete falla, npm no sigue con los demás.
    func planUpgradeList(_ packages: [InstalledPackage]) -> PlannedCommand?
    /// Un comando por paquete, en orden de nombre. “Actualizar todo” usa esto
    /// para que un error no cancele el resto.
    func planUpgradeCommands(_ packages: [InstalledPackage]) -> [PlannedCommand]
}

extension PackageProvider {
    public func details(_ package: InstalledPackage) async throws -> PackageDetails {
        PackageDetails(summary: package.summary, location: package.location)
    }

    public func upgrades() async throws -> [PackageUpgrade] { [] }

    public func planUpgradeList(_ packages: [InstalledPackage]) -> PlannedCommand? {
        planUpgrade(nil)
    }

    public func planUpgradeCommands(_ packages: [InstalledPackage]) -> [PlannedCommand] {
        packages
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .compactMap { planUpgrade($0) }
    }
}
