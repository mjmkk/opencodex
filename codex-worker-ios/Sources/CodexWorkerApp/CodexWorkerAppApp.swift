import SwiftUI
import ComposableArchitecture
import CodexWorker

@main
struct CodexWorkerAppApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView(
                store: Store(
                    initialState: AppFeature.State(),
                    reducer: { AppFeature() }
                )
            )
        }
    }
}
