//
//  TerminalView.swift
//  CodexWorker
//
//  半屏终端视图（iSH 风格：终端区直接输入）
//

import ComposableArchitecture
import SwiftUI
#if canImport(Foundation)
import Foundation
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(SwiftTerm)
import SwiftTerm
#endif

public struct TerminalView: View {
    @Environment(\.colorScheme) private var colorScheme

    private struct ViewState: Equatable {
        let cwd: String
        let connectionState: TerminalFeature.State.ConnectionState
        let terminalText: String
        let canSendInput: Bool
        let errorMessage: String?
        let isClosing: Bool
        let showRiskNotice: Bool
        let transportMode: String

        init(_ state: TerminalFeature.State) {
            self.cwd = state.session?.cwd ?? state.activeThread?.cwd ?? "未绑定目录"
            self.connectionState = state.connectionState
            self.terminalText = state.terminalText
            self.canSendInput = state.canSendInput
            self.errorMessage = state.errorMessage
            self.isClosing = state.isClosing
            self.showRiskNotice = state.showRiskNotice
            self.transportMode = state.session?.transportMode ?? "pty"
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
                    .background(Color(uiColor: .separator))

                terminalOutput(viewStore: viewStore)
            }
            .background(Color(uiColor: .secondarySystemBackground))
            .overlay(alignment: .topLeading) {
                if let error = viewStore.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(uiColor: .systemBackground).opacity(0.95))
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
                            .foregroundStyle(Color(uiColor: .label))
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            viewStore.send(.dismissRiskNotice)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(colorScheme == .dark ? 0.20 : 0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.top, 8)
                    .padding(.trailing, 8)
                }
            }
            .background(
                GeometryReader { proxy in
                    Color.clear
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

    @ViewBuilder
    private func header(viewStore: ViewStore<ViewState, TerminalFeature.Action>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal.fill")
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(viewStore.cwd)
                    .font(.caption.monospaced())
                    .foregroundStyle(Color(uiColor: .label))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(connectionLabel(for: viewStore.connectionState))
                        .font(.caption2)
                        .foregroundStyle(connectionColor(for: viewStore.connectionState))

                    Text(viewStore.transportMode == "pipe" ? "兼容模式" : "终端模式")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(uiColor: .tertiarySystemFill))
                        .clipShape(Capsule())
                }
            }

            Spacer(minLength: 8)

            Button {
                viewStore.send(.clearOutput)
            } label: {
                Image(systemName: "trash")
                    .font(.subheadline)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("清空终端显示")

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
            .foregroundStyle(.secondary)
            .accessibilityLabel("关闭终端会话")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func terminalOutput(viewStore: ViewStore<ViewState, TerminalFeature.Action>) -> some View {
        TerminalOutputSurface(
            text: viewStore.terminalText,
            canSendInput: viewStore.canSendInput,
            isDarkMode: colorScheme == .dark,
            placeholder: "终端连接后会在此显示输出。",
            onInput: { payload in
                viewStore.send(.sendRawInput(payload))
            }
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
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
            return .orange
        case .connected:
            return .green
        case .failed:
            return .red
        }
    }
}

private struct TerminalOutputSurface: View {
    let text: String
    let canSendInput: Bool
    let isDarkMode: Bool
    let placeholder: String
    let onInput: (String) -> Void

    var body: some View {
#if canImport(SwiftTerm) && canImport(UIKit)
        TerminalSurfaceRepresentable(
            text: text,
            canSendInput: canSendInput,
            isDarkMode: isDarkMode,
            onInput: onInput
        )
#else
        ScrollView {
            Text(text.isEmpty ? placeholder : text)
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .foregroundStyle(text.isEmpty ? .secondary : Color(uiColor: .label))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(uiColor: .systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(uiColor: .separator).opacity(0.35), lineWidth: 1)
        )
#endif
    }
}

#if canImport(SwiftTerm) && canImport(UIKit)
private struct TerminalSurfaceRepresentable: UIViewRepresentable {
    private struct TerminalPalette: Equatable {
        let background: UIColor
        let foreground: UIColor
    }

    let text: String
    let canSendInput: Bool
    let isDarkMode: Bool
    let onInput: (String) -> Void

    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let view = SwiftTerm.TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        context.coordinator.applyTheme(isDarkMode: isDarkMode, to: view)
        view.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view.optionAsMetaKey = true
        view.allowMouseReporting = true
        view.notifyUpdateChanges = false
        // 关闭输入附件条，保持 iSH 风格的纯终端区域输入。
        view.inputAccessoryView = nil
        #if !os(visionOS)
        view.inputAssistantItem.leadingBarButtonGroups = []
        view.inputAssistantItem.trailingBarButtonGroups = []
        #endif
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartDashesType = .no
        view.smartQuotesType = .no
        view.spellCheckingType = .no
        return view
    }

    func updateUIView(_ uiView: SwiftTerm.TerminalView, context: Context) {
        context.coordinator.applyTheme(isDarkMode: isDarkMode, to: uiView)
        context.coordinator.updateInputHandler(onInput)
        context.coordinator.apply(content: text, to: uiView)
        context.coordinator.updateFocus(enabled: canSendInput, on: uiView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, SwiftTerm.TerminalViewDelegate {
        private var lastRendered = ""
        private var onInput: ((String) -> Void)?
        private var autoFocused = false
        private var appliedPalette: TerminalPalette?

        func updateInputHandler(_ handler: @escaping (String) -> Void) {
            onInput = handler
        }

        func apply(content: String, to view: SwiftTerm.TerminalView) {
            guard content != lastRendered else { return }
            if content.hasPrefix(lastRendered) {
                let deltaStart = content.index(content.startIndex, offsetBy: lastRendered.count)
                let delta = String(content[deltaStart...])
                if !delta.isEmpty {
                    view.feed(text: delta)
                }
            } else {
                view.feed(text: "\u{001B}[2J\u{001B}[H")
                if !content.isEmpty {
                    view.feed(text: content)
                }
            }
            lastRendered = content
        }

        func applyTheme(isDarkMode: Bool, to view: SwiftTerm.TerminalView) {
            let palette = TerminalSurfaceRepresentable.palette(isDarkMode: isDarkMode)
            guard appliedPalette != palette else {
                return
            }
            appliedPalette = palette
            view.backgroundColor = palette.background
            view.nativeBackgroundColor = palette.background
            view.nativeForegroundColor = palette.foreground
        }

        func updateFocus(enabled: Bool, on view: SwiftTerm.TerminalView) {
            if enabled {
                if !autoFocused || !view.isFirstResponder {
                    autoFocused = true
                    DispatchQueue.main.async {
                        _ = view.becomeFirstResponder()
                    }
                }
            } else {
                autoFocused = false
                if view.isFirstResponder {
                    view.resignFirstResponder()
                }
            }
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

    private static func palette(isDarkMode: Bool) -> TerminalPalette {
        if isDarkMode {
            return TerminalPalette(
                background: UIColor(red: 0.05, green: 0.06, blue: 0.08, alpha: 1.0),
                foreground: UIColor(white: 0.95, alpha: 1.0)
            )
        }
        return TerminalPalette(
            background: UIColor(red: 0.96, green: 0.97, blue: 0.99, alpha: 1.0),
            foreground: UIColor(red: 0.10, green: 0.11, blue: 0.13, alpha: 1.0)
        )
    }
}
#endif
