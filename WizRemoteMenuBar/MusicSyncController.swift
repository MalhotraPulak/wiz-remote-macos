import AppKit
import Foundation
import SwiftUI

@MainActor
final class MusicSyncController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var level: Float = 0
    @Published private(set) var bass: Float = 0
    @Published private(set) var midrange: Float = 0
    @Published private(set) var treble: Float = 0
    @Published private(set) var isBeat = false
    @Published private(set) var statusMessage = "Ready for a system-audio test."
    @Published private(set) var selectedBulbIDs: Set<String> = []
    @Published private(set) var framesSent = 0
    @Published private(set) var packetsSent = 0
    @Published private(set) var packetErrors = 0
    @Published private(set) var acknowledgements = 0
    @Published private(set) var estimatedBPM: Double?
    @Published private(set) var beatConfidence: Float = 0
    @Published private(set) var partySection = PartySection.listening
    @Published var updateRate = 10
    @Published var sendsToLights = false
    @Published var partyPalette = PartyPalette.neon
    @Published var partyIntensity = 0.85

    private let audioCapture = SystemAudioCapture()
    private let sender = WizRealtimeSender()
    private let partyEngine = PartyLightEngine()
    private var sendTimer: Timer?
    private var latestFeatures = AudioFeatures.silence
    private var availableBulbs: [WizBulb] = []
    private var savedBulbStates: [WizBulb] = []
    private var initializedSelection = false
    private var observers: [NSObjectProtocol] = []

    init() {
        observers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.stop(message: "Stopped before sleep and restored the selected lights.")
                }
            }
        )
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.stop(message: "Stopped.")
                }
            }
        )
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    func updateAvailableBulbs(_ bulbs: [WizBulb]) {
        availableBulbs = bulbs.filter(\.isLightingDevice)
        let validIDs = Set(availableBulbs.map(\.id))
        selectedBulbIDs.formIntersection(validIDs)

        if !initializedSelection, !availableBulbs.isEmpty {
            selectedBulbIDs = validIDs
            initializedSelection = true
        }
    }

    func setSelected(_ selected: Bool, bulbID: String) {
        guard !isRunning else { return }
        if selected {
            selectedBulbIDs.insert(bulbID)
        } else {
            selectedBulbIDs.remove(bulbID)
        }
    }

    func toggle() {
        isRunning ? stop() : start()
    }

    func start() {
        guard !isRunning else { return }

        let targets = sendsToLights
            ? availableBulbs.filter { selectedBulbIDs.contains($0.id) }
            : []
        guard !sendsToLights || !targets.isEmpty else {
            statusMessage = "Select at least one light. Sockets are excluded."
            return
        }

        updateRate = [5, 10, 15, 20].min(by: {
            abs($0 - updateRate) < abs($1 - updateRate)
        }) ?? 10
        savedBulbStates = targets
        latestFeatures = .silence
        resetMetrics()
        partyEngine.palette = partyPalette
        partyEngine.intensity = Float(partyIntensity)

        do {
            try audioCapture.start { [weak self] features in
                Task { @MainActor in
                    self?.receive(features)
                }
            }
        } catch {
            savedBulbStates = []
            statusMessage = error.localizedDescription
            return
        }

        isRunning = true
        if sendsToLights {
            statusMessage = "Capturing system audio locally at \(updateRate) updates/sec."
            startSendTimer()
        } else {
            statusMessage = "Capturing and analyzing audio locally; light output is disabled."
        }
    }

    func stop(message: String? = nil) {
        guard isRunning || audioCapture.isRunning else { return }

        let controlledLights = !savedBulbStates.isEmpty
        sendTimer?.invalidate()
        sendTimer = nil
        audioCapture.stop()
        _ = sender.restore(savedBulbStates)
        savedBulbStates = []
        latestFeatures = .silence
        partyEngine.reset()
        isRunning = false
        isBeat = false
        estimatedBPM = nil
        beatConfidence = 0
        partySection = .listening
        statusMessage = message ?? (controlledLights
            ? "Stopped and restored the selected lights."
            : "System-audio capture stopped.")
    }

    private func startSendTimer() {
        sendTimer?.invalidate()
        let interval = 1 / Double(updateRate)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sendLatestFrame()
            }
        }
        timer.tolerance = interval * 0.08
        RunLoop.main.add(timer, forMode: .common)
        sendTimer = timer
    }

    private func receive(_ features: AudioFeatures) {
        latestFeatures = features
        partyEngine.observe(features)
        level = features.level
        bass = features.bass
        midrange = features.midrange
        treble = features.treble
        isBeat = features.isBeat
        estimatedBPM = partyEngine.currentBPM
        beatConfidence = partyEngine.beatConfidence
        partySection = partyEngine.currentSection
        if isRunning, !sendsToLights {
            statusMessage = "Audio is live. Enable light output after checking the meters."
        }
    }

    private func sendLatestFrame() {
        guard isRunning else { return }
        guard Date().timeIntervalSince(latestFeatures.capturedAt) < 0.6 else {
            statusMessage = "Capture is running, but no PCM audio has arrived yet."
            return
        }

        let targets = savedBulbStates
        guard !targets.isEmpty else { return }

        partyEngine.palette = partyPalette
        partyEngine.intensity = Float(partyIntensity)
        let partyOutput = partyEngine.render(
            lightCount: targets.count,
            at: latestFeatures.capturedAt
        )
        var framesByBulbID: [String: WizMusicFrame] = [:]
        for (bulb, frame) in zip(targets, partyOutput.frames) {
            framesByBulbID[bulb.id] = WizMusicFrame(
                red: frame.color.red,
                green: frame.color.green,
                blue: frame.color.blue,
                brightness: frame.brightness
            )
        }

        let result = sender.send(
            framesByBulbID,
            to: targets
        )
        estimatedBPM = partyOutput.bpm
        beatConfidence = partyOutput.beatConfidence
        partySection = partyOutput.section
        isBeat = partyOutput.triggeredBeat
        framesSent += 1
        packetsSent += result.packetsSent
        packetErrors += result.packetErrors
        acknowledgements += result.acknowledgements
        statusMessage = "Streaming \(updateRate) updates/sec to \(targets.count) light\(targets.count == 1 ? "" : "s")."
    }

    private func resetMetrics() {
        framesSent = 0
        packetsSent = 0
        packetErrors = 0
        acknowledgements = 0
        level = 0
        bass = 0
        midrange = 0
        treble = 0
        isBeat = false
        estimatedBPM = nil
        beatConfidence = 0
        partySection = .listening
        partyEngine.reset()
    }
}
