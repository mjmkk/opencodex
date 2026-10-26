import ComposableArchitecture
import Foundation

extension ChatFeature {
    static func readControl(_ thread: Thread, readID: String) -> Effect<Action> {
        guard let configuration = WorkerConfiguration.load() else {
            return .send(.controlResponse(identity: thread.id, account: "", readID: readID, .failure(.notConfigured)))
        }
        let account = MobileSyncEngine.scope(configuration: configuration)
        return .run { send in
            @Dependency(\.apiClient) var api
            do {
                let observation = try await api.nativeControl(thread, configuration)
                guard observation.validates(thread: thread) else { throw CodexError.invalidState }
                await send(.controlResponse(identity: thread.id, account: account, readID: readID, .success(observation)))
            } catch {
                await send(.controlResponse(identity: thread.id, account: account, readID: readID, .failure(CodexError.from(error))))
            }
        }
    }

    static func beginControl(state: inout State, operation: NativeControlOperation, text: String) -> Effect<Action> {
        guard let thread = state.activeThread, let shown = state.controlObservation,
              let configuration = WorkerConfiguration.load(),
              operation == .input ? state.canSend : state.canStop,
              operation != .input || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let editOrdinal = state.composerEditOrdinal,
              let cache = MobileSyncCache.shared else {
            state.controlMessage = "当前操作尚不可用，草稿已保留。请先核对执行状态。"
            return .none
        }
        let account = MobileSyncEngine.scope(configuration: configuration)
        let scope = MobileSyncEngine.threadScope(for: thread, configuration: configuration)
        // The cache binds legacy drafts before hydration. Capture the exact
        // displayed edit; never allocate a newer order for an old operation.
        if state.composerTextRevision == nil { state.composerTextRevision = UUID().uuidString }
        if state.composerEditedAt == nil { state.composerEditedAt = Date() }
        let textRevision = state.composerTextRevision
        let editedAt = state.composerEditedAt
        let id = UUID().uuidString
        // A read started before this write must not overwrite its later state.
        state.controlReadID = nil; state.isControlPolling = false
        state.isSending = true; state.pendingControlOperation = operation; state.pendingControlID = id
        state.isReceiptChecking = false
        state.controlMessage = nil
        // This effect deliberately survives switching tasks. Its endpoint,
        // original identity and cache scope remain fixed through reconciliation.
        return .run { send in
            @Dependency(\.apiClient) var api
            var committed = false
            do {
                let current = try await api.nativeControl(thread, configuration)
                guard current.validates(thread: thread), current.executionContext == shown.executionContext,
                      WorkerConfiguration.load() == configuration,
                      operation == .input ? current.canInput
                        : current.canStop && current.active_turn_id == shown.active_turn_id else { throw CodexError.invalidState }
                let body = NativeControlWriteBody(submission_id: id, control_receipt: current.control_receipt,
                    control_version: current.control_version, text: operation == .input ? text : nil,
                    expected_turn_id: operation == .interrupt ? shown.active_turn_id : nil)
                let attempt = NativeControlAttempt(operation: operation, request: body, attemptedAt: Date(),
                    executionContext: current.executionContext, accountScope: account)
                let saved = try await cache.beginControlAttempt(attempt, text: text,
                    textRevision: textRevision, editedAt: editedAt, editOrdinal: editOrdinal,
                    threadId: thread.threadId, scope: scope)
                committed = true
                await send(.controlWillWrite(identity: thread.id, account: account, operationID: id, saved))
                guard WorkerConfiguration.load() == configuration else {
                    let retained = try await cache.reconcileControlAttempt(id: id, localRejection: "CONNECTION_CHANGED_BEFORE_WRITE",
                        threadId: thread.threadId, scope: scope)
                    await send(.controlFinished(identity: thread.id, account: account, operationID: id, .success(retained)))
                    return
                }
                let receipt = try await api.submitNativeControl(thread.threadId, operation, body, configuration)
                guard attempt.validates(receipt, threadID: thread.threadId) else { throw CodexError.invalidState }
                let retained = try await cache.reconcileControlAttempt(id: id, receipt: receipt, threadId: thread.threadId, scope: scope)
                await send(.controlFinished(identity: thread.id, account: account, operationID: id, .success(retained)))
            } catch {
                if committed {
                    // A transport/parse/cancellation failure after intent is
                    // unknown. Only an explicit server preflight rejection is
                    // known not to have written; neither path auto-resends.
                    do {
                        let retained = try await cache.reconcileControlAttempt(id: id,
                            localRejection: definiteControlRejection(CodexError.from(error)),
                            threadId: thread.threadId, scope: scope)
                        await send(.controlFinished(identity: thread.id, account: account, operationID: id, .success(retained)))
                    } catch {
                        await send(.controlFinished(identity: thread.id, account: account, operationID: id, .failure(CodexError.from(error))))
                    }
                } else {
                    await send(.controlFinished(identity: thread.id, account: account, operationID: id, .failure(CodexError.from(error))))
                }
            }
        }
    }

    static func checkControl(_ thread: Thread, attempt: NativeControlAttempt) -> Effect<Action> {
        guard let configuration = WorkerConfiguration.load(), let cache = MobileSyncCache.shared else { return .none }
        let account = MobileSyncEngine.scope(configuration: configuration)
        let scope = MobileSyncEngine.threadScope(for: thread, configuration: configuration)
        let id = attempt.request.submission_id
        return .run { send in
            @Dependency(\.apiClient) var api
            do {
                guard attempt.accountScope == nil || attempt.accountScope == account,
                      attempt.executionContext == nil || attempt.executionContext?.validates(thread: thread) == true
                else { throw CodexError.invalidState }
                if let retained = try await cache.composer(threadId: thread.threadId, scope: scope),
                   let known = retained.controlAttempt,
                   known.request.submission_id == id, !known.isUncertain {
                    await send(.controlFinished(identity: thread.id, account: account, operationID: id, .success(retained)))
                    return
                }
                let receipt = try await api.nativeControlReceipt(thread.threadId, id, configuration)
                guard attempt.validates(receipt, threadID: thread.threadId) else { throw CodexError.invalidState }
                let retained = try await cache.reconcileControlAttempt(id: id, receipt: receipt, threadId: thread.threadId, scope: scope)
                await send(.controlFinished(identity: thread.id, account: account, operationID: id, .success(retained)))
            } catch {
                // 404, a changed owner, or an idle observation does not prove
                // that the original uncertain write was never delivered.
                await send(.controlFinished(identity: thread.id, account: account, operationID: id, .failure(CodexError.from(error))))
            }
        }
    }

    private static func definiteControlRejection(_ error: CodexError) -> String? {
        if case .unauthorized = error { return "UNAUTHORIZED_BEFORE_WRITE" }
        if case let .apiError(code, _) = error,
           ["INVALID_NATIVE_CONTROL", "NATIVE_CONTROL_CHANGED", "NATIVE_THREAD_NOT_CONFIGURED",
            "NATIVE_OWNER_UNAVAILABLE", "NATIVE_CONTROL_UNAVAILABLE", "NATIVE_SUBMISSION_ID_CONFLICT"].contains(code) {
            return code
        }
        return nil
    }
}
