import SwiftUI

struct MusicSyncPanel: View {
    @ObservedObject var controller: MusicSyncController
    let bulbs: [WizBulb]
    @State private var isExpanded = false

    private var lightingDevices: [WizBulb] {
        bulbs.filter(\.isLightingDevice)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                deviceSelection
                Toggle("Send UDP colours to selected lights", isOn: $controller.sendsToLights)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.system(size: 11, weight: .medium))
                    .disabled(controller.isRunning)
                partyControls
                rateSelection
                meters
                controls

                Text(controller.statusMessage)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if controller.isRunning {
                    Text(
                        "Frames \(controller.framesSent)  •  Packets \(controller.packetsSent)  •  Send errors \(controller.packetErrors)  •  Replies \(controller.acknowledgements)"
                    )
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                }
            }
            .padding(.top, 11)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: controller.isRunning ? "waveform.circle.fill" : "waveform.circle")
                    .foregroundStyle(controller.isRunning ? .green : .secondary)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Music Sync Lab")
                        .font(.system(size: 13, weight: .semibold))
                    Text(controller.isRunning ? syncSummary : "Beat-aware two-light party mode")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if controller.isRunning {
                    Circle()
                        .fill(controller.isBeat ? Color.yellow : Color.green)
                        .frame(width: controller.isBeat ? 11 : 7, height: controller.isBeat ? 11 : 7)
                        .animation(.easeOut(duration: 0.12), value: controller.isBeat)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var deviceSelection: some View {
        if lightingDevices.isEmpty {
            Label("No lighting devices reported brightness, white, or RGB capability.", systemImage: "exclamationmark.triangle")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("LIGHTS — SOCKETS ARE EXCLUDED")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)

                ForEach(Array(lightingDevices.enumerated()), id: \.element.id) { index, bulb in
                    Toggle(
                        isOn: Binding(
                            get: { controller.selectedBulbIDs.contains(bulb.id) },
                            set: { controller.setSelected($0, bulbID: bulb.id) }
                        )
                    ) {
                        HStack(spacing: 5) {
                            Text(bulb.moduleName ?? "WiZ light \(index + 1)")
                                .lineLimit(1)
                            Text(bulb.supportsColor ? "RGB" : "DIM")
                                .font(.system(size: 8, weight: .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(.secondary.opacity(0.14))
                                .clipShape(Capsule())
                        }
                    }
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .disabled(controller.isRunning)
                }
            }
        }
    }

    private var rateSelection: some View {
        HStack(spacing: 9) {
            Text("UDP rate")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)

            Picker("UDP rate", selection: $controller.updateRate) {
                ForEach([5, 10, 15, 20], id: \.self) { rate in
                    Text("\(rate) Hz").tag(rate)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(controller.isRunning)
        }
    }

    private var partyControls: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Palette")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)

                Spacer()

                Picker("Palette", selection: $controller.partyPalette) {
                    ForEach(PartyPalette.allCases) { palette in
                        Text(palette.rawValue).tag(palette)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 105)
            }

            HStack(spacing: 8) {
                Text("Intensity")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .leading)

                Slider(value: $controller.partyIntensity, in: 0.25...1)

                Text("\(Int(controller.partyIntensity * 100))%")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)
            }
        }
    }

    private var meters: some View {
        VStack(spacing: 6) {
            MeterRow(label: "LEVEL", value: controller.level, color: .white)
            MeterRow(label: "BASS", value: controller.bass, color: .red)
            MeterRow(label: "MIDS", value: controller.midrange, color: .green)
            MeterRow(label: "HIGH", value: controller.treble, color: .blue)
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                controller.toggle()
            } label: {
                Label(
                    controller.isRunning ? "Stop and Restore" : "Start Music Sync",
                    systemImage: controller.isRunning ? "stop.fill" : "play.fill"
                )
                .font(.system(size: 11, weight: .semibold))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(controller.isRunning ? .red : .accentColor)
            .disabled(
                !controller.isRunning
                    && controller.sendsToLights
                    && controller.selectedBulbIDs.isEmpty
            )
        }
    }

    private var syncSummary: String {
        if let bpm = controller.estimatedBPM {
            return "\(controller.partySection.rawValue) • \(Int(bpm.rounded())) BPM • \(Int(controller.beatConfidence * 100))% lock"
        }
        return "\(controller.partySection.rawValue) • finding the beat"
    }
}

private struct MeterRow: View {
    let label: String
    let value: Float
    let color: Color

    var body: some View {
        HStack(spacing: 7) {
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.secondary.opacity(0.14))
                    Capsule()
                        .fill(color.opacity(0.82))
                        .frame(width: geometry.size.width * CGFloat(min(1, max(0, value))))
                }
            }
            .frame(height: 6)

            Text("\(Int(value * 100))")
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .trailing)
        }
    }
}
