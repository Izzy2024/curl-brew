import CellarCore
import Foundation
import Testing
@testable import CellarProviders

@Test func listsFormulaeAndCasksWithoutAShell() async throws {
    let runner = ScriptedRunner()
    runner.set(.init(stdout: "Homebrew 7.0.12\n"), for: ["brew", "--version"])
    runner.set(.init(stdout: "wget 1.25.0\nllvm 18.1.8 17.0.6\n==> Formulae\n"), for: ["brew", "list", "--formula", "--versions"])
    runner.set(.init(stdout: "firefox 120.0\n"), for: ["brew", "list", "--cask", "--versions"])
    let provider = HomebrewProvider(
        locator: StaticLocator(paths: ["brew": "/opt/homebrew/bin/brew"]),
        runner: runner
    )
    let availability = await provider.availability()
    #expect(availability == .available(version: "Homebrew 7.0.12", binary: "/opt/homebrew/bin/brew"))
    let packages = try await provider.installed()
    #expect(packages.map(\.name) == ["wget", "llvm", "firefox"])
    #expect(packages[1].version == "18.1.8, 17.0.6")
    #expect(packages[2].kind == .cask)
    let install = provider.planInstall(PackageRef(name: "wget", kind: .formula))
    #expect(install?.argv == ["/opt/homebrew/bin/brew", "install", "--formula", "--", "wget"])
    #expect(install?.workingDirectory == "/private/tmp")
    #expect(provider.planInstall(PackageRef(name: "--force", kind: .formula)) == nil)
    #expect(!runner.ran.contains { $0.first == "/bin/zsh" || $0.first == "zsh" })
}

@Test func parsesOutdatedJSON() throws {
    let json = """
    {"formulae":[{"name":"wget","installed_versions":["1.21.4"],"current_version":"1.25.0","pinned":false}],
     "casks":[{"name":"firefox","installed_versions":["120"],"current_version":"121"}]}
    """.data(using: .utf8)!
    let upgrades = try HomebrewJSON.upgrades(from: json, provider: .homebrew)
    #expect(upgrades.map(\.name) == ["wget", "firefox"])
    #expect(upgrades[0].availableVersion == "1.25.0")
    #expect(upgrades[1].kind == .cask)
}

@Test func infoJSONReadsDescription() throws {
    let json = """
    {"formulae":[{"name":"wget","desc":"Internet file retriever","homepage":"https://www.gnu.org/software/wget/","pinned":false,"dependencies":["libidn2"]}],"casks":[]}
    """.data(using: .utf8)!
    let details = try HomebrewJSON.details(from: json, kind: .formula, provider: .homebrew)
    #expect(details.summary == "Internet file retriever")
    #expect(details.dependencies == ["libidn2"])
}

@Test func npmAndPnpmParseGlobalJSON() throws {
    let npm = """
    {"name":"lib","dependencies":{"left-pad":{"version":"1.3.0"},"corepack":{"version":"0.36.0"}}}
    """.data(using: .utf8)!
    let npmPackages = try DependencyJSON.packages(from: npm, provider: .npm)
    #expect(npmPackages.map(\.name) == ["corepack", "left-pad"])
    #expect(npmPackages.first { $0.name == "left-pad" }?.version == "1.3.0")

    let pnpm = """
    [{"path":"/Users/example/Library/pnpm/global/v11","dependencies":{"typescript":{"version":"5.6.2"}}}]
    """.data(using: .utf8)!
    let pnpmPackages = try DependencyJSON.packages(from: pnpm, provider: .pnpm)
    #expect(pnpmPackages.map(\.name) == ["typescript"])
    #expect(pnpmPackages[0].location == "/Users/example/Library/pnpm/global/v11/node_modules/typescript")
}

@Test func outdatedObjectAndArray() throws {
    let npm = """
    {"left-pad":{"current":"1.0.0","wanted":"1.0.1","latest":"1.0.2"}}
    """.data(using: .utf8)!
    let upgrades = try JSUpgrades.parse(npm, provider: .npm)
    #expect(upgrades.count == 1)
    #expect(upgrades[0].availableVersion == "1.0.2")
    let empty = try JSUpgrades.parse(Data("{}".utf8), provider: .pnpm)
    #expect(empty.isEmpty)
    let array = """
    [{"packageName":"typescript","current":"5.0.0","latest":"5.6.2"}]
    """.data(using: .utf8)!
    #expect(try JSUpgrades.parse(array, provider: .pnpm).map(\.name) == ["typescript"])
}

@Test func registrySearchParser() throws {
    let json = """
    {"objects":[{"package":{"name":"left-pad","version":"1.3.0","description":"Pad a string"}}]}
    """.data(using: .utf8)!
    let results = try RegistrySearch.parse(json, provider: .npm, kind: .globalPackage)
    #expect(results.map(\.name) == ["left-pad"])
    #expect(results[0].summary == "Pad a string")
}

@Test func npmPlanUsesGlobalFlagAndRejectsFlagsAsNames() async {
    let runner = ScriptedRunner()
    runner.set(.init(stdout: "11.19.1\n"), for: ["npm", "--version"])
    let provider = NpmProvider(locator: StaticLocator(paths: ["npm": "/opt/homebrew/bin/npm"]), runner: runner)
    let plan = provider.planInstall(PackageRef(name: "@scope/pkg", kind: .globalPackage))
    #expect(plan?.argv == ["/opt/homebrew/bin/npm", "install", "--global", "@scope/pkg"])
    #expect(provider.planUninstall(InstalledPackage(name: "--save", version: "1", provider: .npm, kind: .globalPackage)) == nil)
    let upgrade = provider.planUpgrade(InstalledPackage(name: "@github/copilot", version: "1.0.85", provider: .npm, kind: .globalPackage))
    #expect(upgrade?.argv == ["/opt/homebrew/bin/npm", "install", "--global", "@github/copilot@latest"])
    let all = provider.planUpgradeList([
        InstalledPackage(name: "left-pad", version: "1.0.0", provider: .npm, kind: .globalPackage),
        InstalledPackage(name: "@github/copilot", version: "1.0.85", provider: .npm, kind: .globalPackage),
    ])
    #expect(all?.argv == ["/opt/homebrew/bin/npm", "install", "--global", "@github/copilot@latest", "left-pad@latest"])
    #expect(provider.planUpgrade(nil) == nil)
    #expect(provider.planUpgradeList([]) == nil)
    #expect(provider.planUpgrade(InstalledPackage(name: "--force", version: "1", provider: .npm, kind: .globalPackage)) == nil)
    let availability = await provider.availability()
    #expect(availability == .available(version: "11.19.1", binary: "/opt/homebrew/bin/npm"))
}

@Test func bunReadsOnlyItsGlobalManifest() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let packageDir = root.appendingPathComponent("node_modules/prettier", isDirectory: true)
    try FileManager.default.createDirectory(at: packageDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try """
    {"dependencies":{"prettier":"^3.0.0"}}
    """.write(to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
    try """
    {"name":"prettier","version":"3.3.3","description":"formatter"}
    """.write(to: packageDir.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
    let provider = BunProvider(
        locator: StaticLocator(paths: ["bun": "/Users/example/.bun/bin/bun"]),
        runner: ScriptedRunner(),
        globalRoot: root
    )
    let packages = try await provider.installed()
    #expect(packages.map(\.name) == ["prettier"])
    #expect(packages[0].version == "3.3.3")
    let details = try await provider.details(packages[0])
    #expect(details.summary == "formatter")
    #expect(provider.planInstall(PackageRef(name: "prettier", kind: .globalPackage))?.argv == ["/Users/example/.bun/bin/bun", "add", "--global", "prettier"])
}

@Test func catalogRejectsTamperedCommandsAndAllowsOfficialOnes() async throws {
    let official = try #require(CurlCatalog.entries.first { $0.id == "nvm" })
    let plan = try #require(CurlCatalog.plan(for: official))
    #expect(plan.argv == ["/bin/zsh", "-lc", official.command])
    var tampered = official
    tampered.command += "; rm -rf /"
    #expect(CurlCatalog.plan(for: tampered) == nil)

    let runner = ScriptedRunner()
    let shell = AllowlistedShellRunner(allowed: CurlCatalog.commands, inner: runner)
    let rejected = await shell.collect(PlannedCommand(argv: ["/bin/zsh", "-lc", "echo pwn"], summary: "no"))
    #expect(rejected.failure == AllowlistedShellRunner<ScriptedRunner>.rejected)
    #expect(runner.ran.isEmpty)
    _ = await shell.collect(plan)
    #expect(runner.ran == [plan.argv])
}

@Test func everyInstallerCommandIsASingleCurlLine() {
    let ids = CurlCatalog.entries.map(\.id)
    #expect(Set(ids).count == ids.count)
    for entry in CurlCatalog.entries {
        #expect(entry.command.contains("curl"))
        #expect(!entry.command.contains("\n"))
        #expect(entry.binary != nil || entry.homeRelativeFile != nil)
    }
    #expect(CurlCatalog.entries.first { $0.id == "nvm" }?.command == "curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.41.0/install.sh | bash")
}

@Test func magpieStaysOnItsOfficialInstallAndUninstallLines() throws {
    let magpie = try #require(CurlCatalog.entries.first { $0.id == "magpie" })
    #expect(magpie.command == "curl -fsSL https://usemagpie.ai/install.sh | sh")
    #expect(magpie.uninstallCommand == "curl -fsSL https://usemagpie.ai/install.sh | sh -s -- --uninstall")
    let uninstall = try #require(magpie.uninstallCommand)
    let install = try #require(CurlCatalog.plan(for: magpie))
    let remove = try #require(CurlCatalog.planUninstall(for: magpie))
    #expect(install.argv == ["/bin/zsh", "-lc", magpie.command])
    #expect(remove.argv == ["/bin/zsh", "-lc", uninstall])
    #expect(CurlCatalog.commands.contains(magpie.command))
    #expect(CurlCatalog.commands.contains(uninstall))
    var tampered = magpie
    tampered.uninstallCommand = (magpie.uninstallCommand ?? "") + "; rm -rf /"
    #expect(CurlCatalog.planUninstall(for: tampered) == nil)

    let home = "/Users/example"
    #expect(CurlCatalog.expandHome("~/Applications/magpie.app/Contents/MacOS/magpie", home: home) == "/Users/example/Applications/magpie.app/Contents/MacOS/magpie")
    let found = CurlCatalog.firstExecutable(
        ["/Applications/magpie.app/Contents/MacOS/magpie", "~/.local/bin/magpie"],
        home: home,
        isExecutable: { $0 == "/Users/example/.local/bin/magpie" }
    )
    #expect(found == "/Users/example/.local/bin/magpie")

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("magpie-plist-\(UUID().uuidString)", isDirectory: true)
    let contents = root.appendingPathComponent("magpie.app/Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS", isDirectory: true), withIntermediateDirectories: true)
    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>9.9.9</string></dict></plist>
    """
    try Data(plist.utf8).write(to: contents.appendingPathComponent("Info.plist"))
    let executable = contents.appendingPathComponent("MacOS/magpie").path
    FileManager.default.createFile(atPath: executable, contents: Data())
    #expect(CurlCatalog.bundleVersion(executablePath: executable) == "9.9.9")
    try? FileManager.default.removeItem(at: root)
}
