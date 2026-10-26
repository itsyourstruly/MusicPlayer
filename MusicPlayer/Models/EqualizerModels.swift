import Foundation
import SwiftUI

/// Frequency band configuration in the 10-band equalizer.
public struct EqualizerBand: Identifiable, Codable, Sendable, Equatable {
    public var id: Int { index }
    public let index: Int
    public let frequencyHz: Double
    public let displayLabel: String
    /// Gain in decibels (-12.0 dB to +12.0 dB).
    public var gainDB: Double

    public init(index: Int, frequencyHz: Double, displayLabel: String, gainDB: Double = 0.0) {
        self.index = index
        self.frequencyHz = frequencyHz
        self.displayLabel = displayLabel
        self.gainDB = min(12.0, max(-12.0, gainDB))
    }

    /// Standard 10 octave bands conforming to ISO acoustic standards.
    public static let standard10Bands: [EqualizerBand] = [
        EqualizerBand(index: 0, frequencyHz: 32, displayLabel: "32", gainDB: 0.0),
        EqualizerBand(index: 1, frequencyHz: 64, displayLabel: "64", gainDB: 0.0),
        EqualizerBand(index: 2, frequencyHz: 125, displayLabel: "125", gainDB: 0.0),
        EqualizerBand(index: 3, frequencyHz: 250, displayLabel: "250", gainDB: 0.0),
        EqualizerBand(index: 4, frequencyHz: 500, displayLabel: "500", gainDB: 0.0),
        EqualizerBand(index: 5, frequencyHz: 1000, displayLabel: "1k", gainDB: 0.0),
        EqualizerBand(index: 6, frequencyHz: 2000, displayLabel: "2k", gainDB: 0.0),
        EqualizerBand(index: 7, frequencyHz: 4000, displayLabel: "4k", gainDB: 0.0),
        EqualizerBand(index: 8, frequencyHz: 8000, displayLabel: "8k", gainDB: 0.0),
        EqualizerBand(index: 9, frequencyHz: 16000, displayLabel: "16k", gainDB: 0.0)
    ]
}

/// User-saved equalizer preset (built-in presets were removed in batch 7). Persisted by EqualizerManager.
public struct EqualizerPreset: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public let gains: [Double] // 10 values corresponding to 32Hz .. 16kHz

    public init(id: UUID = UUID(), name: String, gains: [Double]) {
        self.id = id
        self.name = name
        self.gains = gains
    }

    /// 'PRESET', then 'PRESET 2', 'PRESET 3', ... skipping names already taken.
    public static func nextDefaultName(existing: [String], base: String = "PRESET") -> String {
        let taken = Set(existing.map { $0.uppercased() })
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
}
