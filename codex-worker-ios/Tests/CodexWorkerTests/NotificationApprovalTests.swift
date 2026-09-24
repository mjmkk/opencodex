import Foundation
import Testing
import CodexActivityModels
@testable import CodexWorker

struct NotificationTests {
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
