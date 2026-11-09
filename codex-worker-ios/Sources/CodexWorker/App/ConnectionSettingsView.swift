import SwiftUI

/// AGT-26 S6：连接设置，只有服务地址和令牌两项。旧的设置页（归档线程、执行权限等）随旧 UI 一起删除了。
struct ConnectionSettingsView: View {
    let done: () -> Void
    @State private var baseURL = WorkerConfiguration.load()?.baseURL ?? "https://spirit-master.tail3c834b.ts.net:8443"
    @State private var token = WorkerConfiguration.load()?.token ?? ""
    @State private var status: String?
    @State private var checking = false

    var body: some View {
        NavigationStack {
            Form {
                Section("服务地址") {
                    TextField("https://…", text: $baseURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                }
                Section("令牌") {
                    SecureField("Bearer token", text: $token)
                }
                Section {
                    Button(checking ? "正在检查…" : "保存并检查连接") { Task { await save() } }
                        .disabled(checking || baseURL.isEmpty || token.isEmpty)
                } footer: {
                    if let status { Text(status) }
                }
            }
            .navigationTitle("连接")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成", action: done) } }
        }
    }

    @MainActor private func save() async {
        checking = true
        defer { checking = false }
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        WorkerConfiguration.save(WorkerConfiguration(baseURL: trimmed, token: token))
        do {
            _ = try await APIClient.live.healthCheck()
            status = "已连接"
        } catch {
            status = "连接失败：请检查地址和令牌"
        }
    }
}
