import SwiftUI

/// 长按线程或 Goal 行，弹出改名输入框。名字存在 Registry 里；对 Codex 线程还会同步修改 Desktop 侧边栏。
struct RenameSheet: View {
    let title: String          // 当前名字，pre-filled
    let subtitle: String       // 显示在副标题，说明改的是哪条线程
    let onRename: (String) async -> Bool   // 返回 true 表示成功
    @State private var input = ""
    @State private var saving = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("新名字", text: $input)
                        .focused($focused)
                        .onSubmit { Task { await submit() } }
                } header: {
                    Text(subtitle).font(.footnote)
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
                }
            }
            .navigationTitle("改名")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { Task { await submit() } }
                        .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                }
            }
            .onAppear {
                input = title
                focused = true
            }
        }
    }

    @MainActor private func submit() async {
        let name = input.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !saving else { return }
        saving = true; error = nil
        let ok = await onRename(name)
        if ok { dismiss() } else { error = "保存失败，可以再试一次"; saving = false }
    }
}
