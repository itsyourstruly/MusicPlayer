import SwiftUI

/// Badge indicator showing whether an audio track is local, cloud-only in iCloud Drive, or downloading.
public struct CloudStatusBadge: View {
    public let track: Track
    public var tintColor: Color

    public init(track: Track, tintColor: Color = .secondary) {
        self.track = track
        self.tintColor = tintColor
    }

    @ViewBuilder
    public var body: some View {
        let availability = AvailabilityCenter.shared.availability(for: track)
        switch availability {
        case .local:
            EmptyView()
        case .jellyfinDownloaded:
            EmptyView()
        case .jellyfinRemote(let isDownloading, let progress):
            if isDownloading {
                if progress > 0 {
                    ZStack {
                        Circle()
                            .stroke(tintColor.opacity(0.25), lineWidth: 1.5)
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(tintColor, lineWidth: 1.5)
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 12, height: 12)
                } else {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(tintColor)
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                }
            } else {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(tintColor.opacity(0.65))
            }
        case .cloudDownloaded:
            EmptyView()
        case .cloudRemote(let isDownloading, _):
            if isDownloading {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(tintColor)
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
            } else {
                Image(systemName: "icloud")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tintColor.opacity(0.8))
            }
        }
    }
}
