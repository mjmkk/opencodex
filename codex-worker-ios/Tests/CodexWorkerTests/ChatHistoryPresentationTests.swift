import ComposableArchitecture
import Foundation
import Testing
@testable import CodexWorker

@MainActor
struct ChatHistoryPresentationTests {
    @Test
    func lateFirstPageCannotReplaceCompletedHistoryFromEitherReader() {
        let complete = history("same", count: 475, next: nil)
        let lateFirstPage = history("same", count: 100, next: 100)
        for cached in [true, false] {
            var state = state(showing: complete)
            state.isHistorySyncing = true
            state.errorMessage = "previous failure"
            var accepted = state
            if !cached {
                accepted.isHistorySyncing = false
                accepted.errorMessage = nil
            }
            _ = ChatFeature().reduce(into: &state,
                action: .historyResponse(identity: complete.threadIdentity, cached: cached, .success(lateFirstPage)))
            #expect(state == accepted)
        }
    }

    @Test
    func latePartialPageCannotReplaceFurtherReadableProgress() {
        let current = history("same", count: 200, next: 200)
        var state = state(showing: current)
        let accepted = state
        _ = ChatFeature().reduce(into: &state,
            action: .historyResponse(identity: current.threadIdentity, cached: true,
                .success(history("same", count: 100, next: 100))))
        #expect(state == accepted)
    }

    @Test
    func furtherProgressAndDifferentSnapshotRemainReadable() {
        let first = history("same", count: 100, next: 100)
        var state = state(showing: first)
        let complete = history("same", count: 475, next: nil)
        _ = ChatFeature().reduce(into: &state,
            action: .historyResponse(identity: first.threadIdentity, cached: true, .success(complete)))
        #expect(state.history == complete)
        #expect(state.messages.count == 475)
        // A replacement snapshot may contain fewer records; counts do not establish recency.
        let replacement = history("replacement", count: 3, next: nil)
        _ = ChatFeature().reduce(into: &state,
            action: .historyResponse(identity: first.threadIdentity, cached: false, .success(replacement)))
        #expect(state.history == replacement)
        #expect(state.messages.count == 3)
    }

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

    private func state(showing history: ThreadHistory) -> ChatFeature.State {
        var state = ChatFeature.State()
        var thread = CodexWorker.Thread(threadId: "history", preview: nil, cwd: nil,
            createdAt: nil, updatedAt: nil, modelProvider: nil)
        thread.origin = .init(namespace: "source", hostID: nil)
        state.activeThread = thread
        _ = ChatFeature().reduce(into: &state,
            action: .historyResponse(identity: thread.id, cached: true, .success(history)))
        return state
    }

    private func history(_ snapshot: String, count: Int, next: Int?) -> ThreadHistory {
        MirrorCachedBody(body: MirrorBody(ok: true, namespace: "source", source: "local_mirror",
            thread: MirrorThread(thread_id: "history", content_coverage: .string("partial")),
            messages: (0..<count).map {
                MirrorMessage(native_id: "message-\($0)", role: "assistant", text_content: "record \($0)")
            }, items: [], attachments: [],
            page: MirrorPage(offset: 0, limit: 100, local_total: 475,
                snapshot: snapshot, next_offset: next, scope: "local_only")),
            downloadedAt: next == nil ? .distantFuture : .distantPast).history
    }
}
