//
//  FileBrowserFeature.swift
//  CodexWorker
//
//  文件树浏览 + 搜索 + 文件查看路由
//

import ComposableArchitecture
import Foundation

@Reducer
public struct FileBrowserFeature {
    @ObservableState
    public struct State: Equatable {
        public var activeThread: Thread?

        public var currentPath: String = "."
        public var entries: [FileTreeEntry] = []
        public var treeNextCursor: Int?
        public var treeHasMore = false
        public var isLoadingTree = false

        public var searchQuery = ""
        public var searchResults: [FileSearchMatch] = []
        public var searchNextCursor: Int?
        public var searchHasMore = false
        public var isSearching = false

        public var errorMessage: String?
        public var viewer: FileViewerFeature.State?

        public init() {}

        public var canLoadMoreTree: Bool {
            treeHasMore && treeNextCursor != nil && !isLoadingTree
        }

        public var canLoadMoreSearch: Bool {
            searchHasMore && searchNextCursor != nil && !isSearching
        }

        public var hasSearchQuery: Bool {
            !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        public var effectiveRootPath: String {
            if let cwd = activeThread?.cwd, !cwd.isEmpty {
                return cwd
            }
            if !currentPath.isEmpty {
                return currentPath
            }
            return "."
        }
    }

    public enum Action {
        case onAppear
        case setActiveThread(Thread?)
        case refresh

        case loadTree(path: String, cursor: Int?)
        case loadTreeCacheResponse(path: String, response: FileTreeResponse?)
        case loadTreeResponse(path: String, cursor: Int?, Result<FileTreeResponse, CodexError>)
        case loadNextTreePage

        case goToParentDirectory
        case entryTapped(FileTreeEntry)

        case searchQueryChanged(String)
        case runSearch
        case searchResponse(cursor: Int?, Result<FileSearchResponse, CodexError>)
        case loadMoreSearch
        case searchMatchTapped(FileSearchMatch)

        case openFromReference(String)
        case resolveReferenceResponse(Result<FileResolveResponse, CodexError>)

        case closeViewer
        case viewer(FileViewerFeature.Action)

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
                guard state.activeThread != nil else { return .none }
                return .send(.refresh)

            case .setActiveThread(let thread):
                state.activeThread = thread
                state.viewer = nil
                state.errorMessage = nil
                state.entries = []
                state.searchQuery = ""
                state.searchResults = []
                state.treeNextCursor = nil
                state.treeHasMore = false
                state.searchNextCursor = nil
                state.searchHasMore = false

                if let cwd = thread?.cwd, !cwd.isEmpty {
                    state.currentPath = cwd
                } else {
                    state.currentPath = "."
                }
                return .none

            case .refresh:
                guard state.activeThread != nil else { return .none }
                return .send(.loadTree(path: state.currentPath, cursor: nil))

            case .loadTree(let path, let cursor):
                guard let threadId = state.activeThread?.threadId else { return .none }
                if cursor == nil {
                    state.isLoadingTree = true
                    state.currentPath = path
                }
                let rootPath = state.effectiveRootPath

                var effects: [Effect<Action>] = []
                if cursor == nil {
                    effects.append(
                        .run { send in
                            @Dependency(\.fileSystemStore) var fileSystemStore
                            let cached = try? await fileSystemStore.loadTreeCache(rootPath, path)
                            await send(.loadTreeCacheResponse(path: path, response: cached))
                        }
                    )
                }

                effects.append(
                    .run { send in
                        @Dependency(\.apiClient) var apiClient
                        await send(
                            .loadTreeResponse(
                                path: path,
                                cursor: cursor,
                                Result {
                                    try await apiClient.listThreadFsTree(threadId, path, cursor, 200)
                                }.mapError { CodexError.from($0) }
                            )
                        )
                    }
                )

                return .merge(effects)

            case .loadTreeCacheResponse(let path, let response):
                guard path == state.currentPath else { return .none }
                guard let response else { return .none }
                if !state.isLoadingTree {
                    return .none
                }
                state.entries = response.data
                state.treeNextCursor = response.nextCursor
                state.treeHasMore = response.hasMore
                return .none

            case .loadTreeResponse(let path, let cursor, .success(let response)):
                state.errorMessage = nil
                if cursor == nil {
                    state.currentPath = path
                    state.entries = response.data
                    state.isLoadingTree = false
                } else {
                    state.entries.append(contentsOf: response.data)
                }
                state.treeNextCursor = response.nextCursor
                state.treeHasMore = response.hasMore

                guard cursor == nil else {
                    return .none
                }
                let cacheRootPath = state.effectiveRootPath
                return .run { _ in
                    @Dependency(\.fileSystemStore) var fileSystemStore
                    try? await fileSystemStore.saveTreeCache(cacheRootPath, path, response)
                }

            case .loadTreeResponse(_, _, .failure(let error)):
                state.isLoadingTree = false
                state.errorMessage = error.localizedDescription
                return .none

            case .loadNextTreePage:
                guard let nextCursor = state.treeNextCursor else { return .none }
                return .send(.loadTree(path: state.currentPath, cursor: nextCursor))

            case .goToParentDirectory:
                let rootPath = URL(fileURLWithPath: state.effectiveRootPath).standardizedFileURL.path
                let normalizedPath = state.currentPath.isEmpty ? rootPath : state.currentPath
                let parentPath = URL(fileURLWithPath: normalizedPath).deletingLastPathComponent().standardizedFileURL.path
                if parentPath == state.currentPath || !parentPath.hasPrefix(rootPath) {
                    return .none
                }
                return .send(.loadTree(path: parentPath, cursor: nil))

            case .entryTapped(let entry):
                if entry.isDirectory {
                    return .send(.loadTree(path: entry.path, cursor: nil))
                }
                guard let threadId = state.activeThread?.threadId else { return .none }
                state.viewer = FileViewerFeature.State(
                    threadId: threadId,
                    rootPath: state.effectiveRootPath,
                    filePath: entry.path,
                    focusLine: nil
                )
                return .none

            case .searchQueryChanged(let query):
                state.searchQuery = query
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    state.searchResults = []
                    state.searchHasMore = false
                    state.searchNextCursor = nil
                }
                return .none

            case .runSearch:
                let trimmed = state.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, let threadId = state.activeThread?.threadId else {
                    state.searchResults = []
                    state.searchHasMore = false
                    state.searchNextCursor = nil
                    return .none
                }
                state.isSearching = true
                return .run { [path = state.effectiveRootPath] send in
                    @Dependency(\.apiClient) var apiClient
                    await send(
                        .searchResponse(
                            cursor: nil,
                            Result {
                                try await apiClient.searchThreadFs(threadId, trimmed, path, nil, 50)
                            }.mapError { CodexError.from($0) }
                        )
                    )
                }

            case .searchResponse(let cursor, .success(let response)):
                state.isSearching = false
                state.errorMessage = nil
                if cursor == nil {
                    state.searchResults = response.data
                } else {
                    state.searchResults.append(contentsOf: response.data)
                }
                state.searchNextCursor = response.nextCursor
                state.searchHasMore = response.hasMore
                return .none

            case .searchResponse(_, .failure(let error)):
                state.isSearching = false
                state.errorMessage = error.localizedDescription
                return .none

            case .loadMoreSearch:
                guard
                    let nextCursor = state.searchNextCursor,
                    let threadId = state.activeThread?.threadId
                else {
                    return .none
                }
                let trimmed = state.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return .none }

                state.isSearching = true
                return .run { [path = state.effectiveRootPath] send in
                    @Dependency(\.apiClient) var apiClient
                    await send(
                        .searchResponse(
                            cursor: nextCursor,
                            Result {
                                try await apiClient.searchThreadFs(threadId, trimmed, path, nextCursor, 50)
                            }.mapError { CodexError.from($0) }
                        )
                    )
                }

            case .searchMatchTapped(let match):
                guard let threadId = state.activeThread?.threadId else { return .none }
                state.viewer = FileViewerFeature.State(
                    threadId: threadId,
                    rootPath: state.effectiveRootPath,
                    filePath: match.path,
                    focusLine: match.line
                )
                return .none

            case .openFromReference(let ref):
                guard let threadId = state.activeThread?.threadId else { return .none }
                return .run { send in
                    @Dependency(\.apiClient) var apiClient
                    await send(
                        .resolveReferenceResponse(
                            Result {
                                try await apiClient.resolveThreadFsReference(threadId, ref)
                            }.mapError { CodexError.from($0) }
                        )
                    )
                }

            case .resolveReferenceResponse(.success(let response)):
                guard response.data.resolved,
                      let filePath = response.data.path,
                      let threadId = state.activeThread?.threadId
                else {
                    state.errorMessage = "未能解析该文件引用"
                    return .none
                }
                state.viewer = FileViewerFeature.State(
                    threadId: threadId,
                    rootPath: state.effectiveRootPath,
                    filePath: filePath,
                    focusLine: response.data.line
                )
                return .none

            case .resolveReferenceResponse(.failure(let error)):
                state.errorMessage = error.localizedDescription
                return .none

            case .closeViewer:
                state.viewer = nil
                return .none

            case .viewer(.delegate(.openInTerminal(let path))):
                return .send(.delegate(.openInTerminal(path: path)))

            case .viewer:
                return .none

            case .clearError:
                state.errorMessage = nil
                return .none

            case .delegate:
                return .none
            }
        }
        .ifLet(\.viewer, action: \.viewer) {
            FileViewerFeature()
        }
    }
}
