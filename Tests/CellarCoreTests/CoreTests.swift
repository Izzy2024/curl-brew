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

@Test func newerGitHubReleaseIsTheZipFromThisRepo() throws {
    let release = try AppUpdateFeed.release(from: releaseJSON("0.2.0"), newerThan: "0.1.0")
    #expect(release?.version == "0.2.0")
    #expect(release?.assetName == "Curlbrew-0.2.0.zip")
    #expect(release?.downloadURL.absoluteString == "https://github.com/Izzy2024/curl-brew/releases/download/v0.2.0/Curlbrew-0.2.0.zip")
    #expect(try AppUpdateFeed.release(from: releaseJSON("0.2.0"), newerThan: "0.2.0") == nil)
    #expect(try AppUpdateFeed.release(from: releaseJSON("0.2.0"), newerThan: "0.10.0") == nil)
}

@Test func versionTenIsNewerThanNine() throws {
    let release = try AppUpdateFeed.release(from: releaseJSON("0.10.0"), newerThan: "0.9.0")
    #expect(release?.version == "0.10.0")
}

@Test func foreignPrereleaseAndQueryUpdatesAreRefused() throws {
    #expect(throws: AppUpdateFailure.noZip("0.3.0")) {
        try AppUpdateFeed.release(from: releaseJSON("0.3.0", url: "https://example.com/Curlbrew-0.3.0.zip"), newerThan: "0.1.0")
    }
    #expect(throws: AppUpdateFailure.noZip("0.3.0")) {
        try AppUpdateFeed.release(
            from: releaseJSON("0.3.0", url: "https://github.com/Izzy2024/curl-brew/releases/download/v0.3.0/Curlbrew-0.3.0.zip?x=1"),
            newerThan: "0.1.0"
        )
    }
    #expect(try AppUpdateFeed.release(from: releaseJSON("9.0.0", prerelease: true), newerThan: "0.1.0") == nil)
}

@Test func bundleCheckRequiresIdentifierAndVersion() {
    let good = Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0"><dict>
    <key>CFBundleIdentifier</key><string>app.curlbrew.macos</string>
    <key>CFBundleShortVersionString</key><string>0.2.0</string>
    <key>CFBundleExecutable</key><string>Curlbrew</string>
    </dict></plist>
    """.utf8)
    #expect(AppUpdateFeed.validateBundle(good, version: "0.2.0"))
    #expect(!AppUpdateFeed.validateBundle(good, version: "0.3.0"))
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

private func releaseJSON(_ version: String, url: String? = nil, prerelease: Bool = false) -> Data {
    let download = url ?? "https://github.com/Izzy2024/curl-brew/releases/download/v\(version)/Curlbrew-\(version).zip"
    let json = """
    {"tag_name":"v\(version)","prerelease":\(prerelease),"assets":[
      {"name":"Curlbrew-\(version).dmg","browser_download_url":"https://github.com/Izzy2024/curl-brew/releases/download/v\(version)/Curlbrew-\(version).dmg"},
      {"name":"Curlbrew-\(version).zip","browser_download_url":"\(download)"}
    ]}
    """
    return Data(json.utf8)
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

@Test func parsesHomebrewDownloadQueueProgressFrames() throws {
    let active = try #require(ProgressParser.parse("⠲ Bottle c-ares (1.34.9)          ##                Downloading  41.0KB/312.6KB"))
    #expect(active.label == "Bottle c-ares (1.34.9)")
    #expect(active.percentText == "13%")
    #expect(active.transferredText == "41.0 KB / 312.6 KB")
    #expect(active.remainingText == "faltan 271.6 KB")
    #expect(!active.isFinished)
    #expect(active.cliBarLine.contains("13%"))
    #expect(active.cliBarLine.contains("faltan 271.6 KB"))
    let activeFraction = try #require(active.fraction)
    #expect(abs(activeFraction - (41.0 / 312.6)) < 0.001)

    let unknownTotal = try #require(ProgressParser.parse("⠖ Bottle Manifest c-ares (1.34.9)                   Downloading   8.2KB/-------"))
    #expect(unknownTotal.label == "Bottle Manifest c-ares (1.34.9)")
    #expect(unknownTotal.fraction == nil)
    #expect(unknownTotal.percentText == nil)
    #expect(unknownTotal.remainingText == nil)
    #expect(unknownTotal.transferredText == "8.2 KB")
    #expect(!unknownTotal.isFinished)
    #expect(unknownTotal.cliBarLine.contains("8.2 KB"))

    let done = try #require(ProgressParser.parse("✔︎ Bottle c-ares (1.34.9)                            Downloaded  312.6KB/312.6KB"))
    #expect(done.label == "Bottle c-ares (1.34.9)")
    #expect(done.fraction == 1.0)
    #expect(done.percentText == "100%")
    #expect(done.transferredText == "312.6 KB / 312.6 KB")
    #expect(done.remainingText == nil)
    #expect(done.isFinished)
    #expect(done.cliBarLine.contains("100%"))
}

@Test func parsesCurlProgressBarAndMeterLines() throws {
    let bar = try #require(ProgressParser.parse("###################################################                       72.1%"))
    #expect(bar.percentText == "72%")
    #expect(bar.remainingText == "falta 28%")
    #expect(!bar.isFinished)
    #expect(bar.cliBarLine.contains("72%"))
    let barFraction = try #require(bar.fraction)
    #expect(abs(barFraction - 0.721) < 0.001)

    let meter = try #require(ProgressParser.parse(" 45  250M   45  112M    0     0  12.5M      0  0:00:20  0:00:09  0:00:11 13.1M"))
    #expect(meter.percentText == "45%")
    #expect(meter.fraction == 0.45)
    #expect(!meter.isFinished)
    #expect(meter.transferredText != nil)
    #expect(meter.remainingText?.contains("0:00:11") == true)
    #expect(meter.cliBarLine.contains("45%"))
}

@Test func parsesPnpmDownloadAndProgressLines() throws {
    let dl = try #require(ProgressParser.parse("Downloading typescript@5.6.2: 12.34 MB/56.78 MB"))
    #expect(dl.label == "typescript@5.6.2")
    #expect(dl.percentText == "22%")
    #expect(dl.transferredText == "12.3 MB / 56.8 MB")
    #expect(dl.remainingText == "faltan 44.4 MB")
    #expect(!dl.isFinished)
    #expect(dl.cliBarLine.contains("22%"))

    let counts = try #require(ProgressParser.parse("Progress: resolved 20, reused 5, downloaded 8, added 0"))
    #expect(counts.fraction == 0.65)
    #expect(counts.percentText == "65%")
    #expect(counts.transferredText == "13 / 20 paquetes")
    #expect(counts.remainingText == "faltan 7")
    #expect(!counts.isFinished)
    #expect(counts.cliBarLine.contains("65%"))
}

@Test func stripsAnsiCursorControlAndSplitsCarriageReturnFrames() {
    let raw = "\u{001B}[?2026h\u{001B}[34m⠋\u{001B}[0m\u{001B}[K\r\u{001B}[34m⠲\u{001B}[0m Bottle c-ares (1.34.9) Downloading 41.0KB/312.6KB\u{001B}[K\u{001B}[1F\u{001B}[?2026l"
    let stripped = ProgressParser.stripTerminalSequences(raw)
    #expect(!stripped.contains("\u{001B}"))
    #expect(!stripped.contains("[?2026h"))
    #expect(!stripped.contains("[1F"))

    let segments = ProgressParser.splitSegments(raw)
    #expect(segments == ["⠲ Bottle c-ares (1.34.9) Downloading 41.0KB/312.6KB"])
}

@Test func distinguishesNonErrorStderrProgressFromRealErrors() {
    #expect(ProgressParser.isNonErrorStderr("npm http fetch GET 200 https://registry.npmjs.org/typescript/-/typescript-5.6.2.tgz 300ms"))
    #expect(ProgressParser.isNonErrorStderr("  % Total    % Received % Xferd  Average Speed"))
    #expect(ProgressParser.isNonErrorStderr("##O#-#"))
    #expect(ProgressParser.isNonErrorStderr("########################################## 72.1%"))
    #expect(!ProgressParser.isNonErrorStderr("npm error code EACCES"))
    #expect(!ProgressParser.isNonErrorStderr("Error: Formula not found"))
}

@Test func runsCommandWithAllocatedPTY() async {
    let result = await ProcessCommandRunner().collect(PlannedCommand(
        argv: ["/bin/echo", "pty-ok"],
        summary: "pty echo",
        allocatePTY: true
    ))
    #expect(result.exitCode == 0)
    #expect(result.failure == nil)
    #expect(result.stdout.contains("pty-ok"))
}
