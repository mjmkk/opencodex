import ComposableArchitecture
import Foundation
import Testing
@testable import CodexWorker

@MainActor
struct ChatHistoryPresentationTests {
    @Test
    func historyWithoutDeliveryOrSentTimeDoesNotInventEither() {
        var state = ChatFeature.State()
        let thread = CodexWorker.Thread(threadId: "history", preview: nil, cwd: nil, createdAt: nil, updatedAt: nil, modelProvider: nil)
        state.activeThread = thread
        let history = ThreadHistory(threadIdentity: thread.id,
            messages: [.init(id: "native-message", role: "user", text: "original text", sentAt: nil)],
            records: [], attachments: [], downloadedAt: .distantFuture, isPartial: true, hasMore: false,
            availableMessageCount: 40, refreshRequested: false)
        _ = ChatFeature().reduce(into: &state, action: .historyResponse(identity: thread.id, cached: true, .success(history)))
        #expect(state.messages.count == 1)
        #expect(state.messages[0].text == "original text")
        #expect(state.messages[0].status == nil)
        #expect(state.messages[0].createdAt == .distantPast)
        #expect(state.history?.isPartial == true)
    }
}
