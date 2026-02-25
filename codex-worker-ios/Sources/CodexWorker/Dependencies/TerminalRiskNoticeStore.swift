//
//  TerminalRiskNoticeStore.swift
//  CodexWorker
//
//  终端风险提示（仅首次）存取
//

import ComposableArchitecture
import Foundation

public struct TerminalRiskNoticeStore: DependencyKey, Sendable {
    public var shouldShowOnNextOpen: @Sendable () -> Bool
    public var markShown: @Sendable () -> Void

    public static let liveValue = TerminalRiskNoticeStore(
        shouldShowOnNextOpen: {
            !UserDefaults.standard.bool(forKey: storageKey)
        },
        markShown: {
            UserDefaults.standard.set(true, forKey: storageKey)
        }
    )

    public static let testValue = TerminalRiskNoticeStore(
        shouldShowOnNextOpen: { false },
        markShown: {}
    )

    public static let previewValue = testValue
}

extension DependencyValues {
    public var terminalRiskNoticeStore: TerminalRiskNoticeStore {
        get { self[TerminalRiskNoticeStore.self] }
        set { self[TerminalRiskNoticeStore.self] = newValue }
    }
}

private let storageKey = "codexworker.terminal.risk_notice_shown"
