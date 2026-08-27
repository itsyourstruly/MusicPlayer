//
//  MusicPlayerApp.swift
//  MusicPlayer
//
//  Created by Principal Apple Software Engineer on 8/24/26.
//

import SwiftUI
import AVFoundation
import os

@main
struct MusicPlayerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                #if os(macOS)
                .frame(minWidth: 860, minHeight: 560)
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1120, height: 740)
        #endif
    }
}
