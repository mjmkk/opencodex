//
//  ApprovalSheetView.swift
//  CodexWorker
//
//  审批弹层视图（里程碑 4）
//

import ComposableArchitecture
import SwiftUI

public struct ApprovalSheetView: View {
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
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .shadow(radius: 12, y: 4)
            }
        }
    }
}
