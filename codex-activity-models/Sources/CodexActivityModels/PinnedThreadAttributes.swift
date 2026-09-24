import ActivityKit
import Foundation

public struct PinnedThreadAttributes: ActivityAttributes, Sendable {
    public struct ContentState: Codable, Hashable, Sendable {
        public var summary: String
        public var updatedAt: Date
        public var executionState: String?
        public var requestID: String?
        public var requestURL: String?
        public init(summary: String, updatedAt: Date, executionState: String? = nil, requestID: String? = nil, requestURL: String? = nil) {
            self.summary = summary; self.updatedAt = updatedAt
            self.executionState = executionState; self.requestID = requestID; self.requestURL = requestURL
        }
        public static func summary(for state: String?) -> String {
            switch state {
            case "WAITING_APPROVAL", "WAITING_USER": return "等待你处理"
            case "RESPONSE_SUBMITTED": return "回复已提交 · 等待原生回执"
            case "REQUEST_RESOLVED": return "请求已结束 · 等待原任务后续"
            case "REQUEST_UNAVAILABLE": return "请求暂不可处理 · 打开核对"
            case "QUEUED": return "等待执行"
            case "RUNNING": return "任务进行中"
            case "IDLE": return "等待下一步"
            case "DONE": return "本轮执行已完成"
            case "FAILED": return "执行失败 · 打开查看"
            case "CANCELLED": return "执行已停止"
            default: return "状态待同步"
            }
        }
    }
    public var threadId: String
    public var title: String
    public var accountScope: String
    public init(threadId: String, title: String, accountScope: String) {
        self.threadId = threadId; self.title = title; self.accountScope = accountScope
    }
}
