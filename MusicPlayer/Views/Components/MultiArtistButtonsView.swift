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

    private struct Row {
        var subviews: [LayoutSubview] = []
        var subviewSizes: [CGSize] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func calculateRows(proposal: ProposedViewSize, subviews: Subviews) -> [Row] {
        guard !subviews.isEmpty else { return [] }
        let maxAvailableWidth = proposal.width ?? .infinity

        var rows: [Row] = []
        var currentRow = Row()

        for subview in subviews {
            // Measure subview proposing maxAvailableWidth so that text components know their horizontal ceiling
            let subviewSize = subview.sizeThatFits(ProposedViewSize(width: maxAvailableWidth.isFinite ? maxAvailableWidth : nil, height: nil))

            let proposedRowWidth = currentRow.width + (currentRow.subviews.isEmpty ? 0 : horizontalSpacing) + subviewSize.width

            if proposedRowWidth > maxAvailableWidth && !currentRow.subviews.isEmpty {
                rows.append(currentRow)
                currentRow = Row(subviews: [subview], subviewSizes: [subviewSize], width: subviewSize.width, height: subviewSize.height)
            } else {
                currentRow.subviews.append(subview)
                currentRow.subviewSizes.append(subviewSize)
                currentRow.width = proposedRowWidth
                currentRow.height = max(currentRow.height, subviewSize.height)
            }
        }

        if !currentRow.subviews.isEmpty {
            rows.append(currentRow)
        }

        return rows
    }

    // Size that fits
    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = calculateRows(proposal: proposal, subviews: subviews)
        guard !rows.isEmpty else { return .zero }

        var totalHeight: CGFloat = 0
        var maxWidth: CGFloat = 0

        for (index, row) in rows.enumerated() {
            totalHeight += row.height
            if index < rows.count - 1 {
                totalHeight += verticalSpacing
            }
            maxWidth = max(maxWidth, row.width)
        }

        return CGSize(width: maxWidth, height: totalHeight)
    }

    // Place subviews
    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = calculateRows(proposal: ProposedViewSize(width: bounds.width, height: bounds.height), subviews: subviews)
        var y = bounds.minY

        for (index, row) in rows.enumerated() {
            var x = bounds.minX
            for (subviewIdx, subview) in row.subviews.enumerated() {
                let subviewSize = row.subviewSizes[subviewIdx]
                let pt = CGPoint(x: x, y: y + (row.height - subviewSize.height) / 2)
                subview.place(at: pt, proposal: ProposedViewSize(subviewSize))
                x += subviewSize.width + horizontalSpacing
            }
            y += row.height
            if index < rows.count - 1 {
                y += verticalSpacing
            }
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
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var buttonsContent: some View {
        ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
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
