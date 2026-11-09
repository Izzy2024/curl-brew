import SwiftUI

@MainActor
enum AppStore {
    static let model = AppModel()
}

@main
struct CurlbrewApp: App {
    var body: some Scene {
        WindowGroup {
            RootView(model: AppStore.model)
        }
        .defaultSize(width: 1120, height: 760)
        .windowToolbarStyle(.unifiedCompact)
    }
}
