import SwiftUI

struct NativeRequestDestination: View {
    let route: NativeRequestRoute
    var onOpenThread: ((String) -> Void)?
    @State private var item: NativeRemoteRequest?
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        Group {
            if let item {
                NativeRequestView(item: item, onOpenThread: onOpenThread)
            } else {
                ContentUnavailableView {
                    Label(loading ? "正在核对原请求" : "暂时无法读取请求", systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text(error ?? "只读取这条通知对应的请求，失效请求不会自动换成其他请求。")
                } actions: {
                    Button("重新读取") { Task { await load() } }.disabled(loading)
                    Button("查看原任务") { onOpenThread?(route.threadID) }
                }
            }
        }
        .task(id: route.id) { await load() }
    }

    @MainActor private func load() async {
        guard !loading, let selection = route.selection else { return }
        loading = true; defer { loading = false }
        do {
            let value = try await APIClient.live.readNativeRequest(selection)
            guard route.matches(value) else { throw CodexError.invalidState }
            item = value; error = nil
        } catch {
            self.error = "原请求暂不可用，或已结束。" + error.localizedDescription
        }
    }
}
