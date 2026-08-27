import SwiftUI
import AVKit

#if canImport(UIKit)
import UIKit

/// Native AirPlay & Bluetooth audio route picker wrapper for iOS.
public struct AirPlayButtonView: UIViewRepresentable {
    // Initialize with configured properties
    public init() {}

    // Make ui view
    public func makeUIView(context: Context) -> AVRoutePickerView {
        // Route picker view
        let routePickerView = AVRoutePickerView()
        routePickerView.tintColor = UIColor.label
        routePickerView.activeTintColor = UIColor.systemBlue
        routePickerView.prioritizesVideoDevices = false
        routePickerView.backgroundColor = .clear
        return routePickerView
    }

    // Update ui view
    public func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = UIColor.label
    }
}
#elseif canImport(AppKit)
import AppKit

/// Native AirPlay audio route picker wrapper for macOS.
public struct AirPlayButtonView: NSViewRepresentable {
    // Initialize with configured properties
    public init() {}

    // Make ns view
    public func makeNSView(context: Context) -> AVRoutePickerView {
        // Route picker view
        let routePickerView = AVRoutePickerView()
        return routePickerView
    }

    // Update ns view
    public func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}
#endif
