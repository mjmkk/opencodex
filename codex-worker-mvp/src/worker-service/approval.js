import { HttpError } from "../errors.js";
import { isNonEmptyString } from "./shared.js";

/**
 * 将审批决策映射为 RPC 格式
 *
 * @param {string} kind
 * @param {string} decision
 * @param {string[] | undefined} execPolicyAmendment
 * @returns {string | {acceptWithExecpolicyAmendment: {execpolicy_amendment: string[]}}}
 */
export function mapDecisionToRpc(kind, decision, execPolicyAmendment) {
  if (!isNonEmptyString(decision)) {
    throw new HttpError(400, "INVALID_DECISION", "decision 不能为空");
  }

  switch (decision) {
    case "accept":
      return "accept";
    case "accept_for_session":
      return "acceptForSession";
    case "decline":
      return "decline";
    case "cancel":
      return "cancel";
    case "accept_with_execpolicy_amendment": {
      if (kind !== "command_execution") {
        throw new HttpError(
          400,
          "INVALID_DECISION_FOR_KIND",
          "accept_with_execpolicy_amendment 仅支持命令审批"
        );
      }
      if (!Array.isArray(execPolicyAmendment) || execPolicyAmendment.length === 0) {
        throw new HttpError(
          400,
          "INVALID_EXEC_POLICY_AMENDMENT",
          "decision=accept_with_execpolicy_amendment 时必须提供非空 execPolicyAmendment 数组"
        );
      }

      const sanitized = execPolicyAmendment.map((token) => {
        if (!isNonEmptyString(token)) {
          throw new HttpError(
            400,
            "INVALID_EXEC_POLICY_AMENDMENT",
            "execPolicyAmendment 只能包含非空字符串"
          );
        }
        return token;
      });

      return {
        acceptWithExecpolicyAmendment: {
          execpolicy_amendment: sanitized,
        },
      };
    }
    default:
      throw new HttpError(
        400,
        "INVALID_DECISION",
        "decision 必须是 accept/accept_for_session/accept_with_execpolicy_amendment/decline/cancel"
      );
  }
}
