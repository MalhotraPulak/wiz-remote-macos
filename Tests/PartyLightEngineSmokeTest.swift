import Foundation

@main
struct PartyLightEngineSmokeTest {
    static func main() {
        checkTempoLockAndTwoLightContrast()
        checkBreakdownDetection()
        print("Party light engine smoke test passed")
    }

    private static func checkTempoLockAndTwoLightContrast() {
        let engine = PartyLightEngine()
        let start = Date(timeIntervalSinceReferenceDate: 10_000)

        for beat in 0..<10 {
            engine.observe(
                feature(
                    at: start.addingTimeInterval(Double(beat) * 0.5),
                    level: 0.68,
                    lowOnset: 0.9,
                    midOnset: beat.isMultiple(of: 2) ? 0.2 : 0.62,
                    isBeat: true
                )
            )
        }

        let output = engine.render(
            lightCount: 2,
            at: start.addingTimeInterval(4.5)
        )
        guard let bpm = output.bpm, abs(bpm - 120) < 1 else {
            fputs("Expected a 120 BPM lock, got \(String(describing: output.bpm))\n", stderr)
            exit(1)
        }
        guard output.beatConfidence > 0.7 else {
            fputs("Expected a confident beat lock, got \(output.beatConfidence)\n", stderr)
            exit(1)
        }
        guard output.frames.count == 2 else {
            fputs("Expected two rendered light frames\n", stderr)
            exit(1)
        }
        let contrast = abs(output.frames[0].brightness - output.frames[1].brightness)
        guard contrast >= 25 else {
            fputs("Expected alternating bulb contrast, got \(contrast)\n", stderr)
            exit(1)
        }
    }

    private static func checkBreakdownDetection() {
        let engine = PartyLightEngine()
        let start = Date(timeIntervalSinceReferenceDate: 20_000)

        for index in 0..<12 {
            engine.observe(
                feature(
                    at: start.addingTimeInterval(Double(index) * 0.05),
                    level: 0.72,
                    lowOnset: index.isMultiple(of: 10) ? 0.8 : 0,
                    isBeat: index.isMultiple(of: 10)
                )
            )
        }
        for index in 0..<40 {
            engine.observe(
                feature(
                    at: start.addingTimeInterval(0.6 + Double(index) * 0.05),
                    level: 0.015,
                    lowOnset: 0,
                    isBeat: false
                )
            )
        }

        let output = engine.render(
            lightCount: 2,
            at: start.addingTimeInterval(2.55)
        )
        guard output.section == .breakdown else {
            fputs("Expected breakdown mode, got \(output.section.rawValue)\n", stderr)
            exit(1)
        }
    }

    private static func feature(
        at date: Date,
        level: Float,
        lowOnset: Float,
        midOnset: Float = 0,
        isBeat: Bool
    ) -> AudioFeatures {
        AudioFeatures(
            level: level,
            bass: level,
            midrange: level * 0.65,
            treble: level * 0.42,
            onsetStrength: max(lowOnset, midOnset),
            lowOnset: lowOnset,
            midOnset: midOnset,
            highOnset: 0,
            isBeat: isBeat,
            capturedAt: date
        )
    }
}
