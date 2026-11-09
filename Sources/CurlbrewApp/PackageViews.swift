import AppKit
import CellarCore
import SwiftUI

struct OverviewView: View {
    var model: AppModel
    var open: (ProviderID) -> Void

    var body: some View {
        List {
            if !model.pendingUpgrades.isEmpty {
                Section {
                    ForEach(model.pendingUpgrades, id: \.provider) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(model.displayName(for: group.provider))
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Button("Actualizar todo") {
                                    model.proposeUpgradeAll(group.provider)
                                }
                                .controlSize(.small)
                                .disabled(model.isBusy)
                            }
                            ForEach(group.upgrades) { upgrade in
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.up.circle.fill")
                                        .foregroundStyle(.orange)
                                    Text(upgrade.name)
                                    Text("\(upgrade.installedVersion) → \(upgrade.availableVersion)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Actualizar") { model.proposeUpgrade(upgrade) }
                                        .controlSize(.small)
                                        .disabled(model.isBusy)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    HStack {
                        Text("Actualizaciones pendientes · \(model.totalUpgradeCount)")
                        if model.isCheckingUpgrades {
                            ProgressView().controlSize(.small)
                        }
                    }
                } footer: {
                    Text("Revisa el comando antes de ejecutarlo. Cada botón abre la confirmación.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Gestores en este Mac") {
                if model.snapshots.isEmpty {
                    ProgressView("Leyendo instalaciones")
                }
                if model.isCheckingUpgrades {
                    Text("Buscando actualizaciones…")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.snapshots) { snapshot in
                    Button { open(snapshot.id) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(snapshot.name).font(.headline)
                            Text(status(snapshot)).foregroundStyle(.secondary)
                            if let error = snapshot.loadError {
                                Text(error).font(.caption).foregroundStyle(.red)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
            Section {
                Text("Apple Silicon, un solo binario arm64. Cubre M1, M2, M3, M4 y M5 en macOS 14 o posterior.")
                    .foregroundStyle(.secondary)
            }
            Section("Curlbrew \(model.appVersion)") {
                if let update = model.offeredUpdate {
                    LabeledContent("Disponible", value: update.version)
                    Button("Actualizar a \(update.version)") { model.presentAppUpdate() }
                        .disabled(model.isUpdatingApp)
                } else {
                    Button(model.isCheckingAppUpdate ? "Buscando…" : "Buscar actualización") {
                        Task { await model.checkForAppUpdate(announce: true) }
                    }
                    .disabled(model.isCheckingAppUpdate || model.isUpdatingApp)
                }
                Text("Una release en GitHub reemplaza esta copia. Un push a main no llega solo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .toolbar {
            ToolbarItem {
                Button("Recargar") { model.startReload() }
                    .disabled(model.isBusy)
                    .keyboardShortcut("r", modifiers: .command)
            }
            if model.isBusy || model.isCheckingUpgrades {
                ToolbarItem { ProgressView().controlSize(.small) }
            }
        }
    }

    private func status(_ snapshot: ProviderSnapshot) -> String {
        let upgrades = model.upgradesByID.values.filter { $0.provider == snapshot.id }.count
        switch snapshot.availability {
        case .available(let version, _):
            let update = upgrades > 0 ? " · \(upgrades) con actualización" : ""
            return "\(version) · \(snapshot.packageCount) paquetes\(update)"
        case .missing(let binary):
            return "No está \(binary)"
        case .failed(let message):
            return message
        }
    }
}

struct ProviderBrowser: View {
    var model: AppModel
    var providerID: ProviderID

    var body: some View {
        GeometryReader { geo in
            HSplitView {
                packageList
                    .frame(
                        minWidth: 280,
                        idealWidth: columnWidth(geo.size.width, fraction: 0.4, minimum: 320, cap: 460),
                        maxWidth: .infinity,
                        maxHeight: .infinity
                    )
                PackageDetail(model: model, providerID: providerID)
                    .frame(
                        minWidth: 300,
                        idealWidth: columnWidth(geo.size.width, fraction: 0.6, minimum: 360, cap: 2000),
                        maxWidth: .infinity,
                        maxHeight: .infinity
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Instalar") { model.beginInstall(provider: providerID) }
                    .disabled(model.isBusy || !available)
            }
            ToolbarItem {
                Button("Actualizar todo") { model.proposeUpgradeAll(providerID) }
                    .disabled(model.isBusy || !available)
            }
            ToolbarItem {
                Toggle("Solo actualizaciones", isOn: Binding(get: { model.upgradesOnly }, set: { model.upgradesOnly = $0 }))
                    .toggleStyle(.checkbox)
                    .help("Oculta lo que no tiene versión nueva")
            }
            ToolbarItem {
                Picker("Orden", selection: Binding(get: { model.sort }, set: { model.sort = $0 })) {
                    ForEach(PackageSort.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .help("Cómo se ordena la lista")
            }
            ToolbarItem {
                Picker("Tipo", selection: Binding(get: { model.kindFilter }, set: { model.kindFilter = $0 })) {
                    Text("Todos").tag(PackageKindFilter.all)
                    ForEach(model.kinds(for: providerID), id: \.self) { kind in
                        Text(kindTitle(kind)).tag(PackageKindFilter.only(kind))
                    }
                }
                .pickerStyle(.menu)
                .help("Filtra por tipo de paquete")
            }
            ToolbarItem {
                Button("Recargar") { model.startReload() }
                    .disabled(model.isBusy)
            }
            if model.isBusy {
                ToolbarItem {
                    Button("Detener") { model.cancel() }
                }
            }
        }
        .searchable(text: Binding(get: { model.query }, set: { model.query = $0 }), prompt: "Filtrar instalados")
    }

    private var available: Bool {
        if case .available = model.snapshots.first(where: { $0.id == providerID })?.availability {
            return true
        }
        return false
    }

    private var packageList: some View {
        let rows = model.packages(for: providerID)
        return Group {
            if !available && !model.isBusy {
                ContentUnavailableView(
                    "\(model.displayName(for: providerID)) no está instalado",
                    systemImage: "questionmark.folder",
                    description: Text("Puedes instalarlo desde Instaladores.")
                )
            } else if rows.isEmpty && !model.isBusy {
                ContentUnavailableView(
                    "Nada en esta lista",
                    systemImage: "tray",
                    description: Text(model.upgradesOnly ? "No hay actualizaciones." : "No hay paquetes que coincidan.")
                )
            } else {
                packageListBody(rows)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Con el orden por defecto la lista se parte en dos secciones: lo que
    /// tiene actualización arriba, el resto abajo. Así se ve de un golpe qué
    /// revisar sin buscar entre cientos de paquetes.
    @ViewBuilder
    private func packageListBody(_ rows: [InstalledPackage]) -> some View {
        let pending = rows.filter { model.upgradesByID[$0.id] != nil }
        let rest = rows.filter { model.upgradesByID[$0.id] == nil }
        let grouped = model.sort == .updatesFirst && !pending.isEmpty

        List(selection: packageSelection) {
            if grouped {
                Section("Actualizaciones · \(pending.count)") {
                    ForEach(pending) { package in
                        packageRow(package)
                    }
                }
                if !rest.isEmpty {
                    Section("Al día · \(rest.count)") {
                        ForEach(rest) { package in
                            packageRow(package)
                        }
                    }
                }
            } else {
                ForEach(rows) { package in
                    packageRow(package)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func packageRow(_ package: InstalledPackage) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(package.name)
                Text(package.version)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(kindTitle(package.kind))
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
            if let upgrade = model.upgradesByID[package.id] {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.up.circle.fill")
                    Text(upgrade.availableVersion)
                }
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .foregroundStyle(.orange)
                .background(Color.orange.opacity(0.16), in: Capsule())
                .help("\(package.version) → \(upgrade.availableVersion)")
            }
        }
        .padding(.vertical, 2)
        .tag(package.id)
        .contextMenu {
            if model.upgradesByID[package.id] != nil {
                Button("Actualizar") { model.proposeUpgrade(package) }
            }
            Button("Desinstalar") { model.proposeUninstall(package) }
        }
    }

    private func columnWidth(_ total: CGFloat, fraction: CGFloat, minimum: CGFloat, cap: CGFloat) -> CGFloat {
        min(max(minimum, total * fraction), cap)
    }

    private var packageSelection: Binding<String?> {
        Binding(
            get: { model.selectedPackageID },
            set: { id in
                model.select(model.packages.first { $0.id == id })
            }
        )
    }
}

struct PackageDetail: View {
    var model: AppModel
    var providerID: ProviderID

    var body: some View {
        detail
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var detail: some View {
        if let package = model.selectedPackage, package.provider == providerID {
            Form {
                LabeledContent("Nombre", value: package.name)
                LabeledContent("Versión", value: package.version)
                LabeledContent("Tipo", value: kindTitle(package.kind))
                LabeledContent("Gestor", value: model.displayName(for: package.provider))
                if let upgrade = model.upgradesByID[package.id] {
                    LabeledContent("Disponible", value: upgrade.availableVersion)
                    if upgrade.pinned {
                        Text("Está fijado. Homebrew puede saltarse la actualización.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let details = model.details {
                    if !details.summary.isEmpty {
                        Text(details.summary)
                    }
                    if let homepage = details.homepage, let url = URL(string: homepage) {
                        Link(homepage, destination: url)
                    }
                    if let location = details.location ?? package.location {
                        LabeledContent("Ruta") {
                            Text(location).font(.body.monospaced()).textSelection(.enabled)
                        }
                    }
                    if !details.dependencies.isEmpty {
                        LabeledContent("Dependencias", value: details.dependencies.joined(separator: ", "))
                    }
                } else if let detailError = model.detailError {
                    Text(detailError).foregroundStyle(.red)
                }
                if let preview = model.preview(package, upgrade: false) {
                    commandBlock("Desinstalar ejecutaría", preview)
                }
                HStack {
                    Button("Actualizar") { model.proposeUpgrade(package) }
                    Button("Desinstalar", role: .destructive) { model.proposeUninstall(package) }
                }
                .disabled(model.isBusy)
            }
            .formStyle(.grouped)
            .padding(.top, 8)
        } else {
            ContentUnavailableView(
                "Elige un paquete",
                systemImage: "shippingbox",
                description: Text("El comando exacto se muestra antes de ejecutarlo.")
            )
        }
    }

    private func commandBlock(_ title: String, _ command: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(command)
                .font(.body.monospaced())
                .textSelection(.enabled)
            Button("Copiar comando") { copyCommand(command) }
                .controlSize(.small)
        }
    }
}

func copyCommand(_ text: String) {
    let board = NSPasteboard.general
    board.clearContents()
    board.setString(text, forType: .string)
}

func kindTitle(_ kind: PackageKind) -> String {
    switch kind {
    case .formula: "Fórmula"
    case .cask: "Cask"
    case .globalPackage: "Global"
    case .tool: "Herramienta"
    }
}
