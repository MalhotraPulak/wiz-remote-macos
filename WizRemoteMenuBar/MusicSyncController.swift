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
    @Published var updateRate = 10
    @Published var sendsToLights = false

    private let audioCapture = SystemAudioCapture()
    private let sender = WizRealtimeSender()
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
        isRunning = false
        isBeat = false
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
        level = features.level
        bass = features.bass
        midrange = features.midrange
        treble = features.treble
        isBeat = features.isBeat
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

        let peak = max(latestFeatures.bass, latestFeatures.midrange, latestFeatures.treble, 0.05)
        let red = Int(255 * min(1, latestFeatures.bass / peak))
        let green = Int(255 * min(1, latestFeatures.midrange / peak))
        let blue = Int(255 * min(1, latestFeatures.treble / peak))
        var brightness = 10 + Int(90 * latestFeatures.level)
        if latestFeatures.isBeat {
            brightness = max(brightness, 85)
        }

        let result = sender.send(
            WizMusicFrame(
                red: red,
                green: green,
                blue: blue,
                brightness: brightness
            ),
            to: targets
        )
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
    }
}
