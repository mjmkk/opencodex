//
//  FileViewerFeature.swift
//  CodexWorker
//
//  文件查看与编辑
//

import ComposableArchitecture
import Foundation

@Reducer
public struct FileViewerFeature {
    @ObservableState
    public struct State: Equatable {
        public var threadId: String
        public var rootPath: String
        public var filePath: String
        public var focusLine: Int?

        public var isLoading = false
        public var isSaving = false
        public var language = "text"
        public var etag = ""
        public var totalLines = 0

        public var content = ""
        public var originalContent = ""
        public var revisions: [CachedFileRevision] = []
        public var showDiff = false
        public var isEditing = false
        public var exitEditingAfterSave = false
        public var errorMessage: String?

        public init(
            threadId: String,
            rootPath: String,
            filePath: String,
            focusLine: Int? = nil
        ) {
            self.threadId = threadId
            self.rootPath = rootPath
            self.filePath = filePath
            self.focusLine = focusLine
        }

        public var isDirty: Bool {
            content != originalContent
        }

        public var diffPreview: String {
            makeSimpleDiff(oldText: originalContent, newText: content)
        }
    }

    public enum Action {
        case onAppear
        case refresh
        case loadCacheResponse(Result<FileContentPayload?, CodexError>)
        case loadResponse(Result<FileContentResponse, CodexError>)
        case revisionsResponse(Result<[CachedFileRevision], CodexError>)
        case contentChanged(String)
        case saveTapped
        case saveAndExitTapped
        case saveResponse(Result<FileWriteResponse, CodexError>)
        case cancelEditingTapped
        case setEditing(Bool)
        case toggleDiff(Bool)
        case restoreRevision(CachedFileRevision)
        case openInTerminalTapped
        case clearError
        case delegate(Delegate)
    }

    public enum Delegate: Equatable {
        case openInTerminal(path: String)
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                return .merge(
                    .send(.refresh),
                    .run { [path = state.filePath] send in
                        @Dependency(\.fileSystemStore) var fileSystemStore
                        await send(
                            .revisionsResponse(
                                Result {
                                    try await fileSystemStore.listRevisions(path, 20)
                                }.mapError { CodexError.from($0) }
                            )
                        )
                    }
                )

            case .refresh:
                state.isLoading = true
                state.errorMessage = nil
                let threadId = state.threadId
                let filePath = state.filePath
                let rootPath = state.rootPath
                return .merge(
                    .run { send in
                        @Dependency(\.fileSystemStore) var fileSystemStore
                        await send(
                            .loadCacheResponse(
                                Result {
                                    try await fileSystemStore.loadLatestFileChunkCache(rootPath, filePath)
                                }.mapError { CodexError.from($0) }
                            )
                        )
                    },
                    .run { send in
                        @Dependency(\.apiClient) var apiClient
                        await send(
                            .loadResponse(
                                Result {
                                    try await apiClient.getThreadFsFile(threadId, filePath, 1, 2_000_000)
                                }.mapError { CodexError.from($0) }
                            )
                        )
                    }
                )

            case .loadCacheResponse(.success(let payload)):
                guard let payload else { return .none }
                state.language = payload.language
                state.etag = payload.etag
                state.totalLines = payload.totalLines
                state.content = payload.fullText
                state.originalContent = payload.fullText
                return .none

            case .loadCacheResponse(.failure):
                return .none

            case .loadResponse(.success(let response)):
                state.isLoading = false
                state.language = response.data.language
                state.etag = response.data.etag
                state.totalLines = response.data.totalLines
                state.content = response.data.fullText
                state.originalContent = response.data.fullText
                state.errorMessage = nil

                let rootPath = state.rootPath
                let payload = response.data
                return .run { send in
                    @Dependency(\.fileSystemStore) var fileSystemStore
                    do {
                        try await fileSystemStore.saveFileChunkCache(rootPath, payload)
                        try await fileSystemStore.saveRevision(payload.path, payload.etag, payload.fullText)
                        let revisions = try await fileSystemStore.listRevisions(payload.path, 20)
                        await send(.revisionsResponse(.success(revisions)))
                    } catch {
                        await send(.revisionsResponse(.failure(CodexError.from(error))))
                    }
                }

            case .loadResponse(.failure(let error)):
                state.isLoading = false
                if state.content.isEmpty {
                    state.errorMessage = error.localizedDescription
                } else {
                    state.errorMessage = "远端刷新失败，已展示本地缓存：\(error.localizedDescription)"
                }
                return .none

            case .revisionsResponse(.success(let revisions)):
                state.revisions = revisions
                if state.content.isEmpty, let revision = revisions.first {
                    state.content = revision.content
                    state.originalContent = revision.content
                    state.etag = revision.etag
                }
                return .none

            case .revisionsResponse(.failure(let error)):
                if state.content.isEmpty {
                    state.errorMessage = error.localizedDescription
                }
                return .none

            case .contentChanged(let content):
                state.content = content
                return .none

            case .saveTapped:
                guard !state.isSaving else { return .none }
                state.isSaving = true
                state.exitEditingAfterSave = false
                state.errorMessage = nil
                let request = FileWriteRequest(path: state.filePath, content: state.content, expectedEtag: state.etag)
                let threadId = state.threadId
                return .run { send in
                    @Dependency(\.apiClient) var apiClient
                    await send(
                        .saveResponse(
                            Result {
                                try await apiClient.writeThreadFsFile(threadId, request)
                            }.mapError { CodexError.from($0) }
                        )
                    )
                }

            case .saveAndExitTapped:
                guard !state.isSaving else { return .none }
                guard state.isDirty else {
                    state.isEditing = false
                    return .none
                }
                state.isSaving = true
                state.exitEditingAfterSave = true
                state.errorMessage = nil
                let request = FileWriteRequest(path: state.filePath, content: state.content, expectedEtag: state.etag)
                let threadId = state.threadId
                return .run { send in
                    @Dependency(\.apiClient) var apiClient
                    await send(
                        .saveResponse(
                            Result {
                                try await apiClient.writeThreadFsFile(threadId, request)
                            }.mapError { CodexError.from($0) }
                        )
                    )
                }

            case .saveResponse(.success(let response)):
                state.isSaving = false
                state.etag = response.data.etag
                state.originalContent = state.content
                if state.exitEditingAfterSave {
                    state.isEditing = false
                    state.showDiff = false
                }
                state.exitEditingAfterSave = false
                state.errorMessage = nil
                let path = state.filePath
                let etag = state.etag
                let content = state.content
                return .run { send in
                    @Dependency(\.fileSystemStore) var fileSystemStore
                    do {
                        try await fileSystemStore.saveRevision(path, etag, content)
                        let revisions = try await fileSystemStore.listRevisions(path, 20)
                        await send(.revisionsResponse(.success(revisions)))
                    } catch {
                        await send(.revisionsResponse(.failure(CodexError.from(error))))
                    }
                }

            case .saveResponse(.failure(let error)):
                state.isSaving = false
                state.exitEditingAfterSave = false
                state.errorMessage = error.localizedDescription
                return .none

            case .cancelEditingTapped:
                state.content = state.originalContent
                state.isEditing = false
                state.showDiff = false
                state.exitEditingAfterSave = false
                return .none

            case .setEditing(let isEditing):
                state.isEditing = isEditing
                if isEditing {
                    state.showDiff = false
                }
                return .none

            case .toggleDiff(let show):
                state.showDiff = show
                if show {
                    state.isEditing = false
                }
                return .none

            case .restoreRevision(let revision):
                state.content = revision.content
                state.showDiff = false
                return .none

            case .openInTerminalTapped:
                let directoryPath = URL(fileURLWithPath: state.filePath).deletingLastPathComponent().path
                return .send(.delegate(.openInTerminal(path: directoryPath)))

            case .clearError:
                state.errorMessage = nil
                return .none

            case .delegate:
                return .none
            }
        }
    }
}

/// 生成简单的逐行位置对比（非 LCS diff）。
/// 注意：此实现按行号逐一对比，顶部插入一行会导致所有后续行显示为变更。
/// 如需精确 diff，应替换为 Myers diff 或 LCS 算法。
private func makeSimpleDiff(oldText: String, newText: String) -> String {
    let oldLines = oldText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let newLines = newText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let maxCount = max(oldLines.count, newLines.count)

    var output: [String] = []
    output.reserveCapacity(maxCount * 2)

    for index in 0 ..< maxCount {
        let oldLine = index < oldLines.count ? oldLines[index] : nil
        let newLine = index < newLines.count ? newLines[index] : nil

        switch (oldLine, newLine) {
        case let (old?, new?) where old == new:
            output.append("  \(old)")
        case let (old?, new?):
            output.append("- \(old)")
            output.append("+ \(new)")
        case let (old?, nil):
            output.append("- \(old)")
        case let (nil, new?):
            output.append("+ \(new)")
        case (nil, nil):
            break
        }
    }

    return output.joined(separator: "\n")
}
