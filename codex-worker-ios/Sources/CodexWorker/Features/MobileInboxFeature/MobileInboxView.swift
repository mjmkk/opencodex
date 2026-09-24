import SwiftUI

public struct MobileInboxView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var nativeDestination: NativeRequestRoute?
    @State private var refreshID = 0
    var nativeRequestRoute: NativeRequestRoute? = nil
    var onOpenThread: ((String) -> Void)? = nil
    public var body: some View {
        NavigationStack {
            List { NativeRequestsSection(refreshing: refreshID, onOpenThread: onOpenThread) }
                .navigationTitle("待你处理")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("关闭") { dismiss() } }
                    ToolbarItem(placement: .topBarTrailing) { Button("刷新", systemImage: "arrow.clockwise") { refreshID += 1 } }
                }
                .refreshable { refreshID += 1 }
                .navigationDestination(item: $nativeDestination) { route in
                    NativeRequestDestination(route: route, onOpenThread: onOpenThread)
                }
        }
        .task { nativeDestination = nativeRequestRoute }
        .onChange(of: nativeRequestRoute) { _, route in nativeDestination = route }
    }
}
