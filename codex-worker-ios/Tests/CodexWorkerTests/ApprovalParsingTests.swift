import Testing
@testable import CodexWorker

struct ApprovalParsingTests {
    @Test
    func parseCamelCasePayload() {
        let payload: [String: JSONValue] = [
            "approvalId": .string("appr_123"),
            "jobId": .string("job_1"),
            "threadId": .string("thread_1"),
            "kind": .string("command_execution"),
            "requestMethod": .string("item/commandExecution/requestApproval"),
            "createdAt": .string("2026-02-16T11:00:00.000Z"),
            "commandActions": .array([.string("run")]),
        ]

        let approval = Approval.fromPayload(payload, fallbackJobId: "job_fallback")

        #expect(approval != nil)
        #expect(approval?.approvalId == "appr_123")
        #expect(approval?.jobId == "job_1")
        #expect(approval?.threadId == "thread_1")
        #expect(approval?.commandActions == ["run"])
    }

    @Test
    func parseSnakeCasePayload() {
        let payload: [String: JSONValue] = [
            "approval_id": .string("appr_456"),
            "job_id": .string("job_2"),
            "thread_id": .string("thread_2"),
            "kind": .string("command_execution"),
            "request_method": .string("item/commandExecution/requestApproval"),
            "created_at": .string("2026-02-16T12:00:00.000Z"),
            "grant_root": .bool(true),
            "command_actions": .array([.string("run"), .string("confirm")]),
            "proposed_execpolicy_amendment": .array([.string("echo"), .string("safe")]),
        ]

        let approval = Approval.fromPayload(payload, fallbackJobId: "job_fallback")

        #expect(approval != nil)
        #expect(approval?.approvalId == "appr_456")
        #expect(approval?.jobId == "job_2")
        #expect(approval?.threadId == "thread_2")
        #expect(approval?.grantRoot == true)
        #expect(approval?.commandActions == ["run", "confirm"])
        #expect(approval?.proposedExecpolicyAmendment == ["echo", "safe"])
    }

    @Test
    func rejectEmptyApprovalId() {
        let payload: [String: JSONValue] = [
            "approvalId": .string(" "),
            "threadId": .string("thread_3"),
            "kind": .string("command_execution"),
            "requestMethod": .string("item/commandExecution/requestApproval"),
            "createdAt": .string("2026-02-16T13:00:00.000Z"),
        ]

        let approval = Approval.fromPayload(payload, fallbackJobId: "job_fallback")
        #expect(approval == nil)
    }
}
