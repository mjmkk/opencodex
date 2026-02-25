//
//  ContentView.swift
//  CodexWorker
//
//  根界面（里程碑 3）
//

import ComposableArchitecture
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

public struct ContentView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase

    private struct ViewState: Equatable {
        let connectionState: ConnectionState
        let executionAccessMode: ExecutionAccessMode
        let isDrawerPresented: Bool
        let isApprovalPresented: Bool
        let isTerminalPresented: Bool
        let isFileBrowserPresented: Bool
        let terminalHeightRatio: Double

        init(_ state: AppFeature.State) {
            self.connectionState = state.connectionState
            self.executionAccessMode = state.executionAccessMode
            self.isDrawerPresented = state.isDrawerPresented
            self.isApprovalPresented = state.approval.isPresented
            self.isTerminalPresented = state.terminal.isPresented
            self.isFileBrowserPresented = state.isFileBrowserPresented
            self.terminalHeightRatio = state.terminal.heightRatio
        }
    }

    public let store: StoreOf<AppFeature>
    @State private var isSettingsPresented = false
    @State private var terminalDragStartRatio: Double?

    public init(store: StoreOf<AppFeature>) {
        self.store = store
    }

    public var body: some View {
        WithViewStore(store, observe: ViewState.init) { viewStore in
            GeometryReader { geometry in
                let drawerWidth = min(geometry.size.width * 0.84, 360)
                let rawTerminalHeight = geometry.size.height * viewStore.terminalHeightRatio
                let terminalHeight = min(max(rawTerminalHeight, 220), geometry.size.height * 0.72)

                ZStack(alignment: .leading) {
                    VStack(spacing: 0) {
                        CodexChatView(
                            store: store.scope(
                                state: \.chat,
                                action: \.chat
                            ),
                            connectionState: viewStore.connectionState,
                            onSidebarTap: {
                                viewStore.send(.setDrawerPresented(true))
                            },
                            onFileBrowserTap: {
                                viewStore.send(.setFileBrowserPresented(true))
                            },
                            onSettingsTap: {
                                isSettingsPresented = true
                            },
                            executionAccessMode: viewStore.executionAccessMode,
                            onExecutionAccessModeChanged: { mode in
                                viewStore.send(.setExecutionAccessMode(mode))
                            },
                            isTerminalPresented: viewStore.isTerminalPresented,
                            onTerminalToggle: {
                                viewStore.send(.terminal(.togglePresented))
                            },
                            onOpenFileReference: { ref in
                                viewStore.send(.openFileReference(ref))
                            }
                        )

                        if viewStore.isTerminalPresented {
                            VStack(spacing: 0) {
                                Capsule()
                                    .fill(Color.secondary.opacity(0.45))
                                    .frame(width: 42, height: 5)
                                    .padding(.top, 7)
                                    .padding(.bottom, 7)
                                    .contentShape(Rectangle())
                                    .gesture(
                                        DragGesture(minimumDistance: 8)
                                            .onChanged { value in
                                                if terminalDragStartRatio == nil {
                                                    terminalDragStartRatio = viewStore.terminalHeightRatio
                                                }
                                                let baselineRatio = terminalDragStartRatio ?? viewStore.terminalHeightRatio
                                                let deltaRatio = -value.translation.height / max(geometry.size.height, 1)
                                                let clamped = min(max(baselineRatio + deltaRatio, 0.35), 0.72)
                                                if abs(clamped - viewStore.terminalHeightRatio) >= 0.002 {
                                                    viewStore.send(.terminal(.binding(.set(\.heightRatio, clamped))))
                                                }
                                            }
                                            .onEnded { _ in
                                                terminalDragStartRatio = nil
                                            }
                                    )

                                TerminalView(
                                    store: store.scope(
                                        state: \.terminal,
                                        action: \.terminal
                                    )
                                )
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .frame(height: terminalHeight)
                            .transition(
                                .move(edge: .bottom)
                                .combined(with: .opacity)
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(!viewStore.isDrawerPresented)

                    if viewStore.isDrawerPresented {
                        Color.black.opacity(drawerMaskOpacity)
                            .ignoresSafeArea()
                            .onTapGesture {
                                viewStore.send(.setDrawerPresented(false))
                            }
                    }

                    ThreadsView(
                        store: store.scope(
                            state: \.threads,
                            action: \.threads
                        ),
                        onDismiss: {
                            viewStore.send(.setDrawerPresented(false))
                        },
                        executionAccessMode: viewStore.executionAccessMode,
                        onExecutionAccessModeChanged: { mode in
                            viewStore.send(.setExecutionAccessMode(mode))
                        }
                    )
                    .frame(width: drawerWidth)
                    .background(.ultraThinMaterial)
                    .offset(x: viewStore.isDrawerPresented ? 0 : (-drawerWidth - 12))
                    .shadow(color: drawerShadowColor, radius: 12, x: 4, y: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.spring(response: 0.28, dampingFraction: 0.9), value: viewStore.isDrawerPresented)
            }
            .safeAreaInset(edge: .bottom) {
                if viewStore.isApprovalPresented {
                    ApprovalSheetView(
                        store: store.scope(
                            state: \.approval,
                            action: \.approval
                        )
                    )
                }
            }
            .onChange(of: viewStore.isTerminalPresented) { _, isPresented in
                if isPresented {
                    dismissKeyboard()
                }
            }
            .onChange(of: scenePhase) { _, newValue in
                let lifecycle: AppFeature.LifecycleState
                switch newValue {
                case .active:
                    lifecycle = .active
                case .inactive:
                    lifecycle = .inactive
                case .background:
                    lifecycle = .background
                @unknown default:
                    lifecycle = .inactive
                }
                viewStore.send(.lifecycleChanged(lifecycle))
            }
            .onAppear { viewStore.send(.onAppear) }
            .onDisappear { viewStore.send(.onDisappear) }
            .sheet(isPresented: $isSettingsPresented) {
                SettingsSheetView(
                    store: store.scope(
                        state: \.settings,
                        action: \.settings
                    ),
                    connectionState: viewStore.connectionState,
                    onClose: {
                        isSettingsPresented = false
                    }
                )
            }
            .sheet(
                isPresented: Binding(
                    get: { viewStore.isFileBrowserPresented },
                    set: { viewStore.send(.setFileBrowserPresented($0)) }
                )
            ) {
                FileBrowserView(
                    store: store.scope(
                        state: \.fileBrowser,
                        action: \.fileBrowser
                    ),
                    onClose: {
                        viewStore.send(.setFileBrowserPresented(false))
                    }
                )
            }
        }
    }

    private var drawerMaskOpacity: Double {
        colorScheme == .dark ? 0.34 : 0.18
    }

    private var drawerShadowColor: Color {
        Color.black.opacity(colorScheme == .dark ? 0.26 : 0.15)
    }

    private func dismissKeyboard() {
#if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
#endif
    }
}
