import SwiftUI

/// Layout that wraps subviews horizontally and onto new lines if horizontal space is exhausted.
public struct ArtistFlowLayout: Layout {
    public var horizontalSpacing: CGFloat
    public var verticalSpacing: CGFloat

    public init(horizontalSpacing: CGFloat = 0, verticalSpacing: CGFloat = 4) {
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
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

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
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
    public let rawArtist: String
    public let joinedArtists: [String]
    public let font: Font
    public let foregroundColor: Color
    public let separatorColor: Color
    public let lineLimit: Int?
    public let onSelectArtist: (String) -> Void

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
    }

    private var matchedJoinedName: String? {
        let clean = rawArtist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !clean.isEmpty else { return nil }
        for joined in joinedArtists {
            let joinedClean = joined.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if clean == joinedClean { return joined }
            let joinedParts = ArtistParser.parseArtists(from: joined).map { $0.lowercased() }
            if joinedParts.count > 1 {
                let rawParts = ArtistParser.parseArtists(from: rawArtist).map { $0.lowercased() }
                if Set(joinedParts).isSubset(of: Set(rawParts)) {
                    return joined
                }
            }
        }
        return nil
    }

    private var segments: [ArtistSegment] {
        if let joinedName = matchedJoinedName {
            return [ArtistSegment(name: joinedName)]
        }
        return ArtistParser.parse(rawArtist: rawArtist)
    }

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
