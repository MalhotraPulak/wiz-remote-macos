import AVFoundation
import SwiftUI

@MainActor
final class SoundPlayer: ObservableObject {
    private var player: AVAudioPlayer?

    func play(_ name: String) {
#if SWIFT_PACKAGE
        let url = Bundle.module.url(forResource: name, withExtension: "wav")
#else
        let url = Bundle.main.url(forResource: name, withExtension: "wav")
#endif

        guard let url else { return }

        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.play()
        } catch {
            print("Error playing sound: \(error.localizedDescription)")
        }
    }
}

struct ContentView: View {
    @StateObject private var viewModel = BulbService()
    @StateObject private var soundPlayer = SoundPlayer()

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black, Color(red: 0.025, green: 0.10, blue: 0.28)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 18) {
                header
                statusBar

                if viewModel.bulbs.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            ForEach(Array(viewModel.bulbs.enumerated()), id: \.element.id) { index, bulb in
                                bulbCard(for: bulb, index: index)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .padding(26)
        }
        .frame(minWidth: 680, minHeight: 520)
        .task {
            viewModel.connectBulbs()
        }
    }

    private var header: some View {
        HStack(spacing: 13) {
            Image(systemName: "lightbulb.led.wide.fill")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(.yellow)

            VStack(alignment: .leading, spacing: 2) {
                Text("WiZ Remote")
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text(lightCountLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
            }

            Spacer()

            Button {
                viewModel.connectBulbs()
            } label: {
                HStack(spacing: 7) {
                    if viewModel.isScanning {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(viewModel.isScanning ? "Scanning…" : "Scan again")
                }
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(.white.opacity(0.12))
                .foregroundStyle(.white)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isScanning)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(viewModel.bulbs.isEmpty ? Color.orange : Color.green)
                .frame(width: 9, height: 9)

            Text(viewModel.statusMessage)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.82))

            Spacer()
        }
        .padding(.horizontal, 13)
        .frame(minHeight: 38)
        .background(.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private var emptyState: some View {
        VStack(spacing: 13) {
            Spacer()

            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.white.opacity(0.62))

            Text(viewModel.isScanning ? "Listening for every bulb…" : "No lights found")
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)

            Text("Your Mac may use 5 GHz. The bulbs can stay on 2.4 GHz as long as both bands are on the same LAN and client isolation is off.")
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.62))
                .frame(maxWidth: 470)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func bulbCard(for bulb: WizBulb, index: Int) -> some View {
        let isPending = viewModel.pendingBulbIDs.contains(bulb.id)
        let requestedState = !(bulb.isOn ?? false)

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 13) {
                ZStack {
                    Circle()
                        .fill(stateColor(for: bulb).opacity(0.18))
                        .frame(width: 46, height: 46)

                    Image(systemName: bulb.isOn == true ? "lightbulb.fill" : "lightbulb")
                        .font(.system(size: 21, weight: .medium))
                        .foregroundStyle(stateColor(for: bulb))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(bulb.moduleName ?? "WiZ light \(index + 1)")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)

                    HStack(spacing: 8) {
                        Text(powerLabel(for: bulb))
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(stateColor(for: bulb))

                        Text(bulb.ipAddress)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.58))
                    }
                }

                Spacer()

                Button {
                    soundPlayer.play(requestedState ? "on" : "off")
                    viewModel.setPower(for: bulb.id, to: requestedState)
                } label: {
                    HStack(spacing: 7) {
                        if isPending {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        } else {
                            Image(systemName: "power")
                        }
                        Text(isPending ? "Confirming…" : (requestedState ? "Turn on" : "Turn off"))
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 118, height: 38)
                    .background(requestedState ? Color.green.opacity(0.86) : Color.red.opacity(0.86))
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isPending)
            }

            Divider()
                .overlay(.white.opacity(0.12))

            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 155), alignment: .leading)
                ],
                alignment: .leading,
                spacing: 9
            ) {
                ForEach(Array(metadata(for: bulb).enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 6) {
                        Text(item.label.uppercased())
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.42))

                        Text(item.value)
                            .font(.system(size: 11, weight: .medium, design: item.monospaced ? .monospaced : .default))
                            .foregroundStyle(.white.opacity(0.78))
                            .lineLimit(1)
                    }
                }
            }

            if let lastError = bulb.lastError {
                Label(lastError, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        }
        .padding(17)
        .background(.white.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        }
    }

    private var lightCountLabel: String {
        switch viewModel.bulbs.count {
        case 0: return "Local network control"
        case 1: return "1 light found"
        default: return "\(viewModel.bulbs.count) lights found"
        }
    }

    private func powerLabel(for bulb: WizBulb) -> String {
        switch bulb.isOn {
        case .some(true): return "ON"
        case .some(false): return "OFF"
        case .none: return "STATE UNKNOWN"
        }
    }

    private func stateColor(for bulb: WizBulb) -> Color {
        switch bulb.isOn {
        case .some(true): return .yellow
        case .some(false): return .white.opacity(0.55)
        case .none: return .orange
        }
    }

    private func metadata(for bulb: WizBulb) -> [(label: String, value: String, monospaced: Bool)] {
        var values: [(String, String, Bool)] = []

        if let mac = bulb.formattedMAC {
            values.append(("MAC", mac, true))
        }
        if let firmware = bulb.firmwareVersion {
            values.append(("Firmware", firmware, true))
        }
        if let homeID = bulb.homeID {
            values.append(("Home", String(homeID), true))
        }
        if let roomID = bulb.roomID {
            values.append(("Room", String(roomID), true))
        }
        if let groupID = bulb.groupID {
            values.append(("Group", String(groupID), true))
        }
        if let rssi = bulb.rssi {
            values.append(("Signal", "\(rssi) dBm", false))
        }
        if let brightness = bulb.brightness {
            values.append(("Brightness", "\(brightness)%", false))
        }
        if let temperature = bulb.temperature {
            values.append(("White", "\(temperature) K", false))
        }
        if let sceneID = bulb.sceneID {
            values.append(("Scene", String(sceneID), false))
        }

        if values.isEmpty {
            values.append(("Device", "No additional metadata returned", false))
        }
        return values
    }
}
