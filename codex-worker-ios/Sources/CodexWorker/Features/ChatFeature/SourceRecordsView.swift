import SwiftUI

struct SourceRecordsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    let records: [ThreadHistory.Record]

    var body: some View {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleRecords = search.isEmpty ? records : records.filter {
            $0.id.localizedCaseInsensitiveContains(search)
                || $0.title.localizedCaseInsensitiveContains(search)
                || displayTitle($0.title).localizedCaseInsensitiveContains(search)
        }

        NavigationStack {
            List {
                VStack(alignment: .leading, spacing: 6) {
                    if search.isEmpty {
                        Text("当前可查看 \(records.count) 条来源索引")
                    } else {
                        Text("匹配 \(visibleRecords.count) 条 · 已保存 \(records.count) 条")
                    }
                    Text("按来源顺序展示。索引未提供执行正文或结果，请在原任务核对。")
                        .foregroundStyle(.secondary)
                }
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
                .listRowInsets(EdgeInsets(top: 16, leading: 20, bottom: 16, trailing: 20))
                .listRowSeparator(.hidden)

                if visibleRecords.isEmpty {
                    Text(search.isEmpty ? "此页尚无来源索引" : "没有匹配记录")
                        .foregroundStyle(.secondary)
                        .listRowInsets(rowInsets)
                        .listRowSeparator(.hidden)
                }

                ForEach(visibleRecords) { item in
                    DisclosureGroup {
                        recordField("原始类型", value: item.title)
                        recordField("完整标识", value: item.id)
                        if let observed = item.observedAt {
                            recordField("来源观察时间", value: observed)
                        }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(displayTitle(item.title))
                                .font(.body)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Text("…" + String(item.id.suffix(8)))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .fixedSize()
                                .accessibilityHidden(true)
                        }
                    }
                    .listRowInsets(rowInsets)
                    .accessibilityIdentifier("source-record-" + item.id)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(CodexAppearance.canvas)
            .tint(.primary)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索类型或记录标识")
            .navigationTitle("来源记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel("关闭来源记录")
                }
            }
        }
    }

    private var rowInsets: EdgeInsets {
        EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20)
    }

    private func recordField(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.footnote).foregroundStyle(.secondary)
            Text(value)
                .font(.footnote.monospaced())
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .listRowInsets(EdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 20))
    }

    private func displayTitle(_ sourceType: String) -> String {
        switch sourceType {
        case "commandExecution": "命令执行"
        case "mcpToolCall": "工具调用"
        case "fileChange": "文件变更"
        case "unknown/functionCallOutput": "类型待确认"
        default: sourceType
        }
    }
}
