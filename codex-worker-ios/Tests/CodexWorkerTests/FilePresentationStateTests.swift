import ComposableArchitecture
import Foundation
import Testing
@testable import CodexWorker

@MainActor
struct FilePresentationStateTests {
    @Test
    func oldTreeIdentityAndGenerationCannotBecomeCurrent() {
        let current = thread(namespace: "new")
        var state = FileBrowserFeature.State()
        state.activeThread = current
        state.currentPath = "/repo"
        state.treeRequestID = 4
        let response = FileTreeResponse(data: [], nextCursor: nil, hasMore: false, total: 0)
        let reducer = FileBrowserFeature()
        _ = reducer.reduce(into: &state, action: .loadTreeResponse(requestID: 4, threadIdentity: thread(namespace: "old").id, rootPath: "/repo", path: "/repo", cursor: nil, .success(response)))
        #expect(!state.hasTreeSnapshot)
        _ = reducer.reduce(into: &state, action: .loadTreeResponse(requestID: 3, threadIdentity: current.id, rootPath: "/repo", path: "/repo", cursor: nil, .success(response)))
        #expect(!state.hasTreeSnapshot)
        _ = reducer.reduce(into: &state, action: .loadTreeResponse(requestID: 4, threadIdentity: current.id, rootPath: "/repo", path: "/repo/other", cursor: nil, .success(response)))
        #expect(!state.hasTreeSnapshot)
        _ = reducer.reduce(into: &state, action: .loadTreeResponse(requestID: 4, threadIdentity: current.id, rootPath: "/repo", path: "/repo", cursor: nil, .success(response)))
        #expect(state.hasTreeSnapshot && state.treeSnapshotIsCurrent)
    }

    @Test
    func switchingThreadClearsLoadingAndNewDirectoryClearsOldPagination() {
        var state = FileBrowserFeature.State()
        state.isLoadingTree = true
        let reducer = FileBrowserFeature()
        _ = reducer.reduce(into: &state, action: .setActiveThread(thread(namespace: "new")))
        #expect(!state.isLoadingTree)
        state.treeNextCursor = 200
        state.treeHasMore = true
        _ = reducer.reduce(into: &state, action: .loadTree(path: "/repo/other", cursor: nil))
        #expect(state.isLoadingTree)
        #expect(state.treeNextCursor == nil && !state.treeHasMore)
        #expect(!state.hasTreeSnapshot && !state.treeSnapshotIsCurrent)
    }

    @Test
    func lateTreeCacheCannotReplaceCurrentButCanRecoverFailedFirstRead() {
        var state = FileBrowserFeature.State()
        let current = thread(namespace: "scope")
        state.activeThread = current
        state.currentPath = "/repo"
        state.treeRequestID = 1
        let reducer = FileBrowserFeature()
        let cache = FileTreeResponse(data: [.init(name: "old", path: "/repo/old", kind: .file, size: nil, modifiedAt: nil)], nextCursor: nil, hasMore: false, total: 1)
        state.treeSnapshotIsCurrent = true
        state.hasTreeSnapshot = true
        _ = reducer.reduce(into: &state, action: .loadTreeCacheResponse(requestID: 1, threadIdentity: current.id, rootPath: "/repo", path: "/repo", response: cache))
        #expect(state.entries.isEmpty && state.treeSnapshotIsCurrent)
        state.treeSnapshotIsCurrent = false
        state.hasTreeSnapshot = false
        state.errorMessage = "read failed"
        _ = reducer.reduce(into: &state, action: .loadTreeCacheResponse(requestID: 1, threadIdentity: current.id, rootPath: "/repo", path: "/repo", response: cache))
        #expect(state.entries.count == 1 && state.hasTreeSnapshot)
        #expect(!state.treeSnapshotIsCurrent && state.errorMessage == "read failed")
    }

    @Test
    func unreadFailureIsNotAnEmptyFileAndLateCacheCannotRollBackRemote() {
        let reducer = FileViewerFeature()
        var state = FileViewerFeature.State(threadId: "t", rootPath: "/repo", filePath: "/repo/a")
        _ = reducer.reduce(into: &state, action: .loadResponse(.failure(.timeout)))
        #expect(!state.hasContentSnapshot && state.errorMessage != nil)
        let empty = payload(text: nil, etag: "fresh")
        _ = reducer.reduce(into: &state, action: .loadResponse(.success(.init(data: empty))))
        #expect(state.hasContentSnapshot && state.content.isEmpty && state.totalLines == 0)
        _ = reducer.reduce(into: &state, action: .loadCacheResponse(.success(payload(text: "old", etag: "old"))))
        #expect(state.content.isEmpty && state.etag == "fresh" && state.originalContent.isEmpty)
    }

    @Test
    func actualTerminalGridAcceptsSmallAccessibleViewportAndIgnoresZero() {
        var state = TerminalFeature.State()
        let reducer = TerminalFeature()
        _ = reducer.reduce(into: &state, action: .measuredSizeChanged(cols: 23, rows: 5))
        #expect(state.viewportCols == 23 && state.viewportRows == 5)
        _ = reducer.reduce(into: &state, action: .measuredSizeChanged(cols: 0, rows: 8))
        #expect(state.viewportCols == 23 && state.viewportRows == 5)
    }

    private func thread(namespace: String) -> CodexWorker.Thread {
        var value = CodexWorker.Thread(threadId: "same-id", preview: nil, cwd: "/repo", createdAt: nil, updatedAt: nil, modelProvider: nil)
        value.origin = .init(namespace: namespace, hostID: nil)
        return value
    }

    private func payload(text: String?, etag: String) -> FileContentPayload {
        .init(path: "/repo/a", language: "text", etag: etag, totalLines: text == nil ? 0 : 1, fromLine: 1, toLine: text == nil ? 0 : 1, truncated: false,
              lines: text.map { [.init(line: 1, text: $0)] } ?? [])
    }
}
