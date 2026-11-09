import CellarCore
import Foundation
import Testing
@testable import CellarProviders

/// El stderr real de `brew list --cask` llega coloreado: `ESC[31mError:ESC[0m`.
/// La app pinta ese mensaje tal cual, así que `failureMessage` debe dejar solo
/// el texto visible y conservar todas las líneas del error.
@Test func failureMessageRemovesAnsiColorCodes() throws {
    let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // CellarProvidersTests
        .deletingLastPathComponent() // Tests
        .appendingPathComponent("Fixtures", isDirectory: true)
    let stderr = try String(
        contentsOf: fixtures.appendingPathComponent("brew-list-cask.stderr.txt"),
        encoding: .utf8
    )
    #expect(stderr.contains("\u{001B}[31m"))

    let result = CommandResult(stdout: "", stderr: stderr, exitCode: 1)
    let message = CommandText.failureMessage(result)

    #expect(!message.contains("\u{001B}"))
    #expect(!message.contains("[31m"))
    #expect(message.contains("Refusing to load cask"))
    #expect(message.contains("untrusted tap"))
    // No se recorta a la primera línea: la sugerencia de `brew trust` sigue ahí.
    #expect(message.contains("brew trust"))
}
