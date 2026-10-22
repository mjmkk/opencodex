import SwiftUI

/// Renders observer projections without deriving scores from task activity.
struct GoalOverviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var filter: GoalOverviewFilter = .all
    @State private var expanded: Set<String> = []
    @State private var sourceURL: URL?
    let rows: [GoalOverviewRow]
    let inventoryValidation: GoalInventoryValidation
    let hasSnapshot: Bool
    let isRefreshing: Bool
    let failure: String?
    let refresh: () async -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    overviewHeader
                    Divider()
                    if !hasSnapshot {
                        ContentUnavailableView {
                            Label(isRefreshing ? "正在读取目标观察" : "目标观察暂不可用", systemImage: "chart.bar.xaxis")
                        } description: {
                            Text(isRefreshing ? "读取完成后显示真实观察与判断时间。" : "尚无可用的目标观察。")
                        } actions: {
                            if isRefreshing { ProgressView() }
                            else { Button("重新读取") { Task { await refresh() } }.frame(minHeight: 44) }
                        }
                    } else if rows.filter(filter.includes).isEmpty {
                        ContentUnavailableView("没有匹配的目标", systemImage: "line.3.horizontal.decrease")
                    } else {
                        ForEach(rows.filter(filter.includes)) { row in
                            goal(row, path: row.id, depth: 0)
                        }
                    }
                }
            }
            .background(Color(uiColor: .systemBackground))
            .refreshable { await refresh() }
            .navigationTitle("目标总览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }.frame(minWidth: 44, minHeight: 44)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await refresh() } } label: {
                        Group {
                            if isRefreshing { ProgressView() }
                            else { Image(systemName: "arrow.clockwise") }
                        }.frame(minWidth: 44, minHeight: 44)
                    }
                    .disabled(isRefreshing)
                    .accessibilityLabel("刷新目标观察")
                }
            }
            .background(OverviewSourcePresenter(url: sourceURL) { sourceURL = nil })
        }
    }

    private var overviewHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 4) { filterButtons }
            } else {
                HStack(spacing: 4) { filterButtons }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(inventoryValidation.title).font(.footnote.weight(.semibold))
                if let verifiedAt = inventoryValidation.verifiedAt { timestamp("列表核对", verifiedAt) }
                Text("列表核对不代表评分已更新。")
                    .font(.footnote).foregroundStyle(.secondary)
                if hasSnapshot {
                    Text("待评估 \(rows.filter { $0.hasPendingAssessment }.count) · 含上次观察 \(rows.filter { $0.hasLastKnownAssessment }.count)")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let failure {
                Label(failure, systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.footnote).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(16)
    }

    private var filterButtons: some View {
        ForEach(GoalOverviewFilter.allCases, id: \.self) { value in
            Button { filter = value } label: {
                Text(filterTitle(value) + (hasSnapshot ? " \(rows.filter(value.includes).count)" : ""))
                    .font(.subheadline.weight(filter == value ? .semibold : .regular))
                    .foregroundStyle(filter == value ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .padding(.horizontal, 4)
                    .background(filter == value ? Color(uiColor: .tertiarySystemFill) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(filter == value ? .isSelected : [])
        }
    }

    private func goal(_ row: GoalOverviewRow, path: String, depth: Int) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 0) {
            Button {
                if !expanded.insert(path).inserted { expanded.remove(path) }
            } label: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        Text(row.title)
                            .font(.body.weight(.semibold)).foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: expanded.contains(path) ? "chevron.up" : "chevron.down")
                            .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.top, 4).accessibilityHidden(true)
                    }
                    let metadata = [row.issueIdentifier, row.project].compactMap { $0 }.joined(separator: " · ")
                    if !metadata.isEmpty {
                        Text(metadata).font(.footnote).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 12) { dimensions(row) }
                    } else {
                        HStack(alignment: .top, spacing: 16) { dimensions(row) }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityValue(expanded.contains(path) ? "已展开" : "已收起")
            .accessibilityHint("轻点\(expanded.contains(path) ? "收起" : "展开")判断、来源与承接事项")
            if expanded.contains(path) {
                VStack(alignment: .leading, spacing: 16) {
                    if let url = row.issueURL { sourceAction("打开 Issue", url: url) }
                    if let description = row.closureScopeDescription {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("承接范围").font(.subheadline.weight(.semibold))
                            Text(description).font(.subheadline).textSelection(.enabled)
                            if let url = row.closureScopeSourceURL { sourceAction("查看范围依据", url: url) }
                        }
                    }
                    if let progress = row.progressDimension, let health = row.healthDimension {
                        dimensionDetails("进度判断", progress)
                        dimensionDetails("健康判断", health)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            if let reason = row.explanation { Text(reasonText(reason)).font(.subheadline) }
                            timestamp("资料覆盖", row.coverageAt)
                            timestamp("判断时间", row.evaluatedAt)
                            sourceNotes(row.sourceNotes)
                        }
                    }
                    if row.workerAssociation != nil || !row.workers.isEmpty { workerDetails(row) }
                }.padding(.horizontal, 16).padding(.bottom, 16)
                if !row.obligations.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Label("承接事项 · \(row.obligations.count)", systemImage: "arrow.turn.down.right")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16).padding(.vertical, 12)
                        ForEach(row.obligations) { obligation in
                            goal(obligation, path: path + "/" + obligation.id, depth: depth + 1)
                        }
                    }
                    .padding(.leading, depth < 2 ? 12 : 0)
                    .background(Color(uiColor: .secondarySystemBackground))
                }
            }
            Divider().padding(.horizontal, 16)
        })
    }

    @ViewBuilder private func dimensions(_ row: GoalOverviewRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("进度").font(.footnote).foregroundStyle(.secondary)
            if let progress = row.validProgress {
                Text("\(progress)%").font(.subheadline.weight(.semibold)).monospacedDigit()
                ProgressView(value: Double(progress), total: 100).tint(.primary).accessibilityHidden(true)
            } else if row.progressNotApplicable {
                Text("无有限完成范围").font(.subheadline.weight(.semibold))
            } else { Text("尚无评分").font(.subheadline.weight(.semibold)) }
            dimensionStatus(row.progressAvailability)
            timestamp("判断", row.progressDimension != nil ? row.progressDimension?.evaluatedAt : row.evaluatedAt)
        }.frame(maxWidth: .infinity, alignment: .leading)
        VStack(alignment: .leading, spacing: 4) {
            Text("健康状态").font(.footnote).foregroundStyle(.secondary)
            if let health = row.visibleHealth {
                Label {
                    Text(healthTitle(health)).foregroundStyle(.primary)
                } icon: {
                    Image(systemName: healthSymbol(health)).foregroundStyle(color(health))
                }.font(.subheadline.weight(.semibold))
            } else { Text("尚无判断").font(.subheadline.weight(.semibold)) }
            dimensionStatus(row.healthAvailability)
            timestamp("判断", row.healthDimension != nil ? row.healthDimension?.evaluatedAt : row.evaluatedAt)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sourceAction(_ title: String, url: URL) -> some View {
        Button { sourceURL = url } label: {
            Label(title, systemImage: "arrow.up.right.square")
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(.tint)
    }

    private func timestamp(_ label: String, _ date: Date?) -> some View {
        (Text(label + "：") + (date.map { Text($0, format: .dateTime.year().month().day().hour().minute()) } ?? Text("未知")))
            .font(.footnote).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func dimensionStatus(_ state: ObservationAvailability) -> some View {
        Text(availability(state)).font(.footnote).foregroundStyle(.secondary)
    }

    private func dimensionDetails(_ name: String, _ dimension: GoalOverviewDimension) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name + " · " + availability(dimension.availability)).font(.subheadline.weight(.semibold))
            if let reason = dimension.explanation { Text(reasonText(reason)).font(.subheadline) }
            timestamp("资料覆盖", dimension.coverageAt)
            timestamp("判断时间", dimension.evaluatedAt)
            sourceNotes(dimension.sourceNotes)
        }
    }

    @ViewBuilder private func sourceNotes(_ notes: [String]) -> some View {
        if !notes.isEmpty {
            DisclosureGroup {
                ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                    Text(note).font(.footnote).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 6)
                }
            } label: {
                Text("资料来源与覆盖").font(.footnote).frame(minHeight: 44)
            }
        }
    }

    private func workerDetails(_ row: GoalOverviewRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let association = row.workerAssociation {
                Label("承接未核验", systemImage: "person.crop.circle.badge.questionmark")
                    .font(.subheadline.weight(.semibold))
                Text("仅确认当前关联，尚未确认接手、运行或授权。").font(.subheadline)
                timestamp("关联观察", association.observedAt)
            }
            if !row.workers.isEmpty {
                DisclosureGroup {
                    ForEach(row.workers) { worker in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(worker.title).font(.subheadline.weight(.medium))
                            Text([worker.host ?? "主机未知", worker.state ?? "状态未知"].joined(separator: " · "))
                                .font(.footnote).foregroundStyle(.secondary)
                            timestamp("Worker 观察", worker.observedAt)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                    }
                } label: {
                    Text("关联 Worker · \(row.workers.count)").font(.subheadline.weight(.medium)).frame(minHeight: 44)
                }
            }
        }
    }

    private func filterTitle(_ value: GoalOverviewFilter) -> String {
        switch value { case .all: return "全部"; case .risk: return "有风险"; case .blocked: return "受阻" }
    }

    private func availability(_ value: ObservationAvailability) -> String {
        switch value {
        case .current: return "当前观察"
        case .pending: return "待评估"
        case .lastKnown: return "上次观察"
        case .partial: return "部分可用"
        case .notApplicable: return "无有限完成范围"
        case .failed: return "刷新失败"
        }
    }

    private func reasonText(_ reason: String) -> String {
        switch reason {
        case "not_evaluated", "observation_absent": return "尚未完成评估"
        case "scope_not_evaluated": return "此承接范围尚未评估"
        case "evaluating": return "新判断正在生成，当前保留上次观察"
        case "evaluation_expired": return "上次判断已过期，等待重新评估"
        case "goal_changed", "input_changed": return "目标或资料已有变化，等待重新评估"
        case "unbounded_goal": return "当前目标没有有限完成条件"
        default: return "本次观察暂不可用，等待更新"
        }
    }

    private func healthTitle(_ health: GoalHealth) -> String {
        switch health { case .onTrack: return "正常推进"; case .atRisk: return "有风险"; case .blocked: return "受阻" }
    }

    private func healthSymbol(_ health: GoalHealth) -> String {
        switch health { case .onTrack: return "checkmark.circle"; case .atRisk: return "exclamationmark.triangle"; case .blocked: return "pause.circle" }
    }

    private func color(_ health: GoalHealth) -> Color {
        switch health { case .onTrack: return .green; case .atRisk: return .orange; case .blocked: return .red }
    }

}
