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
            VStack(alignment: .leading, spacing: 6) {
                Label(context.attributes.title, systemImage: "pin.fill").font(.headline).lineLimit(1)
                Text(context.isStale ? "等待同步 · 打开查看最新内容" : context.state.summary)
                Text(context.state.updatedAt, style: .time).font(.caption).foregroundStyle(.secondary)
            }.padding().widgetURL(URL(string: "opencodex://thread/\(context.attributes.threadId)"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Image(systemName: "pin.fill") }
                DynamicIslandExpandedRegion(.center) { Text(context.attributes.title).lineLimit(1) }
                DynamicIslandExpandedRegion(.bottom) { Text(context.isStale ? "等待同步" : context.state.summary) }
            } compactLeading: { Image(systemName: "pin.fill")
            } compactTrailing: { Text(context.isStale ? "待同步" : "Codex")
            } minimal: { Image(systemName: "pin.fill") }
            .widgetURL(URL(string: "opencodex://thread/\(context.attributes.threadId)"))
        }
    }
}
