import Foundation
import Darwin

enum TelemetrySnapshotStore {
    // Lock a separate, permanent inode: atomic replacement changes the JSON file's inode.
    private static func withLock<T>(_ body: (URL) throws -> T) throws -> T {
        let container = try TelemetryConfiguration.sharedContainer()
        let lockURL = container.appendingPathComponent("telemetry.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw TelemetryError.unavailableStorage }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw TelemetryError.unavailableStorage }
        defer { flock(descriptor, LOCK_UN) }
        return try body(container.appendingPathComponent("telemetry.json"))
    }

    private static func read(_ url: URL) throws -> TelemetrySnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard data.count <= 16_384 else { throw TelemetryError.invalidSnapshot }
        return try JSONDecoder().decode(TelemetrySnapshot.self, from: data).validated()
    }

    static func load() throws -> TelemetrySnapshot? {
        try withLock { try read($0) }
    }

    @discardableResult
    static func save(_ snapshot: TelemetrySnapshot, expectedEntity: String? = nil) throws -> Bool {
        let snapshot = try snapshot.validated()
        return try withLock { url in
            let current = try read(url)
            if let expectedEntity {
                guard snapshot.entityId == expectedEntity, current?.entityId == expectedEntity else {
                    throw TelemetryError.invalidResponse
                }
            }
            if let current {
                if snapshot.lastUpdatedTimestamp < current.lastUpdatedTimestamp { return false }
                if snapshot.lastUpdatedTimestamp == current.lastUpdatedTimestamp {
                    return snapshot == current
                }
            }
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        }
    }
}
