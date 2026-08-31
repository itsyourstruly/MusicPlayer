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

/// Equalizer preset top-level section.
public enum EqualizerPresetSection: String, CaseIterable, Identifiable, Sendable {
    case soundSignatures = "SOUND SIGNATURES"
    case headphones = "HEADPHONES"

    public var id: String { rawValue }
}

/// Equalizer sound profile preset.
public struct EqualizerPreset: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let section: EqualizerPresetSection
    public let group: String
    public let description: String
    public let gains: [Double] // 10 values corresponding to 32Hz .. 16kHz

    public init(
        name: String,
        section: EqualizerPresetSection,
        group: String,
        description: String,
        gains: [Double]
    ) {
        self.name = name
        self.section = section
        self.group = group
        self.description = description
        self.gains = gains
    }

    public static let builtInPresets: [EqualizerPreset] = soundSignaturesPresets + headphonesPresets

    // MARK: - Part 1 & Part 2: Sound Signatures & Genre Profiles

    public static let soundSignaturesPresets: [EqualizerPreset] = [
        // Part 1: Sound Signatures & Acoustic Profiles
        EqualizerPreset(
            name: "Flat / Bit-Perfect Reference",
            section: .soundSignatures,
            group: "Acoustic Profiles",
            description: "Pure uncolored pass-through. Preserves the exact mastering balance, dynamic range, and phase linearity intended by the recording engineer.",
            gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        ),
        EqualizerPreset(
            name: "Harman Target Baseline",
            section: .soundSignatures,
            group: "Acoustic Profiles",
            description: "Emulates scientifically validated room acoustics with a +4 dB sub-bass shelf below 100 Hz, neutral midrange, and smooth +2 dB pinna ear-gain.",
            gains: [4, 3, 1, 0, 0, 0, 1, 2, 1, 0]
        ),
        EqualizerPreset(
            name: "Audiophile Neutral (IEF Clean)",
            section: .soundSignatures,
            group: "Acoustic Profiles",
            description: "Studio-grade linear response based on Crinacle's IEF target. Delivers uncolored bass separation with natural vocal timbre and zero mid-bass bloat.",
            gains: [2, 1, 0, 0, 0, 0, 1, 1, 0, 0]
        ),
        EqualizerPreset(
            name: "Dynamic V-Shape",
            section: .soundSignatures,
            group: "Acoustic Profiles",
            description: "Compensates for Fletcher-Munson loudness contours at low-to-moderate listening volumes with boosted sub-bass, recessed mids, and airy treble sparkle.",
            gains: [5, 3, 1, -1, -2, -1, 0, 2, 3, 4]
        ),
        EqualizerPreset(
            name: "Warm & Relaxed",
            section: .soundSignatures,
            group: "Acoustic Profiles",
            description: "Classic anti-fatigue tuning. Adds low-end warmth while gently rolling off frequencies above 4 kHz to eliminate sibilance and treble glare.",
            gains: [2, 2, 2, 1, 0, 0, 0, -1, -2, -3]
        ),
        EqualizerPreset(
            name: "Analytical & Detail",
            section: .soundSignatures,
            group: "Acoustic Profiles",
            description: "Maximizes micro-detail, soundstage width, and instrument separation by trimming lower-mid mud and elevating the 4 kHz–16 kHz air band.",
            gains: [0, 0, -1, -1, 0, 0, 1, 2, 3, 4]
        ),
        EqualizerPreset(
            name: "Clean Sub-Bass Focus",
            section: .soundSignatures,
            group: "Acoustic Profiles",
            description: "Delivers deep, physical sub-bass rumble strictly isolated below 80 Hz, keeping the midrange and vocal tracks pristine and uncluttered.",
            gains: [5, 4, 1, 0, 0, 0, 0, 0, 0, 0]
        ),
        EqualizerPreset(
            name: "Mid-Bass Slam",
            section: .soundSignatures,
            group: "Acoustic Profiles",
            description: "Focuses low-end energy on punchy kick-drum transients (64 Hz–125 Hz) while notching 500 Hz to avoid boxiness.",
            gains: [2, 5, 3, 1, -1, 0, 1, 2, 2, 2]
        ),

        // Part 2: Genre-Specific Presets
        EqualizerPreset(
            name: "Hip-Hop & Trap",
            section: .soundSignatures,
            group: "Genres",
            description: "Maximizes synthesized 808 sub-bass extension, scoops lower mids to preserve headroom, and sharpens hi-hat percussion transients.",
            gains: [6, 5, 2, -1, -1, 0, 1, 2, 3, 3]
        ),
        EqualizerPreset(
            name: "Rock & Alternative",
            section: .soundSignatures,
            group: "Genres",
            description: "Cleans electric guitar congestion by dipping 500 Hz, while boosting 2 kHz–4 kHz to emphasize pick attack, overdrive, and snare crack.",
            gains: [4, 3, 1, -1, -2, 0, 2, 3, 2, 2]
        ),
        EqualizerPreset(
            name: "Heavy Metal & Hardcore",
            section: .soundSignatures,
            group: "Genres",
            description: "Tames wall-of-sound guitar distortion and fast double-kick buildup with an aggressive 250 Hz–500 Hz scoop and a +4 dB boost at 4 kHz for bite.",
            gains: [5, 4, 1, -2, -3, -1, 2, 4, 3, 2]
        ),
        EqualizerPreset(
            name: "Electronic & EDM",
            section: .soundSignatures,
            group: "Genres",
            description: "Enhances deep synth bass drops and driving rhythm sections while opening up upper-treble stereo imaging and reverb tails.",
            gains: [5, 4, 2, 0, -1, 1, 2, 3, 4, 3]
        ),
        EqualizerPreset(
            name: "Acoustic & Singer-Songwriter",
            section: .soundSignatures,
            group: "Genres",
            description: "Preserves natural acoustic timbre with subtle body warmth and a +3 dB lift at 4 kHz for intimate vocal and string attack.",
            gains: [1, 2, 1, 1, 1, 1, 2, 3, 2, 1]
        ),
        EqualizerPreset(
            name: "Classical & Symphonic",
            section: .soundSignatures,
            group: "Genres",
            description: "Maintains organic hall resonance and orchestral balance, adding low-end weight for timpanis and delicate violin overtone air.",
            gains: [3, 2, 1, 1, 0, 0, 0, 2, 2, 2]
        ),
        EqualizerPreset(
            name: "Jazz & R&B",
            section: .soundSignatures,
            group: "Genres",
            description: "Accentuates upright bass body and electric piano warmth with silky vocal clarity and smooth, non-fatiguing brass presence.",
            gains: [3, 3, 2, 1, 0, 1, 1, 2, 2, 2]
        ),
        EqualizerPreset(
            name: "Spoken Word & Podcast",
            section: .soundSignatures,
            group: "Genres",
            description: "High-pass filter that cuts desk thumps and mic boom (32 Hz–125 Hz) while centering energy around the human vocal core (1 kHz–2 kHz).",
            gains: [-5, -4, -2, 0, 2, 3, 2, 1, 0, -2]
        )
    ]

    // MARK: - Part 3 & Part 4: Headphones & In-Ear Monitors

    public static let headphonesPresets: [EqualizerPreset] = [
        // Moondrop
        EqualizerPreset(
            name: "Moondrop Chu / Chu II / Chu II DSP",
            section: .headphones,
            group: "Moondrop",
            description: "Softens upper-treble metallic timbre and 8 kHz–12 kHz driver resonance while keeping stock bass intact.",
            gains: [0, 0, 0, 0, 0, 0, 0, -1, -2, -3]
        ),
        EqualizerPreset(
            name: "Moondrop Aria / Aria SE / Aria 2",
            section: .headphones,
            group: "Moondrop",
            description: "Adds subtle sub-bass weight and relaxes upper-treble zinc-cavity reflections.",
            gains: [1, 0, 0, 0, 0, 0, 0, -1, -2, -2]
        ),
        EqualizerPreset(
            name: "Moondrop Blessing 2 / Blessing 2 Dusk",
            section: .headphones,
            group: "Moondrop",
            description: "Restores deep sub-bass fullness and smooths balanced armature high-frequency grain.",
            gains: [3, 2, 1, 0, 0, 0, 0, -1, -1, -2]
        ),
        EqualizerPreset(
            name: "Moondrop Blessing 3",
            section: .headphones,
            group: "Moondrop",
            description: "Delivers missing sub-bass slam to balance the lean stock tuning and tames aggressive 8 kHz treble bite.",
            gains: [4, 3, 1, 0, 0, 0, 0, -1, -2, -3]
        ),
        EqualizerPreset(
            name: "Moondrop Variations",
            section: .headphones,
            group: "Moondrop",
            description: "Fills the lower-mid scoop (200 Hz) and smooths ultra-high electrostatic driver sparkle.",
            gains: [2, 1, 0, 0, 0, 0, 0, -1, -2, -3]
        ),
        EqualizerPreset(
            name: "Moondrop Kato",
            section: .headphones,
            group: "Moondrop",
            description: "Shaves minor upper-treble glare for a smoother, fatigue-free presentation.",
            gains: [1, 1, 0, 0, 0, 0, 0, 0, -1, -2]
        ),
        EqualizerPreset(
            name: "Moondrop Starfield / Starfield 2",
            section: .headphones,
            group: "Moondrop",
            description: "Elevates sub-bass impact while calming upper-treble energy.",
            gains: [1, 1, 0, 0, 0, 0, 0, -1, -2, -3]
        ),
        EqualizerPreset(
            name: "Moondrop KXXS / Spaceship",
            section: .headphones,
            group: "Moondrop",
            description: "Boosts sub-bass extension, improves vocal presence, and cuts bright high-frequency peaks.",
            gains: [2, 1, 0, 0, 0, 0, 1, 0, -2, -3]
        ),
        EqualizerPreset(
            name: "Moondrop S8 / Solis 2",
            section: .headphones,
            group: "Moondrop",
            description: "Warms up multi-BA low-end punch while smoothing transient treble spikes.",
            gains: [3, 2, 1, 0, 0, 0, 0, 0, -1, -2]
        ),
        EqualizerPreset(
            name: "Moondrop Stellaris (Planar)",
            section: .headphones,
            group: "Moondrop",
            description: "Essential rescue curve: drastically slashes the piercing +8 dB treble spike at 6 kHz–8 kHz and restores sub-bass.",
            gains: [4, 3, 1, 0, 0, 0, -1, -4, -6, -5]
        ),
        EqualizerPreset(
            name: "Moondrop May (DSP Hybrid)",
            section: .headphones,
            group: "Moondrop",
            description: "Gently trims residual planar tweeter sizzle above 8 kHz.",
            gains: [0, 0, 0, 0, 0, 0, 0, -1, -1, -2]
        ),
        EqualizerPreset(
            name: "Moondrop Kadenz / Droplet",
            section: .headphones,
            group: "Moondrop",
            description: "Smooths top-octave response while supporting foundational sub-bass rumble.",
            gains: [1, 0, 0, 0, 0, 0, 0, -1, -2, -2]
        ),
        EqualizerPreset(
            name: "Moondrop Quarks / Quarks DSP",
            section: .headphones,
            group: "Moondrop",
            description: "Damps narrow 6 kHz micro-driver ear canal resonance for natural vocal timbre.",
            gains: [1, 0, 0, 0, 0, 0, 0, -1, -1, -2]
        ),

        // Truthear
        EqualizerPreset(
            name: "Truthear Hexa",
            section: .headphones,
            group: "Truthear",
            description: "Injects authoritative sub-bass into Hexa's clinical baseline and polishes high-frequency roll-off.",
            gains: [3, 2, 1, 0, 0, 0, 0, 0, -1, -2]
        ),
        EqualizerPreset(
            name: "Truthear Zero (Blue - Harman)",
            section: .headphones,
            group: "Truthear",
            description: "Preserves textbook Harman bass while removing slight excess ear-gain brightness in the treble.",
            gains: [0, 0, 0, 0, 0, 0, 0, -1, -2, -3]
        ),
        EqualizerPreset(
            name: "Truthear Zero:RED (Crinacle)",
            section: .headphones,
            group: "Truthear",
            description: "Adds subtle low-end impact and polishes the uppermost 16 kHz air band.",
            gains: [1, 0, 0, 0, 0, 0, 0, 0, -1, -2]
        ),
        EqualizerPreset(
            name: "Truthear Nova",
            section: .headphones,
            group: "Truthear",
            description: "Bridges the mid-bass tuck to enrich male vocal body and eases upper-treble intensity.",
            gains: [2, 1, 0, 0, 0, 0, 0, -1, -1, -2]
        ),
        EqualizerPreset(
            name: "Truthear Gate / Hola",
            section: .headphones,
            group: "Truthear",
            description: "Smooths lower-treble transitions while maintaining clean, punchy dynamic bass.",
            gains: [1, 0, 0, 0, 0, 0, 0, -1, -2, -3]
        ),
        EqualizerPreset(
            name: "Truthear Pure",
            section: .headphones,
            group: "Truthear",
            description: "Deepens sub-bass extension while keeping the midrange transparent and uncolored.",
            gains: [2, 1, 0, 0, 0, 0, 0, 0, -1, -2]
        ),

        // 7Hz
        EqualizerPreset(
            name: "7Hz Zero / Zero:2 (Crinacle)",
            section: .headphones,
            group: "7Hz",
            description: "Minor high-treble polish on an already class-leading budget Harman benchmark.",
            gains: [0, 0, 0, 0, 0, 0, 0, 0, -1, -2]
        ),
        EqualizerPreset(
            name: "7Hz Timeless / Timeless AE (Planar)",
            section: .headphones,
            group: "7Hz",
            description: "Delivers deep planar sub-bass speed while taming the sharp 8 kHz treble peak.",
            gains: [3, 2, 1, 0, 0, 0, 0, 1, -1, -2]
        ),
        EqualizerPreset(
            name: "7Hz Dioko (Crinacle Planar)",
            section: .headphones,
            group: "7Hz",
            description: "Smooths the aggressive 8 kHz–12 kHz treble rise and supplements lower-octave warmth.",
            gains: [3, 2, 1, 0, 0, 0, 0, -1, -3, -3]
        ),
        EqualizerPreset(
            name: "7Hz Legato",
            section: .headphones,
            group: "7Hz",
            description: "Cuts bloated mid-bass shelf to restore vocal clarity, instrumental separation, and upper-mid bite.",
            gains: [-3, -4, -3, -1, 0, 1, 2, 3, -1, -2]
        ),
        EqualizerPreset(
            name: "7Hz Sonus",
            section: .headphones,
            group: "7Hz",
            description: "Balances hybrid DD/BA crossover transitions with smoother lower-treble energy.",
            gains: [1, 0, 0, 0, 0, 0, 0, -1, -2, -3]
        ),
        EqualizerPreset(
            name: "7Hz Aurora",
            section: .headphones,
            group: "7Hz",
            description: "Enhances sub-bass depth with a smooth, natural high-frequency taper.",
            gains: [2, 1, 0, 0, 0, 0, 0, 0, -1, -2]
        ),

        // Tangzu
        EqualizerPreset(
            name: "Tangzu Wan'er S.G / Wan'er SE",
            section: .headphones,
            group: "Tangzu",
            description: "Tames high-treble sheen while preserving the Wan'er's lush, forward vocal intimacy.",
            gains: [1, 0, 0, 0, 0, 0, 0, -1, -2, -3]
        ),
        EqualizerPreset(
            name: "Tangzu Zetian Wu / Heyday (Planar)",
            section: .headphones,
            group: "Tangzu",
            description: "Extends low-end planar rumble and eliminates subtle high-volume sibilance.",
            gains: [2, 1, 0, 0, 0, 0, 0, 0, -1, -2]
        ),
        EqualizerPreset(
            name: "Tangzu Fudu Verse 1",
            section: .headphones,
            group: "Tangzu",
            description: "Tightens warm mid-bass and elevates vocal presence at 2 kHz–4 kHz.",
            gains: [0, -1, 0, 0, 0, 0, 1, 1, -1, -2]
        ),
        EqualizerPreset(
            name: "Tangzu Xuan NV",
            section: .headphones,
            group: "Tangzu",
            description: "Smooths top-end extension to maintain an organic, fatigue-free studio profile.",
            gains: [1, 0, 0, 0, 0, 0, 0, 0, -1, -2]
        ),

        // Simgot
        EqualizerPreset(
            name: "Simgot EW100P / EW100 DSP",
            section: .headphones,
            group: "Simgot",
            description: "Eases upper-mid glare while maintaining clear dynamic vocal articulation.",
            gains: [1, 0, 0, 0, 0, 0, 0, -1, -2, -2]
        ),
        EqualizerPreset(
            name: "Simgot EW200 (Maze)",
            section: .headphones,
            group: "Simgot",
            description: "Essential fix: pulls down Simgot's bright 5 kHz–8 kHz peak for a smooth, fatigue-free presentation.",
            gains: [1, 0, 0, 0, 0, 0, 0, -2, -3, -2]
        ),
        EqualizerPreset(
            name: "Simgot EW300 / EW300 DSP",
            section: .headphones,
            group: "Simgot",
            description: "Relaxes piezo/dynamic hybrid treble energy while preserving transient precision.",
            gains: [0, 0, 0, 0, 0, 0, 0, -1, -2, -2]
        ),
        EqualizerPreset(
            name: "Simgot EA500 / EA500LM",
            section: .headphones,
            group: "Simgot",
            description: "Damps energetic nozzle resonance around 6 kHz–8 kHz and deepens sub-bass authority.",
            gains: [2, 1, 0, 0, 0, 0, 0, -2, -3, -2]
        ),
        EqualizerPreset(
            name: "Simgot EA1000 Fermat",
            section: .headphones,
            group: "Simgot",
            description: "Controls passive-radiator harmonics and softens treble peaks for an expansive soundstage.",
            gains: [2, 1, 0, 0, 0, 0, 0, -1, -2, -2]
        ),
        EqualizerPreset(
            name: "Simgot EM6L (Phoenix Hybrid)",
            section: .headphones,
            group: "Simgot",
            description: "Smooths multi-BA crossover transitions, eliminating vocal sibilance on bright tracks.",
            gains: [1, 0, 0, 0, 0, 0, 0, -1, -2, -2]
        ),
        EqualizerPreset(
            name: "Simgot SuperMix 4",
            section: .headphones,
            group: "Simgot",
            description: "Balances quad-brid driver cohesion by gently shelving down extreme 16 kHz air.",
            gains: [1, 0, 0, 0, 0, 0, 0, 0, -1, -2]
        ),

        // Kiwi Ears
        EqualizerPreset(
            name: "Kiwi Ears Cadenza",
            section: .headphones,
            group: "Kiwi Ears",
            description: "Polishes the beryllium driver's natural Harman curve with minor top-octave smoothing.",
            gains: [1, 0, 0, 0, 0, 0, 0, 0, -1, -2]
        ),
        EqualizerPreset(
            name: "Kiwi Ears Orchestra Lite",
            section: .headphones,
            group: "Kiwi Ears",
            description: "Supplies essential sub-bass weight to match the fast, reference-grade all-BA midrange.",
            gains: [3, 2, 1, 0, 0, 0, 0, 0, -1, -2]
        ),
        EqualizerPreset(
            name: "Kiwi Ears Quintet",
            section: .headphones,
            group: "Kiwi Ears",
            description: "Calms micro-planar and PZT tweeter brightness (8 kHz–16 kHz) while bolstering sub-bass.",
            gains: [2, 1, 0, 0, 0, 0, 0, -1, -2, -3]
        ),
        EqualizerPreset(
            name: "Kiwi Ears Melody (Planar)",
            section: .headphones,
            group: "Kiwi Ears",
            description: "Refines planar transient speed with a smoother, grain-free treble curve.",
            gains: [1, 0, 0, 0, 0, 0, 0, -1, -2, -3]
        ),
        EqualizerPreset(
            name: "Kiwi Ears Quartet",
            section: .headphones,
            group: "Kiwi Ears",
            description: "Cleans dual-dynamic mid-bass bloom and pushes vocal presence forward.",
            gains: [-1, -2, -1, 0, 0, 0, 1, 1, -2, -3]
        ),
        EqualizerPreset(
            name: "Kiwi Ears Forteza",
            section: .headphones,
            group: "Kiwi Ears",
            description: "Corrects aggressive V-shaped spikes at 6 kHz–8 kHz and cleans lower-mid transition.",
            gains: [-2, -2, -1, 0, 0, 0, -1, -2, -4, -3]
        ),
        EqualizerPreset(
            name: "Kiwi Ears Singolo (Klippel)",
            section: .headphones,
            group: "Kiwi Ears",
            description: "Minor treble refinement on Crinacle's Klippel acoustic resonator chamber.",
            gains: [1, 0, 0, 0, 0, 0, 0, 0, -1, -2]
        ),
        EqualizerPreset(
            name: "Kiwi Ears Canta / Ke4",
            section: .headphones,
            group: "Kiwi Ears",
            description: "Shaves excess high-frequency sparkle for precise alignment with modern meta-targets.",
            gains: [0, 0, 0, 0, 0, 0, 0, 0, -1, -2]
        ),

        // KZ & CCA
        EqualizerPreset(
            name: "KZ ZSN Pro / ZSN Pro X / ZSN Pro 2",
            section: .headphones,
            group: "KZ & CCA",
            description: "Essential rescue curve: slashes the piercing +10 dB BA peak at 6 kHz–8 kHz and cleans muddy mid-bass boom.",
            gains: [-3, -2, -1, 0, 0, 0, -2, -5, -6, -4]
        ),
        EqualizerPreset(
            name: "KZ ZS10 Pro / ZS10 Pro X / ZS10 Pro 2",
            section: .headphones,
            group: "KZ & CCA",
            description: "Tames aggressive V-shaped sibilance, bringing vocals forward and eliminating cymbal splash.",
            gains: [-2, -2, -1, 0, 0, 0, -1, -4, -5, -3]
        ),
        EqualizerPreset(
            name: "KZ Castor (Harman Edition)",
            section: .headphones,
            group: "KZ & CCA",
            description: "Subtle top-end smoothing on a well-engineered dual-dynamic driver configuration.",
            gains: [0, 0, 0, 0, 0, 0, 0, -1, -2, -2]
        ),
        EqualizerPreset(
            name: "KZ Castor (Enhanced Bass Edition)",
            section: .headphones,
            group: "KZ & CCA",
            description: "Trims excess mid-bass bloom to reveal punchy sub-bass impact and clean vocal clarity.",
            gains: [-2, -3, -2, 0, 0, 0, 0, -1, -2, -2]
        ),
        EqualizerPreset(
            name: "KZ PR1 Pro / PR2 / PR3 (Planar)",
            section: .headphones,
            group: "KZ & CCA",
            description: "Tames the un-damped 8 kHz planar treble spike while preserving speed and resolution.",
            gains: [2, 1, 0, 0, 0, 0, 0, -2, -5, -4]
        ),
        EqualizerPreset(
            name: "KZ Krila / Symphony",
            section: .headphones,
            group: "KZ & CCA",
            description: "Lowers high-frequency resonant peaks to achieve a balanced, neutral studio response.",
            gains: [0, -1, 0, 0, 0, 0, -1, -3, -4, -3]
        ),
        EqualizerPreset(
            name: "KZ ZAX / AS16 Pro",
            section: .headphones,
            group: "KZ & CCA",
            description: "Softens multi-BA treble ringing and eliminates vocal sibilance on bright recordings.",
            gains: [-2, -2, -1, 0, 0, 0, 0, -3, -4, -3]
        ),
        EqualizerPreset(
            name: "CCA CRA / CRA+",
            section: .headphones,
            group: "KZ & CCA",
            description: "Fixes CRA's peaky 8 kHz upper treble to convert raw energy into clean audiophile clarity.",
            gains: [-1, -2, -1, 0, 0, 0, 0, -2, -4, -3]
        ),
        EqualizerPreset(
            name: "CCA Rhapsody / Hydro",
            section: .headphones,
            group: "KZ & CCA",
            description: "Trims mid-bass thickness and balances hybrid crossover frequencies.",
            gains: [-1, -2, -1, 0, 0, 0, 0, -1, -2, -2]
        ),
        EqualizerPreset(
            name: "CCA Trio",
            section: .headphones,
            group: "KZ & CCA",
            description: "Minor smoothing on the triple dynamic setup to prevent high-frequency fatigue.",
            gains: [0, 0, 0, 0, 0, 0, 0, -1, -2, -2]
        ),

        // Thieaudio
        EqualizerPreset(
            name: "Thieaudio Monarch Mk1 / Mk2 / Mk3",
            section: .headphones,
            group: "Thieaudio",
            description: "Bolsters sub-bass authority and smooths ultra-high electrostatic driver sparkle.",
            gains: [2, 1, 0, 0, 0, 0, 0, 0, -1, -2]
        ),
        EqualizerPreset(
            name: "Thieaudio Clairvoyance",
            section: .headphones,
            group: "Thieaudio",
            description: "Adds low-end depth while maintaining Clairvoyance's signature lush vocal timbre.",
            gains: [2, 1, 0, 0, 0, 0, 0, 0, -1, -2]
        ),
        EqualizerPreset(
            name: "Thieaudio Oracle / Oracle Mk2 / Mk3",
            section: .headphones,
            group: "Thieaudio",
            description: "Polishes studio reference curve by calming minor EST treble energy above 10 kHz.",
            gains: [2, 1, 0, 0, 0, 0, 0, 0, -1, -2]
        ),
        EqualizerPreset(
            name: "Thieaudio Prestige / Prestige LTD",
            section: .headphones,
            group: "Thieaudio",
            description: "Damps energetic 10 kHz–16 kHz electrostatic drivers to eliminate listening fatigue.",
            gains: [2, 1, 0, 0, 0, 0, 0, -1, -2, -3]
        ),
        EqualizerPreset(
            name: "Thieaudio Hype 2 / Hype 4 / Hype 10",
            section: .headphones,
            group: "Thieaudio",
            description: "Tightens isobaric subwoofer slam and gently controls high-frequency extension.",
            gains: [1, 0, 0, 0, 0, 0, 0, 0, -1, -2]
        ),
        EqualizerPreset(
            name: "Thieaudio Elixir / Ghost",
            section: .headphones,
            group: "Thieaudio",
            description: "Deepens dynamic bass impact and brings mid-range instruments forward in the stage.",
            gains: [3, 2, 1, 0, 0, 0, 0, 1, -1, -2]
        ),
        EqualizerPreset(
            name: "Thieaudio Origin",
            section: .headphones,
            group: "Thieaudio",
            description: "Minor polish on the single dynamic driver flagship's ultra-wide frequency response.",
            gains: [1, 0, 0, 0, 0, 0, 0, 0, -1, -2]
        ),

        // DUNU
        EqualizerPreset(
            name: "DUNU Titan S / Titan S2",
            section: .headphones,
            group: "DUNU",
            description: "Adds missing sub-bass warmth to Titan's analytical profile and tames upper-mid brightness.",
            gains: [2, 1, 0, 0, 0, 0, 0, -1, -2, -2]
        ),
        EqualizerPreset(
            name: "DUNU Kima / Kima Classic",
            section: .headphones,
            group: "DUNU",
            description: "Smooths DLC dynamic driver treble for a relaxed, natural vocal signature.",
            gains: [1, 0, 0, 0, 0, 0, 0, 0, -1, -2]
        ),
        EqualizerPreset(
            name: "DUNU Falcon Pro / Falcon Ultra",
            section: .headphones,
            group: "DUNU",
            description: "Controls lithium-magnesium dome treble resonance without sacrificing transient speed.",
            gains: [1, 0, 0, 0, 0, 0, 0, -1, -2, -2]
        ),
        EqualizerPreset(
            name: "DUNU SA6 / SA6 Mk2 / SA6 Ultra",
            section: .headphones,
            group: "DUNU",
            description: "Adds deep sub-bass punch to match all-BA speed while smoothing upper-mid grain.",
            gains: [2, 1, 0, 0, 0, 0, 0, 0, -1, -1]
        ),
        EqualizerPreset(
            name: "DUNU EST112",
            section: .headphones,
            group: "DUNU",
            description: "Elevates sub-bass punch and integrates hybrid EST/BA/DD crossover cohesion.",
            gains: [3, 2, 1, 0, 0, 0, 0, 0, -1, -2]
        ),
        EqualizerPreset(
            name: "DUNU DaVinci (Gizaudio)",
            section: .headphones,
            group: "DUNU",
            description: "Refines dual-subwoofer warmth with subtle high-frequency air smoothing.",
            gains: [0, 0, 0, 0, 0, 0, 0, 0, -1, -2]
        ),
        EqualizerPreset(
            name: "DUNU Vulkan",
            section: .headphones,
            group: "DUNU",
            description: "Tightens dual-dynamic low-end control and relaxes the 4-BA upper-mid peak.",
            gains: [2, 1, 0, 0, 0, 0, 0, -1, -2, -2]
        ),

        // LETSHUOER
        EqualizerPreset(
            name: "LETSHUOER S12 / S12 Pro (Planar)",
            section: .headphones,
            group: "LETSHUOER",
            description: "Essential planar fix: sharply pulls down the peaky 6 kHz–8 kHz treble spike and deepens sub-bass.",
            gains: [2, 1, 0, 0, 0, 0, 0, -2, -4, -3]
        ),
        EqualizerPreset(
            name: "LETSHUOER S15 (Passive Planar)",
            section: .headphones,
            group: "LETSHUOER",
            description: "Polishes upper harmonics for a cohesive, relaxed soundstage presentation.",
            gains: [1, 0, 0, 0, 0, 0, 0, 0, -1, -2]
        ),
        EqualizerPreset(
            name: "LETSHUOER S08 (Compact Planar)",
            section: .headphones,
            group: "LETSHUOER",
            description: "Subtle high-frequency roll-off for smooth, fatigue-free planar listening.",
            gains: [1, 0, 0, 0, 0, 0, 0, 0, -1, -2]
        ),
        EqualizerPreset(
            name: "LETSHUOER DZ4",
            section: .headphones,
            group: "LETSHUOER",
            description: "Enhances triple-dynamic sub-bass impact and smooths passive radiator crossover points.",
            gains: [2, 1, 0, 0, 0, 0, 0, 0, -1, -2]
        ),
        EqualizerPreset(
            name: "LETSHUOER Cadenza 4 / Cadenza 12",
            section: .headphones,
            group: "LETSHUOER",
            description: "Gentle high-frequency refinement on LETSHUOER's reference monitoring flagship.",
            gains: [1, 0, 0, 0, 0, 0, 0, 0, -1, -2]
        ),
        EqualizerPreset(
            name: "LETSHUOER Galileo (Gizaudio)",
            section: .headphones,
            group: "LETSHUOER",
            description: "Adds sub-bass authority to Galileo's famously smooth, uncolored midrange baseline.",
            gains: [2, 1, 0, 0, 0, 0, 0, 0, -1, -2]
        ),

        // AFUL
        EqualizerPreset(
            name: "AFUL Performer 5 (P5)",
            section: .headphones,
            group: "AFUL",
            description: "Refines RLC crossover balance by rolling off slight upper-treble BA resonance.",
            gains: [1, 0, 0, 0, 0, 0, 0, 0, -1, -2]
        ),
        EqualizerPreset(
            name: "AFUL Performer 8 (P8)",
            section: .headphones,
            group: "AFUL",
            description: "Enriches P8's analytical bassline with sub-bass authority without vocal bleed.",
            gains: [2, 1, 0, 0, 0, 0, 0, 0, -1, -2]
        ),
        EqualizerPreset(
            name: "AFUL Explorer",
            section: .headphones,
            group: "AFUL",
            description: "Shaves minor 16 kHz air to accentuate Explorer's warm, relaxed signature.",
            gains: [0, 0, 0, 0, 0, 0, 0, 0, -1, -2]
        ),
        EqualizerPreset(
            name: "AFUL MagicOne",
            section: .headphones,
            group: "AFUL",
            description: "Compensates for physical single-BA bass limitations with a +3 dB sub-bass shelf.",
            gains: [3, 2, 1, 0, 0, 0, 0, 0, -1, -2]
        ),
        EqualizerPreset(
            name: "AFUL Cantor (14 BA Flagship)",
            section: .headphones,
            group: "AFUL",
            description: "Enhances sub-bass dynamic punch to match Cantor's ultra-resolving midrange resolution.",
            gains: [2, 1, 0, 0, 0, 0, 0, 0, -1, -2]
        ),

        // Etymotic Research
        EqualizerPreset(
            name: "Etymotic ER2SE (Studio Edition)",
            section: .headphones,
            group: "Etymotic Research",
            description: "Transforms diffuse-field flat tuning into a full, natural Harman daily driver by adding the missing bass shelf.",
            gains: [5, 4, 2, 0, 0, 0, 0, 0, 0, 0]
        ),
        EqualizerPreset(
            name: "Etymotic ER2XR (Extended Response)",
            section: .headphones,
            group: "Etymotic Research",
            description: "Lifts the lowest sub-bass octave below 50 Hz for deep subwoofer rumble.",
            gains: [2, 1, 0, 0, 0, 0, 0, 0, 0, 0]
        ),
        EqualizerPreset(
            name: "Etymotic ER3SE / ER4SR (Reference)",
            section: .headphones,
            group: "Etymotic Research",
            description: "Supplies the essential low-end foundation needed to correct single-BA sub-bass roll-off.",
            gains: [6, 5, 3, 0, 0, 0, 0, 0, 0, 0]
        ),
        EqualizerPreset(
            name: "Etymotic ER3XR / ER4XR",
            section: .headphones,
            group: "Etymotic Research",
            description: "Adds deep sub-bass weight while preserving Etymotic's pinpoint midrange accuracy.",
            gains: [3, 2, 1, 0, 0, 0, 0, 0, 0, 0]
        ),
        EqualizerPreset(
            name: "Etymotic EVO (Multi-Driver)",
            section: .headphones,
            group: "Etymotic Research",
            description: "Balances triple-BA array with a richer sub-bass floor and smooth high-treble response.",
            gains: [2, 1, 0, 0, 0, 0, 0, 0, -1, -2]
        ),

        // Sennheiser IE Series
        EqualizerPreset(
            name: "Sennheiser IE 200",
            section: .headphones,
            group: "Sennheiser",
            description: "Tames the sharp 6 kHz–8 kHz nozzle peak while maintaining TrueResponse dynamic bass.",
            gains: [1, 1, 0, 0, 0, 0, 0, -2, -3, -2]
        ),
        EqualizerPreset(
            name: "Sennheiser IE 300",
            section: .headphones,
            group: "Sennheiser",
            description: "Cleans boomy mid-bass bloat and significantly reduces the intense 8 kHz V-shaped treble spike.",
            gains: [-2, -3, -2, 0, 0, 0, 0, -2, -4, -3]
        ),
        EqualizerPreset(
            name: "Sennheiser IE 600",
            section: .headphones,
            group: "Sennheiser",
            description: "Preserves benchmark-level sub-bass and midrange while taming the narrow 7 kHz–8 kHz sibilance peak.",
            gains: [1, 0, 0, 0, 0, 0, 0, -1, -3, -2]
        ),
        EqualizerPreset(
            name: "Sennheiser IE 900",
            section: .headphones,
            group: "Sennheiser",
            description: "Substantially attenuates aggressive 6 kHz–10 kHz resonator peaks to restore natural vocal timbre.",
            gains: [0, -1, -1, 0, 0, 0, 0, -2, -5, -4]
        ),
        EqualizerPreset(
            name: "Sennheiser IE 40 PRO / IE 100 PRO",
            section: .headphones,
            group: "Sennheiser",
            description: "Controls harsh stage-monitoring treble brightness and supports low-end foundation.",
            gains: [2, 1, 0, 0, 0, 0, 0, -2, -4, -3]
        ),
        EqualizerPreset(
            name: "Sennheiser IE 400 PRO / IE 500 PRO",
            section: .headphones,
            group: "Sennheiser",
            description: "Damps upper-mid and treble peaks for comfortable, non-fatiguing long listening sessions.",
            gains: [1, 0, 0, 0, 0, 0, 0, -1, -3, -3]
        ),

        // Final Audio
        EqualizerPreset(
            name: "Final Audio E500 / E1000 / E2000",
            section: .headphones,
            group: "Final Audio",
            description: "Polishes micro-dynamic treble extension while reinforcing low-end impact.",
            gains: [1, 0, 0, 0, 0, 0, 0, 0, -1, -2]
        ),
        EqualizerPreset(
            name: "Final Audio E3000 / E4000 / E5000",
            section: .headphones,
            group: "Final Audio",
            description: "De-bloats heavy mid-bass boom and elevates upper midrange (1 kHz–4 kHz) to bring recessed vocals forward.",
            gains: [-2, -3, -2, 0, 1, 1, 2, 2, -1, -2]
        ),
        EqualizerPreset(
            name: "Final Audio A3000 / A4000",
            section: .headphones,
            group: "Final Audio",
            description: "Tames sharp A-series 6 kHz–8 kHz treble peaks while adding warm sub-bass depth.",
            gains: [2, 1, 0, 0, 0, 0, 0, -2, -4, -3]
        ),
        EqualizerPreset(
            name: "Final Audio A5000",
            section: .headphones,
            group: "Final Audio",
            description: "Smooths high-frequency sparkle for a cohesive, balanced soundstage.",
            gains: [1, 0, 0, 0, 0, 0, 0, -1, -3, -2]
        ),
        EqualizerPreset(
            name: "Final Audio VR3000 (Gaming)",
            section: .headphones,
            group: "Final Audio",
            description: "Balances spatial treble cues for natural, fatigue-free music reproduction.",
            gains: [1, 0, 0, 0, 0, 0, 0, -1, -2, -2]
        ),

        // Tanchjim
        EqualizerPreset(
            name: "Tanchjim Tanya / Tanya DSP",
            section: .headphones,
            group: "Tanchjim",
            description: "Smooths bullet-style chamber treble resonance in the upper octaves.",
            gains: [1, 0, 0, 0, 0, 0, 0, -1, -2, -2]
        ),
        EqualizerPreset(
            name: "Tanchjim Ola / Ola Bass",
            section: .headphones,
            group: "Tanchjim",
            description: "Adds sub-bass body to Ola's lean diffuse-field profile and softens upper-mid energy.",
            gains: [2, 1, 0, 0, 0, 0, 0, -1, -2, -2]
        ),
        EqualizerPreset(
            name: "Tanchjim Oxygen",
            section: .headphones,
            group: "Tanchjim",
            description: "Refines Oxygen's benchmark dynamic tuning by eliminating slight top-octave splash.",
            gains: [1, 0, 0, 0, 0, 0, 0, 0, -1, -2]
        ),
        EqualizerPreset(
            name: "Tanchjim Hana (2021)",
            section: .headphones,
            group: "Tanchjim",
            description: "Smooths upper midrange to prevent vocal sibilance on bright master tracks.",
            gains: [1, 0, 0, 0, 0, 0, 0, 0, -1, -2]
        ),
        EqualizerPreset(
            name: "Tanchjim Kara (Hybrid)",
            section: .headphones,
            group: "Tanchjim",
            description: "Elevates sub-bass punch to match Kara's smooth, relaxed midrange response.",
            gains: [2, 1, 0, 0, 0, 0, 0, 0, -1, -2]
        ),
        EqualizerPreset(
            name: "Tanchjim Origin / 4U",
            section: .headphones,
            group: "Tanchjim",
            description: "Provides a transparent top-end shelf for Tanchjim's flagship dynamic driver.",
            gains: [1, 0, 0, 0, 0, 0, 0, 0, -1, -2]
        ),

        // SeeAudio
        EqualizerPreset(
            name: "SeeAudio Yume / Yume II / Yume Ultra",
            section: .headphones,
            group: "SeeAudio",
            description: "Subtly enhances sub-bass rumble while maintaining textbook Harman midrange balance.",
            gains: [1, 0, 0, 0, 0, 0, 0, 0, -1, -2]
        ),
        EqualizerPreset(
            name: "SeeAudio Bravery / Bravery Anniversary",
            section: .headphones,
            group: "SeeAudio",
            description: "Supplies sub-bass extension to this all-BA set and smooths upper-treble response.",
            gains: [2, 1, 0, 0, 0, 0, 0, 0, -1, -2]
        ),
        EqualizerPreset(
            name: "SeeAudio Kaguya / Neko",
            section: .headphones,
            group: "SeeAudio",
            description: "Balances multi-BA speed with warmer low-end body and relaxed treble air.",
            gains: [2, 1, 0, 0, 0, 0, 0, 0, -1, -1]
        ),
        EqualizerPreset(
            name: "SeeAudio Hakuya",
            section: .headphones,
            group: "SeeAudio",
            description: "Minor high-frequency refinement across the EST/BA hybrid array.",
            gains: [1, 0, 0, 0, 0, 0, 0, 0, -1, -2]
        ),

        // Softears
        EqualizerPreset(
            name: "Softears RSV (Reference Sound 5)",
            section: .headphones,
            group: "Softears",
            description: "Lifts sub-bass impact while maintaining RSV's class-leading reference vocal tonality.",
            gains: [2, 1, 0, 0, 0, 0, 0, 0, -1, -1]
        ),
        EqualizerPreset(
            name: "Softears RS10",
            section: .headphones,
            group: "Softears",
            description: "Lifts lowest octave extension on this 10-BA studio flagship while preserving perfect phase linearity.",
            gains: [2, 1, 0, 0, 0, 0, 0, 0, 0, -1]
        ),
        EqualizerPreset(
            name: "Softears Volume",
            section: .headphones,
            group: "Softears",
            description: "Controls lower-treble sharpness and balances hybrid dynamic woofer output.",
            gains: [1, 0, 0, 0, 0, 0, 0, -1, -2, -2]
        ),
        EqualizerPreset(
            name: "Softears Twilight",
            section: .headphones,
            group: "Softears",
            description: "Expands deep sub-bass reach on this single dynamic driver flagship.",
            gains: [2, 1, 0, 0, 0, 0, 0, 0, -1, -2]
        ),
        EqualizerPreset(
            name: "Softears Studio 4",
            section: .headphones,
            group: "Softears",
            description: "Adds sub-bass body to Studio 4's flat monitoring profile for casual listening enjoyment.",
            gains: [3, 2, 1, 0, 0, 0, 0, 0, 0, -1]
        ),

        // Campfire Audio
        EqualizerPreset(
            name: "Campfire Andromeda (Classic / 2020 / Emerald Sea)",
            section: .headphones,
            group: "Campfire Audio",
            description: "Adds sub-bass authority, controls impedance-sensitive lower-mid bloat, and tames sibilance peaks.",
            gains: [4, 3, 1, -1, -1, 0, 1, 2, -2, -3]
        ),
        EqualizerPreset(
            name: "Campfire Solaris (Classic / 2020 / Stellar Horizon)",
            section: .headphones,
            group: "Campfire Audio",
            description: "Tightens low-end punch and smooths upper-mid transitions for natural vocal realism.",
            gains: [2, 1, 0, 0, 0, 0, 1, 0, -2, -3]
        ),
        EqualizerPreset(
            name: "Campfire Mammoth / Honeydew",
            section: .headphones,
            group: "Campfire Audio",
            description: "Slashes excessive bass mud and restores buried vocal clarity (1 kHz–4 kHz).",
            gains: [-4, -5, -4, -2, 0, 1, 2, 3, -2, -3]
        ),
        EqualizerPreset(
            name: "Campfire Holocene / Ara",
            section: .headphones,
            group: "Campfire Audio",
            description: "Warms up lean reference bass and smooths high-frequency BA air.",
            gains: [3, 2, 1, 0, 0, 0, 0, 1, -1, -2]
        ),
        EqualizerPreset(
            name: "Campfire Bonneville",
            section: .headphones,
            group: "Campfire Audio",
            description: "Trims dominant mid-bass energy and relaxes the high-treble shelf.",
            gains: [0, -1, -1, 0, 0, 0, 0, 0, -1, -2]
        ),

        // Sony (In-Ear Series)
        EqualizerPreset(
            name: "Sony IER-M7 / IER-M9 (Stage Monitor)",
            section: .headphones,
            group: "Sony",
            description: "Adds sub-bass punch and lifts upper-mid presence (2 kHz) to brighten Sony's warm stage tuning.",
            gains: [3, 2, 1, 0, 0, 0, 0, 1, 0, -1]
        ),
        EqualizerPreset(
            name: "Sony IER-Z1R",
            section: .headphones,
            group: "Sony",
            description: "Preserves unmatched sub-bass dynamic slam while dampening the notorious 6 kHz–8 kHz treble peak.",
            gains: [0, -1, -1, 0, 0, 0, 0, -1, -3, -2]
        ),
        EqualizerPreset(
            name: "Sony XBA-N3 / N3AP",
            section: .headphones,
            group: "Sony",
            description: "Reduces loose mid-bass bloom while pushing vocal presence and smoothing top-end extension.",
            gains: [-1, -2, -2, 0, 0, 0, 1, 1, -1, -2]
        ),
        EqualizerPreset(
            name: "Sony MDR-EX800ST / MDR-7550",
            section: .headphones,
            group: "Sony",
            description: "Compensates for studio bass roll-off and smooths peaky 6 kHz–8 kHz treble response.",
            gains: [4, 3, 1, 0, 0, 0, 0, 0, -2, -3]
        ),

        // Shure & Westone
        EqualizerPreset(
            name: "Shure SE215 / Aonic 215",
            section: .headphones,
            group: "Shure & Westone",
            description: "Essential fix: cuts muddy mid-bass bloat and heavily boosts upper mids (2 kHz–4 kHz) to reveal buried vocals.",
            gains: [-4, -3, -2, 0, 1, 2, 4, 5, 3, 1]
        ),
        EqualizerPreset(
            name: "Shure SE425 / SE535",
            section: .headphones,
            group: "Shure & Westone",
            description: "Supplies missing sub-bass depth and opens up high-frequency extension on mid-forward BA monitors.",
            gains: [5, 4, 2, 0, 0, -1, 1, 3, 2, 0]
        ),
        EqualizerPreset(
            name: "Shure SE846 (White Filter)",
            section: .headphones,
            group: "Shure & Westone",
            description: "Smooths lower-treble bite and balances SE846's physical low-pass bass filter.",
            gains: [1, 1, 0, 0, 0, 0, 1, 1, -1, -2]
        ),
        EqualizerPreset(
            name: "Shure Aonic 3 / 4 / 5",
            section: .headphones,
            group: "Shure & Westone",
            description: "Lifts lowest sub-bass octave while evening out upper-mid crossover response.",
            gains: [2, 1, 0, 0, 0, 0, 1, 1, -1, -2]
        ),
        EqualizerPreset(
            name: "Westone UM Pro 30 / Pro X30",
            section: .headphones,
            group: "Shure & Westone",
            description: "De-muddies warm stage bass and elevates recessed vocal presence for clear consumer playback.",
            gains: [-2, -3, -2, 0, 1, 2, 3, 3, 0, -1]
        ),
        EqualizerPreset(
            name: "Westone Mach 60 / Mach 70 / Mach 80",
            section: .headphones,
            group: "Shure & Westone",
            description: "Lifts sub-bass impact while maintaining Mach-series reference phase linearity.",
            gains: [2, 1, 0, 0, 0, 0, 0, 1, 0, -1]
        ),

        // Binary Acoustics & QKZ
        EqualizerPreset(
            name: "Binary x Gizaudio Chopin",
            section: .headphones,
            group: "Binary Acoustics & QKZ",
            description: "Smooths upper-treble sparkle while preserving Chopin's clean, isolated sub-bass tuck.",
            gains: [1, 0, 0, 0, 0, 0, 0, 0, -1, -2]
        ),
        EqualizerPreset(
            name: "QKZ x HBB Khan",
            section: .headphones,
            group: "Binary Acoustics & QKZ",
            description: "Minor high-frequency polish on HBB's dual-dynamic bass-focused profile.",
            gains: [1, 0, 0, 0, 0, 0, 0, 0, -1, -2]
        ),
        EqualizerPreset(
            name: "QKZ x HBB Hades",
            section: .headphones,
            group: "Binary Acoustics & QKZ",
            description: "Heavily reduces Hades' overwhelming bass shelf to pull vocals and lead instruments out of the mud.",
            gains: [-4, -6, -4, -1, 0, 1, 2, 3, -1, -2]
        ),
        EqualizerPreset(
            name: "QKZ VK4 (Classic)",
            section: .headphones,
            group: "Binary Acoustics & QKZ",
            description: "Tames budget treble splashiness while maintaining warm, punchy dynamic low-end.",
            gains: [1, 0, 0, 0, 0, 0, 0, -1, -2, -3]
        ),

        // Apple (Over-Ear & On-Ear / Earbuds)
        EqualizerPreset(
            name: "Apple AirPods Max",
            section: .headphones,
            group: "Apple",
            description: "Lifts recessed upper mids (2 kHz–4 kHz) for vocal clarity, adds sub-bass depth, and tames the sharp 9 kHz treble spike.",
            gains: [2, 1, 0, 0, 0, 0, 2, 3, -1, -4]
        ),
        EqualizerPreset(
            name: "Apple AirPods Pro 2",
            section: .headphones,
            group: "Apple",
            description: "Refines Apple's adaptive EQ by reducing high-treble sibilance and smoothing the pinna ear-gain rise.",
            gains: [1, 1, 0, 0, 0, 0, -1, 2, -2, -3]
        ),
        EqualizerPreset(
            name: "Apple AirPods Pro (1st Gen)",
            section: .headphones,
            group: "Apple",
            description: "Restores sub-bass below 50 Hz, pushes recessed 4 kHz presence, and reduces 8 kHz treble glare.",
            gains: [2, 1, 0, 0, 0, 0, 1, 3, -2, -4]
        ),
        EqualizerPreset(
            name: "Apple AirPods 3 / 4 (Open-Ear)",
            section: .headphones,
            group: "Apple",
            description: "Compensates for physical acoustic seal loss inherent in non-sealed open-ear earbuds while controlling mid-bass boom.",
            gains: [8, 6, 2, -2, -1, 0, 2, 3, -1, -3]
        ),
        EqualizerPreset(
            name: "Apple AirPods 2",
            section: .headphones,
            group: "Apple",
            description: "Adds low-end warmth and smooths high-frequency resonance on Apple's classic stem design.",
            gains: [3, 2, 1, 0, 0, 0, 1, 2, -2, -4]
        ),
        EqualizerPreset(
            name: "Apple EarPods (3.5mm / Lightning / USB-C)",
            section: .headphones,
            group: "Apple",
            description: "Restores low-end body lost to ambient air leakage and cleans up upper-frequency harshness.",
            gains: [6, 4, 2, 0, 0, 0, 1, 2, -1, -3]
        ),

        // Sony (Over-Ear & Wireless)
        EqualizerPreset(
            name: "Sony WH-1000XM5",
            section: .headphones,
            group: "Sony",
            description: "Audiophile transformation: slashes muddy 100 Hz–300 Hz boom and elevates suppressed 2 kHz–4 kHz vocals.",
            gains: [-2, -4, -4, -2, 0, 2, 3, 3, -2, -4]
        ),
        EqualizerPreset(
            name: "Sony WH-1000XM4",
            section: .headphones,
            group: "Sony",
            description: "Aggressively cuts muddy mid-bass bloat and boosts upper mids to eliminate the classic Sony vocal veil.",
            gains: [-2, -5, -4, -1, 0, 2, 3, 2, -3, -5]
        ),
        EqualizerPreset(
            name: "Sony WH-1000XM3",
            section: .headphones,
            group: "Sony",
            description: "Eliminates heavy mid-bass boominess, elevates recessed upper mids, and rolls off peaky 8 kHz–16 kHz treble.",
            gains: [-3, -5, -4, -2, 0, 1, 3, 3, -3, -5]
        ),
        EqualizerPreset(
            name: "Sony WF-1000XM5",
            section: .headphones,
            group: "Sony",
            description: "De-bloats lower mids and elevates the 2 kHz–4 kHz ear-gain region for crisper vocal articulation.",
            gains: [-1, -2, -2, -1, 0, 1, 2, 3, -2, -4]
        ),
        EqualizerPreset(
            name: "Sony WF-1000XM4",
            section: .headphones,
            group: "Sony",
            description: "Cleans mid-bass muddiness, elevates upper-mid vocal projection, and damps treble sibilance.",
            gains: [0, -2, -3, -1, 0, 1, 3, 3, -3, -5]
        ),
        EqualizerPreset(
            name: "Sony MDR-7506",
            section: .headphones,
            group: "Sony",
            description: "Adds sub-bass fullness while aggressively pulling down the piercing 4 kHz–8 kHz studio treble glare.",
            gains: [2, 1, 0, 0, 0, 0, 1, -2, -4, -3]
        ),
        EqualizerPreset(
            name: "Sony MDR-CD900ST",
            section: .headphones,
            group: "Sony",
            description: "Restores missing low-end body on this Japanese broadcast standard and smooths aggressive monitoring highs.",
            gains: [4, 3, 1, 0, 0, -1, 1, -1, -3, -4]
        ),
        EqualizerPreset(
            name: "Sony MDR-1AM2",
            section: .headphones,
            group: "Sony",
            description: "Controls enthusiastic consumer bass boom and balances high-frequency clarity.",
            gains: [-2, -3, -2, 0, 0, 1, 2, 1, -2, -3]
        ),
        EqualizerPreset(
            name: "Sony ULT WEAR",
            section: .headphones,
            group: "Sony",
            description: "Restructures bass for deep sub-bass impact while controlling mid-bass bleed into vocal tracks.",
            gains: [6, 5, 2, -1, 0, 0, 1, 2, -1, -3]
        ),

        // Bose
        EqualizerPreset(
            name: "Bose QuietComfort Ultra Headphones",
            section: .headphones,
            group: "Bose",
            description: "Tames over-emphasized 64 Hz–125 Hz bass hump, elevates vocal intelligibility at 2 kHz, and smooths treble sparkle.",
            gains: [-4, -5, -3, -1, 0, 1, 2, 1, -2, -3]
        ),
        EqualizerPreset(
            name: "Bose QuietComfort Ultra Earbuds",
            section: .headphones,
            group: "Bose",
            description: "Cuts excess bass resonance and tames sharp 8 kHz–16 kHz upper treble for a balanced Harman profile.",
            gains: [-3, -4, -3, -1, 0, 1, 2, 2, -3, -5]
        ),
        EqualizerPreset(
            name: "Bose QuietComfort 45 / QC SE",
            section: .headphones,
            group: "Bose",
            description: "Crucial fix for QC45's +6 dB treble spike: sharply cuts 4 kHz–8 kHz to eliminate piercing sibilance.",
            gains: [2, 1, 0, 0, 0, 0, 0, -3, -4, -3]
        ),
        EqualizerPreset(
            name: "Bose QuietComfort 35 II",
            section: .headphones,
            group: "Bose",
            description: "Boosts sub-bass extension and smooths upper treble for fatigue-free travel listening.",
            gains: [2, 1, 0, 0, 0, 0, 1, -2, -3, -3]
        ),
        EqualizerPreset(
            name: "Bose Noise Cancelling Headphones 700",
            section: .headphones,
            group: "Bose",
            description: "Adds low-end body and controls top-end brightness on Bose's slimline ANC flagship.",
            gains: [2, 1, 0, 0, 0, 0, 1, 1, -2, -3]
        ),

        // Sennheiser (Over-Ear & Wireless)
        EqualizerPreset(
            name: "Sennheiser HD 600",
            section: .headphones,
            group: "Sennheiser",
            description: "Restores sub-bass roll-off below 80 Hz, leaving the legendary reference midrange untouched.",
            gains: [6, 4, 2, 0, 0, 0, 0, 1, -1, -2]
        ),
        EqualizerPreset(
            name: "Sennheiser HD 650 / HD 6XX",
            section: .headphones,
            group: "Sennheiser",
            description: "Supplies deep sub-bass rumble and adds +2 dB at 4 kHz to lift the \"Sennheiser veil\" without harshness.",
            gains: [6, 5, 2, 0, 0, 0, 0, 2, 0, -2]
        ),
        EqualizerPreset(
            name: "Sennheiser HD 560S",
            section: .headphones,
            group: "Sennheiser",
            description: "Gives the analytical 560S satisfying sub-bass authority while damping its sharp 6 kHz–8 kHz treble peak.",
            gains: [4, 3, 1, 0, 0, 0, 0, -1, -2, -3]
        ),
        EqualizerPreset(
            name: "Sennheiser HD 800 S",
            section: .headphones,
            group: "Sennheiser",
            description: "Adds missing sub-bass foundation and aggressively tames the notorious 6 kHz ring-radiator treble peak.",
            gains: [6, 4, 1, 0, 0, 0, 0, -2, -5, -2]
        ),
        EqualizerPreset(
            name: "Sennheiser HD 490 PRO (Mixing Pads)",
            section: .headphones,
            group: "Sennheiser",
            description: "Lifts sub-bass extension while preserving the mixing pads' exceptionally flat reference response.",
            gains: [3, 2, 1, 0, 0, 0, 0, 1, 0, -1]
        ),
        EqualizerPreset(
            name: "Sennheiser HD 599 / HD 598",
            section: .headphones,
            group: "Sennheiser",
            description: "Cleans up mid-bass warmth at 500 Hz and extends low/high octaves for gaming and music immersion.",
            gains: [4, 3, 1, 0, -1, 0, 1, 2, -1, -2]
        ),
        EqualizerPreset(
            name: "Sennheiser Momentum 4 Wireless",
            section: .headphones,
            group: "Sennheiser",
            description: "Tames heavy consumer mid-bass (64 Hz–125 Hz) and brings recessed mids forward for audiophile clarity.",
            gains: [-3, -5, -3, -1, 0, 1, 2, 2, -1, -3]
        ),
        EqualizerPreset(
            name: "Sennheiser Momentum True Wireless 4",
            section: .headphones,
            group: "Sennheiser",
            description: "Tightens dynamic bass impact and smooths high-frequency extension.",
            gains: [-2, -2, -1, 0, 0, 0, 1, 2, -1, -3]
        ),
        EqualizerPreset(
            name: "Sennheiser Accentum Wireless",
            section: .headphones,
            group: "Sennheiser",
            description: "De-bloats low-end shelf and opens up upper-mid clarity for vocals.",
            gains: [-1, -2, -1, 0, 0, 1, 2, 2, -2, -3]
        ),

        // Beyerdynamic
        EqualizerPreset(
            name: "Beyerdynamic DT 770 PRO (80 Ohm)",
            section: .headphones,
            group: "Beyerdynamic",
            description: "Essential DT 770 fix: eliminates the piercing 8 kHz \"Beyer-peak\", removes 125 Hz cup boom, and lifts sub-bass.",
            gains: [4, 3, -2, 0, 0, 0, 2, 3, -5, -4]
        ),
        EqualizerPreset(
            name: "Beyerdynamic DT 990 PRO (250 Ohm)",
            section: .headphones,
            group: "Beyerdynamic",
            description: "Cuts the intense +8 dB treble peak at 8 kHz–10 kHz to end ear fatigue and adds warm sub-bass extension.",
            gains: [5, 3, 0, 0, 0, 0, 1, -1, -6, -5]
        ),
        EqualizerPreset(
            name: "Beyerdynamic DT 880 PRO (250 Ohm)",
            section: .headphones,
            group: "Beyerdynamic",
            description: "Reinforces sub-bass depth while slightly relaxing top-end air on this semi-open reference monitor.",
            gains: [3, 2, 0, 0, 0, 0, 1, 1, -1, -2]
        ),
        EqualizerPreset(
            name: "Beyerdynamic DT 900 PRO X",
            section: .headphones,
            group: "Beyerdynamic",
            description: "Smooths Stellar.45 driver treble peaks and bolsters the sub-bass floor.",
            gains: [3, 2, 0, 0, 0, 0, 1, 1, -3, -3]
        ),
        EqualizerPreset(
            name: "Beyerdynamic DT 700 PRO X",
            section: .headphones,
            group: "Beyerdynamic",
            description: "Corrects closed-back chamber treble reflections and provides a clean low-end shelf.",
            gains: [2, 1, 0, 0, 0, 0, 1, 2, -2, -3]
        ),
        EqualizerPreset(
            name: "Beyerdynamic TYGR 300 R",
            section: .headphones,
            group: "Beyerdynamic",
            description: "Refines acoustic foam-damped treble for ultra-smooth spatial gaming and musical enjoyment.",
            gains: [3, 2, 0, 0, 0, 0, 0, 1, -2, -3]
        ),
        EqualizerPreset(
            name: "Beyerdynamic DT 1990 PRO (Balanced Pads)",
            section: .headphones,
            group: "Beyerdynamic",
            description: "Eliminates the sharp 8 kHz Tesla driver treble spike while retaining supreme micro-detail resolution.",
            gains: [4, 2, 0, 0, 0, 0, 1, -1, -5, -4]
        ),

        // Audio-Technica
        EqualizerPreset(
            name: "Audio-Technica ATH-M50X",
            section: .headphones,
            group: "Audio-Technica",
            description: "Restructures boomy 125 Hz mid-bass into a true sub-bass shelf, restores recessed 2 kHz vocals, and smooths metallic treble.",
            gains: [4, 0, -1, -1, -1, -1, 3, 1, -3, -1]
        ),
        EqualizerPreset(
            name: "Audio-Technica ATH-M40X",
            section: .headphones,
            group: "Audio-Technica",
            description: "Polishes M40X's naturally flatter response with deep sub-bass extension and subtle high-treble smoothing.",
            gains: [3, 1, 0, 0, 0, 0, 2, 1, -2, -2]
        ),
        EqualizerPreset(
            name: "Audio-Technica ATH-R70X",
            section: .headphones,
            group: "Audio-Technica",
            description: "Restores missing sub-bass depth to Audio-Technica's flagship open-back reference while keeping its neutral midrange intact.",
            gains: [5, 3, 1, 0, 0, 0, 0, 1, -1, -2]
        ),
        EqualizerPreset(
            name: "Audio-Technica ATH-AD900X / AD700X",
            section: .headphones,
            group: "Audio-Technica",
            description: "Supplies missing sub-bass foundation on these bass-light, ultra-wide soundstage open-air monitors.",
            gains: [5, 3, 1, 0, 0, 0, 1, 2, 1, 0]
        ),
        EqualizerPreset(
            name: "Audio-Technica ATH-MSR7b",
            section: .headphones,
            group: "Audio-Technica",
            description: "Adds low-end warmth and relaxes MSR7b's hyper-analytical high-frequency glare.",
            gains: [3, 2, 0, 0, 0, 0, 0, -1, -3, -2]
        ),

        // HiFiMAN
        EqualizerPreset(
            name: "HiFiMAN Sundara",
            section: .headphones,
            group: "HiFiMAN",
            description: "The gold standard Sundara EQ: lifts the planar sub-bass shelf below 60 Hz without muddying fast planar mids.",
            gains: [5, 4, 1, 0, 0, 0, 0, 0, -1, -2]
        ),
        EqualizerPreset(
            name: "HiFiMAN Edition XS",
            section: .headphones,
            group: "HiFiMAN",
            description: "Restores visceral planar sub-bass rumble and softens wide 8 kHz–12 kHz treble elevation for fatigue-free staging.",
            gains: [4, 3, 1, 0, 0, 0, 0, 0, -2, -3]
        ),
        EqualizerPreset(
            name: "HiFiMAN Ananda / Ananda Nano",
            section: .headphones,
            group: "HiFiMAN",
            description: "Warms up lower octaves and refines upper-mid ear gain for realistic vocal staging.",
            gains: [4, 3, 1, 0, 0, 0, 0, 1, -1, -2]
        ),
        EqualizerPreset(
            name: "HiFiMAN Arya Stealth / Organic",
            section: .headphones,
            group: "HiFiMAN",
            description: "Adds authoritative sub-bass extension and slightly smooths Arya's tall, ultra-resolving soundstage.",
            gains: [3, 2, 1, 0, 0, 0, 0, 1, -1, -2]
        ),
        EqualizerPreset(
            name: "HiFiMAN HE400SE",
            section: .headphones,
            group: "HiFiMAN",
            description: "Fixes budget planar sub-bass roll-off and dabs down high-frequency sibilance.",
            gains: [5, 3, 1, 0, 0, 0, 0, 0, -2, -3]
        ),
        EqualizerPreset(
            name: "HiFiMAN Susvara",
            section: .headphones,
            group: "HiFiMAN",
            description: "Delivers deep sub-bass weight to match Susvara's world-class planar speed and acoustic transparency.",
            gains: [6, 4, 2, 0, 0, 0, 0, 1, -2, -3]
        ),

        // Audeze
        EqualizerPreset(
            name: "Audeze LCD-X / LCD-XC",
            section: .headphones,
            group: "Audeze",
            description: "Lifts recessed 2 kHz–4 kHz ear-gain to bring vocals forward, backed by distortion-free planar sub-bass.",
            gains: [3, 2, 1, 0, 0, 0, 1, 2, 0, -1]
        ),
        EqualizerPreset(
            name: "Audeze LCD-2 / LCD-2 Classic",
            section: .headphones,
            group: "Audeze",
            description: "Brightens the famous dark LCD-2 midrange and injects deep, linear planar low-end rumble.",
            gains: [4, 3, 1, 0, 0, 0, 0, 1, -1, -2]
        ),
        EqualizerPreset(
            name: "Audeze Maxwell (Wireless)",
            section: .headphones,
            group: "Audeze",
            description: "Polishes factory planar tuning by smoothing the top octave for pristine audio playback.",
            gains: [1, 1, 0, 0, 0, 0, 0, 0, -1, -2]
        ),
        EqualizerPreset(
            name: "Audeze MM-100 / MM-500",
            section: .headphones,
            group: "Audeze",
            description: "Manny Marroquin reference studio polish: elevates sub-bass depth while preserving pinpoint mixing transients.",
            gains: [2, 1, 0, 0, 0, 0, 1, 1, 0, -1]
        ),

        // Samsung & Google
        EqualizerPreset(
            name: "Samsung Galaxy Buds 2 Pro",
            section: .headphones,
            group: "Samsung & Google",
            description: "Gently tames slight 8 kHz–16 kHz treble grit on an otherwise near-perfect Harman baseline.",
            gains: [0, 0, 0, 0, 0, 0, 0, -1, -2, -2]
        ),
        EqualizerPreset(
            name: "Samsung Galaxy Buds 3 Pro",
            section: .headphones,
            group: "Samsung & Google",
            description: "Balances dual-amp planar/dynamic driver crossover by smoothing upper midrange.",
            gains: [1, 1, 0, 0, 0, 0, -1, 1, -1, -2]
        ),
        EqualizerPreset(
            name: "Samsung Galaxy Buds FE",
            section: .headphones,
            group: "Samsung & Google",
            description: "Lifts deep sub-bass rumble while maintaining a clean, uncolored vocal midrange.",
            gains: [1, 0, 0, 0, 0, 0, 0, -1, -2, -2]
        ),
        EqualizerPreset(
            name: "Google Pixel Buds Pro / Pro 2",
            section: .headphones,
            group: "Samsung & Google",
            description: "Adds sub-bass extension and tightens treble tuning for balanced clarity.",
            gains: [2, 1, 0, 0, 0, 0, 0, 1, -2, -3]
        ),
        EqualizerPreset(
            name: "Google Pixel Buds A-Series",
            section: .headphones,
            group: "Samsung & Google",
            description: "Restores low-end body lost through the spatial vent and smooths vocal presence.",
            gains: [3, 2, 1, 0, 0, 0, 1, 2, -1, -2]
        ),

        // Focal, Meze, Koss & Dan Clark
        EqualizerPreset(
            name: "Focal Clear / Clear Mg",
            section: .headphones,
            group: "Focal, Meze, Koss & Dan Clark",
            description: "Adds rich sub-bass extension while smoothing 8 kHz–10 kHz metallic dome resonance to showcase Focal's dynamic punch.",
            gains: [3, 2, 1, 0, 0, 0, 0, 1, -1, -2]
        ),
        EqualizerPreset(
            name: "Focal Bathys (Wireless)",
            section: .headphones,
            group: "Focal, Meze, Koss & Dan Clark",
            description: "Polishes Bathys' audiophile wireless tuning with smoother high-frequency roll-off.",
            gains: [1, 0, 0, 0, 0, 0, 0, 1, -1, -2]
        ),
        EqualizerPreset(
            name: "Focal Azurys / Hadenys",
            section: .headphones,
            group: "Focal, Meze, Koss & Dan Clark",
            description: "Supports M-shaped aluminum/magnesium dome with deep low-end body and transparent treble.",
            gains: [2, 1, 0, 0, 0, 0, 0, 1, 0, -1]
        ),
        EqualizerPreset(
            name: "Meze 99 Classics / Neo",
            section: .headphones,
            group: "Focal, Meze, Koss & Dan Clark",
            description: "Legendary rescue curve: slashes massive +8 dB mid-bass bloat (64 Hz–250 Hz) to reveal sparkling mids and clear vocals.",
            gains: [-4, -6, -5, -2, 0, 1, 2, 2, -2, -3]
        ),
        EqualizerPreset(
            name: "Meze 109 Pro",
            section: .headphones,
            group: "Focal, Meze, Koss & Dan Clark",
            description: "Adds low-end warmth while taming the aggressive 6 kHz–8 kHz beryllium/polymer dome brightness peak.",
            gains: [3, 2, 0, 0, 0, 0, 0, -1, -4, -3]
        ),
        EqualizerPreset(
            name: "Koss Porta Pro / KSC75",
            section: .headphones,
            group: "Focal, Meze, Koss & Dan Clark",
            description: "Cleans boomy 250 Hz mud, boosts sub-bass, and elevates upper mids (2 kHz–4 kHz) for audiophile-grade fidelity.",
            gains: [5, 2, -2, -2, -1, 0, 2, 4, 3, 1]
        ),
        EqualizerPreset(
            name: "Dan Clark Audio E3 / Aeon 2",
            section: .headphones,
            group: "Focal, Meze, Koss & Dan Clark",
            description: "Complements DCA AMTS metamaterial tuning with subtle sub-bass support and pristine planar air.",
            gains: [2, 1, 0, 0, 0, 0, 0, 1, -1, -2]
        )
    ]
}
