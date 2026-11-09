import CellarCore
import CellarProviders
import SwiftUI

struct InstallerBrowser: View {
    var model: AppModel

    var body: some View {
        GeometryReader { geo in
            HSplitView {
                List(model.installers, selection: Binding(get: { model.installerSelection }, set: { model.installerSelection = $0 })) { status in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(status.installer.name)
                        Text(presenceTitle(status.presence))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(status.id)
                }
                .frame(
                    minWidth: 240,
                    idealWidth: min(max(280, geo.size.width * 0.34), 380),
                    maxWidth: .infinity,
                    maxHeight: .infinity
                )
                installerDetail
                    .frame(
                        minWidth: 340,
                        idealWidth: max(340, geo.size.width * 0.66),
                        maxWidth: .infinity,
                        maxHeight: .infinity
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var installerDetail: some View {
        if let status = model.installers.first(where: { $0.id == model.installerSelection }) {
            Form {
                Text(status.installer.summary)
                LabeledContent("Estado", value: presenceTitle(status.presence))
                if case .installed(let path, _) = status.presence {
                    LabeledContent("Ruta") {
                        Text(path).font(.body.monospaced()).textSelection(.enabled)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Comando oficial").font(.caption).foregroundStyle(.secondary)
                    Text(status.installer.command)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
                if let url = URL(string: status.installer.docsURL) {
                    Link("Documentación", destination: url)
                }
                Button(actionTitle(status.presence, name: status.installer.name)) {
                    model.proposeScript(status.installer)
                }
                .disabled(model.isBusy)
                if case .installed = status.presence, status.installer.uninstallCommand != nil {
                    Button("Quitar \(status.installer.name)", role: .destructive) {
                        model.proposeRemoveScript(status.installer)
                    }
                    .disabled(model.isBusy)
                }
            }
            .formStyle(.grouped)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            ContentUnavailableView("Elige un instalador", systemImage: "arrow.down.circle")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func presenceTitle(_ presence: CurlPresence) -> String {
        switch presence {
        case .missing:
            "No instalado"
        case .installed(_, let version?):
            "Instalado · \(version)"
        case .installed:
            "Instalado"
        }
    }

    private func actionTitle(_ presence: CurlPresence, name: String) -> String {
        switch presence {
        case .missing: "Instalar \(name)"
        case .installed: "Reinstalar \(name)"
        }
    }
}

struct InstallSheet: View {
    var model: AppModel
    var providerID: ProviderID

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Instalar en \(model.displayName(for: providerID))")
                .font(.title2)
            HStack {
                TextField("Nombre", text: Binding(get: { model.installQuery }, set: { model.installQuery = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.searchInstall() } }
                Button("Buscar") { Task { await model.searchInstall() } }
                    .disabled(model.installBusy || model.installQuery.trimmingCharacters(in: .whitespaces).isEmpty)
                if model.installBusy { ProgressView().controlSize(.small) }
            }
            if let installError = model.installError {
                Text(installError).foregroundStyle(.red)
            }
            List(model.installResults) { package in
                Button {
                    model.proposeInstall(provider: providerID, package: package.ref)
                    model.installPresented = false
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(package.name).font(.headline)
                            Spacer()
                            Text(kindTitle(package.kind)).foregroundStyle(.secondary)
                        }
                        if !package.version.isEmpty {
                            Text(package.version).font(.caption).foregroundStyle(.secondary)
                        }
                        if !package.summary.isEmpty {
                            Text(package.summary).lineLimit(2).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            HStack {
                Spacer()
                Button("Cerrar") { model.installPresented = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 440)
    }
}

struct ConfirmSheet: View {
    var pending: PendingOperation
    var onCancel: () -> Void
    var onRun: () -> Void

    private var script: String {
        pending.commands.map(\.display).joined(separator: "\n")
    }

    private var several: Bool { pending.commands.count > 1 }

    private var commandText: some View {
        Text(script)
            .font(.system(several ? .body : .title3, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(pending.title).font(.title2)
            Text(several ? "\(pending.commands.count) paquetes, cada uno con su comando" : (pending.commands.first?.summary ?? ""))
                .foregroundStyle(.secondary)
            Text(several ? "Se ejecutarán estos comandos, uno por uno" : "Se ejecutará este comando")
                .font(.caption)
                .foregroundStyle(.secondary)
            Group {
                if several {
                    ScrollView {
                        commandText
                    }
                    .frame(maxHeight: 280)
                } else {
                    commandText
                }
            }
            Button(several ? "Copiar comandos" : "Copiar comando") { copyCommand(script) }
                .controlSize(.small)
            if let warning = pending.warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancelar", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Ejecutar", action: onRun)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 560)
    }
}
