import ComposableArchitecture
import Testing
@testable import CodexWorker

@MainActor
struct AppFeatureConnectionTests {
    @Test
    func convergesReachabilityAndStreamConnectionState() async {
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

        await store.send(.chat(.delegate(.streamConnectionChanged(.failed("socket closed"))))) {
            $0.streamConnectionState = .failed("socket closed")
            $0.connectionState = .failed("实时流连接失败：socket closed")
        }

        await store.send(.chat(.delegate(.streamConnectionChanged(.connected)))) {
            $0.streamConnectionState = .connected
            $0.connectionState = .connected
        }

        await store.send(.healthCheckResponse(.failure(.connectionFailed("server down")))) {
            $0.workerReachability = .unreachable("连接失败: server down")
            $0.connectionState = .failed("连接失败: server down")
        }
    }
}
