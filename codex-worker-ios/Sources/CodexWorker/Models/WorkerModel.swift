//
//  WorkerModel.swift
//  CodexWorker
//
//  模型列表与线程归档响应模型
//

import Foundation

public struct WorkerModel: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let provider: String?
    public let displayName: String?

    public init(
        id: String,
        name: String,
        provider: String?,
        displayName: String?
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.displayName = displayName
    }

    public var listTitle: String {
        if let displayName, !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return displayName
        }
        if let provider, !provider.isEmpty {
            return "\(provider)/\(id)"
        }
        return id
    }
}

public struct WorkerModelsResponse: Codable, Sendable {
    public let data: [WorkerModel]

    public init(data: [WorkerModel]) {
        self.data = data
    }
}

public struct ArchiveThreadResponse: Codable, Sendable {
    public let threadId: String
    public let status: String

    public init(threadId: String, status: String) {
        self.threadId = threadId
        self.status = status
    }
}
