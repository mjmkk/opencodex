import SwiftUI

/// The existing App owns navigation; this view only renders observer projections.
struct GoalOverviewView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var filter: GoalOverviewFilter = .all
    @State private var expanded: Set<String> = []
    let rows: [GoalOverviewRow]
    let hasSnapshot: Bool
    let isRefreshing: Bool
    let failure: String?
    let refresh: () async -> Void

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let columns = Columns(width: max(1, geometry.size.width))
                VStack(spacing: 12) {
                    Picker("筛选目标", selection: $filter) {
                        ForEach(GoalOverviewFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).padding(.horizontal, 12)
                    if hasSnapshot {
                        HStack {
                            Text("\(rows.count) active")
                            Text("\(rows.filter { $0.visibleHealth == .atRisk }.count) at risk")
                            Text("\(rows.filter { $0.visibleHealth == .blocked }.count) blocked")
                        }.font(.caption).foregroundStyle(.secondary)
                        if rows.contains(where: { $0.visibleHealth == nil || $0.availability == .lastKnown }) {
                            Text("待评估 \(rows.filter { $0.visibleHealth == nil }.count) · 上次观察 \(rows.filter { $0.availability == .lastKnown }.count)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    if let failure {
                        Label(failure, systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
                    }
                    ScrollView(.vertical) {
                        VStack(spacing: 0) {
                            header(columns)
                            Divider()
                            if !hasSnapshot {
                                ContentUnavailableView(failure == nil ? "待评估" : "暂不可用", systemImage: "chart.bar.xaxis",
                                    description: Text(isRefreshing ? "正在读取目标观察" : "尚无可用的目标观察"))
                            } else if rows.filter(filter.includes).isEmpty {
                                ContentUnavailableView("没有匹配的目标", systemImage: "line.3.horizontal.decrease")
                            } else {
                                ForEach(rows.filter(filter.includes)) { row in
                                    goal(row, columns: columns, path: row.id, depth: 0)
                                }
                            }
                        }.frame(width: columns.width)
                    }.refreshable { await refresh() }
                }.padding(.top, 8)
            }
            .navigationTitle("Goal Overview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await refresh() } } label: {
                        if isRefreshing { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                    }.disabled(isRefreshing).accessibilityLabel("刷新目标观察")
                }
            }
        }
    }

    private func header(_ c: Columns) -> some View {
        HStack(spacing: 6) {
            Text("Task").frame(width: c.task, alignment: .leading)
            Text("Project").frame(width: c.project, alignment: .leading)
            Text("Progress").frame(width: c.progress, alignment: .leading)
            Text("Health").frame(width: c.health, alignment: .leading)
            Image(systemName: "chevron.down").frame(width: c.expand).accessibilityLabel("Expand")
        }.font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 8)
    }

    private func goal(_ row: GoalOverviewRow, columns c: Columns, path: String, depth: Int) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 3) {
                    if let url = row.issueURL {
                        Link(destination: url) { title(row) }
                    } else { title(row) }
                    if row.availability != .current {
                        Text(availability(row.availability)).font(.caption2).foregroundStyle(.secondary)
                    }
                }.padding(.leading, CGFloat(min(depth, 2)) * 5).frame(width: c.task, alignment: .leading)
                Text(row.project ?? "—").font(.caption2).lineLimit(2).frame(width: c.project, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    if let progress = row.validProgress {
                        Text("\(progress)%").monospacedDigit().font(.caption)
                        ProgressView(value: Double(progress), total: 100).tint(.accentColor)
                    } else { Text("—").accessibilityLabel("进度尚未评估") }
                }.frame(width: c.progress, alignment: .leading)
                HStack(spacing: 3) {
                    if let health = row.visibleHealth {
                        Circle().fill(color(health)).frame(width: 5, height: 5)
                        Text(health.rawValue).font(.caption2).lineLimit(2)
                    } else { Text("—").accessibilityLabel("健康状态尚未评估") }
                }.frame(width: c.health, alignment: .leading)
                Button {
                    if !expanded.insert(path).inserted { expanded.remove(path) }
                } label: {
                    Image(systemName: expanded.contains(path) ? "chevron.up" : "chevron.down")
                        .frame(width: c.expand, height: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("\(expanded.contains(path) ? "收起" : "展开") \(row.title)")
            }.padding(.horizontal, 8).padding(.vertical, 6)
            if expanded.contains(path) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(row.title).font(.subheadline)
                    if let reason = row.explanation { Text(reasonText(reason)).font(.caption) }
                    timestamp("资料覆盖", row.coverageAt)
                    timestamp("判断时间", row.evaluatedAt)
                    if !row.sourceNotes.isEmpty {
                        DisclosureGroup("资料来源与覆盖") {
                            ForEach(Array(row.sourceNotes.enumerated()), id: \.offset) { _, note in
                                Text(note).font(.caption2).textSelection(.enabled)
                            }
                        }.font(.caption)
                    }
                }.foregroundStyle(.secondary).padding(12)
                if !row.obligations.isEmpty {
                    Text("Closure obligations").font(.caption.bold()).padding(.horizontal, 12)
                    ForEach(row.obligations) { obligation in
                        goal(obligation, columns: c, path: path + "/" + obligation.id, depth: depth + 1)
                    }
                }
                if !row.workers.isEmpty {
                    DisclosureGroup("Workers") {
                        ForEach(row.workers) { worker in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(worker.title)
                                Text([worker.host, worker.state].compactMap { $0 }.joined(separator: " · "))
                                    .foregroundStyle(.secondary)
                                timestamp("Worker 观察时间", worker.observedAt)
                            }.font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                        }
                    }.font(.caption).padding(12)
                }
            }
            Divider()
        })
    }

    private func title(_ row: GoalOverviewRow) -> some View {
        Text([row.issueIdentifier, row.title].compactMap { $0 }.joined(separator: " · "))
            .font(.caption).lineLimit(2).truncationMode(.tail)
    }

    private func timestamp(_ label: String, _ date: Date?) -> some View {
        HStack(spacing: 4) {
            Text(label + "：")
            if let date { Text(date, format: .dateTime.year().month().day().hour().minute()) }
            else { Text("未知") }
        }.font(.caption2)
    }

    private func availability(_ value: ObservationAvailability) -> String {
        switch value {
        case .current: return ""
        case .pending: return "待评估"
        case .lastKnown: return "上次观察"
        case .failed: return "刷新失败"
        }
    }

    private func reasonText(_ reason: String) -> String {
        switch reason {
        case "not_evaluated", "observation_absent": return "尚未完成评估"
        case "evaluating": return "新判断正在生成，当前保留上次观察"
        case "evaluation_expired": return "上次判断已过期，等待重新评估"
        case "goal_changed", "input_changed": return "目标或资料已有变化，等待重新评估"
        default: return "本次观察暂不可用，等待更新"
        }
    }

    private func color(_ health: GoalHealth) -> Color {
        switch health { case .onTrack: return .green; case .atRisk: return .orange; case .blocked: return .red }
    }

    private struct Columns {
        let width: CGFloat
        var project: CGFloat { width < 380 ? width * 0.12 : 56 }
        var progress: CGFloat { width < 380 ? width * 0.18 : 76 }
        var health: CGFloat { width < 380 ? width * 0.15 : 60 }
        var expand: CGFloat { width < 380 ? width * 0.075 : 30 }
        var task: CGFloat { max(0, width - 40 - project - progress - health - expand) }
    }
}
