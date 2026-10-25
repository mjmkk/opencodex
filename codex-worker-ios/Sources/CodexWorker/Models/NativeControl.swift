import Foundation

/// A current configured native owner's observation. Mirror metadata never grants control.
public struct NativeControlObservation: Codable, Equatable, Sendable {
    public var thread_id: String
    public var host_id: String
    public var owner_client_id: String
    public var `protocol`: String
    public var status: String
    public var reply_route: String?
    public var input_available: Bool
    public var stop_available: Bool
    public var active_turn_id: String?
    public var control_receipt: String
    public var control_version: String
    public var revision: Int?
    public var reason: String?
    public var steer_semantics: String
    public var stop_mode: String
    public var stop_pauses_goal: Bool
    public var stop_may_interrupt_active_thread_descendants: Bool

    func validates(threadID: String) -> Bool {
        self.protocol == "plain-text-local-v2" && thread_id == threadID && host_id == "local"
            && !owner_client_id.isEmpty
            && control_receipt.count == 64 && control_version.count == 64
            && control_receipt.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            && control_version.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    var canInput: Bool {
        input_available && ((status == "idle" && reply_route == "start")
            || (status == "running" && reply_route == "steer" && active_turn_id?.isEmpty == false
                && steer_semantics == "current-task-may-follow-new-active-turn"))
    }

    var canStop: Bool {
        status == "running" && stop_available && active_turn_id?.isEmpty == false
            && stop_mode == "user-stop" && !stop_pauses_goal && stop_may_interrupt_active_thread_descendants
    }
}

public enum NativeControlOperation: String, Codable, Sendable {
    case input, interrupt
}

public struct NativeControlWriteBody: Codable, Equatable, Sendable {
    public var submission_id: String
    public var control_receipt: String
    public var control_version: String
    public var text: String?
    public var expected_turn_id: String?
}

public struct NativeControlReceipt: Codable, Equatable, Sendable {
    public var submission_id: String
    public var thread_id: String
    public var operation: String
    public var status: String
    public var turn_id: String?
    public var code: String?
    public var goal_pause_error: String?
}

/// Stored with the existing scoped composer. Endpoint credentials are never stored here.
public struct NativeControlAttempt: Codable, Equatable, Sendable {
    public var operation: NativeControlOperation
    public var request: NativeControlWriteBody
    public var attemptedAt: Date
    public var receipt: NativeControlReceipt? = nil
    public var localRejection: String? = nil
    public var draftTextRevision: String? = nil
    public var draftEditOrdinal: UInt64? = nil

    var isUncertain: Bool {
        localRejection == nil && (receipt == nil || receipt?.status == "unknown")
    }

    /// A delayed GET or transport failure cannot erase an already known result.
    /// Two different terminal receipts for one write are a conflict, not progress.
    func reconciled(receipt incoming: NativeControlReceipt?, localRejection: String?, threadID: String) throws -> Self {
        if let incoming, !validates(incoming, threadID: threadID) { throw CodexError.invalidState }
        if !isUncertain {
            if let incoming, incoming.status != "unknown", incoming != receipt { throw CodexError.invalidState }
            return self
        }
        var result = self
        result.receipt = incoming ?? receipt
        result.localRejection = localRejection
        return result
    }

    func validates(_ receipt: NativeControlReceipt, threadID: String) -> Bool {
        guard receipt.thread_id == threadID, receipt.submission_id == request.submission_id else { return false }
        if operation == .input {
            guard ["start", "steer"].contains(receipt.operation) else { return false }
            return receipt.status == "accepted" ? receipt.turn_id?.isEmpty == false
                : ["unknown", "rejected"].contains(receipt.status)
        }
        guard receipt.operation == "interrupt" else { return false }
        switch receipt.status {
        case "interrupted": return receipt.turn_id == request.expected_turn_id && receipt.turn_id?.isEmpty == false
        case "not_interrupted": return receipt.turn_id == nil
        case "unknown", "rejected": return true
        default: return false
        }
    }
}
