import SwiftUI

/// AGT-26 S6：Node 观测到线程在等 Human（Claude Code 的 PermissionRequest / Notification，或 Codex 的钩子事件）时，
/// 在输入框上方说明它在等什么。Claude Code 的权限审批只能在原会话里点，手机上不给假按钮；
/// 如果它等的是一句话，直接用下面的输入框回复即可。
struct WaitingCard: View {
    let waiting: HarnessMember.Waiting
    let hostLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(waiting.isPermission ? "在等你批准" + (waiting.tool.map { "：" + $0 } ?? "") : "在等你回复",
                  systemImage: "hand.raised.fill")
                .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.needsYou)
            if !waiting.summary.isEmpty {
                Text(waiting.summary).font(.callout.monospaced()).lineLimit(4)
            }
            Text(waiting.isPermission
                 ? "这类审批要在 \(hostLabel) 上的原会话里点。"
                 : "直接在下面回复就行。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.needsYou.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.needsYou.opacity(0.35)))
        .accessibilityElement(children: .combine)
    }
}
