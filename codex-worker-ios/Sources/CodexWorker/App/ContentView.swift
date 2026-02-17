//
//  ContentView.swift
//  CodexWorker
//
//  根界面（里程碑 3）
//

import ComposableArchitecture
import SwiftUI

public struct ContentView: View {
    @Environment(\.colorScheme) private var colorScheme

    private struct ViewState: Equatable {
        let connectionState: ConnectionState
        let executionAccessMode: ExecutionAccessMode
        let isDrawerPresented: Bool
        let isApprovalPresented: Bool

        init(_ state: AppFeature.State) {
            self.connectionState = state.connectionState
            self.executionAccessMode = state.executionAccessMode
            self.isDrawerPresented = state.isDrawerPresented
            self.isApprovalPresented = state.approval.isPresented
        }
    }

    public let store: StoreOf<AppFeature>
    @State private var isSettingsPresented = false

    public init(store: StoreOf<AppFeature>) {
        self.store = store
    }

    public var body: some View {
        WithViewStore(store, observe: ViewState.init) { viewStore in
            GeometryReader { geometry in
                let drawerWidth = min(geometry.size.width * 0.84, 360)

                ZStack(alignment: .leading) {
                    CodexChatView(
                        store: store.scope(
                            state: \.chat,
                            action: \.chat
                        ),
                        connectionState: viewStore.connectionState,
                        onSidebarTap: {
                            viewStore.send(.setDrawerPresented(true))
                        },
                        onSettingsTap: {
                            isSettingsPresented = true
                        },
                        executionAccessMode: viewStore.executionAccessMode,
                        onExecutionAccessModeChanged: { mode in
                            viewStore.send(.setExecutionAccessMode(mode))
                        }
                    )
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
        }
    }

    private var drawerMaskOpacity: Double {
        colorScheme == .dark ? 0.34 : 0.18
    }

    private var drawerShadowColor: Color {
        Color.black.opacity(colorScheme == .dark ? 0.26 : 0.15)
    }
}
