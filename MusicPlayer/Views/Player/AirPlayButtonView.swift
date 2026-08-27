//
//  AirPlayButtonView.swift
//  MusicPlayer
//
//  Created by Principal Apple Software Engineer on 8/24/26.
//

import SwiftUI
import AVKit

#if canImport(UIKit)
import UIKit

/// Native AirPlay & Bluetooth audio route picker wrapper for iOS.
public struct AirPlayButtonView: UIViewRepresentable {
    public init() {}

    public func makeUIView(context: Context) -> AVRoutePickerView {
        let routePickerView = AVRoutePickerView()
        routePickerView.tintColor = UIColor.label
        routePickerView.activeTintColor = UIColor.systemBlue
        routePickerView.prioritizesVideoDevices = false
        routePickerView.backgroundColor = .clear
        return routePickerView
    }

    public func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = UIColor.label
    }
}
#elseif canImport(AppKit)
import AppKit

/// Native AirPlay audio route picker wrapper for macOS.
public struct AirPlayButtonView: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> AVRoutePickerView {
        let routePickerView = AVRoutePickerView()
        return routePickerView
    }

    public func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}
#endif
