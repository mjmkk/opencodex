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

public enum RemotePushRegistrationService {
    private enum Keys {
        static let pendingDeviceToken = "codex.push.pending_device_token"
        static let uploadedDeviceToken = "codex.push.uploaded_device_token"
    }

    private struct RegisterRequest: Codable, Sendable {
        let platform: String
        let deviceToken: String
        let bundleId: String?
        let environment: String
        let deviceName: String?
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
        if uploaded == normalized {
            UserDefaults.standard.removeObject(forKey: Keys.pendingDeviceToken)
            return
        }

        do {
            try await register(token: normalized)
            UserDefaults.standard.set(normalized, forKey: Keys.uploadedDeviceToken)
            UserDefaults.standard.removeObject(forKey: Keys.pendingDeviceToken)
        } catch {
            #if DEBUG
            print("[PushSync] register failed: \(error.localizedDescription)")
            #endif
        }
    }

    private static func register(token: String) async throws {
        guard let configuration = WorkerConfiguration.load() else {
            throw URLError(.userAuthenticationRequired)
        }

        guard var components = URLComponents(string: configuration.baseURL) else {
            throw URLError(.badURL)
        }
        let normalizedPath = components.path.trimmingCharacters(in: .whitespacesAndNewlines)
        components.path = normalizedPath + "/v1/push/devices/register"
        guard let url = components.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let authToken = configuration.token, !authToken.isEmpty {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }

        let payload = RegisterRequest(
            platform: "ios",
            deviceToken: token,
            bundleId: Bundle.main.bundleIdentifier,
            environment: buildEnvironment,
            deviceName: currentDeviceName
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

    private static var currentDeviceName: String? {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return nil
        #endif
    }
}
