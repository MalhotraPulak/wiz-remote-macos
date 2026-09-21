import AppKit
import SwiftUI

struct MenuBarContentView: View {
    @ObservedObject var viewModel: BulbService
    @ObservedObject var launchAtLogin: LaunchAtLoginController
    @ObservedObject var musicSync: MusicSyncController

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if viewModel.bulbs.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(viewModel.bulbs.enumerated()), id: \.element.id) { index, bulb in
                            bulbRow(bulb, index: index)

                            if bulb.id != viewModel.bulbs.last?.id {
                                Divider()
                                    .padding(.leading, 42)
                            }
                        }
                    }
                }
                .frame(maxHeight: 310)
            }

            Divider()
            MusicSyncPanel(controller: musicSync, bulbs: viewModel.bulbs)

            Divider()
            footer
        }
        .frame(width: 370)
        .task {
            if viewModel.bulbs.isEmpty {
                viewModel.connectBulbs()
            }
            musicSync.updateAvailableBulbs(viewModel.bulbs)
        }
        .onChange(of: viewModel.bulbs) { bulbs in
            musicSync.updateAvailableBulbs(bulbs)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "lightbulb.led.wide.fill")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.yellow)

            VStack(alignment: .leading, spacing: 1) {
                Text("WiZ Remote")
                    .font(.system(size: 15, weight: .semibold))

                Text(lightCountLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                viewModel.connectBulbs()
            } label: {
                if viewModel.isScanning {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 18, height: 18)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 18, height: 18)
                }
            }
            .buttonStyle(.borderless)
            .help("Scan again")
            .disabled(viewModel.isScanning)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: viewModel.isScanning ? "dot.radiowaves.left.and.right" : "wifi.exclamationmark")
                .font(.system(size: 27, weight: .light))
                .foregroundStyle(.secondary)

            Text(viewModel.isScanning ? "Finding WiZ devices…" : "No WiZ devices found")
                .font(.system(size: 13, weight: .semibold))

            Text("The Mac may use 5 GHz; devices can use 2.4 GHz when both bands share the same LAN.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    private func bulbRow(_ bulb: WizBulb, index: Int) -> some View {
        let isPending = viewModel.pendingBulbIDs.contains(bulb.id)

        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Circle()
                    .fill(stateColor(for: bulb))
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(bulb.moduleName ?? "WiZ device \(index + 1)")
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)

                    Text(deviceIdentifier(for: bulb))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if isPending {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 38)
                } else {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { bulb.isOn ?? false },
                            set: { viewModel.setPower(for: bulb.id, to: $0) }
                        )
                    )
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                }
            }

            HStack(spacing: 9) {
                if let brightness = bulb.brightness {
                    Label("\(brightness)%", systemImage: "sun.max")
                }
                if let temperature = bulb.temperature {
                    Label("\(temperature) K", systemImage: "thermometer.medium")
                }
                if let rssi = bulb.rssi {
                    Label("\(rssi) dBm", systemImage: "wifi")
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.leading, 18)

            if let lastError = bulb.lastError {
                Label(lastError, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 18)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            HStack {
                Toggle(
                    "Launch at Login",
                    isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { launchAtLogin.setEnabled($0) }
                    )
                )
                .toggleStyle(.switch)
                .controlSize(.small)

                Spacer()

                if launchAtLogin.requiresApproval {
                    Button("Approve…") {
                        launchAtLogin.openLoginItemSettings()
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10, weight: .medium))
                }
            }

            if let statusNote = launchAtLogin.statusNote {
                Text(statusNote)
                    .font(.system(size: 10))
                    .foregroundStyle(launchAtLogin.requiresApproval ? .orange : .secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(viewModel.statusMessage)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(maxWidth: .infinity)

            HStack {
                Button("Open Full App") {
                    openFullApp()
                }
                .buttonStyle(.borderless)

                Spacer()

                Button("Quit") {
                    musicSync.stop()
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderless)
            }
            .font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var lightCountLabel: String {
        switch viewModel.bulbs.count {
        case 0:
            return "Local controls"
        case 1:
            return "1 device"
        default:
            return "\(viewModel.bulbs.count) devices"
        }
    }

    private func deviceIdentifier(for bulb: WizBulb) -> String {
        if let mac = bulb.formattedMAC {
            return "\(bulb.ipAddress)  •  \(mac)"
        }
        return bulb.ipAddress
    }

    private func stateColor(for bulb: WizBulb) -> Color {
        switch bulb.isOn {
        case .some(true):
            return .green
        case .some(false):
            return .secondary
        case .none:
            return .orange
        }
    }

    private func openFullApp() {
        let applicationURL = URL(fileURLWithPath: "/Applications/WiZ Remote.app")
        NSWorkspace.shared.open(applicationURL)
    }
}
