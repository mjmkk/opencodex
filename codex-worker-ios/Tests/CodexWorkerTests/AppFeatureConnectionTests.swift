import ComposableArchitecture
import Testing
@testable import CodexWorker

@MainActor
struct AppFeatureConnectionTests {
    @Test
    func reportsReachabilityWithoutRetiredEventStream() async {
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        }

        await store.send(
            .healthCheckResponse(
                .success(HealthCheckResponse(status: "ok", authEnabled: false))
            )
        ) {
            $0.workerReachability = .reachable
            $0.connectionState = .connected
        }

        await store.send(.healthCheckResponse(.failure(.connectionFailed("server down")))) {
            $0.workerReachability = .unreachable("连接失败: server down")
            $0.connectionState = .failed("连接失败: server down")
        }
    }
}
