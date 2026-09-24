import Foundation

enum PushEnvironment {
    // Release builds can be development-signed. Read the signed provisioning
    // environment instead of inferring APNs routing from the optimization mode.
    static var current: String {
        #if targetEnvironment(simulator)
        return "sandbox"
        #else
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8))?.lowerBound,
              let end = data.range(of: Data("</plist>".utf8), in: start..<data.count)?.upperBound,
              let plist = try? PropertyListSerialization.propertyList(from: data[start..<end], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let environment = entitlements["aps-environment"] as? String else { return "production" }
        return environment == "development" ? "sandbox" : "production"
        #endif
    }
}
