//
//  ApprovalSheetView.swift
//  CodexWorker
//
//  审批弹层视图（里程碑 4）
//

import ComposableArchitecture
import SwiftUI

public struct ApprovalSheetView: View {
    @Environment(\.colorScheme) private var colorScheme

    let store: StoreOf<ApprovalFeature>

    public var body: some View {
        WithViewStore(store, observe: { $0 }) { viewStore in
            if let approval = viewStore.currentApproval {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label(approval.kind.title, systemImage: approval.kind.iconName)
                            .font(.headline)
                        Spacer()
                        Text(approval.riskLevel.label)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(approval.riskLevel.color.opacity(0.2))
                            .clipShape(Capsule())
                    }

                    if let command = approval.command, !command.isEmpty {
                        Text(command)
                            .font(.system(.footnote, design: .monospaced))
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    if let cwd = approval.cwd, !cwd.isEmpty {
                        Text("cwd: \(cwd)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if let error = viewStore.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("拒绝理由（可选）")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TextField(
                            "例如：此命令会修改生产环境，不允许执行",
                            text: Binding(
                                get: { viewStore.declineReasonInput },
                                set: { viewStore.send(.declineReasonChanged($0)) }
                            ),
                            axis: .vertical
                        )
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2 ... 4)
                    }

                    HStack(spacing: 8) {
                        Button("拒绝") {
                            viewStore.send(.submitTapped(.decline))
                        }
                        .buttonStyle(.bordered)

                        Button("会话接受") {
                            viewStore.send(.submitTapped(.acceptForSession))
                        }
                        .buttonStyle(.bordered)

                        Button("接受") {
                            viewStore.send(.submitTapped(.accept))
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .disabled(viewStore.isSubmitting)

                    Button("取消任务") {
                        viewStore.send(.submitTapped(.cancel))
                    }
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .disabled(viewStore.isSubmitting)
                }
                .padding(14)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(panelBorderColor, lineWidth: 1)
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .shadow(color: panelShadowColor, radius: 12, y: 4)
            }
        }
    }

    private var panelBorderColor: Color {
        Color(uiColor: .separator).opacity(colorScheme == .dark ? 0.55 : 0.24)
    }

    private var panelShadowColor: Color {
        Color.black.opacity(colorScheme == .dark ? 0.34 : 0.12)
    }
}
