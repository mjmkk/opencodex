//
//  Errors.swift
//  CodexWorker
//
//  错误类型定义
//

import Foundation

// MARK: - Codex 错误

/// Codex Worker 错误类型
enum CodexError: Error, Equatable, Sendable {
    // MARK: - 网络错误

    /// 连接失败
    case connectionFailed(String)
    /// 请求超时
    case timeout
    /// 未授权（Token 无效）
    case unauthorized

    // MARK: - API 错误

    /// API 错误（后端返回）
    case apiError(code: String, message: String)
    /// 任务不存在
    case jobNotFound(String)
    /// 线程不存在
    case threadNotFound(String)
    /// 审批不存在
    case approvalNotFound(String)

    // MARK: - 业务错误

    /// 线程已有活跃任务
    case threadHasActiveJob(String)
    /// 游标已过期
    case cursorExpired
    /// 状态无效
    case invalidState

    // MARK: - 本地错误

    /// 未配置
    case notConfigured
    /// 数据解析失败
    case decodingError
    /// 未知错误
    case unknown(String)
}

// MARK: - LocalizedError

extension CodexError: LocalizedError {
    var errorDescription: String? {
        localizedDescription
    }

    var localizedDescription: String {
        switch self {
        // 网络错误
        case let .connectionFailed(msg):
            return "连接失败: \(msg)"
        case .timeout:
            return "请求超时"
        case .unauthorized:
            return "未授权，请检查 Token"

        // API 错误
        case let .apiError(code, msg):
            return "[\(code)] \(msg)"
        case let .jobNotFound(id):
            return "任务不存在: \(id)"
        case let .threadNotFound(id):
            return "线程不存在: \(id)"
        case let .approvalNotFound(id):
            return "审批不存在: \(id)"

        // 业务错误
        case let .threadHasActiveJob(id):
            return "线程已有活跃任务: \(id)"
        case .cursorExpired:
            return "游标已过期，正在恢复..."
        case .invalidState:
            return "状态无效"

        // 本地错误
        case .notConfigured:
            return "请先配置 Worker 连接"
        case .decodingError:
            return "数据解析失败"
        case let .unknown(msg):
            return "未知错误: \(msg)"
        }
    }
}

// MARK: - API 错误响应

/// API 错误响应结构
///
/// 后端返回格式：
/// ```json
/// {
///   "error": {
///     "code": "THREAD_NOT_FOUND",
///     "message": "线程不存在"
///   }
/// }
/// ```
struct APIErrorResponse: Codable, Sendable {
    let error: APIErrorDetail

    struct APIErrorDetail: Codable, Sendable {
        let code: String
        let message: String
    }
}

// MARK: - 错误转换

extension CodexError {
    /// 从 HTTP 状态码和响应创建错误
    static func from(statusCode: Int, data: Data?) -> CodexError {
        // 尝试解析错误响应
        if let data = data,
           let errorResponse = try? JSONDecoder().decode(APIErrorResponse.self, from: data)
        {
            let code = errorResponse.error.code
            let message = errorResponse.error.message

            // 映射常见错误码
            switch code {
            case "UNAUTHORIZED":
                return .unauthorized
            case "JOB_NOT_FOUND":
                return .jobNotFound(message)
            case "THREAD_NOT_FOUND":
                return .threadNotFound(message)
            case "APPROVAL_NOT_FOUND":
                return .approvalNotFound(message)
            case "THREAD_HAS_ACTIVE_JOB":
                return .threadHasActiveJob(message)
            case "CURSOR_EXPIRED":
                return .cursorExpired
            default:
                return .apiError(code: code, message: message)
            }
        }

        // 根据 HTTP 状态码判断
        switch statusCode {
        case 401:
            return .unauthorized
        case 404:
            return .apiError(code: "NOT_FOUND", message: "资源不存在")
        case 408:
            return .timeout
        case 409:
            return .invalidState
        default:
            return .apiError(code: "HTTP_\(statusCode)", message: "HTTP 错误")
        }
    }

    /// 从 Error 转换
    static func from(_ error: Error) -> CodexError {
        if let codexError = error as? CodexError {
            return codexError
        }

        let nsError = error as NSError

        // 网络错误
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost:
                return .timeout
            case NSURLErrorNotConnectedToInternet, NSURLErrorCannotConnectToHost:
                return .connectionFailed(error.localizedDescription)
            default:
                return .connectionFailed(error.localizedDescription)
            }
        }

        return .unknown(error.localizedDescription)
    }
}

// MARK: - 可恢复错误

/// 可恢复错误协议
protocol RecoverableError: Error {
    /// 是否可恢复
    var isRecoverable: Bool { get }

    /// 恢复策略
    var recoveryStrategy: RecoveryStrategy { get }
}

/// 恢复策略
enum RecoveryStrategy: Sendable {
    /// 重试
    case retry
    /// 重连
    case reconnect
    /// 拉取快照
    case fetchSnapshot
    /// 重新配置
    case reconfigure
    /// 无
    case none
}

// MARK: - CodexError 恢复策略

extension CodexError: RecoverableError {
    var isRecoverable: Bool {
        switch self {
        case .connectionFailed, .timeout, .cursorExpired:
            return true
        case .unauthorized, .notConfigured:
            return true
        default:
            return false
        }
    }

    var recoveryStrategy: RecoveryStrategy {
        switch self {
        case .connectionFailed, .timeout:
            return .reconnect
        case .cursorExpired:
            return .fetchSnapshot
        case .unauthorized, .notConfigured:
            return .reconfigure
        default:
            return .none
        }
    }
}
