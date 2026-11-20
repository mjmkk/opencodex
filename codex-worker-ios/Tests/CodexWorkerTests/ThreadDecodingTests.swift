import Foundation
import Testing
@testable import CodexWorker

struct ThreadDecodingTests {
    @Test
    func decodesThreadWithNumericTimestamps() throws {
        let json = """
        {
          "id": "thread_123",
          "preview": "hello",
          "cwd": "/tmp/project",
          "createdAt": 1771240692,
          "updatedAt": 1771240717,
          "modelProvider": "openai",
          "pendingRequestCount": 2
        }
        """

        let data = Data(json.utf8)
        let thread = try JSONDecoder().decode(Thread.self, from: data)

        #expect(thread.threadId == "thread_123")
        #expect(thread.preview == "hello")
        #expect(thread.cwd == "/tmp/project")
        #expect(thread.modelProvider == "openai")
        #expect(thread.createdAt != nil)
        #expect(thread.updatedAt != nil)
        #expect(thread.createdDate != nil)
        #expect(thread.lastActiveAt != nil)
        #expect(thread.pendingRequestCount == 2)
    }
}
