import Foundation

struct PartyRGB: Equatable, Sendable {
    let red: Int
    let green: Int
    let blue: Int
}

enum PartyPalette: String, CaseIterable, Identifiable, Sendable {
    case neon = "Neon"
    case club = "Club"
    case sunset = "Sunset"
    case cyber = "Cyber"

    var id: String { rawValue }

    fileprivate var colors: [PartyRGB] {
        switch self {
        case .neon:
            return [
                PartyRGB(red: 255, green: 0, blue: 116),
                PartyRGB(red: 88, green: 0, blue: 255),
                PartyRGB(red: 0, green: 210, blue: 255),
                PartyRGB(red: 255, green: 35, blue: 0)
            ]
        case .club:
            return [
                PartyRGB(red: 45, green: 0, blue: 255),
                PartyRGB(red: 195, green: 0, blue: 255),
                PartyRGB(red: 0, green: 115, blue: 255),
                PartyRGB(red: 255, green: 0, blue: 62)
            ]
        case .sunset:
            return [
                PartyRGB(red: 255, green: 35, blue: 0),
                PartyRGB(red: 255, green: 118, blue: 0),
                PartyRGB(red: 255, green: 0, blue: 92),
                PartyRGB(red: 150, green: 0, blue: 255)
            ]
        case .cyber:
            return [
                PartyRGB(red: 0, green: 255, blue: 190),
                PartyRGB(red: 0, green: 110, blue: 255),
                PartyRGB(red: 255, green: 0, blue: 220),
                PartyRGB(red: 105, green: 255, blue: 0)
            ]
        }
    }
}

enum PartySection: String, Sendable {
    case listening = "Listening"
    case breakdown = "Breakdown"
    case build = "Build"
    case groove = "Groove"
    case drop = "Drop"
}

struct PartyLightFrame: Equatable, Sendable {
    let color: PartyRGB
    let brightness: Int
}

struct PartyRenderOutput: Sendable {
    let frames: [PartyLightFrame]
    let bpm: Double?
    let beatConfidence: Float
    let section: PartySection
    let triggeredBeat: Bool
}

/// Turns audio analysis into a small lighting show rather than directly mapping
/// frequency bands to RGB. It tracks quarter-note timing, keeps colors stable for
/// a bar, and uses contrast between lights to make beats visually legible.
final class PartyLightEngine {
    var palette: PartyPalette = .neon
    var intensity: Float = 0.85

    private var levelFloor: Float = 0
    private var levelCeiling: Float = 0
    private var adaptiveLevel: Float = 0
    private var shortEnergy: Float = 0
    private var longEnergy: Float = 0
    private var hasEnergyReference = false

    private var acceptedBeatTime: TimeInterval?
    private var beatPeriod: TimeInterval?
    private var beatIntervals: [TimeInterval] = []
    private var beatOrdinal = 0
    private var lastRenderedOrdinal: Int?
    private(set) var beatConfidence: Float = 0

    private var pendingBeat = false
    private var pendingKick: Float = 0
    private var pendingSnare: Float = 0
    private var pendingHat: Float = 0

    private var section: PartySection = .listening
    private var quietSince: TimeInterval?
    private var dropUntil: TimeInterval = 0

    var currentBPM: Double? {
        guard let beatPeriod, beatConfidence >= 0.18 else { return nil }
        return 60 / beatPeriod
    }

    var currentSection: PartySection { section }

    func reset() {
        levelFloor = 0
        levelCeiling = 0
        adaptiveLevel = 0
        shortEnergy = 0
        longEnergy = 0
        hasEnergyReference = false
        acceptedBeatTime = nil
        beatPeriod = nil
        beatIntervals.removeAll(keepingCapacity: true)
        beatOrdinal = 0
        lastRenderedOrdinal = nil
        beatConfidence = 0
        pendingBeat = false
        pendingKick = 0
        pendingSnare = 0
        pendingHat = 0
        section = .listening
        quietSince = nil
        dropUntil = 0
    }

    func observe(_ features: AudioFeatures) {
        let timestamp = features.capturedAt.timeIntervalSinceReferenceDate
        updateAdaptiveEnergy(features.level)

        pendingKick = max(pendingKick, features.lowOnset)
        pendingSnare = max(pendingSnare, features.midOnset)
        pendingHat = max(pendingHat, features.highOnset)

        let beatEvidence = max(
            features.lowOnset * 1.18,
            features.onsetStrength,
            features.midOnset * 0.78
        )
        if features.isBeat || beatEvidence > 0.48 {
            registerBeatCandidate(at: timestamp, strength: beatEvidence)
        }

        updateSection(at: timestamp, lowOnset: features.lowOnset)
    }

    func render(lightCount: Int, at date: Date) -> PartyRenderOutput {
        guard lightCount > 0 else {
            return PartyRenderOutput(
                frames: [],
                bpm: currentBPM,
                beatConfidence: beatConfidence,
                section: section,
                triggeredBeat: false
            )
        }

        let timestamp = date.timeIntervalSinceReferenceDate
        let timing = effectiveBeatTiming(at: timestamp)
        let triggeredBeat = pendingBeat || timing.ordinal != lastRenderedOrdinal
        if triggeredBeat {
            lastRenderedOrdinal = timing.ordinal
        }

        let strength = min(1, max(0.25, intensity))
        let pulse = max(timing.pulse, triggeredBeat ? 1 : 0)
        let downbeat = timing.ordinal.isMultiple(of: 4)
        let bar = max(0, timing.ordinal / 4)
        let colors = palette.colors
        let baseColorIndex = bar % colors.count

        var frames: [PartyLightFrame] = []
        frames.reserveCapacity(lightCount)

        for lightIndex in 0..<lightCount {
            let activeLight = timing.ordinal % lightCount
            let isActive = downbeat || lightIndex == activeLight

            var colorIndex = (baseColorIndex + lightIndex) % colors.count
            if pendingSnare > 0.52 {
                colorIndex = (colorIndex + 1) % colors.count
            }
            if section == .drop, downbeat {
                colorIndex = (baseColorIndex + 2) % colors.count
            }

            let quietBase = 10 + 22 * adaptiveLevel
            let contrast = (34 + 38 * strength) * pulse
            var brightness = quietBase
            if isActive {
                brightness += contrast
                brightness += 15 * pendingKick
            } else {
                brightness += 7 * pulse
                brightness += 12 * pendingHat
            }

            switch section {
            case .listening:
                brightness = min(brightness, 38)
            case .breakdown:
                brightness = 12 + 30 * adaptiveLevel + (isActive ? 14 * pulse : 0)
            case .build:
                brightness += 8 * strength
            case .groove:
                break
            case .drop:
                brightness += downbeat ? 18 * strength : 7 * strength
            }

            frames.append(
                PartyLightFrame(
                    color: colors[colorIndex],
                    brightness: Int(min(100, max(10, brightness.rounded())))
                )
            )
        }

        pendingBeat = false
        pendingKick = 0
        pendingSnare = 0
        pendingHat = 0

        return PartyRenderOutput(
            frames: frames,
            bpm: currentBPM,
            beatConfidence: beatConfidence,
            section: section,
            triggeredBeat: triggeredBeat
        )
    }

    private func updateAdaptiveEnergy(_ level: Float) {
        if !hasEnergyReference {
            levelFloor = max(0, level * 0.35)
            levelCeiling = max(0.22, level)
            shortEnergy = level
            longEnergy = level
            hasEnergyReference = true
        }

        if level < levelFloor {
            levelFloor = levelFloor * 0.72 + level * 0.28
        } else {
            levelFloor += (level - levelFloor) * 0.002
        }

        if level > levelCeiling {
            levelCeiling = levelCeiling * 0.45 + level * 0.55
        } else {
            levelCeiling += (level - levelCeiling) * 0.006
        }

        let dynamicRange = max(0.14, levelCeiling - levelFloor)
        let normalized = min(1, max(0, (level - levelFloor) / dynamicRange))
        adaptiveLevel += (normalized - adaptiveLevel) * (normalized > adaptiveLevel ? 0.42 : 0.11)
        shortEnergy += (adaptiveLevel - shortEnergy) * 0.16
        longEnergy += (adaptiveLevel - longEnergy) * 0.018
    }

    private func registerBeatCandidate(at timestamp: TimeInterval, strength: Float) {
        if let acceptedBeatTime {
            let elapsed = timestamp - acceptedBeatTime
            guard elapsed >= 0.21 else { return }

            if let beatPeriod, elapsed < beatPeriod * 0.62, strength < 0.82 {
                return
            }

            let normalizedInterval = foldIntoTempoRange(elapsed)
            if (0.28...0.75).contains(normalizedInterval) {
                beatIntervals.append(normalizedInterval)
                if beatIntervals.count > 12 {
                    beatIntervals.removeFirst(beatIntervals.count - 12)
                }
                updateTempoEstimate()
            }
        }

        acceptedBeatTime = timestamp
        beatOrdinal += 1
        pendingBeat = true
    }

    private func foldIntoTempoRange(_ interval: TimeInterval) -> TimeInterval {
        var folded = interval
        while folded < 0.28 {
            folded *= 2
        }
        while folded > 0.75 {
            folded /= 2
        }
        return folded
    }

    private func updateTempoEstimate() {
        guard !beatIntervals.isEmpty else { return }
        let sorted = beatIntervals.sorted()
        let median = sorted[sorted.count / 2]
        if let current = beatPeriod {
            beatPeriod = current * 0.72 + median * 0.28
        } else {
            beatPeriod = median
        }

        let absoluteDeviations = beatIntervals.map { abs($0 - median) }.sorted()
        let medianDeviation = absoluteDeviations[absoluteDeviations.count / 2]
        let sampleConfidence = min(1, Float(beatIntervals.count) / 6)
        let stability = max(0, 1 - Float(medianDeviation / 0.11))
        beatConfidence = sampleConfidence * stability
    }

    private func effectiveBeatTiming(at timestamp: TimeInterval) -> (ordinal: Int, pulse: Float) {
        guard let acceptedBeatTime else {
            return (beatOrdinal, 0)
        }
        guard let beatPeriod, beatConfidence >= 0.32 else {
            let elapsed = max(0, timestamp - acceptedBeatTime)
            return (beatOrdinal, Float(exp(-elapsed / 0.14)))
        }

        let elapsed = max(0, timestamp - acceptedBeatTime)
        let predictedSteps = max(0, Int(floor((elapsed + beatPeriod * 0.08) / beatPeriod)))
        let beatTime = acceptedBeatTime + Double(predictedSteps) * beatPeriod
        let phase = max(0, timestamp - beatTime)
        let pulse = Float(exp(-phase / max(0.08, beatPeriod * 0.24)))
        return (beatOrdinal + predictedSteps, pulse)
    }

    private func updateSection(at timestamp: TimeInterval, lowOnset: Float) {
        if timestamp < dropUntil {
            section = .drop
            return
        }

        if adaptiveLevel < 0.16 {
            if quietSince == nil {
                quietSince = timestamp
            }
            if timestamp - (quietSince ?? timestamp) > 1.1 {
                section = .breakdown
            }
            return
        }

        if section == .breakdown, adaptiveLevel > 0.58, lowOnset > 0.35 {
            dropUntil = timestamp + 1.8
            section = .drop
            quietSince = nil
            return
        }

        quietSince = nil
        if shortEnergy > longEnergy + 0.14, adaptiveLevel > 0.35 {
            section = .build
        } else if beatConfidence > 0.18 {
            section = .groove
        } else {
            section = .listening
        }
    }
}
