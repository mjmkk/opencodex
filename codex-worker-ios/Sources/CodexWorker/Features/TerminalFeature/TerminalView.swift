//
//  TerminalView.swift
//  CodexWorker
//
//  半屏终端视图
//

import ComposableArchitecture
import SwiftUI

public struct TerminalView: View {
    private struct ViewState: Equatable {
        let cwd: String
        let connectionState: TerminalFeature.State.ConnectionState
        let terminalText: String
        let inputText: String
        let canSendInput: Bool
        let errorMessage: String?
        let isClosing: Bool

        init(_ state: TerminalFeature.State) {
            self.cwd = state.session?.cwd ?? state.activeThread?.cwd ?? "未绑定目录"
            self.connectionState = state.connectionState
            self.terminalText = state.terminalText
            self.inputText = state.inputText
            self.canSendInput = state.canSendInput
            self.errorMessage = state.errorMessage
            self.isClosing = state.isClosing
        }
    }

    private let store: StoreOf<TerminalFeature>

    public init(store: StoreOf<TerminalFeature>) {
        self.store = store
    }

    public var body: some View {
        WithViewStore(store, observe: ViewState.init) { viewStore in
            VStack(spacing: 0) {
                header(viewStore: viewStore)

                Divider()
                    .background(Color.white.opacity(0.2))

                terminalOutput(viewStore: viewStore)

                Divider()
                    .background(Color.white.opacity(0.2))

                inputBar(viewStore: viewStore)
            }
            .background(terminalBackground)
            .overlay(alignment: .topLeading) {
                if let error = viewStore.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.45))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .padding(.top, 8)
                        .padding(.leading, 8)
                }
            }
        }
    }

    private var terminalBackground: Color {
        Color(red: 0.05, green: 0.06, blue: 0.08)
    }

    @ViewBuilder
    private func header(viewStore: ViewStore<ViewState, TerminalFeature.Action>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal.fill")
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 2) {
                Text(viewStore.cwd)
                    .font(.caption.monospaced())
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(connectionLabel(for: viewStore.connectionState))
                    .font(.caption2)
                    .foregroundStyle(connectionColor(for: viewStore.connectionState))
            }

            Spacer(minLength: 8)

            Button {
                viewStore.send(.closeSession)
            } label: {
                if viewStore.isClosing {
                    ProgressView()
                        .progressViewStyle(.circular)
                } else {
                    Image(systemName: "xmark.circle.fill")
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.86))
            .accessibilityLabel("关闭终端会话")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func terminalOutput(viewStore: ViewStore<ViewState, TerminalFeature.Action>) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(viewStore.terminalText.isEmpty ? "终端已连接，输入命令后回车执行。" : viewStore.terminalText)
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .foregroundStyle(viewStore.terminalText.isEmpty ? .white.opacity(0.55) : .white.opacity(0.95))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)

                Color.clear
                    .frame(height: 1)
                    .id("terminal-bottom-anchor")
            }
            .onAppear {
                proxy.scrollTo("terminal-bottom-anchor", anchor: .bottom)
            }
            .onChange(of: viewStore.terminalText) { _, _ in
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo("terminal-bottom-anchor", anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func inputBar(viewStore: ViewStore<ViewState, TerminalFeature.Action>) -> some View {
        HStack(spacing: 8) {
            TextField(
                "输入命令后回车（例如：ls -la）",
                text: Binding(
                    get: { viewStore.inputText },
                    set: { viewStore.send(.binding(.set(\.inputText, $0))) }
                )
            )
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .regular, design: .monospaced))
            .foregroundStyle(.white)
            .submitLabel(.send)
            .disabled(!viewStore.canSendInput)
            .onSubmit {
                viewStore.send(.sendInput)
            }

            Button {
                viewStore.send(.sendInput)
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .foregroundStyle(viewStore.canSendInput ? .green : .gray)
            .disabled(!viewStore.canSendInput)
            .accessibilityLabel("发送终端输入")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func connectionLabel(for state: TerminalFeature.State.ConnectionState) -> String {
        switch state {
        case .idle:
            return "未连接"
        case .connecting:
            return "连接中..."
        case .connected:
            return "已连接"
        case .failed(let message):
            return "连接失败：\(message)"
        }
    }

    private func connectionColor(for state: TerminalFeature.State.ConnectionState) -> Color {
        switch state {
        case .idle:
            return .gray
        case .connecting:
            return .yellow
        case .connected:
            return .green
        case .failed:
            return .red
        }
    }
}
