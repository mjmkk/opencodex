import SwiftUI
import CodexWorker

@main
struct CodexWorkerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView(
                store: .init(
                    initialState: AppFeature.State(),
                    reducer: { AppFeature() }
                )
            )
        }
    }
}
