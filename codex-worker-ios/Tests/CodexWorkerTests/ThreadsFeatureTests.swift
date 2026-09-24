import ComposableArchitecture
import Foundation
import Testing
@testable import CodexWorker

@MainActor
struct ThreadsFeatureTests {
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
