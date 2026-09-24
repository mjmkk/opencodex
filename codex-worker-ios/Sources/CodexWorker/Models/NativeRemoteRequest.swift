import Foundation

/// A live native observation. This is not a persisted approval lifecycle.
public struct NativeRemoteRequest: Codable, Equatable, Sendable, Identifiable {
    public var receipt_id: String
    public var request_id: JSONValue
    public var thread_id: String
    public var turn_id: String?
    public var issue: String?
    public var request: [String: JSONValue]?
    public var request_version: String?
    public var response_available: Bool
    public var response_submitted: Bool
    public var native_resolution: JSONValue?
    public var native_terminal: JSONValue?
    public var observation: String?
    public var id: String { receipt_id + ":" + request_id.nativeJSON }
    public var method: String { request?["method"]?.stringValue ?? "" }
    public var params: [String: JSONValue] { request?["params"]?.objectValue ?? [:] }
    /// The exact text and destination the user reviewed, including absent versions.
    var confirmationContext: JSONValue {
        .object(["receipt": .string(receipt_id), "id": request_id,
                 "thread": .string(thread_id), "turn": turn_id.map(JSONValue.string) ?? .null,
                 "version": request_version.map(JSONValue.string) ?? .null,
                 "request": request.map(JSONValue.object) ?? .null])
    }
    var canSubmitResponse: Bool {
        request != nil && response_available && !response_submitted &&
            native_resolution == nil && native_terminal == nil
    }
    func matchesDestination(of other: Self) -> Bool {
        receipt_id == other.receipt_id && request_id == other.request_id &&
            thread_id == other.thread_id && turn_id == other.turn_id
    }
    func validatesConfirmation(of reviewed: Self) -> Bool {
        canSubmitResponse && confirmationContext == reviewed.confirmationContext
    }
    public var title: String {
        switch method {
        case "item/commandExecution/requestApproval": return "是否执行这条命令"
        case "item/fileChange/requestApproval": return "是否应用这些文件修改"
        case "item/permissions/requestApproval": return "是否授予请求的权限"
        case "item/tool/requestUserInput": return "需要你的回答"
        case "mcpServer/elicitation/request": return "需要你补充信息"
        default: return params["message"]?.stringValue ?? params["reason"]?.stringValue ?? (method.isEmpty ? "原生请求记录" : method)
        }
    }
    public var selection: NativeRequestSelection {
        .init(receipt_id: receipt_id, request_id: request_id, request_version: request_version)
    }
    public var statusText: String {
        if native_resolution != nil { return "原生请求已结束（已响应或已清理）" }
        if native_terminal != nil { return "原轮次已结束" }
        if response_submitted { return "已提交，等待原生回执" }
        return response_available ? "等待你处理" : "当前无法响应，请刷新核对"
    }
    public var decisions: [JSONValue] {
        switch method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            if let available = params["availableDecisions"]?.arrayValue { return available }
            var values: [JSONValue] = [.string("accept"), .string("acceptForSession"), .string("decline"), .string("cancel")]
            if method == "item/commandExecution/requestApproval" {
                if let amendment = params["proposedExecpolicyAmendment"], amendment.arrayValue != nil {
                    values.append(.object(["acceptWithExecpolicyAmendment": .object(["execpolicy_amendment": amendment])]))
                }
                for amendment in params["proposedNetworkPolicyAmendments"]?.arrayValue ?? [] {
                    values.append(.object(["applyNetworkPolicyAmendment": .object(["network_policy_amendment": amendment])]))
                }
            }
            return values
        default: return []
        }
    }
    public static func decisionLabel(_ value: JSONValue) -> String {
        switch value.stringValue {
        case "accept": return "仅允许本次"
        case "acceptForSession": return "本会话后续同类请求也允许"
        case "decline": return "拒绝此操作，保留原轮次"
        case "cancel": return "拒绝并中断原轮次"
        default:
            if value.objectValue?["acceptWithExecpolicyAmendment"] != nil { return "允许并保存命令前缀规则" }
            if value.objectValue?["applyNetworkPolicyAmendment"] != nil { return "保存网络规则" }
            return value.nativeJSON
        }
    }
}

public struct NativeRequestList: Codable, Sendable { public var data: [NativeRemoteRequest] }
public struct NativeRequestSelection: Codable, Sendable {
    public var receipt_id: String
    public var request_id: JSONValue
    public var request_version: String?
    public var response: JSONValue? = nil
}

extension JSONValue {
    var nativeJSON: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? String(data: encoder.encode(self), encoding: .utf8)) ?? "null"
    }
}

/// Only render schema forms we understand; never invent a binary approval.
enum NativeForm {
    static func options(_ schema: [String: JSONValue]) -> [(String, String)] {
        if let values = schema["enum"]?.arrayValue {
            let names = schema["enumNames"]?.arrayValue ?? []
            return values.enumerated().compactMap { index, value in
                guard let text = value.stringValue else { return nil }
                return (text, index < names.count ? names[index].stringValue ?? text : text)
            }
        }
        return (schema["oneOf"]?.arrayValue ?? schema["anyOf"]?.arrayValue ?? []).compactMap {
            guard let object = $0.objectValue, let value = object["const"]?.stringValue else { return nil }
            return (value, object["title"]?.stringValue ?? value)
        }
    }
    static func supported(_ schema: [String: JSONValue]) -> Bool {
        guard schema["type"]?.stringValue == "object", let fields = schema["properties"]?.objectValue else { return false }
        return fields.values.allSatisfy { field in
            guard let f = field.objectValue else { return false }
            // Extended forms with references/conditional logic need the native client.
            if f["$ref"] != nil || f["pattern"] != nil || f["allOf"] != nil { return false }
            switch f["type"]?.stringValue {
            case "string", "number", "integer", "boolean": return true
            case "array": return !options(f["items"]?.objectValue ?? [:]).isEmpty
            default: return false
            }
        }
    }
    static func valid(_ schema: [String: JSONValue], content: [String: JSONValue]) -> Bool {
        guard supported(schema) else { return false }
        for key in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
            if content[key] == nil { return false }
        }
        for (key, value) in content {
            guard let field = schema["properties"]?.objectValue?[key]?.objectValue else { return false }
            let choices = options(field).map(\.0)
            switch field["type"]?.stringValue {
            case "string":
                guard let text = value.stringValue else { return false }
                if !choices.isEmpty && !choices.contains(text) { return false }
                if let min = field["minLength"]?.intValue, text.count < min { return false }
                if let max = field["maxLength"]?.intValue, text.count > max { return false }
            case "number", "integer":
                guard let number = value.doubleValue, number.isFinite else { return false }
                if field["type"]?.stringValue == "integer" && value.intValue == nil { return false }
                if let min = field["minimum"]?.doubleValue, number < min { return false }
                if let max = field["maximum"]?.doubleValue, number > max { return false }
            case "boolean": if value.boolValue == nil { return false }
            case "array":
                guard let array = value.arrayValue else { return false }
                let allowed = options(field["items"]?.objectValue ?? [:]).map(\.0)
                if !array.allSatisfy({ $0.stringValue.map(allowed.contains) ?? false }) { return false }
                if let min = field["minItems"]?.intValue, array.count < min { return false }
                if let max = field["maxItems"]?.intValue, array.count > max { return false }
            default: return false
            }
        }
        return true
    }
}
