import Testing
@testable import CodexWorker

/// 最小冒烟测试：确保测试 target 可被 Xcode / SwiftPM 正确识别。
struct SmokeTests {
    @Test
    func packageLoads() {
        #expect(true)
    }
}
