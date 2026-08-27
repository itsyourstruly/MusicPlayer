//
//  Playlist.swift
//  MusicPlayer
//
//  Created by Principal Apple Software Engineer on 8/24/26.
//

import Foundation

/// User-curated custom playlist entity supporting pinning, ordering, and metadata.
public struct Playlist: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public var name: String
    public var description: String
    public var isPinned: Bool
    public var customArtworkKey: String?
    public var trackIDs: [UUID]
    public let dateCreated: Date
    public var dateModified: Date

    public init(
        id: UUID = UUID(),
        name: String,
        description: String = "",
        isPinned: Bool = false,
        customArtworkKey: String? = nil,
        trackIDs: [UUID] = [],
        dateCreated: Date = Date(),
        dateModified: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.isPinned = isPinned
        self.customArtworkKey = customArtworkKey
        self.trackIDs = trackIDs
        self.dateCreated = dateCreated
        self.dateModified = dateModified
    }

    enum CodingKeys: String, CodingKey {
        case id, name, description, isPinned, customArtworkKey, trackIDs, dateCreated, dateModified
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        self.isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        self.customArtworkKey = try container.decodeIfPresent(String.self, forKey: .customArtworkKey)
        self.trackIDs = try container.decodeIfPresent([UUID].self, forKey: .trackIDs) ?? []
        self.dateCreated = try container.decodeIfPresent(Date.self, forKey: .dateCreated) ?? Date()
        self.dateModified = try container.decodeIfPresent(Date.self, forKey: .dateModified) ?? Date()
    }

    public var normalizedName: String {
        FuzzyMatcher.normalize(name)
    }

    public var searchTokens: String {
        let nName = FuzzyMatcher.normalize(name)
        let nDesc = FuzzyMatcher.normalize(description)
        return "\(nName) \(nDesc)"
    }

    /// Formatted track count string (e.g. `24 TRACKS` or `EMPTY`).
    public var formattedTrackCount: String {
        if trackIDs.isEmpty {
            return "0 TRACKS"
        } else if trackIDs.count == 1 {
            return "1 TRACK"
        } else {
            return "\(trackIDs.count) TRACKS"
        }
    }
}
