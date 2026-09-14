import ComposableArchitecture
import SwiftUI

public struct MobileInboxView: View {
    @Environment(\.dismiss) private var dismiss
    let store: StoreOf<MobileInboxFeature>
    public var body: some View {
        WithViewStore(store, observe: { $0 }) { viewStore in
            NavigationStack {
                List {
                    if let message = viewStore.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                    if viewStore.items.isEmpty { Text(viewStore.isLoading ? "正在同步请求…" : "没有待处理请求") }
                    ForEach(viewStore.items) { item in
                        Section {
                            Text(item.question).font(.headline)
                                .onAppear { viewStore.send(.view(item.id)) }
                            Text(item.statusText).font(.caption).foregroundStyle(.secondary)
                            Text([item.request["issue"]?.stringValue, item.request["source"]?.objectValue?["executor"]?.stringValue].compactMap { $0 }.joined(separator: " · ")).font(.caption)
                            if let impact = item.request["impact"]?.stringValue { Text("范围：" + impact).font(.footnote) }
                            if let consequence = item.request["consequence"]?.stringValue { Text("提交后：" + consequence).font(.footnote) }
                            if let recommendation = item.request["recommendation"]?.stringValue { Text("建议：" + recommendation).font(.footnote) }
                            DisclosureGroup("来源与依据") {
                                if let thread = item.request["source"]?.objectValue?["thread_id"]?.stringValue { Text(thread).font(.caption).textSelection(.enabled) }
                                Text(item.request["context_version"]?.stringValue ?? "版本未知").font(.caption)
                                if let evidence = item.request["evidence"] {
                                    Text(evidence.displayText).font(.caption).textSelection(.enabled)
                                }
                            }
                            if item.state == "pending" && !item.expired {
                                ApprovalInputView(schema: item.schema, value: Binding(
                                    get: { viewStore.drafts[item.id]?.value ?? .null },
                                    set: { viewStore.send(.edit(item.id, $0)) }))
                                .disabled(viewStore.isSubmitting)
                                Button("提交当前请求") { viewStore.send(.submit([item.id], nil)) }
                                    .disabled(viewStore.isSubmitting || viewStore.drafts[item.id] == nil)
                                if item.batchScope != nil {
                                    Toggle("加入范围内批量提交", isOn: Binding(get: { viewStore.selected.contains(item.id) }, set: { viewStore.send(.select(item.id, $0)) }))
                                }
                            }
                        }
                    }
                    if let scope = viewStore.batchScope {
                        Section {
                            Text("本次范围：" + scope).font(.footnote)
                            Button("提交所选 \(viewStore.selected.count) 项") { viewStore.send(.submit(Array(viewStore.selected).sorted(), scope)) }
                                .disabled(viewStore.isSubmitting)
                        }
                    }
                }
                .navigationTitle("待确认")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("关闭") { dismiss() } }
                    ToolbarItem(placement: .topBarTrailing) { Button("刷新") { viewStore.send(.load) }.disabled(viewStore.isLoading) }
                }
                .task { viewStore.send(.load) }
                .onDisappear { viewStore.send(.dismiss) }
            }
        }
    }
}

private struct ApprovalInputView: View {
    let schema: [String: JSONValue]
    @Binding var value: JSONValue
    var body: some View {
        Group {
            switch schema["kind"]?.stringValue {
            case "approve_reject":
                choices(["approve", "reject"], labels: ["approve": "同意本次", "reject": "拒绝本次"], multiple: false)
            case "single", "multi":
                choices(schema["options"]?.arrayValue?.compactMap(\.stringValue) ?? [], labels: [:], multiple: schema["kind"]?.stringValue == "multi")
            case "text":
                TextField("填写回复", text: Binding(get: { value.stringValue ?? "" }, set: { value = .string($0) }), axis: .vertical).lineLimit(2...8)
            case "form":
                ForEach(Array((schema["fields"]?.arrayValue ?? []).enumerated()), id: \.offset) { entry in
                    if let field = entry.element.objectValue, let id = field["id"]?.stringValue {
                        VStack(alignment: .leading) {
                            Text(field["label"]?.stringValue ?? id).font(.subheadline)
                            AnyView(ApprovalInputView(schema: field, value: Binding(
                                get: { value.objectValue?[id] ?? .null },
                                set: { var fields = value.objectValue ?? [:]; fields[id] = $0; value = .object(fields) })))
                        }
                    }
                }
            default: Text("此请求需要在原任务中处理。")
            }
        }
    }
    private func choices(_ options: [String], labels: [String: String], multiple: Bool) -> some View {
        ForEach(options, id: \.self) { option in
            let selected = multiple ? (value.arrayValue?.contains(.string(option)) ?? false) : value.stringValue == option
            Button {
                if multiple {
                    var items = value.arrayValue ?? []
                    if selected { items.removeAll { $0 == .string(option) } } else { items.append(.string(option)) }
                    value = .array(items)
                } else { value = .string(option) }
            } label: {
                Label(labels[option] ?? option, systemImage: selected ? "checkmark.circle.fill" : "circle")
            }.buttonStyle(.plain)
        }
    }
}

private extension JSONValue {
    var displayText: String {
        if let stringValue { return stringValue }
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
