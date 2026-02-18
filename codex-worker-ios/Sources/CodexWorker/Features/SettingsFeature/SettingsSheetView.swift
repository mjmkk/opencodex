//
//  SettingsSheetView.swift
//  CodexWorker
//
//  连接配置弹层视图
//

import ComposableArchitecture
import SwiftUI

public struct SettingsSheetView: View {
    let store: StoreOf<SettingsFeature>
    let connectionState: ConnectionState
    let onClose: (() -> Void)?

    public init(
        store: StoreOf<SettingsFeature>,
        connectionState: ConnectionState,
        onClose: (() -> Void)? = nil
    ) {
        self.store = store
        self.connectionState = connectionState
        self.onClose = onClose
    }

    public var body: some View {
        WithViewStore(store, observe: { $0 }) { viewStore in
            NavigationStack {
                Form {
                    Section("后端地址") {
                        HStack(spacing: 8) {
                            TextField(
                                "http://192.168.1.10:8787",
                                text: Binding(
                                    get: { viewStore.baseURL },
                                    set: { viewStore.send(.baseURLChanged($0)) }
                                )
                            )
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .keyboardType(.URL)

                            reachabilityBadge(connectionState)
                        }

                        Text("请输入可访问的 Worker 地址（包含端口）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Section("鉴权 Token（可选）") {
                        TextField(
                            "Bearer Token",
                            text: Binding(
                                get: { viewStore.token },
                                set: { viewStore.send(.tokenChanged($0)) }
                            )
                        )
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                    }

                    Section("模型（可选）") {
                        TextField(
                            "例如 openai/gpt-5（留空跟随后端默认）",
                            text: Binding(
                                get: { viewStore.model },
                                set: { viewStore.send(.modelChanged($0)) }
                            )
                        )
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)

                        if viewStore.isLoadingModels {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("正在加载模型列表...")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        } else if !viewStore.availableModels.isEmpty {
                            Picker(
                                "快速选择",
                                selection: Binding(
                                    get: { viewStore.model },
                                    set: { viewStore.send(.modelChanged($0)) }
                                )
                            ) {
                                Text("跟随后端默认模型").tag("")
                                ForEach(viewStore.availableModels, id: \.id) { model in
                                    Text(model.listTitle).tag(model.id)
                                }
                            }
                            .pickerStyle(.menu)
                        }

                        if let modelLoadError = viewStore.modelLoadError, !modelLoadError.isEmpty {
                            Text("模型列表加载失败：\(modelLoadError)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section {
                        Button("保存并检测连通性") {
                            viewStore.send(.saveTapped)
                            onClose?()
                        }
                        .disabled(
                            viewStore.baseURL
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .isEmpty
                        )

                        if viewStore.saveSucceeded {
                            Label("配置已保存", systemImage: "checkmark.circle.fill")
                                .font(.footnote)
                                .foregroundStyle(.green)
                        }
                    }
                }
                .navigationTitle("连接设置")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("关闭") {
                            onClose?()
                        }
                    }
                }
            }
            .onAppear {
                viewStore.send(.onAppear)
            }
        }
    }

    private func reachabilityBadge(_ state: ConnectionState) -> some View {
        let style: (text: String, tint: Color) = switch state {
        case .connected:
            ("可达", .green)
        case .connecting, .reconnecting:
            ("检测中", .orange)
        case .failed, .disconnected:
            ("不可达", .red)
        }

        return Text(style.text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(style.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(style.tint.opacity(0.14))
            .clipShape(Capsule())
    }
}
