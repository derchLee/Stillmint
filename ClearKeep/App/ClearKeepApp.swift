import SwiftUI

@main
struct ClearKeepApp: App {
    @StateObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    init() {
        #if DEBUG
        _model = StateObject(wrappedValue: DebugE2EFixture.makeModelIfRequested() ?? (ProcessInfo.processInfo.arguments.contains("--clearkeep-ui-fixture") ? DebugReviewFixture.makeModel() : AppModel()))
        #else
        _model = StateObject(wrappedValue: AppModel())
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .preferredColorScheme(nil)
                .task { await model.store.load() }
                .onChange(of: scenePhase) { _, phase in if phase != .active { model.flushReviewCheckpoint() } }
        }
    }
}
