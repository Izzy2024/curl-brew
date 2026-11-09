import Foundation

/// Cómo se ordena la lista de instalados.
public enum PackageSort: String, Hashable, Sendable, Codable, CaseIterable {
    /// Actualizaciones primero, luego por nombre. Es el orden por defecto.
    case updatesFirst
    case name
    /// Versión instalada más nueva primero; sirve para ver lo recién puesto.
    case version

    public var title: String {
        switch self {
        case .updatesFirst: "Actualizaciones primero"
        case .name: "Nombre"
        case .version: "Versión"
        }
    }
}

/// Filtro por tipo de paquete. `nil` significa todos.
public enum PackageKindFilter: Hashable, Sendable {
    case all
    case only(PackageKind)
}

public enum PackageOrdering {
    /// Aplica búsqueda, filtro de actualizaciones, filtro de tipo y orden.
    ///
    /// El orden `updatesFirst` es estable: dentro de "con actualización" y
    /// "sin actualización" se ordena por nombre, así que la lista no baila
    /// entre recargas.
    public static func arrange(
        _ packages: [InstalledPackage],
        query: String,
        upgradesByID: [String: PackageUpgrade],
        upgradesOnly: Bool,
        kind: PackageKindFilter,
        sort: PackageSort
    ) -> [InstalledPackage] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = packages.filter { package in
            if !trimmed.isEmpty, !matches(package, trimmed) { return false }
            if upgradesOnly, upgradesByID[package.id] == nil { return false }
            if case .only(let wanted) = kind, package.kind != wanted { return false }
            return true
        }
        return sorted(filtered, upgradesByID: upgradesByID, sort: sort)
    }

    /// La búsqueda mira el nombre y también la versión disponible, para que
    /// escribir "1.2.3" encuentre el paquete que espera esa actualización.
    static func matches(_ package: InstalledPackage, _ query: String) -> Bool {
        if package.name.localizedCaseInsensitiveContains(query) { return true }
        if !package.summary.isEmpty, package.summary.localizedCaseInsensitiveContains(query) { return true }
        return false
    }

    static func sorted(
        _ packages: [InstalledPackage],
        upgradesByID: [String: PackageUpgrade],
        sort: PackageSort
    ) -> [InstalledPackage] {
        switch sort {
        case .updatesFirst:
            return packages.sorted { left, right in
                let leftHas = upgradesByID[left.id] != nil
                let rightHas = upgradesByID[right.id] != nil
                if leftHas != rightHas { return leftHas }
                return byName(left, right)
            }
        case .name:
            return packages.sorted(by: byName)
        case .version:
            return packages.sorted { left, right in
                let order = VersionText.compare(left.version, right.version)
                if order != .orderedSame { return order == .orderedDescending }
                return byName(left, right)
            }
        }
    }

    private static func byName(_ left: InstalledPackage, _ right: InstalledPackage) -> Bool {
        left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
    }

    /// Tipos presentes en la lista, en el orden en que se muestran los filtros.
    public static func kinds(in packages: [InstalledPackage]) -> [PackageKind] {
        PackageKind.allCases.filter { kind in packages.contains { $0.kind == kind } }
    }
}

/// Compara versiones por trozos numéricos, sin depender de `OperatingSystemVersion`.
/// "1.10.0" es mayor que "1.9.2"; lo que no es número se compara como texto.
public enum VersionText {
    public static func compare(_ left: String, _ right: String) -> ComparisonResult {
        let leftParts = split(left)
        let rightParts = split(right)
        for index in 0..<min(leftParts.count, rightParts.count) {
            let a = leftParts[index]
            let b = rightParts[index]
            switch (UInt64(a), UInt64(b)) {
            case let (a?, b?):
                if a != b { return a < b ? .orderedAscending : .orderedDescending }
            default:
                let order = a.localizedCaseInsensitiveCompare(b)
                if order != .orderedSame { return order }
            }
        }
        if leftParts.count == rightParts.count { return .orderedSame }
        return leftParts.count < rightParts.count ? .orderedAscending : .orderedDescending
    }

    private static func split(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "." || $0 == "-" || $0 == "_" }).map(String.init)
    }
}
