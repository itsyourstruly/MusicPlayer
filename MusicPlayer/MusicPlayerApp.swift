import SwiftUI
import AVFoundation
import os
#if os(iOS)
import UIKit
#endif

// AVFoundation imported so the app can configure the audio session at launch if needed.
// os imported for unified logging (OSLog) used in player and library subsystems.

@main
struct MusicPlayerApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        AppLogger.ui.info("LAC MusicPlayer application launched. Session logging active.")
        #if DEBUG
        // DEBUG-only classifier/normalizer/tokenizer self-check (logged via os.Logger; compiled out of Release).
        Task.detached(priority: .utility) { SearchSelfCheck.run() }
        #endif
    }

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
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                #if os(iOS)
                var taskID: UIBackgroundTaskIdentifier = .invalid
                taskID = UIApplication.shared.beginBackgroundTask(withName: "FlushLibrarySnapshot") {
                    if taskID != .invalid {
                        UIApplication.shared.endBackgroundTask(taskID)
                        taskID = .invalid
                    }
                }
                Task.detached(priority: .utility) {
                    if let store = await MainActor.run(body: { LibraryStore.shared }) {
                        let sDir = await MainActor.run { store.storageDirectoryURL }
                        let sHash = await MainActor.run { store.computeSettingsHash() }
                        await LibraryRepository.shared.flushImmediate(storageDir: sDir, settingsHash: sHash)
                    }
                    await MainActor.run {
                        LibraryStore.shared?.flushSnapshotImmediate()
                    }
                    if taskID != .invalid {
                        UIApplication.shared.endBackgroundTask(taskID)
                        taskID = .invalid
                    }
                }
                #else
                Task.detached(priority: .utility) {
                    if let store = await MainActor.run(body: { LibraryStore.shared }) {
                        let sDir = await MainActor.run { store.storageDirectoryURL }
                        let sHash = await MainActor.run { store.computeSettingsHash() }
                        await LibraryRepository.shared.flushImmediate(storageDir: sDir, settingsHash: sHash)
                    }
                    await MainActor.run {
                        LibraryStore.shared?.flushSnapshotImmediate()
                    }
                }
                #endif
            }
        }
    }
}
