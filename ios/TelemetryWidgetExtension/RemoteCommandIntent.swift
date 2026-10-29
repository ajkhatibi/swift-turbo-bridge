import AppIntents
import Foundation
import WidgetKit

@available(iOS 17.0, *)
enum TelemetryCommand: String, AppEnum {
    case lock = "LOCK"
    case unlock = "UNLOCK"
    case startClimate = "START_CLIMATE"

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Vehicle command")
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .lock: "Lock", .unlock: "Unlock", .startClimate: "Start climate"
    ]
}

@available(iOS 17.0, *)
struct RemoteCommandIntent: AppIntent {
    static var title: LocalizedStringResource = "Send vehicle command"
    static var description = IntentDescription("Send an authenticated command and show the server-confirmed telemetry.")
    static var openAppWhenRun = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Entity") var entityId: String
    @Parameter(title: "Command") var command: TelemetryCommand

    init() {}

    init(entityId: String, command: TelemetryCommand) {
        self.entityId = entityId
        self.command = command
    }

    func perform() async throws -> some IntentResult {
        if command == .unlock {
            try await requestConfirmation(result: .result(dialog: "Unlock this vehicle?"))
        }
        try await TelemetryCommandClient.send(entityId: entityId, command: command.rawValue)
        WidgetCenter.shared.reloadTimelines(ofKind: TelemetryConfiguration.widgetKind)
        return .result()
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private enum TelemetryCommandClient {
    static func send(entityId: String, command: String) async throws {
        guard ["LOCK", "UNLOCK", "START_CLIMATE"].contains(command),
              let current = try TelemetrySnapshotStore.load(), current.entityId == entityId else {
            throw TelemetryError.invalidCommand
        }
        let url = try TelemetryConfiguration.commandURL()
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let authorization = ["Bearer", try TelemetryKeychain.token()].joined(separator: " ")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "Idempotency-Key")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "entityId": entityId, "command": command
        ])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url == url, response.mimeType?.lowercased() == "application/json",
              data.count <= 16_384 else { throw TelemetryError.invalidResponse }
        let snapshot = try JSONDecoder().decode(TelemetrySnapshot.self, from: data).validated()
        guard snapshot.entityId == entityId,
              snapshot.lastUpdatedTimestamp > current.lastUpdatedTimestamp,
              command != "LOCK" || snapshot.lockState == "LOCKED",
              command != "UNLOCK" || snapshot.lockState == "UNLOCKED" else {
            throw TelemetryError.invalidResponse
        }
        // Re-read and compare under flock, after the network round trip. Never optimistically
        // change local lock state or overwrite a newer host/extension snapshot.
        guard try TelemetrySnapshotStore.save(snapshot, expectedEntity: entityId) else {
            throw TelemetryError.staleSnapshot
        }
    }
}
