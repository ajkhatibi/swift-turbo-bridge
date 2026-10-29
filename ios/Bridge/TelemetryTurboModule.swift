import Foundation
import ActivityKit
import WidgetKit

@objc(TelemetryBridgeImplementation)
public final class TelemetryBridgeImplementation: NSObject {
    @objc(setSharedKeychainToken:accessGroup:)
    public func setSharedKeychainToken(_ token: String, accessGroup: String) -> Bool {
        TelemetryKeychain.set(token: token, accessGroup: accessGroup)
    }

    private func decode(_ value: NSDictionary) throws -> TelemetrySnapshot {
        let data = try JSONSerialization.data(withJSONObject: value)
        return try JSONDecoder().decode(TelemetrySnapshot.self, from: data).validated()
    }

    @objc(syncTelemetryToWidget:resolve:reject:)
    public func syncTelemetryToWidget(
        _ value: NSDictionary, resolve: @escaping (Any?) -> Void,
        reject: @escaping (String, String, NSError?) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            do {
                let saved = try TelemetrySnapshotStore.save(self.decode(value))
                if saved { WidgetCenter.shared.reloadTimelines(ofKind: TelemetryConfiguration.widgetKind) }
                resolve(saved)
            } catch { reject("E_TELEMETRY_SYNC", "Unable to save telemetry.", error as NSError) }
        }
    }

    @objc(upsertLiveActivity:resolve:reject:)
    public func upsertLiveActivity(
        _ value: NSDictionary, resolve: @escaping (Any?) -> Void,
        reject: @escaping (String, String, NSError?) -> Void
    ) {
        do {
            let snapshot = try decode(value)
            guard #available(iOS 16.2, *) else {
                reject("E_ACTIVITY_UNAVAILABLE", "Live Activities require iOS 16.2.", nil)
                return
            }
            Task {
                do { resolve(try await TelemetryActivityManager.shared.upsert(snapshot)) } catch {
                    reject("E_ACTIVITY", "Unable to update Live Activity.", error as NSError)
                }
            }
        } catch { reject("E_INVALID_SNAPSHOT", "Invalid telemetry snapshot.", error as NSError) }
    }

    @objc(endAllLiveActivitiesWithResolve:reject:)
    public func endAllLiveActivities(
        resolve: @escaping (Any?) -> Void, reject: @escaping (String, String, NSError?) -> Void
    ) {
        guard #available(iOS 16.2, *) else { resolve(nil); return }
        Task {
            await TelemetryActivityManager.shared.endAll()
            resolve(nil)
        }
    }
}

@available(iOS 16.2, *)
private actor TelemetryActivityManager {
    static let shared = TelemetryActivityManager()
    private var tail: Task<Void, Never>?

    func upsert(_ snapshot: TelemetrySnapshot) async throws -> String {
        let previous = tail
        let operation = Task {
            await previous?.value
            return try await self.performUpsert(snapshot)
        }
        tail = Task { _ = try? await operation.value }
        return try await operation.value
    }

    private func performUpsert(_ snapshot: TelemetrySnapshot) async throws -> String {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            throw TelemetryError.invalidConfiguration
        }
        guard try TelemetrySnapshotStore.save(snapshot) else { throw TelemetryError.staleSnapshot }
        WidgetCenter.shared.reloadTimelines(ofKind: TelemetryConfiguration.widgetKind)
        let content = ActivityContent(
            state: TelemetryActivityAttributes.ContentState(snapshot: snapshot),
            staleDate: Date(timeIntervalSince1970: snapshot.lastUpdatedTimestamp / 1000).addingTimeInterval(900)
        )
        let activities = Activity<TelemetryActivityAttributes>.activities
        let matchingActivity = activities
            .filter { $0.attributes.entityId == snapshot.entityId }
            .max { $0.content.state.snapshot.lastUpdatedTimestamp < $1.content.state.snapshot.lastUpdatedTimestamp }
        if let activity = matchingActivity {
            guard activity.content.state.snapshot.lastUpdatedTimestamp <= snapshot.lastUpdatedTimestamp else {
                throw TelemetryError.staleSnapshot
            }
        }
        // A telemetry session owns one activity. Entity replacement ends the previous
        // session, and retaining only the newest match also cleans up duplicates.
        for activity in activities where activity.id != matchingActivity?.id {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        if let activity = matchingActivity {
            await activity.update(content)
            return activity.id
        }
        return try Activity.request(
            attributes: TelemetryActivityAttributes(entityId: snapshot.entityId), content: content, pushType: nil
        ).id
    }

    func endAll() async {
        let previous = tail
        let operation = Task {
            await previous?.value
            await self.performEndAll()
        }
        tail = operation
        await operation.value
    }

    private func performEndAll() async {
        for activity in Activity<TelemetryActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
