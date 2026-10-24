import SwiftUI

/// Observer facts stay independent even when their presentation is grouped.
struct GoalOverviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var filter: GoalOverviewFilter = .all
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
                    if !hasSnapshot {
                        ContentUnavailableView {
                            Label(isRefreshing ? "正在读取目标" : "暂时无法读取目标", systemImage: "chart.bar.xaxis")
                        } description: {
                            Text("读取完成后，这里会显示目标的真实进展。")
                        } actions: {
                            if isRefreshing { ProgressView() }
                            else { Button("重试") { Task { await refresh() } }.frame(minHeight: 44) }
                        }
                    } else if rows.filter(filter.includes).isEmpty {
                        ContentUnavailableView("没有匹配的目标", systemImage: "line.3.horizontal.decrease")
                    } else {
                        ForEach(rows.filter(filter.includes)) { row in goalLink(row) }
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
                    .disabled(isRefreshing).accessibilityLabel("刷新目标")
                }
            }
        }
        .background(OverviewSourcePresenter(url: sourceURL) { sourceURL = nil })
        .tint(.primary)
    }

    private var overviewHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 4) { filterButtons }
            } else { HStack(spacing: 4) { filterButtons } }
            NavigationLink {
                inventoryDetails
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(hasSnapshot
                         ? "\(rows.filter { $0.hasPendingAssessment }.count) 待评估 · \(rows.filter { $0.hasLastKnownAssessment }.count) 含上次观察"
                         : inventoryValidation.title)
                    Spacer(minLength: 0)
                    Image(systemName: "info.circle").accessibilityHidden(true)
                }
                .font(.footnote).foregroundStyle(.secondary)
                .frame(minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if let failure {
                Label(failure, systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.horizontal, 20).padding(.top, 12)
    }

    private var inventoryDetails: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(inventoryValidation.title).font(.title2.weight(.semibold))
                Text("任务列表和每个目标的评分分别更新。刷新列表后，目标可能仍保留上一次判断。")
                timestamp("列表核对", inventoryValidation.verifiedAt)
                Text("每项目标均标明判断状态与原始时间。尚无判断的项目会显示待评估，不会记成 0%。")
                    .foregroundStyle(.secondary)
            }.font(.body).padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }.navigationTitle("观察说明").navigationBarTitleDisplayMode(.inline)
    }

    private var filterButtons: some View {
        ForEach(GoalOverviewFilter.allCases, id: \.self) { value in
            Button { filter = value } label: {
                Text(filterTitle(value) + (hasSnapshot ? " \(rows.filter(value.includes).count)" : ""))
                    .font(.subheadline.weight(filter == value ? .semibold : .regular))
                    .foregroundStyle(filter == value ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44).padding(.horizontal, 4)
                    .background(filter == value ? Color(uiColor: .secondarySystemFill) : Color.clear, in: Capsule())
                    .contentShape(Capsule())
            }.buttonStyle(.plain).accessibilityAddTraits(filter == value ? .isSelected : [])
        }
    }

    private func goalLink(_ row: GoalOverviewRow, inset: CGFloat = 20) -> some View {
        VStack(spacing: 0) {
            NavigationLink {
                goalDetails(row)
            } label: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        metadata(row)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary).accessibilityHidden(true)
                    }
                    Text(row.title).font(.headline).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 8) { summaryValues(row) }
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 16) { summaryValues(row) }
                    }
                    observationCaption(row)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, inset).padding(.vertical, 18).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityHint("查看进展、判断依据与承接事项")
            Divider().padding(.horizontal, inset)
        }
    }

    private func metadata(_ row: GoalOverviewRow) -> some View {
        Text([row.issueIdentifier, row.project].compactMap { $0 }.joined(separator: " · "))
            .font(.footnote).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func summaryValues(_ row: GoalOverviewRow) -> some View {
        HStack(spacing: 6) {
            Text("进度").foregroundStyle(.secondary)
            Text(progressTitle(row)).fontWeight(.medium).monospacedDigit()
        }.font(.subheadline).foregroundStyle(.primary)
        HStack(spacing: 6) {
            if let health = row.visibleHealth {
                Image(systemName: healthSymbol(health)).foregroundStyle(color(health))
                Text(healthTitle(health))
            } else {
                Text(row.healthAvailability == .pending ? "状态待评估" : "状态暂无判断")
            }
        }.font(.subheadline.weight(.medium)).foregroundStyle(.primary)
    }

    @ViewBuilder private func observationCaption(_ row: GoalOverviewRow) -> some View {
        let progressAt = row.progressDimension == nil ? row.evaluatedAt : row.progressDimension?.evaluatedAt
        let healthAt = row.healthDimension == nil ? row.evaluatedAt : row.healthDimension?.evaluatedAt
        if row.progressAvailability == .pending, row.healthAvailability == .pending,
           progressAt == nil, healthAt == nil {
            // No judgment exists to date; both pending values are already visible above.
            EmptyView()
        } else if row.progressAvailability == row.healthAvailability, let progressAt, progressAt == healthAt {
            Text(observationText(row.progressAvailability, progressAt))
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text("进度 · " + observationText(row.progressAvailability, progressAt))
                Text("状态 · " + observationText(row.healthAvailability, healthAt))
            }.font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func goalDetails(_ row: GoalOverviewRow) -> AnyView {
        AnyView(ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    metadata(row)
                    Text(row.title).font(.title2.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    if let url = row.issueURL { sourceAction("查看原始任务", url: url) }
                }
                if let scope = row.closureScopeDescription {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("本次承接范围")
                        Text(scope).font(.body).lineSpacing(4).textSelection(.enabled)
                        if let url = row.closureScopeSourceURL { sourceAction("查看范围依据", url: url) }
                    }
                }
                if row.progressAvailability == .pending, row.healthAvailability == .pending {
                    VStack(alignment: .leading, spacing: 12) {
                        sectionTitle("评估状态")
                        Text(row.closureScopeDescription == nil
                             ? "进度与健康状态均待评估。" : "此承接范围尚未评估。")
                            .font(.body).foregroundStyle(.secondary)
                        DisclosureGroup("查看评估详情") { assessments(row).padding(.top, 16) }
                            .font(.subheadline).tint(.primary)
                    }
                } else { assessments(row) }
                if !row.obligations.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        sectionTitle("承接事项 · \(row.obligations.count)")
                        ForEach(row.obligations) { obligation in goalLink(obligation, inset: 0) }
                    }
                }
                if row.workerAssociation != nil || !row.workers.isEmpty { workerDetails(row) }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }.background(Color(uiColor: .systemBackground))
            .navigationTitle(row.issueIdentifier ?? "目标详情").navigationBarTitleDisplayMode(.inline))
    }

    private func assessments(_ row: GoalOverviewRow) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            assessment("进度", value: progressTitle(row), state: row.progressAvailability,
                       dimension: row.progressDimension, row: row, progress: row.validProgress)
            Divider()
            assessment("健康状态", value: row.visibleHealth.map(healthTitle) ?? "尚无判断",
                       state: row.healthAvailability, dimension: row.healthDimension, row: row)
        }
    }

    private func assessment(_ name: String, value: String, state: ObservationAvailability,
                            dimension: GoalOverviewDimension?, row: GoalOverviewRow,
                            progress: Int? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    sectionTitle(name)
                    Text(value).font(.headline)
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    sectionTitle(name)
                    Spacer(minLength: 12)
                    Text(value).font(.headline).multilineTextAlignment(.trailing)
                }
            }
            if let progress {
                ProgressView(value: Double(progress), total: 100).tint(.primary)
                    .accessibilityLabel("进度 \(progress)%")
            }
            Text(observationText(state, dimension == nil ? row.evaluatedAt : dimension?.evaluatedAt))
                .font(.footnote).foregroundStyle(.secondary)
            if let reason = dimension?.explanation ?? (dimension == nil ? row.explanation : nil) {
                Text(reasonText(reason)).font(.body).lineSpacing(3)
            }
            timestamp("资料覆盖至", dimension == nil ? row.coverageAt : dimension?.coverageAt)
            sourceDetails(dimension?.sourceNotes ?? row.sourceNotes, observation: dimension?.observation)
        }
    }

    @ViewBuilder private func sourceDetails(_ notes: [String], observation: JSONValue?) -> some View {
        let sources = observation?.objectValue?["sources"]?.arrayValue ?? []
        if !notes.isEmpty || !sources.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(sources.enumerated()), id: \.offset) { _, source in
                        if let fields = source.objectValue {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(sourceTitle(fields["source_type"]?.stringValue)).font(.subheadline.weight(.medium))
                                if let coverage = fields["coverage"]?.objectValue {
                                    if coverage["content"]?.stringValue == "current_issue_description" {
                                        Text("依据当次任务正文").font(.footnote).foregroundStyle(.secondary)
                                    }
                                    if coverage["attachments"]?.stringValue == "unknown" {
                                        Text("附件覆盖情况未知").font(.footnote).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    DisclosureGroup("技术记录") {
                        ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                            Text(note).font(.footnote.monospaced()).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                        }
                    }.font(.footnote).foregroundStyle(.secondary)
                }.padding(.top, 8)
            } label: {
                Label("判断依据 · \(max(notes.count, sources.count)) 项记录", systemImage: "doc.text")
                    .font(.subheadline).frame(minHeight: 44)
            }.tint(.primary)
        }
    }

    private func workerDetails(_ row: GoalOverviewRow) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                if let association = row.workerAssociation {
                    Text("已有关联，承接尚未核验").font(.subheadline.weight(.medium))
                    Text("关联信息尚不能确认接手、运行或授权。")
                        .font(.footnote).foregroundStyle(.secondary)
                    timestamp("关联观察", association.observedAt)
                }
                ForEach(row.workers) { worker in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(worker.title).font(.subheadline.weight(.medium))
                        Text([worker.host ?? "主机未知", worker.state ?? "状态未知"].joined(separator: " · "))
                            .font(.footnote).foregroundStyle(.secondary)
                        timestamp("观察时间", worker.observedAt)
                    }.padding(.vertical, 6)
                }
            }.padding(.top, 10)
        } label: {
            Text("关联执行者 · \(row.workers.count)").font(.subheadline.weight(.medium))
                .frame(minHeight: 44)
        }.tint(.primary)
    }

    private func sectionTitle(_ title: String) -> some View { Text(title).font(.headline) }

    private func sourceAction(_ title: String, url: URL) -> some View {
        Button { sourceURL = url } label: {
            Label(title, systemImage: "arrow.up.right").font(.subheadline.weight(.medium))
                .frame(minHeight: 44, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(.primary)
    }

    private func timestamp(_ label: String, _ date: Date?) -> some View {
        Text(label + " · " + (date.map(shortDate) ?? "未知"))
            .font(.footnote).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func observationText(_ availability: ObservationAvailability, _ date: Date?) -> String {
        let state: String
        switch availability {
        case .current: state = "当前观察"
        case .lastKnown: state = "上次观察"
        case .pending: state = "待评估"
        case .partial: state = "部分资料可用"
        case .notApplicable: state = "不适用"
        case .failed: state = "刷新失败"
        }
        return state + " · " + (date.map(shortDate) ?? "判断时间未知")
    }

    private func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        return formatter.string(from: date)
    }

    private func progressTitle(_ row: GoalOverviewRow) -> String {
        if let progress = row.validProgress { return "\(progress)%" }
        if row.progressNotApplicable { return "不设百分比" }
        switch row.progressAvailability {
        case .pending: return "待评估"
        case .failed: return "暂不可用"
        default: return "暂无评分"
        }
    }

    private func filterTitle(_ value: GoalOverviewFilter) -> String {
        switch value { case .all: return "全部"; case .risk: return "有风险"; case .blocked: return "受阻" }
    }

    private func reasonText(_ reason: String) -> String {
        switch reason {
        case "not_evaluated", "observation_absent": return "尚未完成评估。"
        case "scope_not_evaluated": return "此承接范围尚未评估。"
        case "evaluating": return "新判断正在生成，当前保留上次观察。"
        case "evaluation_expired": return "上次判断已过期，等待重新评估。"
        case "goal_changed", "input_changed": return "目标或资料已有变化，等待重新评估。"
        case "unbounded_goal": return "当前目标没有有限完成条件，因此不显示完成百分比。"
        default: return "本次观察暂不可用，等待更新。"
        }
    }

    private func sourceTitle(_ type: String?) -> String {
        switch type {
        case "linear": return "Linear 任务资料"
        case "memory": return "任务记忆"
        case "codex": return "Codex 任务记录"
        default: return type.map { "来源 · " + $0 } ?? "来源类型未知"
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
