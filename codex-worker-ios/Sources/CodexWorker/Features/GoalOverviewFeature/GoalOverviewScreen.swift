import SwiftUI

@MainActor
struct GoalOverviewScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var reader = GoalOverviewReader()

    var body: some View {
        GoalOverviewView(rows: reader.rows, inventoryValidation: reader.inventoryValidation,
            hasSnapshot: reader.hasSnapshot, isRefreshing: reader.isRefreshing,
            failure: reader.failure, refresh: reader.refresh)
            .task { await reader.refresh() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await reader.refresh() } }
            }
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
                reader.identityChanged()
            }
            .onDisappear { reader.invalidate() }
    }
}
