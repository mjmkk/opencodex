//
//  SettingsSheetView.swift
//  CodexWorker
//
//  连接配置弹层视图
//

import ComposableArchitecture
import SwiftUI
import ActivityKit
import UserNotifications

public struct SettingsSheetView: View {
    @State private var showAllArchivedThreads = false
    @State private var notificationStatus = "正在读取"

    let store: StoreOf<SettingsFeature>
    let connectionState: ConnectionState
    let isCheckingConnection: Bool
    let lastSyncedAt: Date?
    let onCheckConnection: (() -> Void)?
    let onClose: (() -> Void)?

    public init(
        store: StoreOf<SettingsFeature>,
        connectionState: ConnectionState,
        isCheckingConnection: Bool = false,
        lastSyncedAt: Date? = nil,
        onCheckConnection: (() -> Void)? = nil,
        onClose: (() -> Void)? = nil
    ) {
        self.store = store
        self.connectionState = connectionState
        self.isCheckingConnection = isCheckingConnection
        self.lastSyncedAt = lastSyncedAt
        self.onCheckConnection = onCheckConnection
        self.onClose = onClose
    }

    public var body: some View {
        WithViewStore(store, observe: { $0 }) { viewStore in
            let archivedCollapsedLimit = 3
            let totalArchivedCount = viewStore.archivedThreads.count
            let displayedArchivedThreads = showAllArchivedThreads
                ? viewStore.archivedThreads
                : Array(viewStore.archivedThreads.prefix(archivedCollapsedLimit))

            NavigationStack {
                List {
                    Section {
                        HStack(spacing: 12) {
                            statusRow("服务可达性", value: isCheckingConnection ? "正在检查…" : reachability.text,
                                      tint: isCheckingConnection ? .secondary : reachability.tint)
                            if let onCheckConnection {
                                Button(action: onCheckConnection) {
                                    Group {
                                        if isCheckingConnection { ProgressView().controlSize(.small) }
                                        else { Image(systemName: "arrow.clockwise") }
                                    }.frame(width: 44, height: 44)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("重新检查连接")
                                .disabled(isCheckingConnection)
                            }
                        }
                        statusRow("访问验证", value: viewStore.authenticatedResponseAt != nil ? "已收到有效响应" : "尚未确认")
                        statusRow("任务同步", value: lastSyncedAt.map(MobileTime.timestamp) ?? "尚未同步")
                        if case let .failed(message) = connectionState {
                            DisclosureGroup(isCheckingConnection ? "上次连接原因与建议" : "连接原因与建议") {
                                Text(message).font(.footnote).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text("请核对服务地址、网络和访问凭据。保存配置后，连接结果仍需单独核对。")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }.font(.footnote)
                        }
                    }
                    Section {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("服务地址").font(.footnote).foregroundStyle(.secondary)
                                .frame(width: 76, alignment: .leading)
                            TextField("https://你的服务地址:端口", text: Binding(
                                get: { viewStore.baseURL }, set: { viewStore.send(.baseURLChanged($0)) }), axis: .vertical)
                                .lineLimit(1...4)
                                .textInputAutocapitalization(.never).disableAutocorrection(true).keyboardType(.URL)
                                .accessibilityLabel("服务地址")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("访问 Token").font(.footnote).foregroundStyle(.secondary)
                                .frame(width: 76, alignment: .leading)
                            SecureField("需要鉴权时填写", text: Binding(
                                get: { viewStore.token }, set: { viewStore.send(.tokenChanged($0)) }))
                                .textInputAutocapitalization(.never).disableAutocorrection(true)
                                .accessibilityLabel("访问 Token").frame(minHeight: 44)
                        }
                        Button { viewStore.send(.saveTapped) } label: {
                            Text("保存连接配置").frame(maxWidth: .infinity)
                        }.buttonStyle(CodexPrimaryButtonStyle())
                            .disabled(viewStore.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))
                        if viewStore.saveSucceeded {
                            Label("配置已保存", systemImage: "checkmark.circle")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    } header: { Text("连接信息").font(.footnote) }
                    footer: {
                        Text("保存后自动检查连接。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("通知与持续展示") {
                        LabeledContent("系统通知", value: notificationStatus)
                        LabeledContent("实时活动", value: ActivityAuthorizationInfo().areActivitiesEnabled ? "系统允许" : "系统未开启")
                        Text("只有你持续展示的任务会显示实时活动。系统允许通知不代表远程通知已送达。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("模型（可选）") {
                        if viewStore.isLoadingModels {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("正在加载模型列表...")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Picker(
                            "模型",
                            selection: Binding(
                                get: { viewStore.model },
                                set: { viewStore.send(.modelChanged($0)) }
                            )
                        ) {
                            Text("跟随后端默认模型").tag("")
                            ForEach(viewStore.availableModels, id: \.id) { model in
                                Text(model.listTitle).tag(model.id)
                            }
                            if !viewStore.model.isEmpty,
                               !viewStore.availableModels.contains(where: { $0.id == viewStore.model })
                            {
                                Text("当前模型（未在服务端列表中）").tag(viewStore.model)
                            }
                        }
                        .pickerStyle(.menu)
                        .disabled(viewStore.isLoadingModels)

                        if !viewStore.isLoadingModels && viewStore.availableModels.isEmpty {
                            Text(viewStore.modelLoadError == nil ? "服务尚未提供可选模型，将跟随后端默认值。" : "模型列表未能读取，当前选择已保留。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if let modelLoadError = viewStore.modelLoadError, !modelLoadError.isEmpty {
                            DisclosureGroup("查看模型读取原因") {
                                Text(modelLoadError).font(.footnote).foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }.font(.footnote).frame(minHeight: 44)
                        }
                    }

                    Section("已归档线程") {
                        if viewStore.isLoadingArchivedThreads {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("正在加载归档线程...")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        } else if viewStore.archivedThreads.isEmpty {
                            Text(viewStore.archivedThreadsLoadError == nil ? "暂无已归档任务" : "暂时无法读取已归档任务")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(displayedArchivedThreads, id: \.threadId) { thread in
                                archivedThreadRow(viewStore: viewStore, thread: thread)
                            }

                            if totalArchivedCount > archivedCollapsedLimit {
                                Button {
                                    showAllArchivedThreads.toggle()
                                } label: {
                                    if showAllArchivedThreads {
                                        Text("收起归档线程")
                                    } else {
                                        Text("显示更多（剩余 \(totalArchivedCount - archivedCollapsedLimit) 条）")
                                    }
                                }
                                .font(.footnote)
                            }
                        }

                        if let archivedThreadsLoadError = viewStore.archivedThreadsLoadError,
                           !archivedThreadsLoadError.isEmpty
                        {
                            DisclosureGroup("查看归档读取或恢复原因") {
                                Text(archivedThreadsLoadError).font(.footnote).foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }.font(.footnote).frame(minHeight: 44)
                        }
                    }

                    Section("关于") {
                        LabeledContent("版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知")
                        LabeledContent("构建", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "未知")
                    }
                }
                .listStyle(.grouped)
                .scrollContentBackground(.hidden)
                .background(CodexAppearance.canvas)
                .navigationTitle("连接与设置")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(CodexAppearance.canvas, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .tint(.primary)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("关闭") {
                            onClose?()
                        }
                    }
                }
            }
            .onAppear {
                showAllArchivedThreads = false
                viewStore.send(.onAppear)
            }
            .task {
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                switch settings.authorizationStatus {
                case .authorized: notificationStatus = "已允许"
                case .provisional, .ephemeral: notificationStatus = "静默或临时授权"
                case .denied: notificationStatus = "已关闭"
                default: notificationStatus = "尚未授权"
                }
            }
        }
    }

    private var reachability: (text: String, tint: Color) {
        switch connectionState {
        case .connected:
            ("服务可达", .secondary)
        case .connecting, .reconnecting:
            ("检测中", .orange)
        case .failed:
            ("连接失败", .red)
        case .disconnected:
            ("服务未连接", .secondary)
        }
    }

    private func statusRow(_ title: String, value: String, tint: Color = .primary) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title).font(.footnote).foregroundStyle(.secondary).fixedSize()
                Spacer(minLength: 8)
                Text(value).font(.body).foregroundStyle(tint).fixedSize()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.footnote).foregroundStyle(.secondary)
                Text(value).font(.body).foregroundStyle(tint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func archivedThreadRow(
        viewStore: ViewStoreOf<SettingsFeature>,
        thread: Thread
    ) -> some View {
        let isRestoring = viewStore.restoringThreadIds.contains(thread.threadId)

        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(thread.settingsListTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(3)
                    .foregroundStyle(.primary)
                if let subtitle = thread.settingsListSubtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            if isRestoring {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("恢复") {
                    viewStore.send(.restoreArchivedTapped(thread.threadId))
                }
                .buttonStyle(.bordered)
                .frame(minWidth: 44, minHeight: 44)
            }
        }
        .padding(.vertical, 4)
    }
}

private extension Thread {
    var settingsListTitle: String {
        if let name, !name.isEmpty { return name }
        let normalized = preview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !normalized.isEmpty {
            return normalized
                .split(whereSeparator: \.isNewline)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? normalized
        }
        return displayName == "Untitled" ? "未命名会话" : displayName
    }

    var settingsListSubtitle: String? {
        var parts: [String] = []
        if let cwd, !cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(cwd)
        }
        if let updatedAt = updatedAt, !updatedAt.isEmpty {
            parts.append(updatedAt)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
