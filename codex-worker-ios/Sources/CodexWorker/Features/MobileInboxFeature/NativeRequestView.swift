import ComposableArchitecture
import SwiftUI

struct NativeRequestsSection: View {
    let refreshing: Int
    var onOpenThread: ((String) -> Void)?
    @State private var records: [NativeRequestRecord] = []
    @State private var currentIDs: Set<String> = []
    @State private var error: String?
    @State private var loaded = false
    var body: some View {
        Section("原生请求") {
            if let error {
                Text("原生请求暂不可用，已保留上次查看内容。请稍后刷新。").font(.footnote).foregroundStyle(.secondary)
                DisclosureGroup("诊断信息") { Text(error).font(.caption).textSelection(.enabled) }
            }
            if currentIDs.isEmpty {
                Text(!loaded ? "正在核对原生请求…" : (error == nil ? "当前没有可读取的原生待处理请求" : "暂时无法确认当前待处理请求")).foregroundStyle(.secondary)
            }
            ForEach(records.filter { currentIDs.contains($0.id) }) { record in row(record, current: true) }
        }
        .task(id: refreshing) {
            do {
                let scope = try MobileSyncEngine.scope()
                if let cache = MobileSyncCache.shared { records = try await cache.nativeRequests(scope: scope) }
                currentIDs = []; loaded = false
                let response = try await APIClient.live.nativeRequests()
                guard try MobileSyncEngine.scope() == scope else { return }
                for item in response.data {
                    try await MobileSyncCache.shared?.saveNativeRequest(item, scope: scope)
                    records.removeAll { $0.id == item.id }
                    records.insert(.init(item: item, observedAt: Date()), at: 0)
                }
                currentIDs = Set(response.data.map(\.id)); loaded = true; error = nil
                await MobileLifecycle.updateNativeRequests(response.data)
            } catch { self.error = error.localizedDescription; loaded = true }
        }
        if records.contains(where: { !currentIDs.contains($0.id) }) {
            Section("最近查看的请求") {
                ForEach(records.filter { !currentIDs.contains($0.id) }) { record in row(record, current: false) }
            }
        }
    }
    private func row(_ record: NativeRequestRecord, current: Bool) -> some View {
        NavigationLink {
            NativeRequestView(item: record.item, onOpenThread: onOpenThread)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(record.item.issue ?? "原任务").font(.caption).foregroundStyle(.secondary)
                Text(record.item.title).lineLimit(3)
                Text(current ? record.item.statusText : "上次查看 · " + MobileTime.timestamp(record.observedAt))
                    .font(.caption).foregroundStyle(.secondary)
                if !current { Text("打开后核对当前状态").font(.caption2).foregroundStyle(.secondary) }
            }.padding(.vertical, 6)
        }
        .accessibilityIdentifier("native-request-" + record.id)
    }
}

struct NativeRequestView: View {
    @State var item: NativeRemoteRequest
    var onOpenThread: ((String) -> Void)?
    @State private var content: [String: JSONValue] = [:]
    @State private var answers: [String: String] = [:]
    @State private var proposed: JSONValue?
    @State private var sent: JSONValue?
    @State private var attempted = false
    @State private var busy = false
    @State private var fresh = false
    @State private var restored = false
    @State private var accountScope: String?
    @State private var error: String?
    private var containsSecretAnswer: Bool {
        (item.params["questions"]?.arrayValue ?? []).contains { $0.objectValue?["isSecret"]?.boolValue == true }
    }
    private func responseText(_ value: JSONValue) -> String {
        containsSecretAnswer ? "包含隐藏回答；完整回复仅发送给原请求。" : value.nativeJSON
    }
    private var canRespond: Bool { restored && fresh && item.canSubmitResponse && !attempted && !busy }

    var body: some View {
        Form {
            Section {
                Text(item.issue ?? "原任务").font(.caption).foregroundStyle(.secondary)
                Text(item.title).font(.headline).textSelection(.enabled)
                Text(fresh ? item.statusText : "正在核对原请求，缓存不能用于提交")
                if let observation = item.observation { Text(observation).font(.footnote).foregroundStyle(.secondary) }
                if item.native_resolution == nil && item.native_terminal == nil && !item.response_submitted && !attempted {
                if let message = item.params["message"]?.stringValue ?? item.params["reason"]?.stringValue {
                    Text(message).textSelection(.enabled)
                }
                forContext("command", title: "命令")
                forContext("cwd", title: "位置")
                forContext("networkApprovalContext", title: "网络访问范围")
                forContext("grantRoot", title: "文件授权范围")
                forContext("permissions", title: "请求的权限")
                }
            }
            if item.native_resolution == nil && item.native_terminal == nil && !item.response_submitted && !attempted {
                responseControls.disabled(!canRespond)
            }
            if let proposed, canRespond {
                Section("核对你的选择") {
                    Text(responseText(proposed)).font(.footnote.monospaced()).textSelection(.enabled)
                    Button("确认发送这次选择") { Task { await submit(proposed) } }
                        .buttonStyle(.borderedProminent)
                }
            }
            if attempted || item.response_submitted || item.native_resolution != nil || item.native_terminal != nil {
                Section("实际回执") {
                    if let sent { Text(responseText(sent)).font(.footnote.monospaced()).textSelection(.enabled) }
                    Text(item.response_submitted ? "已收到响应提交回执" : "响应提交结果尚未确认")
                    Text(item.native_resolution != nil ? "已收到原生 request resolved" : "尚未收到原生 request resolved")
                    if let terminal = item.native_terminal { Text("原轮次：" + terminal.nativeJSON).font(.footnote) }
                    else { Text("原轮次后续尚待核对").font(.footnote) }
                    if attempted && fresh && item.canSubmitResponse {
                        Button("已核对尚未提交，重新选择") {
                            attempted = false; sent = nil; proposed = nil
                            Task { await persistDraft() }
                        }.disabled(busy)
                    }
                    Text("请求结束也可能来自清理；请结合原任务后续判断执行结果。").font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
            Section {
                Button("回到原任务") { onOpenThread?(item.thread_id) }
                DisclosureGroup("完整原生请求") {
                    Text(JSONValue.object(item.request ?? [:]).nativeJSON).font(.footnote.monospaced()).textSelection(.enabled)
                    Text("Thread: " + item.thread_id).textSelection(.enabled)
                    Text("Turn: " + (item.turn_id ?? "未提供")).textSelection(.enabled)
                }
            }
        }
        .navigationTitle("原生请求").navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("刷新") { Task { await refresh() } }.disabled(busy) }
        .onChange(of: content) { _, _ in Task { await persistDraft() } }
        .onChange(of: answers) { _, _ in Task { await persistDraft() } }
        .onChange(of: proposed) { _, _ in Task { await persistDraft() } }
        .task {
            await restoreDraft()
            await refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                if attempted || item.response_submitted { await refresh() }
            }
        }
    }

    @ViewBuilder private func forContext(_ key: String, title: String) -> some View {
        if let value = item.params[key], value != .null {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value.stringValue ?? value.nativeJSON).font(.footnote).textSelection(.enabled)
            }
        }
    }

    @ViewBuilder private var responseControls: some View {
        switch item.method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            Section("原生选项") {
                ForEach(Array(item.decisions.enumerated()), id: \.offset) { _, decision in
                    Button { proposed = .object(["decision": decision]) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(NativeRemoteRequest.decisionLabel(decision))
                            Text(decision.nativeJSON).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        case "mcpServer/elicitation/request":
            let schema = item.params["requestedSchema"]?.objectValue ?? [:]
            let mode = item.params["mode"]?.stringValue
            Section("需要你填写") {
                if NativeForm.supported(schema) && ["form", "openai/form", "openaiForm"].contains(mode ?? "") {
                    ForEach((schema["properties"]?.objectValue ?? [:]).keys.sorted(), id: \.self) { key in
                        NativeSchemaField(name: key, schema: schema["properties"]?.objectValue?[key]?.objectValue ?? [:],
                                          value: Binding(get: { content[key] }, set: { content[key] = $0; proposed = nil }))
                    }
                    Button("提交填写内容") { proposed = .object(["action": .string("accept"), "content": .object(content)]) }
                        .disabled(!NativeForm.valid(schema, content: content))
                } else if mode == "url", let text = item.params["url"]?.stringValue, let url = URL(string: text), ["https", "http"].contains(url.scheme ?? "") {
                    Link("打开请求中的网页", destination: url)
                    Button("我已完成网页操作") { proposed = .object(["action": .string("accept"), "content": .null]) }
                } else {
                    Text("此表单包含当前手机版尚不支持的字段，请在原生客户端填写。")
                }
                Button("拒绝填写") { proposed = .object(["action": .string("decline"), "content": .null]) }
                Button("取消此次询问") { proposed = .object(["action": .string("cancel"), "content": .null]) }
            }
        case "item/tool/requestUserInput":
            let questions = item.params["questions"]?.arrayValue?.compactMap(\.objectValue) ?? []
            Section("原生问题") {
                ForEach(Array(questions.enumerated()), id: \.offset) { _, question in
                    if let id = question["id"]?.stringValue {
                        Text(question["question"]?.stringValue ?? id)
                        ForEach(Array((question["options"]?.arrayValue ?? []).enumerated()), id: \.offset) { _, option in
                            if let label = option.objectValue?["label"]?.stringValue {
                                Button { answers[id] = label; proposed = nil } label: {
                                    VStack(alignment: .leading) {
                                        Label(label, systemImage: answers[id] == label ? "checkmark.circle.fill" : "circle")
                                        if let detail = option.objectValue?["description"]?.stringValue { Text(detail).font(.caption) }
                                    }
                                }
                            }
                        }
                        if question["isSecret"]?.boolValue == true {
                            SecureField("你的回答", text: answerBinding(id))
                        } else { TextField("你的回答", text: answerBinding(id), axis: .vertical) }
                    }
                }
                Button("提交这些回答") {
                    proposed = .object(["answers": .object(answers.mapValues { .object(["answers": .array([.string($0)])]) })])
                }.disabled(questions.isEmpty || !questions.allSatisfy { q in q["id"]?.stringValue.flatMap { answers[$0] }.map { !$0.isEmpty } ?? false })
            }
        case "item/permissions/requestApproval":
            if let permissions = item.params["permissions"] {
                Section("权限范围") {
                    Button("仅本轮授予上述权限") { proposed = .object(["permissions": permissions, "scope": .string("turn")]) }
                    Button("本会话授予上述权限") { proposed = .object(["permissions": permissions, "scope": .string("session")]) }
                    Button("不授予权限") { proposed = .object(["permissions": .object([:]), "scope": .string("turn")]) }
                }
            }
        default: Section { Text("此原生方法尚无手机编辑器，请在原生客户端处理。") }
        }
    }
    private func answerBinding(_ id: String) -> Binding<String> {
        Binding(get: { answers[id] ?? "" }, set: { answers[id] = $0; proposed = nil })
    }
    private var draft: NativeRequestDraft {
        .init(requestVersion: item.request_version, confirmationContext: item.confirmationContext, content: content, answers: answers,
              proposed: proposed, attemptedResponse: sent, responseSubmitted: item.response_submitted)
    }
    @MainActor private func restoreDraft() async {
        do {
            let scope = try MobileSyncEngine.scope()
            guard let cache = MobileSyncCache.shared else { throw CodexError.invalidState }
            if let saved = try await cache.nativeDraft(id: item.id, scope: scope) {
                if saved.confirmationContext == item.confirmationContext {
                    content = saved.content; answers = saved.answers; proposed = saved.proposed
                }
                sent = saved.attemptedResponse; attempted = sent != nil
                item.response_submitted = item.response_submitted || saved.responseSubmitted
            }
            accountScope = scope; restored = true
        } catch { self.error = "本地草稿暂不可用，未启用提交。" + error.localizedDescription }
    }
    @MainActor private func persistDraft() async {
        guard restored, let scope = accountScope, (try? MobileSyncEngine.scope()) == scope else { return }
        do { try await MobileSyncCache.shared?.saveNativeDraft(draft, id: item.id, scope: scope) }
        catch { self.error = "草稿暂未保存。" + error.localizedDescription }
    }
    @MainActor private func refresh() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            guard let scope = accountScope, try MobileSyncEngine.scope() == scope else { throw CodexError.invalidState }
            var current = try await APIClient.live.readNativeRequest(item.selection)
            guard try MobileSyncEngine.scope() == scope, current.matchesDestination(of: item) else {
                clearProposal(); throw CodexError.invalidState
            }
            if current.confirmationContext != item.confirmationContext || !current.canSubmitResponse { clearProposal() }
            // Preserve the acknowledged write fact after pending leaves the owner.
            current.response_submitted = current.response_submitted || item.response_submitted
            item = current; fresh = true; error = nil
            try await MobileSyncCache.shared?.saveNativeRequest(current, scope: scope)
            await persistDraft()
            await MobileLifecycle.updateNativeRequest(current)
        } catch { fresh = false; self.error = error.localizedDescription }
    }
    @MainActor private func clearProposal() {
        proposed = nil; content = [:]; answers = [:]
    }
    @MainActor private func submit(_ result: JSONValue) async {
        guard canRespond, proposed == result else { return }
        let reviewed = item
        busy = true; fresh = false; error = nil
        var writeStarted = false
        defer { busy = false }
        do {
            guard let scope = accountScope, try MobileSyncEngine.scope() == scope,
                  let cache = MobileSyncCache.shared else { throw CodexError.invalidState }
            let receipt = try await NativeRequestSubmission.send(reviewed: reviewed, result: result,
                read: { try await APIClient.live.readNativeRequest($0) },
                beforeWrite: { current, response in
                    guard try MobileSyncEngine.scope() == scope else { throw CodexError.invalidState }
                    item = current; attempted = true; sent = response
                    // Persist before the one write so a restart cannot resend an unknown response.
                    try await cache.saveNativeDraft(draft, id: item.id, scope: scope)
                    guard try MobileSyncEngine.scope() == scope else { throw CodexError.invalidState }
                    writeStarted = true
                }, respond: { try await APIClient.live.respondNativeRequest($0) })
            guard try MobileSyncEngine.scope() == scope, receipt.matchesDestination(of: reviewed) else { throw CodexError.invalidState }
            item = receipt; fresh = true
            try await cache.saveNativeRequest(receipt, scope: scope)
            await persistDraft()
            await MobileLifecycle.updateNativeRequest(receipt)
        } catch NativeRequestConfirmationError.changed(let current) {
            clearProposal()
            if let scope = accountScope, (try? MobileSyncEngine.scope()) == scope,
               current.matchesDestination(of: reviewed) {
                item = current; fresh = true
                try? await MobileSyncCache.shared?.saveNativeRequest(current, scope: scope)
                await persistDraft()
            }
            error = "原请求内容、位置或状态已变化，本次未提交。请核对后重新选择。"
        } catch {
            if writeStarted {
                self.error = "提交结果尚未确认，请刷新核对；不会自动重试。" + error.localizedDescription
            } else {
                attempted = false; sent = nil; fresh = false; clearProposal()
                await persistDraft()
                self.error = "发送前核对失败，本次未提交。请刷新后重试。" + error.localizedDescription
            }
        }
    }
}

private struct NativeSchemaField: View {
    let name: String
    let schema: [String: JSONValue]
    @Binding var value: JSONValue?
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(schema["title"]?.stringValue ?? name)
            if let detail = schema["description"]?.stringValue { Text(detail).font(.caption).foregroundStyle(.secondary) }
            let multiple = schema["type"]?.stringValue == "array"
            let options = NativeForm.options(multiple ? schema["items"]?.objectValue ?? [:] : schema)
            if !options.isEmpty {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    let selected = multiple ? value?.arrayValue?.contains(.string(option.0)) == true : value?.stringValue == option.0
                    Button {
                        if multiple {
                            var values = value?.arrayValue ?? []
                            if selected { values.removeAll { $0 == .string(option.0) } } else { values.append(.string(option.0)) }
                            value = .array(values)
                        } else { value = .string(option.0) }
                    } label: { Label(option.1, systemImage: selected ? "checkmark.circle.fill" : "circle") }
                }
            } else if schema["type"]?.stringValue == "boolean" {
                HStack {
                    Button { value = .bool(true) } label: { Label("是", systemImage: value?.boolValue == true ? "checkmark.circle.fill" : "circle") }
                    Button { value = .bool(false) } label: { Label("否", systemImage: value?.boolValue == false ? "checkmark.circle.fill" : "circle") }
                }
            } else {
                TextField("填写" + name, text: Binding(get: {
                    value?.stringValue ?? value.map { $0.nativeJSON } ?? ""
                }, set: { text in
                    switch schema["type"]?.stringValue {
                    case "integer": value = Int(text).map(JSONValue.int)
                    case "number": value = Double(text).map(JSONValue.double)
                    default: value = .string(text)
                    }
                }), axis: .vertical)
            }
        }.padding(.vertical, 4)
    }
}
