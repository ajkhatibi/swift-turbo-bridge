import ActivityKit
import SwiftUI
import WidgetKit

@available(iOS 16.2, *)
struct TelemetryLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TelemetryActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 8) {
                Text(context.state.snapshot.displayName).font(.headline)
                Text(context.state.snapshot.lockState)
                ProgressView(value: context.state.snapshot.batteryOrProgressPercent, total: 100)
                Text(Date(timeIntervalSince1970: context.state.snapshot.lastUpdatedTimestamp / 1000), style: .relative)
                    .font(.caption)
            }
            .padding()
            .foregroundStyle(.white)
            .activityBackgroundTint(.black.opacity(0.85))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.snapshot.lockState == "LOCKED" ? "lock.fill" : "lock.open")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(Int(context.state.snapshot.batteryOrProgressPercent))%")
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack {
                        Text(context.state.snapshot.displayName).lineLimit(1)
                        Text(context.state.snapshot.lockState).font(.caption)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.snapshot.lockState == "LOCKED" ? "lock.fill" : "lock.open")
            } compactTrailing: {
                Text("\(Int(context.state.snapshot.batteryOrProgressPercent))%")
            } minimal: {
                Image(systemName: "bolt.car")
            }
        }
    }
}
