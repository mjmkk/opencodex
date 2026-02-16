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

    public init(store: StoreOf<AppFeature>) {
        self.store = store
    }

    public var body: some View {
        NavigationStack {
            Group {
                if viewStore.activeThread == nil {
                    ThreadsView(
                        store: store.scope(
                            state: \.threads,
                            action: \.threads
                        )
                    )
                } else {
                    VStack(spacing: 0) {
                        ThreadsView(
                            store: store.scope(
                                state: \.threads,
                                action: \.threads
                            )
                        )
                        .frame(maxHeight: 280)

                        Divider()

                        CodexChatView(
                            store: store.scope(
                                state: \.chat,
                                action: \.chat
                            )
                        )
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
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
    }

    private var viewStore: ViewStoreOf<AppFeature> {
        ViewStore(self.store, observe: { $0 })
    }
}
