import Foundation

enum MobileTime {
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(seconds / 60) 分钟前" }
        if seconds < 86400 { return "\(seconds / 3600) 小时前" }
        if seconds < 604800 { return "\(seconds / 86400) 天前" }
        return date.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).month().day())
    }

    static func timestamp(_ date: Date) -> String {
        date.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).month().day().hour().minute())
    }
}

extension Thread {
    var attentionReason: String? {
        if pendingRequestCount > 0 { return "\(pendingRequestCount) 项等待你处理" }
        switch executionState {
        case "WAITING_APPROVAL": return "等待你的回复"
        case "FAILED": return "上次执行失败"
        case "RUNNING": return "正在执行"
        case "QUEUED": return "等待执行"
        default: return nil
        }
    }
}
