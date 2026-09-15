import Foundation
import Testing
import CodexActivityModels
@testable import CodexWorker

struct NotificationApprovalTests {
    private let info = ["source":"structured_approval", "approvalId":"request", "requestVersion":"v1", "clientScope":"account-installation"]
    private var document: MobileApproval {
        .init(request: ["id":.string("request"), "risk":.string("ordinary"), "input":.object(["kind":.string("approve_reject")]),
                        "expires_at":.double(Date().addingTimeInterval(3600).timeIntervalSince1970)],
              request_version:"v1",state:"pending",quick_response:["kind":.string("approve_reject")])
    }

    @Test func buttonRepeatKeepsNonceButAnotherDecisionDoesNot() throws {
        let approve = try #require(NotificationApprovalIntent(info:info,action:"AGT_APPROVE"))
        let reject = try #require(NotificationApprovalIntent(info:info,action:"AGT_REJECT"))
        let one = try approve.submission(document:document,expectedClientScope:"account-installation")
        #expect(one.event_id == (try approve.submission(document:document,expectedClientScope:"account-installation")).event_id)
        #expect(one.event_id != (try reject.submission(document:document,expectedClientScope:"account-installation")).event_id)
        #expect(one.notification_action == true)
        #expect(NotificationApprovalIntent(info:info,action:"VIEW_CONTEXT") == nil)
    }

    @Test func staleCrossAccountHighRiskAndExpiredResponsesNeverSubmit() throws {
        let intent = try #require(NotificationApprovalIntent(info:info,action:"AGT_APPROVE"))
        #expect(throws: (any Error).self) { try intent.submission(document:document,expectedClientScope:"another-account") }
        var changed = document
        changed.request_version = "v2"
        #expect(throws: (any Error).self) { try intent.submission(document:changed,expectedClientScope:"account-installation") }
        changed = document; changed.request["risk"] = .string("high")
        #expect(throws: (any Error).self) { try intent.submission(document:changed,expectedClientScope:"account-installation") }
        changed = document; changed.request["expires_at"] = .double(0)
        #expect(throws: (any Error).self) { try intent.submission(document:changed,expectedClientScope:"account-installation") }
        changed = document; changed.quick_response = nil
        #expect(throws: (any Error).self) { try intent.submission(document:changed,expectedClientScope:"account-installation") }
    }

    @Test @MainActor func publicPushBindingIsStableAndIsolatedFromAccountIdentity() throws {
        let suite = "notification-tests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let one = RemotePushRegistrationService.binding(for:"account-a",defaults:defaults)
        #expect(one == RemotePushRegistrationService.binding(for:"account-a",defaults:defaults))
        #expect(one != RemotePushRegistrationService.binding(for:"account-b",defaults:defaults))
        #expect(UUID(uuidString:one) != nil)
    }

    @Test func remoteActivityStateUsesTheSystemDefaultDateEncoding() throws {
        let state = try JSONDecoder().decode(PinnedThreadAttributes.ContentState.self,
            from: Data(#"{"summary":"任务进行中","updatedAt":811123800}"#.utf8))
        #expect(state.updatedAt.timeIntervalSince1970 == 1789431000)
        #expect(state.summary == "任务进行中")
    }
}
