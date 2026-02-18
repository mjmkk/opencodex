import ComposableArchitecture
import Foundation
import Testing
@testable import CodexWorker

@MainActor
struct ThreadsFeatureTests {
    @Test
    func onAppearAutoActivatesMostRecentThread() async {
        let recent = Thread(
            threadId: "thread_recent",
            preview: "recent",
            cwd: "/repo/recent",
            createdAt: "2026-02-18T09:00:00.000Z",
            updatedAt: "2026-02-18T11:00:00.000Z",
            modelProvider: "openai"
        )
        let older = Thread(
            threadId: "thread_old",
            preview: "old",
            cwd: "/repo/old",
            createdAt: "2026-02-18T07:00:00.000Z",
            updatedAt: "2026-02-18T08:00:00.000Z",
            modelProvider: "openai"
        )
        let response = ThreadsListResponse(
            data: [older, recent],
            nextCursor: nil
        )

        let store = TestStore(initialState: ThreadsFeature.State()) {
            ThreadsFeature()
        } withDependencies: { dependencies in
            var apiClient = APIClient.mock
            apiClient.listThreads = { response }
            dependencies.apiClient = apiClient
            dependencies.threadHistoryStore = .testValue
        }
        store.exhaustivity = .off

        await store.send(.onAppear) {
            $0.isLoading = true
            $0.errorMessage = nil
        }
        await store.receive(.loadResponse(.success(response))) {
            $0.isLoading = false
            $0.items = response.data
            $0.selectedThreadId = "thread_recent"
        }
        await store.receive(.delegate(.didActivateThread(recent)))
    }

    @Test
    func cwdGroupsSortByGroupRecencyThenPath() {
        var state = ThreadsFeature.State()
        state.items = [
            Thread(
                threadId: "t1",
                preview: "A-old",
                cwd: "/repo/A",
                createdAt: "2026-02-18T08:00:00.000Z",
                updatedAt: "2026-02-18T08:00:00.000Z",
                modelProvider: "openai"
            ),
            Thread(
                threadId: "t2",
                preview: "B-new",
                cwd: "/repo/B",
                createdAt: "2026-02-18T11:00:00.000Z",
                updatedAt: "2026-02-18T11:00:00.000Z",
                modelProvider: "openai"
            ),
            Thread(
                threadId: "t3",
                preview: "No-cwd-mid",
                cwd: nil,
                createdAt: "2026-02-18T10:00:00.000Z",
                updatedAt: "2026-02-18T10:00:00.000Z",
                modelProvider: "openai"
            ),
        ]

        let groups = state.cwdGroups
        #expect(groups.count == 3)
        #expect(groups[0].id == "/repo/B")
        #expect(groups[1].id == "__no_cwd__")
        #expect(groups[2].id == "/repo/A")
    }
}
