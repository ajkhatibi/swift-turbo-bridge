import Foundation

enum TelemetryError: Error, LocalizedError {
    case invalidSnapshot, invalidConfiguration, unavailableStorage, staleSnapshot
    case keychainFailure, invalidCommand, invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidSnapshot: return "Invalid telemetry snapshot."
        case .invalidConfiguration: return "Native telemetry configuration is missing or invalid."
        case .unavailableStorage: return "Shared telemetry storage is unavailable."
        case .staleSnapshot: return "Telemetry is older than the stored snapshot."
        case .keychainFailure: return "Shared credentials are unavailable."
        case .invalidCommand: return "Unsupported remote command."
        case .invalidResponse: return "The command server returned an invalid response."
        }
    }
}

struct TelemetrySnapshot: Codable, Hashable {
    let entityId: String
    let displayName: String
    let batteryOrProgressPercent: Double
    let lockState: String
    // Unix epoch milliseconds, matching the JS contract and server response.
    let lastUpdatedTimestamp: Double

    func validated() throws -> Self {
        guard !entityId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              entityId.utf16.count <= 256,
              !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              displayName.utf16.count <= 256,
              !entityId.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }),
              !displayName.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }),
              batteryOrProgressPercent.isFinite,
              (0...100).contains(batteryOrProgressPercent),
              ["LOCKED", "UNLOCKED", "TRANSITIONING"].contains(lockState),
              lastUpdatedTimestamp.isFinite, lastUpdatedTimestamp >= 0,
              lastUpdatedTimestamp <= 9_007_199_254_740_991,
              lastUpdatedTimestamp.rounded(.towardZero) == lastUpdatedTimestamp else {
            throw TelemetryError.invalidSnapshot
        }
        return self
    }
}

enum TelemetryConfiguration {
    static let appGroup = "group.com.khatibi.enterprise.telemetry"
    static let widgetKind = "TelemetryWidget"

    static func sharedContainer() throws -> URL {
        guard Bundle.main.object(forInfoDictionaryKey: "TelemetryAppGroup") as? String == appGroup,
              let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
            throw TelemetryError.invalidConfiguration
        }
        return url
    }

    static func keychainAccessGroup() throws -> String {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "TelemetryKeychainAccessGroup") as? String,
              !group.isEmpty, !group.contains("$("), !group.contains("*"),
              group.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw TelemetryError.invalidConfiguration
        }
        return group
    }

    static func commandURL() throws -> URL {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "TelemetryCommandBaseURL") as? String,
              let parts = URLComponents(string: value),
              parts.scheme == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port == nil || parts.port == 443,
              let url = parts.url else {
            throw TelemetryError.invalidConfiguration
        }
        return url.appendingPathComponent("v1/vehicles/command")
    }
}
