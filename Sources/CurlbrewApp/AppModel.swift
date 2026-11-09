import CellarCore
import CellarProviders
import Foundation
import Observation

struct ProviderSnapshot: Identifiable, Hashable, Sendable {
    var id: ProviderID
    var name: String
    var availability: ProviderAvailability
    var packageCount: Int
    var loadError: String?
}

struct LogLine: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var isError: Bool
}

struct PendingOperation: Identifiable {
    let id = UUID()
    var title: String
    var command: PlannedCommand
    var warning: String?
}

@MainActor
@Observable
final class AppModel {
    var snapshots: [ProviderSnapshot] = []
    var packages: [InstalledPackage] = []
    var upgradesByID: [String: PackageUpgrade] = [:]
    var installers: [CurlInstallerStatus] = []
    var query = ""
    var upgradesOnly = false
    var sort: PackageSort = .updatesFirst
    var kindFilter: PackageKindFilter = .all
    var logLines: [LogLine] = []
    var isBusy = false
    var isCheckingUpgrades = false
    var errorMessage: String?
    var pending: PendingOperation?
    var installPresented = false
    var installProvider: ProviderID?
    var installQuery = ""
    var installResults: [RemotePackage] = []
    var installError: String?
    var installBusy = false
    var details: PackageDetails?
    var detailError: String?
    var selectedPackageID: String?
    var section: SidebarItem? = .overview
    var installerSelection: String?
    var notice: StatusNotice?

    @ObservationIgnored private let providers: [any PackageProvider]
    @ObservationIgnored private let processRunner: any CommandRunning
    @ObservationIgnored private let shellRunner: any CommandRunning
    @ObservationIgnored private let locator: BinaryLocator
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    init() {
        let locator = BinaryLocator.fromEnvironment()
        let direct = ProcessCommandRunner()
        var shellInner = direct
        shellInner.allowShell = true
        self.locator = locator
        self.processRunner = direct
        self.shellRunner = AllowlistedShellRunner(allowed: CurlCatalog.commands, inner: shellInner)
        self.providers = ProviderCatalog.makeAll(locator: locator, runner: direct)
    }

    var entries: [ProviderEntry] {
        providers.map { ProviderEntry(id: $0.id, name: $0.displayName) }
    }

    func displayName(for id: ProviderID) -> String {
        providers.first { $0.id == id }?.displayName ?? id.rawValue
    }

    func packages(for provider: ProviderID) -> [InstalledPackage] {
        let mine = packages.filter { $0.provider == provider }
        return PackageOrdering.arrange(
            mine,
            query: query,
            upgradesByID: upgradesByID,
            upgradesOnly: upgradesOnly,
            kind: kindFilter,
            sort: sort
        )
    }

    /// Tipos que existen en este gestor, para no ofrecer filtros vacíos.
    func kinds(for provider: ProviderID) -> [PackageKind] {
        PackageOrdering.kinds(in: packages.filter { $0.provider == provider })
    }

    func upgradeCount(for provider: ProviderID) -> Int {
        upgradesByID.values.filter { $0.provider == provider }.count
    }

    /// Total de actualizaciones en todos los gestores, para el resumen.
    var totalUpgradeCount: Int {
        upgradesByID.count
    }

    /// Todas las actualizaciones pendientes, agrupadas por gestor y ordenadas
    /// por nombre. Es lo que muestra el resumen, sin tener que abrir cada uno.
    var pendingUpgrades: [(provider: ProviderID, upgrades: [PackageUpgrade])] {
        let grouped = Dictionary(grouping: upgradesByID.values) { $0.provider }
        return providers.compactMap { provider in
            guard let list = grouped[provider.id], !list.isEmpty else { return nil }
            return (provider.id, list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
        }
    }

    /// Actualiza un paquete desde el resumen, sin cambiar de sección.
    func proposeUpgrade(_ upgrade: PackageUpgrade) {
        let package = InstalledPackage(
            name: upgrade.name,
            version: upgrade.installedVersion,
            provider: upgrade.provider,
            kind: upgrade.kind
        )
        proposeUpgrade(package)
    }

    var selectedPackage: InstalledPackage? {
        guard let selectedPackageID else { return nil }
        return packages.first { $0.id == selectedPackageID }
    }

    func startReload() {
        operation?.cancel()
        generation += 1
        let token = generation
        operation = Task { await self.reload(token: token) }
    }

    func cancel() {
        operation?.cancel()
        appendLog("detenido", error: true)
    }

    func beginInstall(provider: ProviderID) {
        installProvider = provider
        installQuery = ""
        installResults = []
        installError = nil
        installPresented = true
    }

    func searchInstall() async {
        guard let installProvider, let provider = self.provider(installProvider) else { return }
        installBusy = true
        installError = nil
        defer { installBusy = false }
        do {
            installResults = try await provider.search(installQuery)
            if installResults.isEmpty { installError = "Sin resultados" }
        } catch {
            installResults = []
            installError = error.localizedDescription
        }
    }

    func proposeInstall(provider: ProviderID, package: PackageRef) {
        guard let command = self.provider(provider)?.planInstall(package) else {
            errorMessage = "No se puede instalar \(package.name)"
            return
        }
        pending = PendingOperation(title: "Instalar \(package.name)", command: command, warning: nil)
    }

    func proposeUninstall(_ package: InstalledPackage) {
        guard let command = provider(package.provider)?.planUninstall(package) else {
            errorMessage = "No se puede desinstalar \(package.name)"
            return
        }
        pending = PendingOperation(title: "Desinstalar \(package.name)", command: command, warning: nil)
    }

    func proposeUpgrade(_ package: InstalledPackage) {
        guard let command = provider(package.provider)?.planUpgrade(package) else {
            errorMessage = "No se puede actualizar \(package.name)"
            return
        }
        pending = PendingOperation(title: "Actualizar \(package.name)", command: command, warning: nil)
    }

    func proposeUpgradeAll(_ providerID: ProviderID) {
        let packages = upgradesByID.values
            .filter { $0.provider == providerID }
            .sorted { $0.name < $1.name }
            .map {
                InstalledPackage(
                    name: $0.name,
                    version: $0.installedVersion,
                    provider: $0.provider,
                    kind: $0.kind
                )
            }
        guard let command = provider(providerID)?.planUpgradeList(packages) else {
            errorMessage = packages.isEmpty
                ? "No hay actualizaciones de \(displayName(for: providerID))"
                : "No se puede actualizar \(displayName(for: providerID))"
            return
        }
        pending = PendingOperation(title: "Actualizar \(displayName(for: providerID))", command: command, warning: nil)
    }

    func proposeScript(_ installer: CurlInstaller) {
        guard let command = CurlCatalog.plan(for: installer) else {
            errorMessage = "Ese instalador no está en la lista blanca"
            return
        }
        pending = PendingOperation(
            title: "Instalar \(installer.name)",
            command: command,
            warning: "Se descarga y ejecuta solo el instalador oficial de arriba."
        )
    }

    func proposeRemoveScript(_ installer: CurlInstaller) {
        guard let command = CurlCatalog.planUninstall(for: installer) else {
            errorMessage = "Ese instalador no está en la lista blanca"
            return
        }
        pending = PendingOperation(
            title: "Quitar \(installer.name)",
            command: command,
            warning: "Quita la app y el comando. Los ajustes en ~/.config/magpie se quedan."
        )
    }

    func preview(_ package: InstalledPackage, upgrade: Bool) -> String? {
        let command = upgrade
            ? provider(package.provider)?.planUpgrade(package)
            : provider(package.provider)?.planUninstall(package)
        return command?.display
    }

    func startExecute() {
        guard let pending else { return }
        let command = pending.command
        self.pending = nil
        operation?.cancel()
        generation += 1
        let token = generation
        operation = Task { await self.execute(command, token: token) }
    }

    func select(_ package: InstalledPackage?) {
        selectedPackageID = package?.id
        details = nil
        detailError = nil
        detailTask?.cancel()
        guard let package else { return }
        detailTask = Task { await self.loadDetails(package) }
    }

    private func reload(token: Int) async {
        isBusy = true
        await loadInventories(token: token)
        guard token == generation, !Task.isCancelled else { return }
        isBusy = false
        isCheckingUpgrades = true
        await loadUpgrades(token: token)
        if token == generation { isCheckingUpgrades = false }
    }

    private func loadInventories(token: Int) async {
        let current = providers
        let loaded = await withTaskGroup(of: Inventory.self) { group in
            for provider in current {
                group.addTask { await Inventory.load(provider) }
            }
            var all: [Inventory] = []
            for await item in group { all.append(item) }
            return all
        }
        guard token == generation, !Task.isCancelled else { return }
        let byID = Dictionary(uniqueKeysWithValues: loaded.map { ($0.snapshot.id, $0) })
        let ordered = current.compactMap { byID[$0.id] }
        snapshots = ordered.map(\.snapshot)
        packages = ordered.flatMap(\.packages).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        let statuses = await CurlCatalog.status(locator: locator, runner: processRunner)
        guard token == generation, !Task.isCancelled else { return }
        installers = statuses
        if let selectedPackageID, !packages.contains(where: { $0.id == selectedPackageID }) {
            select(nil)
        }
    }

    private func loadUpgrades(token: Int) async {
        let current = providers
        let found = await withTaskGroup(of: [PackageUpgrade].self) { group in
            for provider in current {
                group.addTask {
                    guard case .available = await provider.availability() else { return [] }
                    return (try? await provider.upgrades()) ?? []
                }
            }
            var all: [PackageUpgrade] = []
            for await batch in group { all.append(contentsOf: batch) }
            return all
        }
        guard token == generation, !Task.isCancelled else { return }
        upgradesByID = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func execute(_ command: PlannedCommand, token: Int) async {
        isBusy = true
        dismissNotice()
        appendLog("$ \(command.display)", error: false)
        appendLog(command.summary, error: false)
        var failed = false
        var sawOutcome = false
        for await event in stream(command) {
            if Task.isCancelled { break }
            switch event {
            case .started:
                break
            case .stdout(let text):
                appendLog(text, error: false)
            case .stderr(let text):
                appendLog(text, error: true)
            case .finished(let code):
                sawOutcome = true
                failed = code != 0
                appendLog("terminó con código \(code)", error: code != 0)
            case .failed(let message):
                sawOutcome = true
                failed = true
                appendLog(message, error: true)
            }
        }
        isBusy = false
        guard token == generation, !Task.isCancelled else { return }
        if sawOutcome {
            showNotice(failed ? "Falló · \(command.summary)" : "Listo · \(command.summary)", isError: failed)
        }
        await loadInventories(token: token)
        guard token == generation, !Task.isCancelled else { return }
        isCheckingUpgrades = true
        await loadUpgrades(token: token)
        if token == generation { isCheckingUpgrades = false }
    }

    private func loadDetails(_ package: InstalledPackage) async {
        guard let provider = provider(package.provider) else { return }
        do {
            let value = try await provider.details(package)
            guard !Task.isCancelled, selectedPackageID == package.id else { return }
            details = value
        } catch {
            guard !Task.isCancelled, selectedPackageID == package.id else { return }
            detailError = error.localizedDescription
        }
    }

    private func provider(_ id: ProviderID) -> (any PackageProvider)? {
        providers.first { $0.id == id }
    }

    private func stream(_ command: PlannedCommand) -> AsyncStream<OperationEvent> {
        if let executable = command.argv.first, isShell(executable) {
            return shellRunner.run(command)
        }
        return processRunner.run(command)
    }

    private func isShell(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name == "zsh" || name == "bash" || name == "sh"
    }

    private func appendLog(_ text: String, error: Bool) {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            logLines.append(LogLine(text: String(line), isError: error))
        }
        if logLines.count > 2000 {
            logLines.removeFirst(logLines.count - 2000)
        }
    }

    func clearLog() { logLines.removeAll() }

    func showNotice(_ text: String, isError: Bool) {
        notice = StatusNotice(text: text, isError: isError)
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(4.5))
            guard !Task.isCancelled else { return }
            notice = nil
        }
    }

    func dismissNotice() {
        noticeTask?.cancel()
        notice = nil
    }
}

struct StatusNotice: Equatable {
    var text: String
    var isError: Bool
}

struct ProviderEntry: Identifiable, Hashable {
    var id: ProviderID
    var name: String
}

private struct Inventory: Sendable {
    var snapshot: ProviderSnapshot
    var packages: [InstalledPackage]

    static func load(_ provider: any PackageProvider) async -> Inventory {
        let availability = await provider.availability()
        var packages: [InstalledPackage] = []
        var loadError: String?
        if case .available = availability {
            do {
                packages = try await provider.installed()
            } catch let failure as ProviderFailure {
                loadError = failure.message
                packages = failure.partial
            } catch {
                loadError = error.localizedDescription
            }
        }
        return Inventory(
            snapshot: ProviderSnapshot(
                id: provider.id,
                name: provider.displayName,
                availability: availability,
                packageCount: packages.count,
                loadError: loadError
            ),
            packages: packages
        )
    }
}
