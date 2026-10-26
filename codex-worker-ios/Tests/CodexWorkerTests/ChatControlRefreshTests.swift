import ComposableArchitecture
import Foundation
import Testing
@testable import CodexWorker

@MainActor
struct ChatControlRefreshTests {
    private func selected() -> ChatFeature.State {
        var state = ChatFeature.State()
        state.activeThread = Thread(threadId: "01a0d2a7-16ff-7082-9081-4c03f50b0e67",
            preview: nil, cwd: nil, createdAt: nil, updatedAt: nil, modelProvider: nil)
        state.isControlVisible = true
        state.inputText = "保留较新的草稿"
        state.composerTextRevision = "retained-revision"
        state.composerEditOrdinal = 525
        return state
    }

    // These tests reduce state only; no returned network or storage effect runs.
    @Test
    func quietReadDoesNotLockComposerOrStartAnotherRead() throws {
        var state = selected()
        let reducer = ChatFeature()
        _ = reducer.reduce(into: &state, action: .pollControl)
        #expect(state.isControlPolling && !state.isControlLoading && !state.isSending)
        _ = try #require(state.controlReadID)
        #expect(state.inputText == "保留较新的草稿" && state.composerEditOrdinal == 525)
        let reading = state
        _ = reducer.reduce(into: &state, action: .pollControl)
        #expect(state == reading)
    }

    @Test
    func hiddenOrBusyChatDoesNotPoll() {
        let reducer = ChatFeature()
        var hidden = selected()
        hidden.isControlVisible = false
        let beforeHidden = hidden
        _ = reducer.reduce(into: &hidden, action: .pollControl)
        #expect(hidden == beforeHidden)

        var sending = selected()
        sending.isSending = true
        sending.pendingControlID = "original-in-flight-submission"
        let beforeSending = sending
        _ = reducer.reduce(into: &sending, action: .pollControl)
        #expect(sending == beforeSending)

        var checking = selected()
        checking.isReceiptChecking = true
        let beforeChecking = checking
        _ = reducer.reduce(into: &checking, action: .pollControl)
        #expect(checking == beforeChecking)
    }

    @Test
    func hidingChatInvalidatesLateReadWithoutChangingDraft() throws {
        var state = selected()
        let reducer = ChatFeature()
        _ = reducer.reduce(into: &state, action: .pollControl)
        let readID = try #require(state.controlReadID)
        let identity = try #require(state.activeThread?.id)
        _ = reducer.reduce(into: &state, action: .controlVisibilityChanged(false))
        #expect(state.controlReadID == nil && !state.isControlPolling && !state.isControlLoading)
        #expect(state.inputText == "保留较新的草稿" && state.composerTextRevision == "retained-revision")
        let hidden = state
        _ = reducer.reduce(into: &state, action: .controlResponse(identity: identity,
            account: "not-consumed-for-invalidated-read", readID: readID, .failure(.timeout)))
        #expect(state == hidden)
    }

    @Test
    func manualReadSupersedesQuietReadAndIgnoresItsLateFailure() throws {
        var state = selected()
        let reducer = ChatFeature()
        _ = reducer.reduce(into: &state, action: .pollControl)
        let oldID = try #require(state.controlReadID)
        let identity = try #require(state.activeThread?.id)
        _ = reducer.reduce(into: &state, action: .refreshControl)
        #expect(state.isControlLoading && !state.isControlPolling)
        #expect(state.controlReadID != nil && state.controlReadID != oldID)
        let current = state
        _ = reducer.reduce(into: &state, action: .controlResponse(identity: identity,
            account: "not-consumed-for-superseded-read", readID: oldID, .failure(.timeout)))
        #expect(state == current)
    }
}
