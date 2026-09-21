import Darwin
import Foundation

struct WizMusicFrame: Sendable {
    let red: Int
    let green: Int
    let blue: Int
    let brightness: Int
}

struct WizStreamSendResult: Sendable {
    let packetsSent: Int
    let packetErrors: Int
    let acknowledgements: Int
}

/// A deliberately small, non-blocking UDP transport for live animation.
/// It never waits for or retries a frame: the next frame is always more useful
/// than an old one by the time a lost datagram is detected.
final class WizRealtimeSender {
    private let port: UInt16 = 38_899
    private var socketDescriptor: Int32 = -1
    private var commandID = 10_000

    init() {
        socketDescriptor = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketDescriptor >= 0 else { return }

        let existingFlags = fcntl(socketDescriptor, F_GETFL)
        if existingFlags >= 0 {
            _ = fcntl(socketDescriptor, F_SETFL, existingFlags | O_NONBLOCK)
        }

        var receiveBufferSize: Int32 = 256 * 1_024
        _ = withUnsafePointer(to: &receiveBufferSize) {
            setsockopt(
                socketDescriptor,
                SOL_SOCKET,
                SO_RCVBUF,
                $0,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }
    }

    deinit {
        if socketDescriptor >= 0 {
            Darwin.close(socketDescriptor)
        }
    }

    func send(_ frame: WizMusicFrame, to bulbs: [WizBulb]) -> WizStreamSendResult {
        guard socketDescriptor >= 0 else {
            return WizStreamSendResult(
                packetsSent: 0,
                packetErrors: bulbs.count,
                acknowledgements: 0
            )
        }

        var sent = 0
        var errors = 0
        let acknowledgements = drainAcknowledgements()

        for bulb in bulbs where bulb.isLightingDevice {
            var parameters: [String: Any] = [
                "state": true,
                "dimming": min(100, max(10, frame.brightness))
            ]
            if bulb.supportsColor {
                parameters["r"] = min(255, max(0, frame.red))
                parameters["g"] = min(255, max(0, frame.green))
                parameters["b"] = min(255, max(0, frame.blue))
            }

            if send(parameters: parameters, to: bulb.ipAddress) {
                sent += 1
            } else {
                errors += 1
            }
        }

        return WizStreamSendResult(
            packetsSent: sent,
            packetErrors: errors,
            acknowledgements: acknowledgements
        )
    }

    @discardableResult
    func restore(_ bulbs: [WizBulb]) -> WizStreamSendResult {
        guard socketDescriptor >= 0 else {
            return WizStreamSendResult(
                packetsSent: 0,
                packetErrors: bulbs.count,
                acknowledgements: 0
            )
        }

        var sent = 0
        var errors = 0
        let acknowledgements = drainAcknowledgements()

        for bulb in bulbs {
            let parameters = restorationParameters(for: bulb)
            if send(parameters: parameters, to: bulb.ipAddress) {
                sent += 1
            } else {
                errors += 1
            }
        }

        return WizStreamSendResult(
            packetsSent: sent,
            packetErrors: errors,
            acknowledgements: acknowledgements
        )
    }

    private func restorationParameters(for bulb: WizBulb) -> [String: Any] {
        guard bulb.isOn == true else {
            return ["state": false]
        }

        var parameters: [String: Any] = ["state": true]
        if let brightness = bulb.brightness {
            parameters["dimming"] = brightness
        }

        if let sceneID = bulb.sceneID, sceneID > 0 {
            parameters["sceneId"] = sceneID
            if let speed = bulb.speed {
                parameters["speed"] = speed
            }
            return parameters
        }

        if let red = bulb.red, let green = bulb.green, let blue = bulb.blue {
            parameters["r"] = red
            parameters["g"] = green
            parameters["b"] = blue
            if let coldWhite = bulb.coldWhite {
                parameters["c"] = coldWhite
            }
            if let warmWhite = bulb.warmWhite {
                parameters["w"] = warmWhite
            }
        } else if let temperature = bulb.temperature {
            parameters["temp"] = temperature
        }

        return parameters
    }

    private func send(parameters: [String: Any], to host: String) -> Bool {
        commandID += 1
        let object: [String: Any] = [
            "id": commandID,
            "method": "setPilot",
            "params": parameters
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: object) else {
            return false
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard host.withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else {
            return false
        }

        let byteCount = payload.withUnsafeBytes { payloadBytes in
            withUnsafePointer(to: &address) { addressPointer in
                addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.sendto(
                        socketDescriptor,
                        payloadBytes.baseAddress,
                        payloadBytes.count,
                        0,
                        $0,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
        }
        return byteCount == payload.count
    }

    private func drainAcknowledgements() -> Int {
        guard socketDescriptor >= 0 else { return 0 }

        var count = 0
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let received = buffer.withUnsafeMutableBytes {
                Darwin.recv(
                    socketDescriptor,
                    $0.baseAddress,
                    $0.count,
                    MSG_DONTWAIT
                )
            }
            if received > 0 {
                count += 1
            } else {
                break
            }
        }
        return count
    }
}
