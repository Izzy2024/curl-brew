import CellarCore
import SwiftUI

enum SidebarItem: Hashable {
    case overview
    case provider(ProviderID)
    case installers
}

struct RootView: View {
    var model: AppModel

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationTitle("Curlbrew")
        .toolbarBackground(Color(nsColor: .windowBackgroundColor), for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .safeAreaInset(edge: .top, spacing: 0) {
            if let notice = model.notice {
                NoticeBanner(notice: notice) { model.dismissNotice() }
                    .padding(.top, 6)
                    .padding(.bottom, 4)
                    .frame(maxWidth: .infinity)
            }
        }
        .animation(.snappy(duration: 0.32), value: model.notice)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            LogView(lines: model.logLines, busy: model.isBusy || model.isCheckingUpgrades || model.isUpdatingApp) {
                model.clearLog()
            }
            .frame(height: 128)
        }
        .toolbar {
            ToolbarItem {
                Button(model.offeredUpdate == nil ? "Buscar actualización" : "Actualizar a \(model.offeredUpdate?.version ?? "")") {
                    if model.offeredUpdate != nil {
                        model.presentAppUpdate()
                    } else {
                        Task { await model.checkForAppUpdate(announce: true) }
                    }
                }
                .disabled(model.isBusy || model.isCheckingAppUpdate || model.isUpdatingApp)
            }
            if model.isCheckingAppUpdate || model.isUpdatingApp {
                ToolbarItem { ProgressView().controlSize(.small) }
            }
        }
        .task {
            model.startReload()
            await model.checkForAppUpdate(announce: false)
        }
        .sheet(isPresented: Binding(get: { model.appUpdatePresented }, set: { model.appUpdatePresented = $0 })) {
            if let release = model.offeredUpdate {
                AppUpdateSheet(release: release) {
                    model.appUpdatePresented = false
                } onInstall: {
                    Task { await model.installOfferedUpdate() }
                }
            }
        }
        .onChange(of: model.section) { _, newValue in
            model.query = ""
            // Un filtro de tipo de otro gestor dejaría la lista vacía.
            model.kindFilter = .all
            if case .provider = newValue {} else {
                model.upgradesOnly = false
            }
            model.select(nil)
        }
        .alert("No se pudo completar", isPresented: errorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sheet(item: Binding(get: { model.pending }, set: { model.pending = $0 })) { pending in
            ConfirmSheet(pending: pending) {
                model.pending = nil
            } onRun: {
                model.startExecute()
            }
        }
        .sheet(isPresented: Binding(get: { model.installPresented }, set: { model.installPresented = $0 })) {
            if let provider = model.installProvider {
                InstallSheet(model: model, providerID: provider)
            }
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }

    private var sidebar: some View {
        List(selection: Binding(get: { model.section }, set: { model.section = $0 })) {
            if model.totalUpgradeCount > 0 {
                Label("Resumen", systemImage: "square.grid.2x2")
                    .badge(model.totalUpgradeCount)
                    .tag(SidebarItem.overview)
            } else {
                Label("Resumen", systemImage: "square.grid.2x2").tag(SidebarItem.overview)
            }
            Section("Gestores") {
                ForEach(model.entries) { entry in
                    sidebarRow(entry)
                        .tag(SidebarItem.provider(entry.id))
                }
            }
            Label("Instaladores", systemImage: "arrow.down.circle").tag(SidebarItem.installers)
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 230)
    }

    @ViewBuilder
    private var detail: some View {
        switch model.section {
        case .overview, nil:
            OverviewView(model: model) { id in model.section = .provider(id) }
        case .provider(let id):
            ProviderBrowser(model: model, providerID: id)
        case .installers:
            InstallerBrowser(model: model)
        }
    }

    private func sidebarRow(_ entry: ProviderEntry) -> some View {
        let count = upgradeCount(entry.id)
        let label = Label(entry.name, systemImage: icon(entry.id))
        return Group {
            if count > 0 {
                label.badge(count)
            } else {
                label
            }
        }
    }

    private func icon(_ id: ProviderID) -> String {
        switch id {
        case .homebrew: "leaf"
        case .npm: "shippingbox"
        case .pnpm: "square.stack.3d.up"
        case .bun: "bolt"
        default: "cube"
        }
    }

    private func upgradeCount(_ id: ProviderID) -> Int {
        model.upgradeCount(for: id)
    }
}

struct LogView: View {
    var lines: [LogLine]
    var busy: Bool
    var clear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Registro", systemImage: "text.alignleft")
                    .font(.headline)
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Limpiar", action: clear)
                    .controlSize(.small)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if lines.isEmpty {
                            Text("Los comandos aparecen aquí antes y durante la ejecución.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(lines) { line in
                            Text(line.text)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(line.isError ? Color.red : Color.primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .clipped()
                .onChange(of: lines.count) { _, _ in
                    if let last = lines.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

struct AppUpdateSheet: View {
    var release: AppRelease
    var onCancel: () -> Void
    var onInstall: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Actualizar Curlbrew a \(release.version)").font(.title2)
            Text("Se descarga el zip de la release, se comprueba que sea \(AppUpdateFeed.bundleIdentifier) \(release.version) y se reemplaza esta copia. Después se vuelve a abrir.")
                .foregroundStyle(.secondary)
            Text(release.downloadURL.absoluteString)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            HStack {
                Spacer()
                Button("Cancelar", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Actualizar", action: onInstall)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 560)
    }
}

struct NoticeBanner: View {
    var notice: StatusNotice
    var dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: notice.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(notice.isError ? Color.red : Color.green)
            Text(notice.text)
                .lineLimit(1)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator.opacity(0.4)))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }
}
