//
//  ExecutionAccessStore.swift
//  CodexWorker
//
//  执行权限模式配置仓储（TCA）
//

import ComposableArchitecture
import Foundation

/// 执行权限模式
///
/// - defaultPermissions: 默认权限（受限）
/// - fullAccess: 完全访问（危险）
public enum ExecutionAccessMode: String, CaseIterable, Codable, Equatable, Sendable {
    case defaultPermissions = "default_permissions"
    case fullAccess = "full_access"

    public var title: String {
        switch self {
        case .defaultPermissions:
            return "Default"
        case .fullAccess:
            return "Full Access"
        }
    }

    public var subtitle: String {
        switch self {
        case .defaultPermissions:
            return "on-request + workspace-write"
        case .fullAccess:
            return "never + danger-full-access"
        }
    }

    /// 映射到后端创建线程参数
    public var threadRequestSettings: (approvalPolicy: String, sandbox: String) {
        switch self {
        case .defaultPermissions:
            return ("on-request", "workspace-write")
        case .fullAccess:
            return ("never", "danger-full-access")
        }
    }

    /// 映射到后端 turn 参数
    public var turnRequestSettings: (approvalPolicy: String, sandbox: String) {
        threadRequestSettings
    }
}

/// 权限模式存储依赖
public struct ExecutionAccessStore: DependencyKey, Sendable {
    public var load: @Sendable () -> ExecutionAccessMode
    public var save: @Sendable (_ mode: ExecutionAccessMode) -> Void

    private static let storageKey = "codex.worker.execution-access-mode"

    public static let liveValue = ExecutionAccessStore(
        load: {
            guard
                let raw = UserDefaults.standard.string(forKey: storageKey),
                let mode = ExecutionAccessMode(rawValue: raw)
            else {
                return .defaultPermissions
            }
            return mode
        },
        save: { mode in
            UserDefaults.standard.set(mode.rawValue, forKey: storageKey)
        }
    )

    public static let testValue = ExecutionAccessStore(
        load: { .defaultPermissions },
        save: { _ in }
    )

    public static let previewValue = testValue
}

extension DependencyValues {
    public var executionAccessStore: ExecutionAccessStore {
        get { self[ExecutionAccessStore.self] }
        set { self[ExecutionAccessStore.self] = newValue }
    }
}
