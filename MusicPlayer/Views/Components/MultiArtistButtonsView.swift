import SwiftUI

/// Layout that wraps subviews horizontally and onto new lines if horizontal space is exhausted.
public struct ArtistFlowLayout: Layout {
    public var horizontalSpacing: CGFloat
    public var verticalSpacing: CGFloat

    // Initialize with configured properties
    public init(horizontalSpacing: CGFloat = 0, verticalSpacing: CGFloat = 4) {
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
    }

    // Size that fits
    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // Width
        let width = proposal.width ?? .infinity
        // Current x
        var currentX: CGFloat = 0
        // Current y
        var currentY: CGFloat = 0
        // Line height
        var lineHeight: CGFloat = 0
        // Max x
        var maxX: CGFloat = 0

        for subview in subviews {
            // Size
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > width && currentX > 0 {
                currentX = 0
                currentY += lineHeight + verticalSpacing
                lineHeight = 0
            }
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + horizontalSpacing
            maxX = max(maxX, currentX)
        }

        return CGSize(width: min(width, maxX), height: currentY + lineHeight)
    }

    // Place subviews
    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // Current x
        var currentX = bounds.minX
        // Current y
        var currentY = bounds.minY
        // Line height
        var lineHeight: CGFloat = 0

        for subview in subviews {
            // Size
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX && currentX > bounds.minX {
                currentX = bounds.minX
                currentY += lineHeight + verticalSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: ProposedViewSize(size))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + horizontalSpacing
        }
    }
}

/// Reusable view that parses and renders multi-artist strings as discrete, individually selectable plain text buttons, wrapping across lines to fit all artists.
public struct MultiArtistButtonsView: View {
    // Raw artist
    public let rawArtist: String
    // Joined artists
    public let joinedArtists: [String]
    // Font
    public let font: Font
    // Foreground color
    public let foregroundColor: Color
    // Separator color
    public let separatorColor: Color
    // Line limit
    public let lineLimit: Int?
    public let onSelectArtist: (String) -> Void
    private let segments: [ArtistSegment]

    // Initialize with configured properties
    public init(
        rawArtist: String,
        joinedArtists: [String] = [],
        font: Font = .system(size: 14, weight: .medium),
        foregroundColor: Color = .primary,
        separatorColor: Color = .secondary,
        lineLimit: Int? = nil,
        onSelectArtist: @escaping (String) -> Void
    ) {
        self.rawArtist = rawArtist
        self.joinedArtists = joinedArtists
        self.font = font
        self.foregroundColor = foregroundColor
        self.separatorColor = separatorColor
        self.lineLimit = lineLimit
        self.onSelectArtist = onSelectArtist

        // Precompute segments once at init
        let clean = rawArtist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var matched: String? = nil
        if !clean.isEmpty {
            for joined in joinedArtists {
                let joinedClean = joined.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if clean == joinedClean {
                    matched = joined
                    break
                }
                let joinedParts = ArtistParser.parseArtists(from: joined).map { $0.lowercased() }
                if joinedParts.count > 1 {
                    let rawParts = ArtistParser.parseArtists(from: rawArtist).map { $0.lowercased() }
                    if Set(joinedParts).isSubset(of: Set(rawParts)) {
                        matched = joined
                        break
                    }
                }
            }
        }
        if let joinedName = matched {
            self.segments = [ArtistSegment(name: joinedName)]
        } else {
            self.segments = ArtistParser.parse(rawArtist: rawArtist)
        }
    }

    // Main view layout structure
    public var body: some View {
        if lineLimit == 1 {
            HStack(spacing: 0) {
                buttonsContent
            }
        } else {
            ArtistFlowLayout(horizontalSpacing: 0, verticalSpacing: 3) {
                buttonsContent
            }
        }
    }

    @ViewBuilder
    private var buttonsContent: some View {
        ForEach(segments) { segment in
            Button(action: {
                HapticFeedback.lightImpact()
                onSelectArtist(segment.name)
            }) {
                Text(segment.name)
                    .font(font)
                    .foregroundStyle(foregroundColor)
                    .lineLimit(lineLimit)
            }
            .buttonStyle(.plain)

            if let sep = segment.separatorAfter {
                Text(sep)
                    .font(font)
                    .foregroundStyle(separatorColor)
                    .lineLimit(lineLimit)
            }
        }
    }
}
