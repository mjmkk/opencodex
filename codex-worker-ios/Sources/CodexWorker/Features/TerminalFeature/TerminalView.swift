//
//  TerminalView.swift
//  CodexWorker
//
//  半屏终端视图
//

import ComposableArchitecture
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(SwiftTerm)
import SwiftTerm
#endif

public struct TerminalView: View {
    private struct ViewState: Equatable {
        let cwd: String
        let connectionState: TerminalFeature.State.ConnectionState
        let terminalText: String
        let inputText: String
        let canSendInput: Bool
        let errorMessage: String?
        let isClosing: Bool
        let showRiskNotice: Bool

        init(_ state: TerminalFeature.State) {
            self.cwd = state.session?.cwd ?? state.activeThread?.cwd ?? "未绑定目录"
            self.connectionState = state.connectionState
            self.terminalText = state.terminalText
            self.inputText = state.inputText
            self.canSendInput = state.canSendInput
            self.errorMessage = state.errorMessage
            self.isClosing = state.isClosing
            self.showRiskNotice = state.showRiskNotice
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
                    .background(SwiftUI.Color.white.opacity(0.2))

                terminalOutput(viewStore: viewStore)

                Divider()
                    .background(SwiftUI.Color.white.opacity(0.2))

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
                        .background(SwiftUI.Color.black.opacity(0.45))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .padding(.top, 8)
                        .padding(.leading, 8)
                }
            }
            .overlay(alignment: .topTrailing) {
                if viewStore.showRiskNotice {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("该终端直接执行 Mac 命令，不经过审批。")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.95))
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            viewStore.send(.dismissRiskNotice)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.white.opacity(0.75))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(SwiftUI.Color.orange.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.top, 8)
                    .padding(.trailing, 8)
                }
            }
            .background(
                GeometryReader { proxy in
                    SwiftUI.Color.clear
                        .onAppear {
                            viewStore.send(
                                .viewportChanged(
                                    width: proxy.size.width,
                                    height: proxy.size.height
                                )
                            )
                        }
                        .onChange(of: proxy.size) { _, newSize in
                            viewStore.send(
                                .viewportChanged(
                                    width: newSize.width,
                                    height: newSize.height
                                )
                            )
                        }
                }
            )
        }
    }

    private var terminalBackground: SwiftUI.Color {
        SwiftUI.Color(red: 0.05, green: 0.06, blue: 0.08)
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
        TerminalOutputSurface(
            text: viewStore.terminalText,
            placeholder: "终端已连接，输入命令后回车执行。",
            onInput: { payload in
                viewStore.send(.sendRawInput(payload))
            }
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
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

    private func connectionColor(for state: TerminalFeature.State.ConnectionState) -> SwiftUI.Color {
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

private struct TerminalOutputSurface: View {
    let text: String
    let placeholder: String
    let onInput: (String) -> Void

    var body: some View {
#if canImport(SwiftTerm) && canImport(UIKit)
        TerminalSurfaceRepresentable(
            text: text,
            placeholder: placeholder,
            onInput: onInput
        )
#else
        ScrollView {
            Text(text.isEmpty ? placeholder : text)
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .foregroundStyle(text.isEmpty ? .white.opacity(0.55) : .white.opacity(0.95))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
#endif
    }
}

#if canImport(SwiftTerm) && canImport(UIKit)
private struct TerminalSurfaceRepresentable: UIViewRepresentable {
    let text: String
    let placeholder: String
    let onInput: (String) -> Void

    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let view = SwiftTerm.TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        view.backgroundColor = UIColor(red: 0.05, green: 0.06, blue: 0.08, alpha: 1.0)
        view.nativeBackgroundColor = UIColor(red: 0.05, green: 0.06, blue: 0.08, alpha: 1.0)
        view.nativeForegroundColor = UIColor(white: 0.95, alpha: 1.0)
        view.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view.optionAsMetaKey = true
        view.allowMouseReporting = true
        view.notifyUpdateChanges = false
        return view
    }

    func updateUIView(_ uiView: SwiftTerm.TerminalView, context: Context) {
        context.coordinator.updateInputHandler(onInput)
        context.coordinator.apply(content: text, placeholder: placeholder, to: uiView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, SwiftTerm.TerminalViewDelegate {
        private var lastRendered = ""
        private var onInput: ((String) -> Void)?

        func updateInputHandler(_ handler: @escaping (String) -> Void) {
            onInput = handler
        }

        func apply(content: String, placeholder: String, to view: SwiftTerm.TerminalView) {
            let next = content.isEmpty ? "\(placeholder)\r\n" : content
            guard next != lastRendered else {
                return
            }

            if next.hasPrefix(lastRendered) {
                let deltaStart = next.index(next.startIndex, offsetBy: lastRendered.count)
                let delta = String(next[deltaStart...])
                if !delta.isEmpty {
                    view.feed(text: delta)
                }
            } else {
                view.feed(text: "\u{001B}[2J\u{001B}[H")
                view.feed(text: next)
            }
            lastRendered = next
        }

        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            let payload = String(decoding: data, as: UTF8.self)
            guard !payload.isEmpty else { return }
            onInput?(payload)
        }
        func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
        func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {}
        func bell(source: SwiftTerm.TerminalView) {}
        func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {}
        func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    }
}
#endif
