import CellarCore
import Foundation
import Testing

@Test func acceptsPackageNamesAndRejectsFlags() {
    #expect(PackageName.isValid("wget"))
    #expect(PackageName.isValid("python@3.12"))
    #expect(PackageName.isValid("@scope/left-pad"))
    #expect(!PackageName.isValid("--force"))
    #expect(!PackageName.isValid("-g"))
    #expect(!PackageName.isValid("../x"))
    #expect(!PackageName.isValid(""))
}

@Test func searchAllowsWordsButNotControlCharacters() {
    #expect(SearchText.normalize(" http client ") == "http client")
    #expect(SearchText.normalize("bad\nname") == nil)
    #expect(SearchText.normalize("   ") == nil)
}

@Test func locatesExecutableOnGivenPath() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let binary = directory.appendingPathComponent("echo-tool")
    try Data("#!/bin/sh\necho hi\n".utf8).write(to: binary)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    let locator = BinaryLocator(searchPaths: [directory.path])
    #expect(locator.locate("echo-tool") == binary.path)
    #expect(locator.locate("missing-tool") == nil)
}

@Test func environmentPathKeepsHomebrewVisible() {
    let locator = BinaryLocator.fromEnvironment(["PATH": "/usr/bin:/bin"], home: "/Users/example")
    #expect(locator.searchPaths.contains("/opt/homebrew/bin"))
    #expect(locator.searchPaths.contains("/Users/example/.bun/bin"))
    #expect(locator.searchPaths.first == "/usr/bin")
}

@Test func echoDoesNotInterpretShell() async {
    let marker = FileManager.default.temporaryDirectory.appendingPathComponent("curlbrew-shell-\(UUID().uuidString)")
    let result = await ProcessCommandRunner().collect(PlannedCommand(
        argv: ["/bin/echo", "$(touch \(marker.path))"],
        summary: "echo"
    ))
    #expect(result.exitCode == 0)
    #expect(result.stdout.contains("touch"))
    #expect(!FileManager.default.fileExists(atPath: marker.path))
}

@Test func rejectsShellInterpreter() async {
    let marker = FileManager.default.temporaryDirectory.appendingPathComponent("curlbrew-zsh-\(UUID().uuidString)")
    let result = await ProcessCommandRunner().collect(PlannedCommand(
        argv: ["/bin/zsh", "-lc", "touch \(marker.path)"],
        summary: "no"
    ))
    #expect(result.failure == "rechazado: el ejecutor directo no corre un shell")
    #expect(!FileManager.default.fileExists(atPath: marker.path))
}

@Test func falseExitsNonZero() async {
    let result = await ProcessCommandRunner().collect(PlannedCommand(argv: ["/usr/bin/false"], summary: "false"))
    #expect(result.exitCode == 1)
    #expect(result.failure == nil)
}

@Test func batchKeepsGoingAfterOneFailure() {
    let report = UpgradeBatch.report([
        UpgradeStep(summary: "Actualizar wget con Homebrew", failed: false, output: ""),
        UpgradeStep(
            summary: "Actualizar left-pad con npm",
            failed: true,
            output: "npm error path /Users/admin/.npm/_cacache/index-v5/32/51/abc\nnpm error code EACCES"
        ),
        UpgradeStep(summary: "Actualizar copilot con npm", failed: false, output: ""),
    ])
    #expect(report.succeededSummaries.count == 2)
    #expect(report.failedSummaries == ["Actualizar left-pad con npm"])
    #expect(report.notice == "Actualizadas 2 de 3. Las demás siguen pendientes.")
    #expect(report.cacheHint == UpgradeBatch.cacheHint)
}

@Test func otherPermissionErrorsAreNotTheNpmCache() {
    #expect(!UpgradeBatch.isCachePermission("npm error code EACCES\nnpm error path /usr/local/lib/node_modules"))
    let report = UpgradeBatch.report([
        UpgradeStep(summary: "Actualizar uno con npm", failed: true, output: "network timeout"),
    ])
    #expect(report.notice == "Falló · Actualizar uno con npm")
    #expect(report.cacheHint == nil)
}

@Test func missingExecutableFailsBeforeLaunch() async {
    let result = await ProcessCommandRunner().collect(PlannedCommand(
        argv: ["/tmp/curlbrew-missing-\(UUID().uuidString)"],
        summary: "missing"
    ))
    #expect(result.failure != nil)
    #expect(result.exitCode == nil)
}

private func fixture(_ name: String, version: String = "1.0.0", kind: PackageKind = .formula) -> InstalledPackage {
    InstalledPackage(name: name, version: version, provider: .homebrew, kind: kind)
}

private func upgrade(_ package: InstalledPackage, to available: String = "2.0.0") -> PackageUpgrade {
    PackageUpgrade(
        name: package.name,
        provider: package.provider,
        kind: package.kind,
        installedVersion: package.version,
        availableVersion: available
    )
}

@Test func updatesSortFirstThenAlphabetical() {
    let packages = [fixture("zlib"), fixture("git"), fixture("curl"), fixture("wget")]
    let upgrades = [
        upgrade(packages[0]).id: upgrade(packages[0]),
        upgrade(packages[2]).id: upgrade(packages[2]),
    ]
    let arranged = PackageOrdering.arrange(
        packages,
        query: "",
        upgradesByID: upgrades,
        upgradesOnly: false,
        kind: .all,
        sort: .updatesFirst
    )
    #expect(arranged.map { $0.name } == ["curl", "zlib", "git", "wget"])
}

@Test func updatesOnlyKeepsJustPackagesWithUpgrades() {
    let packages = [fixture("git"), fixture("curl"), fixture("wget")]
    let upgrades = [upgrade(packages[1]).id: upgrade(packages[1])]
    let arranged = PackageOrdering.arrange(
        packages,
        query: "",
        upgradesByID: upgrades,
        upgradesOnly: true,
        kind: .all,
        sort: .updatesFirst
    )
    #expect(arranged.map { $0.name } == ["curl"])
}

@Test func queryAndKindFilterCombine() {
    let packages = [
        fixture("git"),
        fixture("git-lfs"),
        fixture("raycast", kind: .cask),
    ]
    let arranged = PackageOrdering.arrange(
        packages,
        query: "git",
        upgradesByID: [:],
        upgradesOnly: false,
        kind: .only(.formula),
        sort: .updatesFirst
    )
    #expect(arranged.map { $0.name } == ["git", "git-lfs"])
}

@Test func versionSortIsNumericNotLexical() {
    let packages = [
        fixture("a", version: "1.9.2"),
        fixture("b", version: "1.10.0"),
        fixture("c", version: "1.2.0"),
    ]
    let arranged = PackageOrdering.arrange(
        packages,
        query: "",
        upgradesByID: [:],
        upgradesOnly: false,
        kind: .all,
        sort: .version
    )
    #expect(arranged.map { $0.name } == ["b", "a", "c"])
}

@Test func versionCompareHandlesUnevenLengths() {
    #expect(VersionText.compare("1.10.0", "1.9.2") == .orderedDescending)
    #expect(VersionText.compare("1.0", "1.0.0") == .orderedAscending)
    #expect(VersionText.compare("2.0.0", "2.0.0") == .orderedSame)
    #expect(VersionText.compare("1.2.3-beta", "1.2.3") == .orderedDescending)
}
