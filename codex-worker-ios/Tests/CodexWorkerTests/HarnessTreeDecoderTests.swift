import Foundation
import XCTest

@testable import CodexWorker

/// AGT-26 S6：`/v1/harness/tree` 的解析与首页展示规则
final class HarnessTreeDecoderTests: XCTestCase {
    /// 从真实 Registry/Linear 快照经生产 owning_goal resolver 投影所得，未使用替身服务。
    func testActualGoalProjectionPreservesWorkBindingsAndSingleMaster() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "harness-goals-2026-11-13", withExtension: "json", subdirectory: "Fixtures"))
        let payload = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        XCTAssertTrue(HarnessTreeCache.isCurrent(payload))
        // 重放快照沿用源响应时间；线上响应会提供当前 Linear 核对时间。
        let goals = try HarnessTreeDecoder.goals(payload)
        XCTAssertEqual(goals.count, 12)
        XCTAssertEqual(goals.filter { $0.ownershipStatus == "verified" }.count, 9)
        XCTAssertEqual(Set(goals.filter(\.needsRelationshipReview).map(\.id)), ["AGT-6", "AGT-39"])
        let robox = try XCTUnwrap(goals.first { $0.id == "BOX-159" })
        XCTAssertEqual(robox.workCount, 21)
        XCTAssertEqual(robox.master?.id, "01a137d1-8040-7953-a23a-d6beeeaea2d7")
        let migration = robox.members.filter { $0.id == "01a19f43-ec2e-7de0-958a-8ec68009f315" }
        XCTAssertEqual(migration.count, 1)
        XCTAssertEqual(Set(migration[0].workIssues.map(\.id)), ["BOX-167", "BOX-169"])
        let agt = try XCTUnwrap(goals.first { $0.id == "AGT-26" })
        XCTAssertEqual(agt.thinkers.first?.externalConversationURL?.absoluteString,
                       "https://chatgpt.com/c/6aa89461-5628-83ee-8bc7-43d5ee6fb5ee")
        XCTAssertNil(agt.master?.externalConversationURL)
        XCTAssertEqual(agt.members.filter { $0.role == .master }.count, 1)
        let workMaster = try XCTUnwrap(agt.members.first { $0.id == "01a1bc84-8d1f-7450-b5f4-9fa8e2377a84" })
        XCTAssertEqual(workMaster.role, .worker)
        XCTAssertEqual(workMaster.roleLabel, "工作负责人")
        XCTAssertTrue(workMaster.workIssues.contains { $0.id == "AGT-47" && $0.role == "master" })
        let missing = try XCTUnwrap(goals.first { $0.id == "AGT-24" })
        XCTAssertNil(missing.master)
        XCTAssertEqual(missing.ownershipStatus, "master_missing")
        XCTAssertEqual(missing.title, missing.issueTitle)
    }

    func testActualDrawerRendersEachMemberOnceAndFoldsThinkers() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "harness-goals-2026-11-13", withExtension: "json", subdirectory: "Fixtures"))
        let goals = try HarnessTreeDecoder.goals(JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url)))
        for g in goals {
            let all = [g.master].compactMap { $0 } + g.thinkers + g.workers
            XCTAssertEqual(Set(all.map(\.identityKey)), Set(g.members.map(\.identityKey)))
            XCTAssertEqual(all.count, Set(all.map(\.identityKey)).count)
            XCTAssertEqual(g.visibleThinkers.count, min(3, g.thinkers.count))
            XCTAssertEqual(g.executionCount, g.workers.count + (g.master == nil ? 0 : 1))
        }
    }

    private func payload(_ goals: [JSONValue]) -> JSONValue {
        .object(["ok": .bool(true), "schema_version": .int(1), "goals": .array(goals)])
    }

    private func member(_ role: String, _ id: String, kind: String, host: String? = nil,
                        title: String? = nil, model: String? = nil) -> JSONValue {
        var m: [String: JSONValue] = ["role": .string(role), "id": .string(id), "kind": .string(kind)]
        m["host_id"] = host.map(JSONValue.string) ?? .null
        m["title"] = title.map(JSONValue.string) ?? .null
        m["model"] = model.map(JSONValue.string) ?? .null
        return .object(m)
    }

    func testDecodesRolesKindsAndRuntimeLine() throws {
        let goals = try HarnessTreeDecoder.goals(payload([
            .object(["issue_id": .string("AGT-26"), "members": .array([
                member("chatgpt", "6aa8", kind: "chatgpt", title: "方案讨论"),
                member("master", "01a1", kind: "codex", host: "local", title: "AGT-26 · Master", model: "gpt-6.1-sol"),
                member("worker", "b483", kind: "claude", host: "mac-m1pro"),
            ])]),
        ]))
        XCTAssertEqual(goals.count, 1)
        let g = goals[0]
        XCTAssertEqual(g.title, "AGT-26", "Master 标题只有 Issue 号和角色时，没有可用的名字，退回 Issue 号")
        XCTAssertEqual(g.issueURL?.absoluteString, "https://linear.app/mjmk/issue/AGT-26")
        XCTAssertEqual(g.members.map(\.role), [.thinker, .master, .worker])
        XCTAssertEqual(g.master?.runtimeLine, "Codex · spirit-master · gpt-6.1-sol")
        XCTAssertEqual(g.members[2].runtimeLine, "Claude Code · M1 Mac")
        XCTAssertEqual(g.members[0].runtimeLine, "ChatGPT")
        XCTAssertEqual(g.members[0].roleLabel, "思考")
    }

    func testDropsGoalsWithoutMasterOrWorkerAndInvalidMembers() throws {
        let goals = try HarnessTreeDecoder.goals(payload([
            .object(["issue_id": .string("AGT-9"), "members": .array([member("chatgpt", "x", kind: "chatgpt")])]),
            .object(["issue_id": .string("BOX-1"), "members": .array([
                member("worker", "w1", kind: "codex", host: "local"),
                .object(["role": .string("unknown-role"), "id": .string("z"), "kind": .string("codex")]),
                .object(["role": .string("worker"), "kind": .string("codex")]),   // 缺 id
            ])]),
        ]))
        XCTAssertEqual(goals.map(\.id), ["BOX-1"])
        XCTAssertEqual(goals[0].members.count, 1)
        XCTAssertEqual(goals[0].title, "BOX-1")   // 没有 Master 时用 Issue 号
    }

    func testNodeStatusAndSubagentsAreDecoded() throws {
        var worker = member("worker", "b483", kind: "claude", host: "mac-m1pro")
        if case .object(var o) = worker {
            o["status"] = .string("needs_you")
            o["subagents"] = .array([.object(["id": .string("b483/a1"), "kind": .string("claude"),
                                              "title": .string("general-purpose"), "status": .string("done")])])
            worker = .object(o)
        }
        let g = try HarnessTreeDecoder.goals(payload([
            .object(["issue_id": .string("AGT-26"), "members": .array([worker])]),
        ]))[0]
        XCTAssertTrue(g.needsYou)
        XCTAssertEqual(g.members[0].subagents.map(\.id), ["b483/a1"])
        XCTAssertEqual(g.members[0].subagents[0].role, .subagent)
        XCTAssertEqual(g.members[0].subagents[0].status, .done)
        XCTAssertEqual(HarnessTreeDecoder.status("bogus"), .unknown)
    }

    /// needs_you 时才解析“在等什么”；状态不是 needs_you 时即使带了 waiting 也忽略
    func testWaitingDecodedOnlyWhenNeedsYou() throws {
        func with(_ status: String) -> JSONValue {
            guard case .object(var o) = member("worker", "b483", kind: "claude", host: "mac-m1pro") else { return .null }
            o["status"] = .string(status)
            o["waiting"] = .object(["kind": .string("permission"), "tool": .string("Bash"), "summary": .string("rm -rf build")])
            return .object(o)
        }
        let goals = try HarnessTreeDecoder.goals(payload([
            .object(["issue_id": .string("A"), "members": .array([with("needs_you")])]),
            .object(["issue_id": .string("B"), "members": .array([with("idle")])]),
        ]))
        XCTAssertEqual(goals[0].members[0].waiting, .init(isPermission: true, tool: "Bash", summary: "rm -rf build"))
        XCTAssertNil(goals[1].members[0].waiting)
    }

    func testGoalTitlePrefersLinearAndMemberTitlesDropGoalPrefix() throws {
        let g = try HarnessTreeDecoder.goals(payload([
            .object(["issue_id": .string("BOX-166"), "title": .string("M2：交付 Robot Integration"),
                     "members": .array([member("worker", "w1", kind: "codex", host: "local")])]),
        ]))[0]
        XCTAssertEqual(g.title, "M2：交付 Robot Integration", "唯一线程没有名字时退回 Linear 标题")
        XCTAssertEqual(HarnessGoal.threadName("AGT-26「AGT 协作开发」· Master", goalId: "AGT-26"), "AGT 协作开发")
        XCTAssertEqual(HarnessGoal.threadName("AGT-47 演练 · Codex Master", goalId: "AGT-47"), "演练")
        XCTAssertEqual(HarnessGoal.threadName("BOX-160「Robot Mind 研发」· Master（接续）", goalId: "BOX-160"), "Robot Mind 研发")
        XCTAssertEqual(HarnessGoal.threadName("BOX-166 · SDK CTest 核查", goalId: "BOX-166"), "SDK CTest 核查")
        XCTAssertNil(HarnessGoal.threadName("Master", goalId: "X-1"))
        XCTAssertEqual(HarnessHomeView.shortTitle("BOX-166 · SDK CTest 核查", goal: g), "SDK CTest 核查")
        XCTAssertEqual(HarnessHomeView.shortTitle("BOX-166「ROBOX 开发」· 图传 Worker", goal: g), "图传 Worker")
        XCTAssertEqual(HarnessHomeView.shortTitle("另一件事", goal: g), "另一件事")
        XCTAssertNil(HarnessHomeView.shortTitle("BOX-166", goal: g))
    }

    func testRejectsNotOkPayload() {
        XCTAssertThrowsError(try HarnessTreeDecoder.goals(.object(["ok": .bool(false)])))
    }

    func testSurfacedNeedsYouAndHostLabels() {
        var w = HarnessMember(id: "w", role: .worker, kind: "codex", host: "remote-control:env_e_x", title: nil, model: nil)
        w.status = .needsYou
        let g = HarnessGoal(id: "BOX-167", issueURL: nil, members: [w])
        XCTAssertTrue(g.needsYou)
        XCTAssertEqual(g.surfaced.map(\.id), ["w"])
        XCTAssertEqual(HarnessMember.hostLabel("remote-ssh-discovered:agt-ubuntu-worker"), "Ubuntu")
        XCTAssertEqual(HarnessMember.hostLabel("remote-control:env_e_x"), "远程设备")
        XCTAssertNil(HarnessMember.hostLabel(""))
    }
}
