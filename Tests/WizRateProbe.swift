import Darwin
import Foundation

@main
struct WizRateProbe {
    static func main() {
        do {
            let bulbs = try WizUDPClient.discover(timeout: 4.5)
            print("Discovered \(bulbs.count) WiZ devices:")
            for bulb in bulbs {
                print("  \(bulb.ipAddress)  \(bulb.moduleName ?? "unknown")  \(bulb.formattedMAC ?? "no MAC")")
            }

            let targets = bulbs.filter(isRequestedTestBulb)
            print("Matched \(targets.count) ES/ESP25 SHRGB test bulbs.")
            for bulb in targets {
                print("  TARGET \(bulb.ipAddress)  \(bulb.moduleName ?? "unknown")")
            }

            guard CommandLine.arguments.contains("--run") else { return }
            guard !targets.isEmpty else {
                fputs("No matching bulbs; refusing to send any UDP animation frames.\n", stderr)
                exit(2)
            }

            let sender = WizRealtimeSender()
            var needsRestore = true
            defer {
                if needsRestore {
                    restore(targets, using: sender)
                }
            }

            let rate = 5
            let frameCount = rate * 4
            var sent = 0
            var errors = 0
            print("Running a 4-second 5 Hz colour sweep…")

            for frameIndex in 0..<frameCount {
                let hue = Double(frameIndex) / Double(frameCount)
                let color = rgb(hue: hue)
                let result = sender.send(
                    WizMusicFrame(
                        red: color.red,
                        green: color.green,
                        blue: color.blue,
                        brightness: 70
                    ),
                    to: targets
                )
                sent += result.packetsSent
                errors += result.packetErrors
                usleep(useconds_t(1_000_000 / rate))
            }

            restore(targets, using: sender)
            needsRestore = false
            print("Sweep complete: \(sent) packets sent, \(errors) local send errors.")

            usleep(500_000)
            let refreshed = try WizUDPClient.discover(timeout: 2.5)
            for original in targets {
                guard let current = refreshed.first(where: { $0.id == original.id }) else {
                    print("  RESTORE CHECK \(original.ipAddress): no verification reply")
                    continue
                }
                let powerMatches = current.isOn == original.isOn
                let sceneMatches = (original.sceneID ?? 0) == 0
                    || current.sceneID == original.sceneID
                print(
                    "  RESTORE CHECK \(original.ipAddress): power=\(powerMatches ? "OK" : "CHANGED") scene=\(sceneMatches ? "OK" : "CHANGED")"
                )
            }
        } catch {
            fputs("WiZ rate probe failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func isRequestedTestBulb(_ bulb: WizBulb) -> Bool {
        guard let moduleName = bulb.moduleName?.uppercased() else { return false }
        let compact = moduleName.filter(\.isLetter)
        let familyMatches = moduleName.contains("ESP25") || moduleName.contains("ES25")
        let colorMatches = compact.contains("SHRGB") || compact.contains("SHRGP")
        return familyMatches && colorMatches && bulb.supportsColor
    }

    private static func restore(_ bulbs: [WizBulb], using sender: WizRealtimeSender) {
        for _ in 0..<3 {
            _ = sender.restore(bulbs)
            usleep(120_000)
        }
    }

    private static func rgb(hue: Double) -> (red: Int, green: Int, blue: Int) {
        let position = (hue - floor(hue)) * 6
        let sector = Int(position)
        let fraction = position - Double(sector)
        let rising = Int(255 * fraction)
        let falling = 255 - rising

        switch sector {
        case 0: return (255, rising, 0)
        case 1: return (falling, 255, 0)
        case 2: return (0, 255, rising)
        case 3: return (0, falling, 255)
        case 4: return (rising, 0, 255)
        default: return (255, 0, falling)
        }
    }
}
