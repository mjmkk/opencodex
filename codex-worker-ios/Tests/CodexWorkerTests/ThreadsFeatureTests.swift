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
            apiClient.listThreads = { _ in response }
            dependencies.apiClient = apiClient
            dependencies.threadHistoryStore = .testValue
        }
        store.exhaustivity = .off

        await store.send(.onAppear) {
            $0.isLoading = true
            $0.errorMessage = nil
        }
        await store.receive({ action in
            if case .loadResponse(.success(let value)) = action {
                return value.nextCursor == response.nextCursor &&
                    value.data.map(\.threadId) == response.data.map(\.threadId)
            }
            return false
        }) {
            $0.isLoading = false
            $0.items = response.data
            $0.selectedThreadId = "thread_recent"
        }
        await store.receive({ action in
            if case .delegate(.didActivateThread(let thread)) = action {
                return thread.threadId == recent.threadId
            }
            return false
        })
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

    @Test
    func archiveSelectedThreadFallsBackToNextThread() async {
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

        var state = ThreadsFeature.State()
        state.items = [recent, older]
        state.selectedThreadId = "thread_recent"

        let store = TestStore(initialState: state) {
            ThreadsFeature()
        } withDependencies: { dependencies in
            var apiClient = APIClient.mock
            apiClient.archiveThread = { threadId in
                ArchiveThreadResponse(threadId: threadId, status: "archived")
            }
            dependencies.apiClient = apiClient
            dependencies.threadHistoryStore = .testValue
        }

        await store.send(.archiveTapped("thread_recent")) {
            $0.archivingThreadIds.insert("thread_recent")
            $0.errorMessage = nil
        }

        await store.receive({ action in
            if case .archiveResponse(let threadId, .success(let response)) = action {
                return threadId == "thread_recent" &&
                    response.threadId == "thread_recent" &&
                    response.status == "archived"
            }
            return false
        }) {
            $0.archivingThreadIds.remove("thread_recent")
            $0.items = [older]
            $0.selectedThreadId = "thread_old"
        }

        await store.receive({ action in
            if case .delegate(.didActivateThread(let thread)) = action {
                return thread.threadId == older.threadId
            }
            return false
        })
    }
}
