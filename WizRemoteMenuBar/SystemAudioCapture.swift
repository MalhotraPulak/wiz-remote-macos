import Accelerate
import CoreAudio
import Foundation

struct AudioFeatures: Sendable {
    let level: Float
    let bass: Float
    let midrange: Float
    let treble: Float
    let onsetStrength: Float
    let lowOnset: Float
    let midOnset: Float
    let highOnset: Float
    let isBeat: Bool
    let capturedAt: Date

    static let silence = AudioFeatures(
        level: 0,
        bass: 0,
        midrange: 0,
        treble: 0,
        onsetStrength: 0,
        lowOnset: 0,
        midOnset: 0,
        highOnset: 0,
        isBeat: false,
        capturedAt: .distantPast
    )
}

enum SystemAudioCaptureError: LocalizedError {
    case unavailable
    case unsupportedFormat
    case operationFailed(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "System-audio capture requires macOS 14.2 or newer."
        case .unsupportedFormat:
            return "macOS returned an unsupported system-audio format."
        case .operationFailed(let operation, let status):
            if status == kAudioDevicePermissionsError {
                return "System Audio Recording permission was denied. Enable WiZ Remote Menu Bar in System Settings → Privacy & Security → Screen & System Audio Recording."
            }
            return "\(operation) failed (Core Audio status \(status))."
        }
    }
}

/// Captures the outgoing system mix with the macOS Core Audio process-tap API.
/// The tap is private, never mutes playback, and only forwards PCM samples to
/// the in-memory analyzer.
final class SystemAudioCapture {
    typealias FeatureHandler = (AudioFeatures) -> Void

    private let audioQueue = DispatchQueue(
        label: "community.wizremote.system-audio",
        qos: .userInteractive
    )
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var analyzer: AudioFeatureAnalyzer?

    var isRunning: Bool {
        ioProcID != nil
    }

    func start(featureHandler: @escaping FeatureHandler) throws {
        guard !isRunning else { return }
        guard #available(macOS 14.2, *) else {
            throw SystemAudioCaptureError.unavailable
        }

        do {
            try startModernCapture(featureHandler: featureHandler)
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if aggregateDeviceID != kAudioObjectUnknown, let ioProcID {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
        }
        ioProcID = nil

        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }

        if #available(macOS 14.2, *), tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }

        analyzer = nil
    }

    deinit {
        stop()
    }

    @available(macOS 14.2, *)
    private func startModernCapture(featureHandler: @escaping FeatureHandler) throws {
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDescription.name = "WiZ Remote Music Sync"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted

        try check(
            AudioHardwareCreateProcessTap(tapDescription, &tapID),
            operation: "Create system-audio tap"
        )

        let tapUID = try propertyString(
            objectID: tapID,
            selector: kAudioTapPropertyUID,
            operation: "Read audio-tap identifier"
        )
        let format = try propertyValue(
            objectID: tapID,
            selector: kAudioTapPropertyFormat,
            defaultValue: AudioStreamBasicDescription(),
            operation: "Read audio-tap format"
        )

        guard
            format.mFormatID == kAudioFormatLinearPCM,
            format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
            format.mBitsPerChannel == 32,
            format.mSampleRate > 0
        else {
            throw SystemAudioCaptureError.unsupportedFormat
        }

        let tapEntry: [String: Any] = [
            kAudioSubTapUIDKey: tapUID,
            kAudioSubTapDriftCompensationKey: true
        ]
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "WiZ Remote Audio Capture",
            kAudioAggregateDeviceUIDKey: "community.wizremote.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [tapEntry]
        ]

        try check(
            AudioHardwareCreateAggregateDevice(
                aggregateDescription as CFDictionary,
                &aggregateDeviceID
            ),
            operation: "Create private audio device"
        )

        analyzer = AudioFeatureAnalyzer(
            sampleRate: format.mSampleRate,
            handler: featureHandler
        )

        var newIOProcID: AudioDeviceIOProcID?
        try check(
            AudioDeviceCreateIOProcIDWithBlock(
                &newIOProcID,
                aggregateDeviceID,
                audioQueue
            ) { [weak self] _, inputData, _, _, _ in
                self?.consume(inputData)
            },
            operation: "Attach audio capture callback"
        )
        guard let newIOProcID else {
            throw SystemAudioCaptureError.operationFailed(
                "Attach audio capture callback",
                kAudioHardwareUnspecifiedError
            )
        }
        ioProcID = newIOProcID

        try check(
            AudioDeviceStart(aggregateDeviceID, newIOProcID),
            operation: "Start system-audio capture"
        )
    }

    private func consume(_ inputData: UnsafePointer<AudioBufferList>) {
        guard let analyzer else { return }

        let mutableList = UnsafeMutablePointer<AudioBufferList>(mutating: inputData)
        let buffers = UnsafeMutableAudioBufferListPointer(mutableList)
        guard !buffers.isEmpty else { return }

        if buffers.count == 1 {
            let buffer = buffers[0]
            guard let data = buffer.mData else { return }

            let channelCount = max(1, Int(buffer.mNumberChannels))
            let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let frameCount = sampleCount / channelCount
            guard frameCount > 0 else { return }

            let samples = data.assumingMemoryBound(to: Float.self)
            if channelCount == 1 {
                analyzer.consume(Array(UnsafeBufferPointer(start: samples, count: frameCount)))
            } else {
                var mono = [Float](repeating: 0, count: frameCount)
                for frame in 0..<frameCount {
                    var sum: Float = 0
                    for channel in 0..<channelCount {
                        sum += samples[frame * channelCount + channel]
                    }
                    mono[frame] = sum / Float(channelCount)
                }
                analyzer.consume(mono)
            }
            return
        }

        let usableBuffers = buffers.filter { $0.mData != nil && $0.mDataByteSize > 0 }
        guard let firstBuffer = usableBuffers.first else { return }
        let frameCount = Int(firstBuffer.mDataByteSize) / MemoryLayout<Float>.size
        guard frameCount > 0 else { return }

        var mono = [Float](repeating: 0, count: frameCount)
        for buffer in usableBuffers {
            guard let data = buffer.mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            let availableFrames = min(
                frameCount,
                Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            )
            for frame in 0..<availableFrames {
                mono[frame] += samples[frame]
            }
        }
        let divisor = Float(usableBuffers.count)
        for index in mono.indices {
            mono[index] /= divisor
        }
        analyzer.consume(mono)
    }

    private func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw SystemAudioCaptureError.operationFailed(operation, status)
        }
    }

    private func propertyString(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        operation: String
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, $0)
        }
        try check(status, operation: operation)
        return value as String
    }

    private func propertyValue<T>(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        defaultValue: T,
        operation: String
    ) throws -> T {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = defaultValue
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, $0)
        }
        try check(status, operation: operation)
        return value
    }
}

final class AudioFeatureAnalyzer {
    private let sampleRate: Double
    private let frameSize = 2_048
    private let handler: (AudioFeatures) -> Void
    private let dftSetup: vDSP_DFT_Setup
    private var accumulator: [Float] = []
    private var window: [Float]
    private var imaginaryInput: [Float]
    private var realOutput: [Float]
    private var imaginaryOutput: [Float]
    private var previousMagnitudes: [Float]
    private var averageFlux: Float = 0
    private var averageLowFlux: Float = 0
    private var averageMidFlux: Float = 0
    private var averageHighFlux: Float = 0
    private var lastBeatDate = Date.distantPast
    private var smoothedLevel: Float = 0
    private var smoothedBass: Float = 0
    private var smoothedMidrange: Float = 0
    private var smoothedTreble: Float = 0

    init(sampleRate: Double, handler: @escaping (AudioFeatures) -> Void) {
        self.sampleRate = sampleRate
        self.handler = handler
        guard let setup = vDSP_DFT_zop_CreateSetup(
            nil,
            vDSP_Length(frameSize),
            .FORWARD
        ) else {
            fatalError("Unable to create vDSP DFT setup")
        }
        dftSetup = setup
        window = [Float](repeating: 0, count: frameSize)
        imaginaryInput = [Float](repeating: 0, count: frameSize)
        realOutput = [Float](repeating: 0, count: frameSize)
        imaginaryOutput = [Float](repeating: 0, count: frameSize)
        previousMagnitudes = [Float](repeating: 0, count: frameSize / 2)

        vDSP_hann_window(
            &window,
            vDSP_Length(frameSize),
            Int32(vDSP_HANN_NORM)
        )
        accumulator.reserveCapacity(frameSize * 2)
    }

    deinit {
        vDSP_DFT_DestroySetup(dftSetup)
    }

    func consume(_ samples: [Float]) {
        accumulator.append(contentsOf: samples)

        while accumulator.count >= frameSize {
            let frame = Array(accumulator.prefix(frameSize))
            accumulator.removeFirst(frameSize)
            analyze(frame)
        }
    }

    private func analyze(_ frame: [Float]) {
        var rms: Float = 0
        vDSP_rmsqv(frame, 1, &rms, vDSP_Length(frameSize))
        let level = normalizedDecibels(20 * log10(max(rms, 0.000_001)), floor: -60)

        var windowed = [Float](repeating: 0, count: frameSize)
        vDSP_vmul(
            frame,
            1,
            window,
            1,
            &windowed,
            1,
            vDSP_Length(frameSize)
        )

        vDSP_DFT_Execute(
            dftSetup,
            windowed,
            imaginaryInput,
            &realOutput,
            &imaginaryOutput
        )

        let binCount = frameSize / 2
        var magnitudes = [Float](repeating: 0, count: binCount)
        for index in 0..<binCount {
            let real = realOutput[index]
            let imaginary = imaginaryOutput[index]
            magnitudes[index] = real * real + imaginary * imaginary
        }

        let bass = bandLevel(magnitudes, lowerHz: 40, upperHz: 180)
        let midrange = bandLevel(magnitudes, lowerHz: 180, upperHz: 2_000)
        let treble = bandLevel(magnitudes, lowerHz: 2_000, upperHz: 12_000)

        let flux = spectralFlux(
            magnitudes,
            previous: previousMagnitudes,
            lowerHz: 30,
            upperHz: min(16_000, sampleRate / 2)
        )
        let lowFlux = spectralFlux(
            magnitudes,
            previous: previousMagnitudes,
            lowerHz: 40,
            upperHz: 180
        )
        let midFlux = spectralFlux(
            magnitudes,
            previous: previousMagnitudes,
            lowerHz: 180,
            upperHz: 2_000
        )
        let highFlux = spectralFlux(
            magnitudes,
            previous: previousMagnitudes,
            lowerHz: 2_000,
            upperHz: 12_000
        )

        let onsetStrength = normalizedOnset(flux, average: &averageFlux)
        let lowOnset = normalizedOnset(lowFlux, average: &averageLowFlux)
        let midOnset = normalizedOnset(midFlux, average: &averageMidFlux)
        let highOnset = normalizedOnset(highFlux, average: &averageHighFlux)
        previousMagnitudes = magnitudes

        let now = Date()
        let beat = level > 0.08
            && max(lowOnset * 1.15, onsetStrength, midOnset * 0.82) > 0.34
            && now.timeIntervalSince(lastBeatDate) > 0.19
        if beat {
            lastBeatDate = now
        }

        smoothedLevel = smooth(smoothedLevel, toward: level)
        smoothedBass = smooth(smoothedBass, toward: bass)
        smoothedMidrange = smooth(smoothedMidrange, toward: midrange)
        smoothedTreble = smooth(smoothedTreble, toward: treble)

        handler(
            AudioFeatures(
                level: smoothedLevel,
                bass: smoothedBass,
                midrange: smoothedMidrange,
                treble: smoothedTreble,
                onsetStrength: onsetStrength,
                lowOnset: lowOnset,
                midOnset: midOnset,
                highOnset: highOnset,
                isBeat: beat,
                capturedAt: now
            )
        )
    }

    private func bandLevel(
        _ magnitudes: [Float],
        lowerHz: Double,
        upperHz: Double
    ) -> Float {
        let frequencyPerBin = sampleRate / Double(frameSize)
        let lowerBin = max(1, Int(lowerHz / frequencyPerBin))
        let upperBin = min(magnitudes.count - 1, Int(upperHz / frequencyPerBin))
        guard upperBin >= lowerBin else { return 0 }

        var sum: Float = 0
        for index in lowerBin...upperBin {
            sum += magnitudes[index]
        }
        let average = sum / Float(upperBin - lowerBin + 1)
        let normalizedPower = average / Float(frameSize * frameSize)
        return normalizedDecibels(
            10 * log10(max(normalizedPower, 0.000_000_000_1)),
            floor: -70
        )
    }

    private func spectralFlux(
        _ magnitudes: [Float],
        previous: [Float],
        lowerHz: Double,
        upperHz: Double
    ) -> Float {
        let frequencyPerBin = sampleRate / Double(frameSize)
        let lowerBin = max(1, Int(lowerHz / frequencyPerBin))
        let upperBin = min(magnitudes.count - 1, Int(upperHz / frequencyPerBin))
        guard upperBin >= lowerBin else { return 0 }

        var flux: Float = 0
        for index in lowerBin...upperBin {
            flux += max(0, sqrt(magnitudes[index]) - sqrt(previous[index]))
        }
        return flux / Float(upperBin - lowerBin + 1)
    }

    private func normalizedOnset(_ flux: Float, average: inout Float) -> Float {
        guard average > 0 else {
            average = max(flux, 0.000_001)
            return 0
        }

        let ratio = flux / max(average, 0.000_001)
        let score = min(1, max(0, (ratio - 1.12) / 1.9))
        average = average * 0.94 + flux * 0.06
        return score
    }

    private func normalizedDecibels(_ decibels: Float, floor: Float) -> Float {
        min(1, max(0, (decibels - floor) / -floor))
    }

    private func smooth(_ previous: Float, toward target: Float) -> Float {
        let coefficient: Float = target > previous ? 0.58 : 0.17
        return previous + (target - previous) * coefficient
    }
}
