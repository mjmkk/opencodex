//
//  Approval.swift
//  CodexWorker
//
//  审批模型 - 与后端 API 对齐
//

import Foundation
import SwiftUI

// MARK: - 审批类型

/// 审批类型枚举
public enum ApprovalKind: String, Codable, Sendable {
    /// 命令执行审批
    case commandExecution = "command_execution"
    /// 文件变更审批
    case fileChange = "file_change"

    /// 显示图标名称
    var iconName: String {
        switch self {
        case .commandExecution:
            return "terminal"
        case .fileChange:
            return "doc.text"
        }
    }

    /// 显示标题
    var title: String {
        switch self {
        case .commandExecution:
            return "命令执行审批"
        case .fileChange:
            return "文件变更审批"
        }
    }
}

// MARK: - 审批决策

/// 审批决策枚举
///
/// 对应后端 `/approve` 接口的 `decision` 字段
public enum ApprovalDecision: String, Codable, Sendable {
    /// 接受本次
    case accept
    /// 会话内接受（后续同类请求自动通过）
    case acceptForSession = "accept_for_session"
    /// 接受并修改命令（仅命令审批）
    case acceptWithExecpolicyAmendment = "accept_with_execpolicy_amendment"
    /// 拒绝
    case decline
    /// 取消任务
    case cancel

    /// 显示文本
    var displayText: String {
        switch self {
        case .accept:
            return "接受"
        case .acceptForSession:
            return "会话内接受"
        case .acceptWithExecpolicyAmendment:
            return "修改后接受"
        case .decline:
            return "拒绝"
        case .cancel:
            return "取消任务"
        }
    }

    /// 是否需要提供 execPolicyAmendment
    var requiresAmendment: Bool {
        self == .acceptWithExecpolicyAmendment
    }
}

// MARK: - 风险等级

/// 审批风险等级
public enum RiskLevel: Int, Codable, Sendable {
    case low = 0
    case medium = 1
    case high = 2

    /// 风险等级颜色
    var color: Color {
        switch self {
        case .low:
            return .green
        case .medium:
            return .orange
        case .high:
            return .red
        }
    }

    /// 风险等级标签
    var label: String {
        switch self {
        case .low:
            return "低风险"
        case .medium:
            return "中风险"
        case .high:
            return "高风险"
        }
    }

    /// 风险等级描述
    var description: String {
        switch self {
        case .low:
            return "安全操作，建议接受"
        case .medium:
            return "需谨慎评估影响"
        case .high:
            return "危险操作，请仔细确认"
        }
    }
}

// MARK: - 审批模型

/// 审批请求
///
/// 从 `approval.required` 事件解析
///
/// 示例 JSON:
/// ```json
/// {
///   "approvalId": "appr_xyz789",
///   "jobId": "job_abc123",
///   "threadId": "thread_def456",
///   "turnId": "turn_ghi789",
///   "itemId": "item_jkl012",
///   "kind": "command_execution",
///   "requestMethod": "item/commandExecution/requestApproval",
///   "createdAt": "2026-02-15T10:30:00.000Z",
///   "reason": "需要执行命令",
///   "command": "npm test",
///   "cwd": "/Users/me/project",
///   "commandActions": ["run"],
///   "grantRoot": false
/// }
/// ```
public struct Approval: Identifiable, Codable, Equatable, Sendable {
    /// 审批唯一标识符
    public let approvalId: String

    /// 所属任务 ID
    public let jobId: String

    /// 所属线程 ID
    public let threadId: String

    /// Turn ID
    public let turnId: String?

    /// Item ID
    public let itemId: String?

    /// 审批类型
    public let kind: ApprovalKind

    /// 请求方法（如 item/commandExecution/requestApproval）
    public let requestMethod: String

    /// 创建时间（ISO 8601 格式）
    public let createdAt: String

    // MARK: - 命令审批字段

    /// 要执行的命令
    public var command: String?

    /// 工作目录
    public var cwd: String?

    /// 命令动作列表
    public var commandActions: [String]?

    /// 审批原因
    public var reason: String?

    /// 是否需要 root 权限
    public var grantRoot: Bool?

    /// 建议的命令修改
    public var proposedExecpolicyAmendment: [String]?

    // MARK: - 文件变更审批字段（待扩展）

    // MARK: - Identifiable

    public var id: String { approvalId }

    public init(
        approvalId: String,
        jobId: String,
        threadId: String,
        turnId: String?,
        itemId: String?,
        kind: ApprovalKind,
        requestMethod: String,
        createdAt: String,
        command: String?,
        cwd: String?,
        commandActions: [String]?,
        reason: String?,
        grantRoot: Bool?,
        proposedExecpolicyAmendment: [String]?
    ) {
        self.approvalId = approvalId
        self.jobId = jobId
        self.threadId = threadId
        self.turnId = turnId
        self.itemId = itemId
        self.kind = kind
        self.requestMethod = requestMethod
        self.createdAt = createdAt
        self.command = command
        self.cwd = cwd
        self.commandActions = commandActions
        self.reason = reason
        self.grantRoot = grantRoot
        self.proposedExecpolicyAmendment = proposedExecpolicyAmendment
    }
}

// MARK: - 风险评估

extension Approval {
    /// 从 SSE payload 构建审批对象
    public static func fromPayload(_ payload: [String: JSONValue], fallbackJobId: String) -> Approval? {
        guard
            let approvalId = nonEmptyString(in: payload, keys: ["approvalId", "approval_id"]),
            let threadId = nonEmptyString(in: payload, keys: ["threadId", "thread_id"]),
            let kindRaw = nonEmptyString(in: payload, keys: ["kind"]),
            let kind = ApprovalKind(rawValue: kindRaw),
            let requestMethod = nonEmptyString(in: payload, keys: ["requestMethod", "request_method"]),
            let createdAt = nonEmptyString(in: payload, keys: ["createdAt", "created_at"])
        else {
            return nil
        }

        let jobId = nonEmptyString(in: payload, keys: ["jobId", "job_id"]) ?? fallbackJobId
        let turnId = nonEmptyString(in: payload, keys: ["turnId", "turn_id"])
        let itemId = nonEmptyString(in: payload, keys: ["itemId", "item_id"])
        let command = nonEmptyString(in: payload, keys: ["command"])
        let cwd = nonEmptyString(in: payload, keys: ["cwd"])
        let reason = nonEmptyString(in: payload, keys: ["reason"])
        let grantRoot = bool(in: payload, keys: ["grantRoot", "grant_root"])

        let commandActions = stringArray(
            in: payload,
            keys: ["commandActions", "command_actions"]
        )
        let proposedExecpolicyAmendment: [String]? =
            stringArray(
                in: payload,
                keys: [
                    "proposedExecpolicyAmendment",
                    "proposed_execpolicy_amendment",
                ]
            )

        return Approval(
            approvalId: approvalId,
            jobId: jobId,
            threadId: threadId,
            turnId: turnId,
            itemId: itemId,
            kind: kind,
            requestMethod: requestMethod,
            createdAt: createdAt,
            command: command,
            cwd: cwd,
            commandActions: commandActions,
            reason: reason,
            grantRoot: grantRoot,
            proposedExecpolicyAmendment: proposedExecpolicyAmendment
        )
    }

    private static func nonEmptyString(in payload: [String: JSONValue], keys: [String]) -> String? {
        for key in keys {
            guard let raw = payload[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                continue
            }
            if !raw.isEmpty {
                return raw
            }
        }
        return nil
    }

    private static func bool(in payload: [String: JSONValue], keys: [String]) -> Bool? {
        for key in keys {
            if let value = payload[key]?.boolValue {
                return value
            }
        }
        return nil
    }

    private static func stringArray(in payload: [String: JSONValue], keys: [String]) -> [String]? {
        for key in keys {
            guard let array = payload[key]?.arrayValue else { continue }
            let values = array
                .compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !values.isEmpty {
                return values
            }
        }
        return nil
    }

    /// 计算风险等级
    ///
    /// 基于命令内容和路径判断风险级别
    public var riskLevel: RiskLevel {
        guard let cmd = command else { return .low }

        let lowerCmd = cmd.lowercased()

        // 高风险命令
        let highRiskPatterns = [
            "rm -rf",
            "rm -r",
            "sudo ",
            "chmod 777",
            "dd if=",
            "> /dev/",
            "mkfs",
            "fdisk",
            "shutdown",
            "reboot",
            "init 0",
            "kill -9",
        ]

        for pattern in highRiskPatterns {
            if lowerCmd.contains(pattern) {
                return .high
            }
        }

        // 中风险命令
        let mediumRiskPatterns = [
            "git push",
            "git push --force",
            "npm publish",
            "cargo publish",
            "pip upload",
            "docker push",
            "git reset --hard",
            "git clean -fd",
            ":(){ :|:& };:",  // fork bomb
        ]

        for pattern in mediumRiskPatterns {
            if lowerCmd.contains(pattern) {
                return .medium
            }
        }

        // 检查是否修改关键文件
        if let cwd = cwd {
            let criticalPaths = ["/etc", "/usr", "/bin", "/sbin", "/System"]
            for path in criticalPaths {
                if cwd.hasPrefix(path) {
                    return .high
                }
            }
        }

        return .low
    }

    /// 是否为高风险
    public var isHighRisk: Bool {
        riskLevel == .high
    }

    /// 格式化的命令预览
    public var formattedCommand: String {
        guard let cmd = command else { return "" }
        // 限制长度，超过 200 字符截断
        if cmd.count > 200 {
            return String(cmd.prefix(200)) + "..."
        }
        return cmd
    }
}

// MARK: - 审批请求体

/// 提交审批请求体
///
/// 对应 `POST /v1/jobs/{jobId}/approve` 请求格式
public struct ApprovalRequest: Codable, Sendable {
    /// 审批 ID
    public let approvalId: String

    /// 决策
    public let decision: String

    /// 修改后的命令（仅用于 accept_with_execpolicy_amendment）
    public var execPolicyAmendment: [String]?

    public init(approvalId: String, decision: String, execPolicyAmendment: [String]?) {
        self.approvalId = approvalId
        self.decision = decision
        self.execPolicyAmendment = execPolicyAmendment
    }
}

// MARK: - 审批响应

/// 审批响应
///
/// 对应 `POST /v1/jobs/{jobId}/approve` 返回
public struct ApprovalResponse: Codable, Sendable {
    /// 审批 ID
    public let approvalId: String

    /// 状态（submitted / already_submitted）
    public let status: String

    /// 决策
    public let decision: String?
}

// MARK: - 取消请求

/// 取消任务响应
///
/// 对应 `POST /v1/jobs/{jobId}/cancel` 返回
public struct CancelResponse: Codable, Sendable {
    /// 任务 ID
    public let jobId: String

    /// 任务状态
    public let state: String
}
