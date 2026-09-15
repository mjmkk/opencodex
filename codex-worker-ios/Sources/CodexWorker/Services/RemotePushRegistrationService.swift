//
//  RemotePushRegistrationService.swift
//  CodexWorker
//
//  远程推送设备注册服务：把 APNs device token 上报到 Worker 后端
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

@MainActor
public enum RemotePushRegistrationService {
    private enum Keys {
        static let pendingDeviceToken = "codex.push.pending_device_token"
        static let uploadedDeviceToken = "codex.push.uploaded_device_token"
        static let uploadedScope = "codex.push.uploaded_scope"
        static let uploadedAt = "codex.push.uploaded_at"
    }

    private struct RegisterRequest: Codable, Sendable {
        let platform: String
        let deviceToken: String
        let bundleId: String?
        let environment: String
        let deviceName: String?
        let clientScope: String
    }

    public static func handleDeviceToken(_ tokenData: Data) async {
        let hex = tokenData.map { String(format: "%02x", $0) }.joined()
        await handleDeviceTokenHexString(hex)
    }

    public static func handleDeviceTokenHexString(_ token: String) async {
        guard let normalized = normalize(token) else { return }
        UserDefaults.standard.set(normalized, forKey: Keys.pendingDeviceToken)
        await flushPendingRegistration()
    }

    public static func flushPendingRegistration() async {
        guard
            let pending = UserDefaults.standard.string(forKey: Keys.pendingDeviceToken),
            let normalized = normalize(pending)
        else {
            return
        }

        let uploaded = UserDefaults.standard.string(forKey: Keys.uploadedDeviceToken)
        guard let configuration = WorkerConfiguration.load(), let scope = try? MobileSyncEngine.scope() else { return }
        if uploaded == normalized && UserDefaults.standard.string(forKey: Keys.uploadedScope) == scope &&
            Date().timeIntervalSince1970 - UserDefaults.standard.double(forKey: Keys.uploadedAt) < 86400 {
            return
        }

        do {
            try await register(token: normalized, configuration: configuration, clientScope: binding(for: scope))
            guard (try? MobileSyncEngine.scope()) == scope else { return }
            UserDefaults.standard.set(normalized, forKey: Keys.uploadedDeviceToken)
            UserDefaults.standard.set(scope, forKey: Keys.uploadedScope)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Keys.uploadedAt)
        } catch {
            #if DEBUG
            print("[PushSync] register failed: \(error.localizedDescription)")
            #endif
        }
    }

    private static func register(token: String, configuration: WorkerConfiguration, clientScope: String) async throws {
        guard var components = URLComponents(string: configuration.baseURL) else {
            throw URLError(.badURL)
        }
        let normalizedPath = components.path.trimmingCharacters(in: .whitespacesAndNewlines)
        components.path = normalizedPath + "/v1/push/devices/register"
        guard let url = components.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let authToken = configuration.token, !authToken.isEmpty {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }

        // UIDevice.current 是 @MainActor 隔离的，需要在主线程读取
        let deviceName = await MainActor.run { currentDeviceName }
        let payload = RegisterRequest(
            platform: "ios",
            deviceToken: token,
            bundleId: Bundle.main.bundleIdentifier,
            environment: buildEnvironment,
            deviceName: deviceName,
            clientScope: clientScope
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            throw URLError(.cannotParseResponse)
        }
    }

    // A random public installation binding is sent in APNs, never an account/token hash.
    static func binding(for accountScope: String, defaults: UserDefaults = .standard) -> String {
        let key = "codex.push.binding." + accountScope
        if let value = defaults.string(forKey: key) { return value }
        let value = UUID().uuidString
        defaults.set(value, forKey: key)
        return value
    }

    public static func matchesCurrentAccount(_ clientScope: String?) -> Bool {
        guard let clientScope, let account = try? MobileSyncEngine.scope() else { return false }
        return binding(for: account) == clientScope
    }

    private static func normalize(_ token: String?) -> String? {
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return nil
        }
        guard token.range(of: "^[0-9a-f]{64,512}$", options: .regularExpression) != nil else {
            return nil
        }
        return token
    }

    private static var buildEnvironment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    @MainActor
    private static var currentDeviceName: String? {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return nil
        #endif
    }
}
