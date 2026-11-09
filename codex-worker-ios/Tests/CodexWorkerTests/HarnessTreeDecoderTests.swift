import Foundation
import XCTest

@testable import CodexWorker

/// AGT-26 S6：`/v1/harness/tree` 的解析与首页展示规则
final class HarnessTreeDecoderTests: XCTestCase {
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
        XCTAssertEqual(g.title, "AGT-26 · Master")
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
