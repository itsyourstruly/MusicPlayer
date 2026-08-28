import SwiftUI
import AVKit

#if canImport(UIKit)
import UIKit

/// Native AirPlay route picker presenter helper that triggers the system route picker modal without showing any background icon.
public final class RoutePickerManager {
    public static let shared = RoutePickerManager()
    private var routePickerView: AVRoutePickerView?

    private init() {}

    @MainActor
    public func presentRoutePicker() {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let window = windowScene.windows.first(where: { $0.isKeyWindow }) ?? windowScene.windows.first,
              let rootVC = window.rootViewController else {
            return
        }

        if routePickerView == nil {
            let picker = AVRoutePickerView(frame: CGRect(x: -200, y: -200, width: 44, height: 44))
            picker.prioritizesVideoDevices = false
            picker.isHidden = false
            picker.alpha = 0.001
            self.routePickerView = picker
        }

        guard let picker = routePickerView else { return }
        if picker.superview == nil {
            rootVC.view.addSubview(picker)
        }

        if let button = findButton(in: picker) {
            button.sendActions(for: .touchUpInside)
        }
    }

    private func findButton(in view: UIView) -> UIButton? {
        if let btn = view as? UIButton { return btn }
        for subview in view.subviews {
            if let btn = findButton(in: subview) { return btn }
        }
        return nil
    }
}

/// Audio route picker button that displays the connected output device name (e.g. "THIS DEVICE", "AIRPODS PRO", "HEADPHONES")
/// aligned to the right with NO visible background icon, opening the system route picker on tap.
public struct AirPlayButtonView: View {
    public let routeName: String
    public let foregroundColor: Color
    public let font: Font

    // Initialize with configured properties
    public init(
        routeName: String = "THIS DEVICE",
        foregroundColor: Color = .primary,
        font: Font = .system(size: 13, weight: .bold, design: .monospaced)
    ) {
        self.routeName = routeName
        self.foregroundColor = foregroundColor
        self.font = font
    }

    public var body: some View {
        Button(action: {
            HapticFeedback.selectionChanged()
            RoutePickerManager.shared.presentRoutePicker()
        }) {
            Text(routeName)
                .font(font)
                .foregroundStyle(foregroundColor)
                .lineLimit(1)
                .multilineTextAlignment(.trailing)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#elseif canImport(AppKit)
import AppKit

/// Native AirPlay route picker presenter helper for macOS.
public final class MacRoutePickerManager {
    public static let shared = MacRoutePickerManager()
    private var routePickerView: AVRoutePickerView?

    private init() {}

    @MainActor
    public func presentRoutePicker() {
        guard let window = NSApplication.shared.keyWindow,
              let contentView = window.contentView else { return }

        if routePickerView == nil {
            let picker = AVRoutePickerView(frame: CGRect(x: -200, y: -200, width: 44, height: 44))
            self.routePickerView = picker
        }

        guard let picker = routePickerView else { return }
        if picker.superview == nil {
            contentView.addSubview(picker)
        }

        if let button = findButton(in: picker) {
            button.performClick(nil)
        }
    }

    private func findButton(in view: NSView) -> NSButton? {
        if let btn = view as? NSButton { return btn }
        for subview in view.subviews {
            if let btn = findButton(in: subview) { return btn }
        }
        return nil
    }
}

/// Audio route picker button for macOS.
public struct AirPlayButtonView: View {
    public let routeName: String
    public let foregroundColor: Color
    public let font: Font

    // Initialize with configured properties
    public init(
        routeName: String = "THIS DEVICE",
        foregroundColor: Color = .primary,
        font: Font = .system(size: 13, weight: .bold, design: .monospaced)
    ) {
        self.routeName = routeName
        self.foregroundColor = foregroundColor
        self.font = font
    }

    public var body: some View {
        Button(action: {
            MacRoutePickerManager.shared.presentRoutePicker()
        }) {
            Text(routeName)
                .font(font)
                .foregroundStyle(foregroundColor)
                .lineLimit(1)
                .multilineTextAlignment(.trailing)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
#endif
