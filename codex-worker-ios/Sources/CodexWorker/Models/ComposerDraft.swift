import Foundation

/// Retains user text and a single attempted write. There is no background resend queue.
public struct ComposerDraft: Codable, Equatable, Sendable {
    public var text: String = ""
    public var outgoing: ComposerSubmission?
    public var controlAttempt: NativeControlAttempt? = nil
    public var editedAt: Date? = Date()
    public var textRevision: String? = UUID().uuidString
}

public struct ComposerSubmission: Codable, Equatable, Sendable {
    public var id: String
    public var body: String
    public var attemptedAt: Date
    public var acknowledgedReceiptID: String?
}
