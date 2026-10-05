import AppIntents
import SwiftUI
import WidgetKit

@main
struct CochleaWidgets: WidgetBundle {
    var body: some Widget {
        RecordingWidget()
        if #available(iOS 18.0, *) {
            CaptureSongControl()
        }
    }
}

@available(iOS 18.0, *)
struct CaptureSongControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.alexmiller.offline-shazam.capture") {
            ControlWidgetButton(action: CaptureSongIntent()) {
                Label("Capture song", systemImage: "waveform")
            }
        }
        .displayName("Capture song")
        .description("Identify music or save a song to recognize later.")
    }
}
