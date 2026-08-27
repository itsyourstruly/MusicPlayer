import SwiftUI
import AVFoundation
import os

// AVFoundation imported so the app can configure the audio session at launch if needed.
// os imported for unified logging (OSLog) used in player and library subsystems.

@main
struct MusicPlayerApp: App {
    // Body
    var body: some Scene {
        WindowGroup {
            ContentView()
                #if os(macOS)
                // Minimum size keeps the split-view layout usable; below this the UI collapses
                .frame(minWidth: 860, minHeight: 560)
                #endif
        }
        #if os(macOS)
        // Default launch size gives comfortable room for the sidebar + detail + player console
        .defaultSize(width: 1120, height: 740)
        #endif
    }
}
