import SwiftUI

/// 完整成员保留在 Goal 内的可搜索目录，不把长列表铺进首页抽屉。
struct HarnessMemberDirectory<MemberRows: View>: View {
    let goal: HarnessGoal
    let kind: HarnessDirectoryKind
    @ViewBuilder var memberRows: (HarnessMember) -> MemberRows
    @State private var query = ""

    var body: some View {
        let all = goal.directoryMembers(kind)
        let matches = goal.directoryMembers(kind, matching: query)
        List {
            Section {
                ForEach(matches, id: \.identityKey) { memberRows($0) }
            } header: {
                Text(goal.id + " · " + (query.isEmpty ? "共 \(all.count) 条" : "找到 \(matches.count) / \(all.count) 条"))
                    .textCase(nil)
            }
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "名称、工作票、机器")
        .overlay {
            if matches.isEmpty {
                ContentUnavailableView("没有找到线程", systemImage: "magnifyingglass",
                    description: Text("试试其他名称、工作票或机器。"))
            }
        }
    }
}
