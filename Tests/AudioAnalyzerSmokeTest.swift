import Foundation

@main
struct AudioAnalyzerSmokeTest {
    static func main() {
        checkDominantBand(frequency: 80, expected: \AudioFeatures.bass, name: "bass")
        checkDominantBand(frequency: 1_000, expected: \AudioFeatures.midrange, name: "midrange")
        checkDominantBand(frequency: 6_000, expected: \AudioFeatures.treble, name: "treble")
        checkLowFrequencyTransient()
        print("Audio analyzer smoke test passed")
    }

    private static func checkDominantBand(
        frequency: Double,
        expected: KeyPath<AudioFeatures, Float>,
        name: String
    ) {
        var latest = AudioFeatures.silence
        let analyzer = AudioFeatureAnalyzer(sampleRate: 48_000) {
            latest = $0
        }
        let samples = (0..<4_096).map { index in
            Float(0.5 * sin(2 * .pi * frequency * Double(index) / 48_000))
        }
        analyzer.consume(samples)

        let expectedValue = latest[keyPath: expected]
        let competingValues = [latest.bass, latest.midrange, latest.treble]
            .filter { $0 != expectedValue }
        guard
            latest.level > 0.3,
            expectedValue > (competingValues.max() ?? 0)
        else {
            fputs(
                "Expected \(name) dominance at \(frequency) Hz, got bass=\(latest.bass), mids=\(latest.midrange), treble=\(latest.treble)\n",
                stderr
            )
            exit(1)
        }
    }

    private static func checkLowFrequencyTransient() {
        var strongestOnset: Float = 0
        var detectedBeat = false
        let analyzer = AudioFeatureAnalyzer(sampleRate: 48_000) { features in
            strongestOnset = max(strongestOnset, features.lowOnset)
            detectedBeat = detectedBeat || features.isBeat
        }

        let frameSize = 2_048
        for block in 0..<8 {
            let amplitude = block < 6 ? 0.035 : 0.8
            let samples = (0..<frameSize).map { index in
                let sampleIndex = block * frameSize + index
                return Float(amplitude * sin(2 * .pi * 80 * Double(sampleIndex) / 48_000))
            }
            analyzer.consume(samples)
        }

        guard strongestOnset > 0.3, detectedBeat else {
            fputs(
                "Expected a bass transient and beat, got low onset=\(strongestOnset), beat=\(detectedBeat)\n",
                stderr
            )
            exit(1)
        }
    }
}
