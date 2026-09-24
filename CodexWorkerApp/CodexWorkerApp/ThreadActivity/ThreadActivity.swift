import ActivityKit
import CodexActivityModels
import SwiftUI
import WidgetKit

@main
struct ThreadActivityBundle: WidgetBundle {
    var body: some Widget { PinnedThreadWidget() }
}

struct PinnedThreadWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PinnedThreadAttributes.self) { context in
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol(context))
                    .font(.title2).foregroundStyle(tint(context))
                    .frame(width: 36, height: 44)
                VStack(alignment: .leading, spacing: 6) {
                    Text(status(context)).font(.headline)
                    Text(context.attributes.title).font(.subheadline).lineLimit(2).privacySensitive()
                    HStack(spacing: 4) {
                        Text(context.isStale ? "内容可能已变化" : "更新于")
                        if !context.isStale { Text(context.state.updatedAt, style: .time) }
                        Spacer()
                        Text(actionTitle(context)).fontWeight(.medium)
                    }.font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .activityBackgroundTint(Color(uiColor: .secondarySystemBackground))
            .widgetURL(destination(context))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("OpenCodex", systemImage: symbol(context))
                        .font(.caption.weight(.semibold)).foregroundStyle(tint(context))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(status(context)).font(.headline).foregroundStyle(tint(context))
                        Text(context.attributes.title).font(.subheadline).lineLimit(2).privacySensitive()
                        HStack {
                            Text(context.isStale ? "打开同步最新状态" : actionTitle(context))
                            Spacer()
                            Image(systemName: "arrow.up.right")
                        }.font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                }
            } compactLeading: {
                Image(systemName: symbol(context)).foregroundStyle(tint(context)).accessibilityLabel(status(context))
            } compactTrailing: {
                Text(compactStatus(context)).font(.caption.weight(.semibold)).foregroundStyle(tint(context))
            } minimal: {
                Image(systemName: symbol(context)).foregroundStyle(tint(context)).accessibilityLabel(status(context))
            }
            .widgetURL(destination(context))
            .keylineTint(tint(context))
        }
    }

    private func status(_ context: ActivityViewContext<PinnedThreadAttributes>) -> String {
        context.isStale ? "等待同步" : context.state.summary
    }
    private func compactStatus(_ context: ActivityViewContext<PinnedThreadAttributes>) -> String {
        if context.isStale { return "待同步" }
        switch context.state.executionState {
        case "WAITING_APPROVAL", "WAITING_USER": return "待处理"
        case "RESPONSE_SUBMITTED": return "已提交"
        case "REQUEST_RESOLVED": return "已结束"
        case "REQUEST_UNAVAILABLE": return "待核对"
        case "PINNED": return "已固定"
        case "RUNNING": return "进行中"
        case "QUEUED": return "排队中"
        case "DONE": return "已完成"
        case "FAILED": return "失败"
        case "CANCELLED": return "已停止"
        default: return "待更新"
        }
    }
    private func symbol(_ context: ActivityViewContext<PinnedThreadAttributes>) -> String {
        if context.isStale { return "arrow.clockwise" }
        switch context.state.executionState {
        case "WAITING_APPROVAL", "WAITING_USER": return "hand.raised.fill"
        case "RESPONSE_SUBMITTED": return "arrow.up.circle.fill"
        case "REQUEST_RESOLVED": return "checkmark.message"
        case "REQUEST_UNAVAILABLE": return "questionmark.circle"
        case "RUNNING": return "ellipsis"
        case "QUEUED": return "clock"
        case "DONE": return "checkmark.circle"
        case "FAILED": return "exclamationmark.circle"
        case "CANCELLED": return "stop.circle"
        default: return "pin.fill"
        }
    }
    private func tint(_ context: ActivityViewContext<PinnedThreadAttributes>) -> Color {
        if context.isStale { return .secondary }
        switch context.state.executionState {
        case "WAITING_APPROVAL", "WAITING_USER": return .orange
        case "RESPONSE_SUBMITTED", "REQUEST_RESOLVED": return .cyan
        case "FAILED": return .red
        case "DONE": return .green
        default: return .accentColor
        }
    }
    private func actionTitle(_ context: ActivityViewContext<PinnedThreadAttributes>) -> String {
        if context.isStale { return "打开核对" }
        return context.state.requestURL == nil ? "查看原任务" : "查看这次请求"
    }
    private func destination(_ context: ActivityViewContext<PinnedThreadAttributes>) -> URL? {
        if let raw = context.state.requestURL, let url = URL(string: raw),
           url.scheme == "opencodex", url.host == "native-request" { return url }
        let encoded = context.attributes.threadId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? ""
        return URL(string: "opencodex://thread/\(encoded)")
    }
}
