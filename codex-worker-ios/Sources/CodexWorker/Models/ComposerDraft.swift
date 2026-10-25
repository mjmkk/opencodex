import Foundation

/// Retains user text and a single attempted write. There is no background resend queue.
public struct ComposerDraft: Codable, Equatable, Sendable {
    public var text: String = ""
    public var outgoing: ComposerSubmission?
    public var controlAttempt: NativeControlAttempt? = nil
    public var editedAt: Date? = Date()
    public var textRevision: String? = UUID().uuidString
    // Allocated when the reducer captures an edit, before its async save starts.
    // Date remains a display fact; it is never the ordering authority.
    public var editOrdinal: UInt64? = ComposerEditOrder.shared.next()
}

/// One App process owns this cache. A lock orders captured edits across tasks;
/// cache initialization seeds it from the durable high water mark.
final class ComposerEditOrder: @unchecked Sendable {
    static let shared = ComposerEditOrder()
    private let lock = NSLock()
    private var highWater: UInt64
    init(highWater: UInt64 = 0) { self.highWater = highWater }
    func observe(_ ordinal: UInt64?) {
        guard let ordinal else { return }
        lock.lock(); defer { lock.unlock() }
        highWater = max(highWater, ordinal)
    }
    func next() -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        guard highWater < UInt64.max else { return nil }
        highWater += 1
        return highWater
    }
}

public struct ComposerSubmission: Codable, Equatable, Sendable {
    public var id: String
    public var body: String
    public var attemptedAt: Date
    public var acknowledgedReceiptID: String?
}
