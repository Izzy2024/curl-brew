import SwiftUI

@MainActor
enum AppStore {
    static let model = AppModel()
    /// La acción de abrir la ventana vive en las vistas (openWindow),
    /// pero el delegado la necesita cuando el clic en el Dock llega sin
    /// ninguna ventana.
    static var openMainWindow: (() -> Void)?
}

/// Cerrar la última ventana deja la app viva y el clic en el Dock envía el
/// evento reopen. SwiftUI no repone una ventana cerrada del WindowGroup, así
/// que el delegado restaura la que haya (minimizada u oculta) o abre otra.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ application: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        if application.isHidden {
            application.unhide(nil)
        } else if let window = application.windows.first(where: { $0.isMiniaturized && !($0 is NSPanel) }) {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        } else if let window = application.windows.first(where: { $0.isVisible && !($0 is NSPanel) }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            AppStore.openMainWindow?()
        }
        application.activate()
        return true
    }
}

@main
struct CurlbrewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(id: "main") {
            MainWindow()
        }
        .defaultSize(width: 1120, height: 760)
        .windowToolbarStyle(.unifiedCompact)
    }
}

private struct MainWindow: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        RootView(model: AppStore.model)
            .onAppear { AppStore.openMainWindow = { openWindow(id: "main") } }
    }
}
