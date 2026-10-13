import SwiftUI
import AVFoundation
import os
#if os(iOS)
import BackgroundTasks
import UIKit
#endif

// AVFoundation imported so the app can configure the audio session at launch if needed.
// os imported for unified logging (OSLog) used in player and library subsystems.

@main
struct MusicPlayerApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        AppLogger.ui.info("LAC MusicPlayer application launched. Session logging active.")
        #if os(iOS)
        registerBackgroundTasks()
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
                let taskID = UIApplication.shared.beginBackgroundTask(withName: "WALCheckpoint") {
                    // Expiration handler
                }
                Task.detached(priority: .utility) {
                    LibraryDatabase.shared.walCheckpoint()
                    UIApplication.shared.endBackgroundTask(taskID)
                }
                scheduleAppRefresh()
                #else
                Task.detached(priority: .utility) {
                    LibraryDatabase.shared.walCheckpoint()
                }
                #endif
            }
        }
    }

    #if os(iOS)
    private func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: "com.musicplayer.jellyfin.sync",
            using: nil
        ) { task in
            guard let appRefreshTask = task as? BGAppRefreshTask else { return }
            handleBackgroundSync(task: appRefreshTask)
        }
    }

    private func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: "com.musicplayer.jellyfin.sync")
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60) // 1 hour
        try? BGTaskScheduler.shared.submit(request)
    }

    private func handleBackgroundSync(task: BGAppRefreshTask) {
        scheduleAppRefresh()
        let syncTask = Task {
            LibraryDatabase.shared.walCheckpoint()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            syncTask.cancel()
        }
    }
    #endif
}
