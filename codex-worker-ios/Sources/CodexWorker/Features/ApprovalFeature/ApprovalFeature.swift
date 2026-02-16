//
//  ApprovalFeature.swift
//  CodexWorker
//
//  审批 Feature（里程碑 4）
//

import ComposableArchitecture

@Reducer
public struct ApprovalFeature {
    @ObservableState
    public struct State: Equatable {
        public var currentApproval: Approval?
        public var isSubmitting = false
        public var errorMessage: String?
        public var submittedDecision: ApprovalDecision?

        public var isPresented: Bool {
            currentApproval != nil
        }

        public init() {}
    }

    public enum Action {
        case present(Approval)
        case dismiss
        case submitTapped(ApprovalDecision)
        case submitResponse(Result<ApprovalResponse, CodexError>)
        case clearError
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .present(let approval):
                state.currentApproval = approval
                state.errorMessage = nil
                state.submittedDecision = nil
                return .none

            case .dismiss:
                state.currentApproval = nil
                state.isSubmitting = false
                state.errorMessage = nil
                state.submittedDecision = nil
                return .none

            case .submitTapped(let decision):
                guard let approval = state.currentApproval, !state.isSubmitting else { return .none }
                let approvalId = approval.approvalId.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !approvalId.isEmpty else {
                    state.errorMessage = "审批请求缺少 approvalId，请重试或刷新线程。"
                    return .none
                }
                state.isSubmitting = true
                state.errorMessage = nil
                state.submittedDecision = decision

                return .run { send in
                    @Dependency(\.apiClient) var apiClient
                    let request = ApprovalRequest(
                        approvalId: approvalId,
                        decision: decision.rawValue,
                        execPolicyAmendment: nil
                    )
                    await send(
                        .submitResponse(
                            Result {
                                try await apiClient.approve(approval.jobId, request)
                            }.mapError { CodexError.from($0) }
                        )
                    )
                }

            case .submitResponse(.success):
                // 是否关闭由 approval.resolved 事件决定，这里只结束提交态
                state.isSubmitting = false
                return .none

            case .submitResponse(.failure(let error)):
                state.isSubmitting = false
                state.errorMessage = error.localizedDescription
                return .none

            case .clearError:
                state.errorMessage = nil
                return .none
            }
        }
    }
}
