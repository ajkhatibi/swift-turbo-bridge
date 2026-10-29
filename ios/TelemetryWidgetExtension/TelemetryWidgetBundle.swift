import SwiftUI
import WidgetKit

@main
struct TelemetryWidgetBundle: WidgetBundle {
    var body: some Widget {
        TelemetryWidget()
        TelemetryLiveActivity()
    }
}
