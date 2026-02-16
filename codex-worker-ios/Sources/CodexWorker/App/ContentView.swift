//
//  ContentView.swift
//  CodexWorker
//
//  根界面（里程碑 3）
//

import ComposableArchitecture
import SwiftUI

public struct ContentView: View {
    public let store: StoreOf<AppFeature>
    @State private var isSettingsPresented = false

    public init(store: StoreOf<AppFeature>) {
        self.store = store
    }

    public var body: some View {
        WithViewStore(store, observe: { $0 }) { viewStore in
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
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(!viewStore.isDrawerPresented)

                    if viewStore.isDrawerPresented {
                        Color.black.opacity(0.18)
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
                        }
                    )
                    .frame(width: drawerWidth)
                    .background(.ultraThinMaterial)
                    .offset(x: viewStore.isDrawerPresented ? 0 : (-drawerWidth - 12))
                    .shadow(color: Color.black.opacity(0.15), radius: 12, x: 4, y: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.spring(response: 0.28, dampingFraction: 0.9), value: viewStore.isDrawerPresented)
            }
            .safeAreaInset(edge: .bottom) {
                if viewStore.approval.isPresented {
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
}
