import ActivityKit

@available(iOS 16.2, *)
struct TelemetryActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let snapshot: TelemetrySnapshot
    }

    let entityId: String
}
