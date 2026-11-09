import CellarCore
import Foundation
import Testing
@testable import CellarProviders

/// Muestras reales capturadas en esta máquina con los mismos comandos de solo
/// lectura que ejecutan los providers. Sirven para comprobar que los parsers
/// aceptan la salida verdadera y no solo los fixtures sintéticos.
///
/// No se puede declarar un bundle de recursos porque `Package.swift` está fuera
/// del alcance de esta tarea, así que las muestras se leen desde el árbol de
/// fuentes con `#filePath`.
private enum LiveSample {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // CellarProvidersTests
        .deletingLastPathComponent() // Tests
        .appendingPathComponent("Fixtures", isDirectory: true)

    static func text(_ name: String) throws -> String {
        try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(name))
    }
}

@Test func homebrewListAcceptsRealFormulaOutput() throws {
    let text = try LiveSample.text("brew-list-formula.txt")
    let packages = HomebrewList.parse(text, kind: .formula, provider: .homebrew)

    // Ninguna línea real se descarta: el parser no rechaza nada de `brew list`.
    #expect(packages.count == text.split(whereSeparator: \.isNewline).count)
    #expect(packages.count == 30)
    #expect(packages.allSatisfy { $0.kind == .formula && $0.provider == .homebrew })
    #expect(!packages.contains { $0.version == "desconocida" })

    #expect(packages.first?.name == "acli")
    #expect(packages.first?.version == "1.3.19-stable")

    let byName = Dictionary(uniqueKeysWithValues: packages.map { ($0.name, $0.version) })
    // Guion en el nombre.
    #expect(byName["ca-certificates"] == "2026-11-05")
    // Revisión de Homebrew (`_1`).
    #expect(byName["cocoapods"] == "1.17.0_1")
    // Arroba de versión en el nombre.
    #expect(byName["icu4c@78"] == "78.3_1")
    #expect(byName["icu4c@79"] == "79.1")
    // Guion bajo en el nombre.
    #expect(byName["hdrhistogram_c"] == "0.12.1")
    #expect(byName["c-ares"] == "1.34.9")
}

@Test func homebrewUpgradesAcceptRealOutdatedJSON() throws {
    let data = try LiveSample.data("brew-outdated.json")
    let upgrades = try HomebrewJSON.upgrades(from: data, provider: .homebrew)
    // En esta máquina no hay nada desactualizado: el JSON real viene con los
    // dos arreglos vacíos y el parser debe aceptarlo sin lanzar.
    #expect(upgrades.isEmpty)
    let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(root["formulae"] is [Any])
    #expect(root["casks"] is [Any])
}

@Test func npmListAcceptsRealGlobalJSON() throws {
    let data = try LiveSample.data("npm-ls-global.json")
    let packages = try DependencyJSON.packages(from: data, provider: .npm)

    // La muestra guarda 20 de los paquetes reales.
    #expect(packages.count == 20)
    #expect(packages.allSatisfy { $0.kind == .globalPackage && $0.provider == .npm })
    #expect(!packages.contains { $0.version == "desconocida" })
    #expect(packages.map(\.name) == packages.map(\.name).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })

    let byName = Dictionary(uniqueKeysWithValues: packages.map { ($0.name, $0.version) })
    // npm añade `"overridden": false` junto a `version`; no debe estorbar.
    #expect(byName["@anthropic-ai/claude-code"] == "2.1.273")
    #expect(byName["@deepseek-ai/dsh"] == "0.2.1-rc.5")
    #expect(byName["@earendil-works/pi-coding-agent"] == "0.99.2")
}

@Test func pnpmListAcceptsRealGlobalJSON() throws {
    let data = try LiveSample.data("pnpm-list-global.json")
    let packages = try DependencyJSON.packages(from: data, provider: .pnpm)
    // pnpm devuelve un arreglo con `path`, `private` y `dependencies`; en esta
    // máquina el objeto global está vacío y eso no es un error.
    #expect(packages.isEmpty)

    let root = try #require(try JSONSerialization.jsonObject(with: data) as? [Any])
    #expect(root.count == 1)
    let entry = try #require(root.first as? [String: Any])
    #expect(entry["path"] as? String == "/Users/admin/Library/pnpm/global/v11")
    #expect((entry["dependencies"] as? [String: Any])?.isEmpty == true)
}

@Test func pnpmUpgradesAcceptRealOutdatedJSON() throws {
    let data = try LiveSample.data("pnpm-outdated.json")
    let upgrades = try JSUpgrades.parse(data, provider: .pnpm)
    // `pnpm outdated --global --json` con todo al día imprime `{}`.
    #expect(upgrades.isEmpty)
}

@Test func homebrewCaskFailureIsReportedAndNotSwallowed() async throws {
    // `brew list --cask --versions` falla en esta máquina con exit 1 y stdout
    // vacío porque hay un cask de un tap sin confiar. No hay muestra de texto
    // que guardar para casks, así que lo que se fija es que el fallo real se
    // propaga con su mensaje y, además, con las fórmulas que sí se pudieron
    // listar en `partial`: el fallo de los casks no borra lo ya leído ni se
    // convierte en una lista vacía.
    //
    // El mensaje puede conservar los códigos ANSI del stderr real; limpiarlos
    // es responsabilidad de otro archivo y aquí no se exige.
    let formulaeText = try LiveSample.text("brew-list-formula.txt")
    let stderr = try LiveSample.text("brew-list-cask.stderr.txt")
    #expect(stderr.contains("untrusted tap"))

    let runner = ScriptedRunner()
    runner.set(.init(stdout: formulaeText), for: ["brew", "list", "--formula", "--versions"])
    runner.set(.init(stderr: stderr, exitCode: 1), for: ["brew", "list", "--cask", "--versions"])
    let provider = HomebrewProvider(
        locator: StaticLocator(paths: ["brew": "/opt/homebrew/bin/brew"]),
        runner: runner
    )

    // Lo que `installed()` debió alcanzar a leer de las fórmulas, en el orden
    // en que `HomebrewList.parse` las devuelve.
    let expected = HomebrewList.parse(formulaeText, kind: .formula, provider: .homebrew)
    #expect(expected.count == 30)

    do {
        _ = try await provider.installed()
        Issue.record("la lista de casks debía fallar con la salida real")
    } catch let failure as ProviderFailure {
        #expect(failure.provider == .homebrew)
        #expect(failure.message.contains("untrusted tap"))
        // Las fórmulas sobreviven al fallo de los casks.
        #expect(!failure.partial.isEmpty)
        #expect(failure.partial.map(\.name) == expected.map(\.name))
        #expect(failure.partial.allSatisfy { $0.kind == .formula && $0.provider == .homebrew })
    }
}
