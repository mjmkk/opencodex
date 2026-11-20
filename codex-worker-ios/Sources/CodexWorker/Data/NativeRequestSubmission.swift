import Foundation

enum NativeRequestConfirmationError: Error {
    case changed(NativeRemoteRequest)
}

enum NativeRequestSubmission {
    /// One final read, durable write intent, then one response. The owner also fences atomically.
    @MainActor static func send(reviewed: NativeRemoteRequest, result: JSONValue,
        read: (NativeRequestSelection) async throws -> NativeRemoteRequest,
        beforeWrite: (NativeRemoteRequest, JSONValue) async throws -> Void,
        respond: (NativeRequestSelection) async throws -> NativeRemoteRequest) async throws -> NativeRemoteRequest {
        let current = try await read(reviewed.selection)
        guard current.validatesConfirmation(of: reviewed) else { throw NativeRequestConfirmationError.changed(current) }
        let response = JSONValue.object(["id": current.request_id, "result": result])
        var selection = current.selection
        selection.response = response
        try await beforeWrite(current, response)
        return try await respond(selection)
    }
}
