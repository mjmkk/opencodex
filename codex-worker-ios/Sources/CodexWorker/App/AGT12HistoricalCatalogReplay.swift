#if AGT12_UI_REPLAY
import ComposableArchitecture
import CryptoKit
import Foundation
import SwiftUI

/// Existing captured responses are read only inside a separately compiled QA entry.
/// No current account data, transport, persistence or business response is used.
struct AGT12HistoricalTasksReplay: View {
    private let store: StoreOf<ThreadsFeature>?
    private let failure: String?
    private let count: Int

    init(path: String) {
        do {
            let data = try AGT12ReplayData.read(path, sha256: "4be23b383ac2630b94b10845f20edbe8dac94854acf258df13086321977a063a")
            let index = try JSONDecoder().decode(MirrorIndex.self, from: data)
            guard index.ok, index.source == "local_mirror", !index.namespace.isEmpty,
                  index.threads.count == 592,
                  index.threads.allSatisfy({ $0.namespace == nil || $0.namespace == index.namespace }) else {
                throw CodexError.invalidState
            }
            var state = ThreadsFeature.State()
            state.items = index.threads.map { $0.thread(in: index.namespace) }
            // The directory has no paired local sync/unread/pin metadata.
            state.syncMetadata = [:]
            if ProcessInfo.processInfo.environment["AGT12_TASKS_REPLAY_LONGEST_ONLY"] == "1" {
                state.items = state.items.max(by: { ($0.name?.count ?? 0) < ($1.name?.count ?? 0) }).map { [$0] } ?? []
            }
            count = state.items.count
            store = Store(initialState: state) {
                Reduce<ThreadsFeature.State, ThreadsFeature.Action> { state, action in
                    // These two interactions change only this ephemeral projection.
                    // Transport, archive, pin and all other business actions are inert.
                    switch action {
                    case .groupingModeChanged(let mode): state.groupingMode = mode
                    case .threadTapped(let id):
                        if state.items.contains(where: { $0.threadId == id }) { state.selectedThreadId = id }
                    default: break
                    }
                    return .none
                }
            }
            failure = nil
        } catch {
            store = nil; count = 0; failure = error.localizedDescription
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            AGT12ReplayBanner(title: "真实目录历史回放 · \(count) / 592 条",
                detail: "2026/10/23 原目录 · 未配对 · 不打开 Chat 或执行操作")
            if let store { ThreadsView(store: store) }
            else { CodexEmptyState(title: "无法读取目录原件", detail: failure ?? "读取失败") }
        }.tint(.primary)
    }
}

struct AGT12HistoricalOverviewReplay: View {
    let path: String
    @State private var rows: [GoalOverviewRow] = []
    @State private var inventory: GoalInventoryValidation = .unknown
    @State private var hasSnapshot = false
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 0) {
            AGT12ReplayBanner(title: "真实评分历史回放 · rev702",
                detail: "2026/10/23 原件，非当前评分 · 刷新仅重读原件")
            GoalOverviewView(rows: rows, inventoryValidation: inventory, hasSnapshot: hasSnapshot,
                isRefreshing: false, failure: failure, refresh: { load() })
        }.task { load() }
    }

    private func load() {
        do {
            let data = try AGT12ReplayData.read(path, sha256: "b8391abed2f7b6846662cf8693c1e868ac769e4c5ee8b2840bcc230e8ff1651d")
            let payload = try JSONDecoder().decode(JSONValue.self, from: data)
            rows = try GoalOverviewDecoder.rows(payload, cached: true)
            inventory = try GoalOverviewDecoder.inventoryValidation(payload, cached: true)
            hasSnapshot = true; failure = nil
        } catch { failure = error.localizedDescription }
    }
}

private struct AGT12ReplayBanner: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.footnote.weight(.semibold))
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20).padding(.vertical, 8)
        .background(Color(uiColor: .secondarySystemBackground))
    }
}

private enum AGT12ReplayData {
    static func read(_ path: String, sha256: String) throws -> Data {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sha256 else {
            throw CodexError.invalidState
        }
        return data
    }
}
#endif
