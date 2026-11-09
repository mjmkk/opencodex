import SwiftUI

/// AGT-26 S6：线程页底部的“等你处理”卡片（参考 Happy 的内联审批：卡片贴着输入框，选中的选项保持高亮，提交后保留结果）。
/// 能在手机上回答的（服务端标了 response_available）直接选、确认、发送；回答不了的只说明去哪台机器处理，不假装能点。
/// 发送沿用原来的 NativeRequestSubmission：发前再读一次，内容变了就不发；写之前先落盘，重启后不会重发。
struct InlineRequestCard: View {
    @State var item: NativeRemoteRequest
    let hostLabel: String
    var onFinished: () -> Void = {}

    @State private var answers: [String: String] = [:]
    @State private var busy = false
    @State private var submitted = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(item.title, systemImage: "hand.raised.fill")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
            if let detail { Text(detail).font(.callout.monospaced()).lineLimit(6) }
            if submitted || item.response_submitted {
                Label("已发送，等待对方继续", systemImage: "checkmark.circle.fill")
                    .font(.footnote).foregroundStyle(.green)
            } else if item.canSubmitResponse && item.method == "item/tool/requestUserInput" {
                questions
            } else {
                Text("手机上暂时不能处理这类请求，请到 \(hostLabel) 上确认。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.orange.opacity(0.35)))
        .task { await restore() }
    }

    /// 命令、原因或问题文本，只取一个最能说明情况的
    private var detail: String? {
        let p = item.params
        if let command = p["command"]?.stringValue ?? p["command"]?.arrayValue?.compactMap(\.stringValue).joined(separator: " ") {
            return command
        }
        return p["reason"]?.stringValue ?? p["message"]?.stringValue
    }

    private var questionList: [[String: JSONValue]] {
        item.params["questions"]?.arrayValue?.compactMap(\.objectValue) ?? []
    }

    @ViewBuilder private var questions: some View {
        ForEach(Array(questionList.enumerated()), id: \.offset) { _, q in
            if let id = q["id"]?.stringValue {
                VStack(alignment: .leading, spacing: 6) {
                    Text(q["question"]?.stringValue ?? id).font(.callout)
                    let options = (q["options"]?.arrayValue ?? []).compactMap { $0.objectValue?["label"]?.stringValue }
                    ForEach(options, id: \.self) { label in
                        Button { answers[id] = label } label: {
                            Label(label, systemImage: answers[id] == label ? "checkmark.circle.fill" : "circle")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered).tint(answers[id] == label ? .accentColor : .secondary)
                    }
                    if q["isSecret"]?.boolValue == true {
                        SecureField("你的回答", text: binding(id)).textFieldStyle(.roundedBorder)
                    } else if options.isEmpty {
                        TextField("你的回答", text: binding(id), axis: .vertical).textFieldStyle(.roundedBorder)
                    }
                }
            }
        }
        Button {
            Task { await submit() }
        } label: {
            if busy { ProgressView().frame(maxWidth: .infinity) } else { Text("发送").frame(maxWidth: .infinity) }
        }
        .buttonStyle(.borderedProminent)
        .disabled(busy || !allAnswered)
    }

    private var allAnswered: Bool {
        !questionList.isEmpty && questionList.allSatisfy { q in
            q["id"]?.stringValue.flatMap { answers[$0] }.map { !$0.isEmpty } ?? false
        }
    }

    private func binding(_ id: String) -> Binding<String> {
        Binding(get: { answers[id] ?? "" }, set: { answers[id] = $0 })
    }

    // MARK: - 草稿和发送

    private var draft: NativeRequestDraft {
        .init(requestVersion: item.request_version, confirmationContext: item.confirmationContext,
              answers: answers, attemptedResponse: submitted ? .bool(true) : nil, responseSubmitted: submitted)
    }

    /// 同一个请求、同一版本才恢复草稿；上次已经发出去（或发送结果不明）就不再给发送按钮
    @MainActor private func restore() async {
        guard let scope = try? MobileSyncEngine.scope(),
              let saved = try? await MobileSyncCache.shared?.nativeDraft(id: item.id, scope: scope),
              saved.confirmationContext == item.confirmationContext else { return }
        answers = saved.answers
        submitted = saved.attemptedResponse != nil || saved.responseSubmitted
    }

    @MainActor private func submit() async {
        guard allAnswered, !busy, !submitted else { return }
        busy = true; error = nil
        defer { busy = false }
        let result = JSONValue.object(["answers": .object(answers.mapValues { .object(["answers": .array([.string($0)])]) })])
        var writeStarted = false
        do {
            let scope = try MobileSyncEngine.scope()
            guard let cache = MobileSyncCache.shared else { throw CodexError.invalidState }
            let receipt = try await NativeRequestSubmission.send(reviewed: item, result: result,
                read: { try await APIClient.live.readNativeRequest($0) },
                beforeWrite: { current, _ in
                    item = current; submitted = true
                    // 写之前先记下“已尝试”，App 重启后不会再发一次
                    try await cache.saveNativeDraft(draft, id: current.id, scope: scope)
                    writeStarted = true
                },
                respond: { try await APIClient.live.respondNativeRequest($0) })
            item = receipt
            try? await cache.saveNativeRequest(receipt, scope: scope)
            onFinished()
        } catch NativeRequestConfirmationError.changed(let current) {
            item = current; submitted = false
            error = "请求内容已经变了，这次没有发送。请重新选择。"
        } catch {
            if writeStarted {
                self.error = "发送结果还没确认，稍后下拉刷新核对，不会自动重发。"
            } else {
                submitted = false
                self.error = "发送前核对失败，这次没有发送。"
            }
        }
    }
}
