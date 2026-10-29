import WidgetKit
import SwiftUI

struct TelemetryEntry: TimelineEntry {
    let date: Date
    let snapshot: TelemetrySnapshot?
}

struct TelemetryProvider: TimelineProvider {
    func placeholder(in context: Context) -> TelemetryEntry {
        TelemetryEntry(date: Date(), snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (TelemetryEntry) -> Void) {
        completion(loadFromSharedContainer())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TelemetryEntry>) -> Void) {
        let entry = loadFromSharedContainer()
        let nextRefresh = Date().addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }

    private func loadFromSharedContainer() -> TelemetryEntry {
        TelemetryEntry(date: Date(), snapshot: try? TelemetrySnapshotStore.load())
    }
}

struct TelemetryWidgetEntryView: View {
    var entry: TelemetryProvider.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let snapshot = entry.snapshot {
                HStack {
                    Image(systemName: snapshot.lockState == "LOCKED" ? "lock.shield.fill" : "lock.open.fill")
                        .foregroundColor(snapshot.lockState == "LOCKED" ? .green : .orange)
                    Text(snapshot.displayName).font(.headline).lineLimit(1)
                }
                ProgressView(value: snapshot.batteryOrProgressPercent, total: 100).tint(.blue)
                Text("Charge / Readiness: \(Int(snapshot.batteryOrProgressPercent))%")
                    .font(.caption2).foregroundColor(.secondary)
                Text(snapshot.lockState).font(.caption2)
                Text(Date(timeIntervalSince1970: snapshot.lastUpdatedTimestamp / 1000), style: .relative)
                    .font(.caption2).foregroundColor(.secondary)
                if #available(iOS 17.0, *) {
                    HStack {
                        Button(intent: RemoteCommandIntent(entityId: snapshot.entityId, command: .lock)) {
                            Label("Lock", systemImage: "lock.fill")
                        }
                        Button(intent: RemoteCommandIntent(entityId: snapshot.entityId, command: .unlock)) {
                            Label("Unlock", systemImage: "lock.open")
                        }
                        Button(intent: RemoteCommandIntent(entityId: snapshot.entityId, command: .startClimate)) {
                            Label("Climate", systemImage: "fan")
                        }
                    }
                    .font(.caption2)
                    .labelStyle(.iconOnly)
                }
            } else {
                Label("Telemetry unavailable", systemImage: "antenna.radiowaves.left.and.right.slash")
                Text("Open the app to sync.").font(.caption)
            }
        }
        .padding()
    }
}

struct TelemetryWidget: Widget {
    let kind = TelemetryConfiguration.widgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TelemetryProvider()) { entry in
            if #available(iOS 17.0, *) {
                TelemetryWidgetEntryView(entry: entry).containerBackground(.background, for: .widget)
            } else {
                TelemetryWidgetEntryView(entry: entry)
            }
        }
        .configurationDisplayName("Vehicle Telemetry")
        .description("Server-confirmed telemetry and secure vehicle commands.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
