import Darwin
import Foundation
import SwiftUI

struct WizBulb: Identifiable, Sendable, Equatable {
    let ipAddress: String
    let macAddress: String?
    let moduleName: String?
    let firmwareVersion: String?
    let homeID: Int?
    let roomID: Int?
    let groupID: Int?
    var isOn: Bool?
    var brightness: Int?
    var temperature: Int?
    var sceneID: Int?
    var speed: Int?
    var red: Int?
    var green: Int?
    var blue: Int?
    var coldWhite: Int?
    var warmWhite: Int?
    var rssi: Int?
    var lastError: String?

    var id: String {
        macAddress?.lowercased() ?? ipAddress
    }

    var formattedMAC: String? {
        guard let macAddress else { return nil }
        let cleaned = macAddress
            .uppercased()
            .filter { $0.isHexDigit }
        guard cleaned.count == 12 else { return macAddress.uppercased() }

        return stride(from: 0, to: cleaned.count, by: 2)
            .map { offset in
                let start = cleaned.index(cleaned.startIndex, offsetBy: offset)
                let end = cleaned.index(start, offsetBy: 2)
                return String(cleaned[start..<end])
            }
            .joined(separator: ":")
    }

    var supportsColor: Bool {
        moduleName?.uppercased().contains("RGB") == true
    }

    var isLightingDevice: Bool {
        supportsColor
            || brightness != nil
            || temperature != nil
            || red != nil
            || coldWhite != nil
            || warmWhite != nil
    }
}

enum WizNetworkError: LocalizedError {
    case invalidAddress(String)
    case malformedResponse
    case remoteError(String)
    case socketFailure(String)
    case timedOut
    case commandNotConfirmed

    var errorDescription: String? {
        switch self {
        case .invalidAddress(let address):
            return "Invalid bulb address: \(address)"
        case .malformedResponse:
            return "The bulb returned an unexpected response."
        case .remoteError(let message):
            return "The bulb rejected the command: \(message)"
        case .socketFailure(let operation):
            return "Network operation failed: \(operation)."
        case .timedOut:
            return "The bulb did not respond."
        case .commandNotConfirmed:
            return "The bulb replied but ignored the command. In the WiZ app, check Settings → Security → Local communication; unverified local control must be allowed unless this app is given your home security key."
        }
    }
}

/// WiZ local UDP protocol client.
///
/// Bulbs listen on UDP port 38899. Discovery binds that same port and sends
/// repeated registration broadcasts for the entire scan window, collecting
/// every reply instead of returning after the first bulb responds.
enum WizUDPClient {
    private static let port: UInt16 = 38_899

    private struct UDPResponse {
        let data: Data
        let sourceIP: String
    }

    private struct DiscoveredEndpoint {
        let ipAddress: String
        let macAddress: String?
    }

    static func discover(timeout: TimeInterval = 4.5) throws -> [WizBulb] {
        let endpoints = try discoverEndpoints(timeout: timeout)

        return endpoints
            .map(loadDetails)
            .sorted {
                let left = $0.moduleName ?? $0.macAddress ?? $0.ipAddress
                let right = $1.moduleName ?? $1.macAddress ?? $1.ipAddress
                return left.localizedStandardCompare(right) == .orderedAscending
            }
    }

    static func setPower(_ requestedState: Bool, for bulb: WizBulb) throws -> WizBulb {
        let state = requestedState ? "true" : "false"
        let payload = Data(
            #"{"id":1,"method":"setPilot","params":{"state":\#(state)}}"#.utf8
        )

        var commandError: Error?
        do {
            let result = try requestResult(
                payload,
                host: bulb.ipAddress,
                timeout: 3.2
            )
            guard boolValue(result["success"]) ?? true else {
                throw WizNetworkError.remoteError("success was false")
            }
        } catch {
            // A lost UDP acknowledgement does not necessarily mean the command
            // failed. Query the state below before surfacing the error.
            commandError = error
        }

        do {
            var updated = try loadPilot(for: bulb)
            guard updated.isOn == requestedState else {
                throw WizNetworkError.commandNotConfirmed
            }
            updated.lastError = nil
            return updated
        } catch {
            throw commandError ?? error
        }
    }

    private static func discoverEndpoints(timeout: TimeInterval) throws -> [DiscoveredEndpoint] {
        let socketDescriptor = try makeSocket(allowsBroadcast: true)
        defer { Darwin.close(socketDescriptor) }

        var listeningAddress = sockaddr_in()
        listeningAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        listeningAddress.sin_family = sa_family_t(AF_INET)
        listeningAddress.sin_port = port.bigEndian
        listeningAddress.sin_addr = in_addr(s_addr: INADDR_ANY)

        let bindResult = withUnsafePointer(to: &listeningAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    socketDescriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bindResult == 0 else {
            throw WizNetworkError.socketFailure("listen on UDP \(port)")
        }

        let registration = Data(
            #"{"method":"registration","params":{"phoneMac":"AAAAAAAAAAAA","register":false,"phoneIp":"1.2.3.4","id":"wizremote"}}"#.utf8
        )
        let broadcastAddresses = try localBroadcastAddresses()
        let deadline = Date().addingTimeInterval(timeout)
        var nextBroadcast = Date.distantPast
        var discovered: [String: DiscoveredEndpoint] = [:]

        while Date() < deadline {
            let now = Date()
            if now >= nextBroadcast {
                for broadcastAddress in broadcastAddresses {
                    try send(
                        registration,
                        using: socketDescriptor,
                        to: broadcastAddress
                    )
                }
                nextBroadcast = now.addingTimeInterval(1)
            }

            let waitUntil = min(nextBroadcast, deadline)
            let waitMilliseconds = Int32(max(1, min(250, waitUntil.timeIntervalSinceNow * 1_000)))
            guard let response = try receive(
                using: socketDescriptor,
                timeoutMilliseconds: waitMilliseconds
            ) else {
                continue
            }

            let macAddress = responseResult(from: response.data)?["mac"] as? String
            let key = macAddress?.lowercased() ?? response.sourceIP
            discovered[key] = DiscoveredEndpoint(
                ipAddress: response.sourceIP,
                macAddress: macAddress
            )
        }

        return Array(discovered.values)
    }

    private static func loadDetails(for endpoint: DiscoveredEndpoint) -> WizBulb {
        let configPayload = Data(
            #"{"id":1,"method":"getSystemConfig","params":{}}"#.utf8
        )
        let pilotPayload = Data(
            #"{"id":1,"method":"getPilot","params":{}}"#.utf8
        )

        let config = try? requestResult(configPayload, host: endpoint.ipAddress, timeout: 2.2)
        let pilot = try? requestResult(pilotPayload, host: endpoint.ipAddress, timeout: 2.2)

        return WizBulb(
            ipAddress: endpoint.ipAddress,
            macAddress: stringValue(config?["mac"])
                ?? stringValue(pilot?["mac"])
                ?? endpoint.macAddress,
            moduleName: stringValue(config?["moduleName"]),
            firmwareVersion: stringValue(config?["fwVersion"]),
            homeID: intValue(config?["homeId"]),
            roomID: intValue(config?["roomId"]),
            groupID: intValue(config?["groupId"]),
            isOn: boolValue(pilot?["state"]),
            brightness: intValue(pilot?["dimming"]),
            temperature: intValue(pilot?["temp"]),
            sceneID: intValue(pilot?["sceneId"]),
            speed: intValue(pilot?["speed"]),
            red: intValue(pilot?["r"]),
            green: intValue(pilot?["g"]),
            blue: intValue(pilot?["b"]),
            coldWhite: intValue(pilot?["c"]),
            warmWhite: intValue(pilot?["w"]),
            rssi: intValue(pilot?["rssi"]),
            lastError: pilot == nil ? "State query did not reply." : nil
        )
    }

    private static func loadPilot(for bulb: WizBulb) throws -> WizBulb {
        let payload = Data(
            #"{"id":1,"method":"getPilot","params":{}}"#.utf8
        )
        let pilot = try requestResult(payload, host: bulb.ipAddress, timeout: 3)

        var updated = bulb
        updated.isOn = boolValue(pilot["state"])
        updated.brightness = intValue(pilot["dimming"])
        updated.temperature = intValue(pilot["temp"])
        updated.sceneID = intValue(pilot["sceneId"])
        updated.speed = intValue(pilot["speed"])
        updated.red = intValue(pilot["r"])
        updated.green = intValue(pilot["g"])
        updated.blue = intValue(pilot["b"])
        updated.coldWhite = intValue(pilot["c"])
        updated.warmWhite = intValue(pilot["w"])
        updated.rssi = intValue(pilot["rssi"])
        return updated
    }

    private static func requestResult(
        _ payload: Data,
        host: String,
        timeout: TimeInterval
    ) throws -> [String: Any] {
        guard let response = try exchange(payload, host: host, timeout: timeout) else {
            throw WizNetworkError.timedOut
        }

        let object = try JSONSerialization.jsonObject(with: response.data)
        guard let dictionary = object as? [String: Any] else {
            throw WizNetworkError.malformedResponse
        }

        if let error = dictionary["error"] as? [String: Any] {
            let message = stringValue(error["message"]) ?? String(describing: error)
            throw WizNetworkError.remoteError(message)
        }

        guard let result = dictionary["result"] as? [String: Any] else {
            throw WizNetworkError.malformedResponse
        }
        return result
    }

    private static func responseResult(from data: Data) -> [String: Any]? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any]
        else {
            return nil
        }
        return dictionary["result"] as? [String: Any]
    }

    private static func exchange(
        _ payload: Data,
        host: String,
        timeout: TimeInterval
    ) throws -> UDPResponse? {
        let socketDescriptor = try makeSocket(allowsBroadcast: false)
        defer { Darwin.close(socketDescriptor) }

        let address = try socketAddress(for: host)
        let deadline = Date().addingTimeInterval(timeout)
        let retryWaits: [TimeInterval] = [0.35, 0.55, 0.8, 1.2]

        for retryWait in retryWaits where Date() < deadline {
            try send(payload, using: socketDescriptor, to: address)
            let attemptDeadline = min(deadline, Date().addingTimeInterval(retryWait))

            while Date() < attemptDeadline {
                let waitMilliseconds = Int32(
                    max(1, min(250, attemptDeadline.timeIntervalSinceNow * 1_000))
                )
                if let response = try receive(
                    using: socketDescriptor,
                    timeoutMilliseconds: waitMilliseconds
                ), response.sourceIP == host {
                    return response
                }
            }
        }

        while Date() < deadline {
            let waitMilliseconds = Int32(max(1, min(250, deadline.timeIntervalSinceNow * 1_000)))
            if let response = try receive(
                using: socketDescriptor,
                timeoutMilliseconds: waitMilliseconds
            ), response.sourceIP == host {
                return response
            }
        }

        return nil
    }

    private static func makeSocket(allowsBroadcast: Bool) throws -> Int32 {
        let socketDescriptor = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketDescriptor >= 0 else {
            throw WizNetworkError.socketFailure("create socket")
        }

        var enabled: Int32 = 1
        let optionSize = socklen_t(MemoryLayout<Int32>.size)
        let reuseAddressResult = withUnsafePointer(to: &enabled) {
            setsockopt(socketDescriptor, SOL_SOCKET, SO_REUSEADDR, $0, optionSize)
        }
        let reusePortResult = withUnsafePointer(to: &enabled) {
            setsockopt(socketDescriptor, SOL_SOCKET, SO_REUSEPORT, $0, optionSize)
        }

        guard reuseAddressResult == 0, reusePortResult == 0 else {
            Darwin.close(socketDescriptor)
            throw WizNetworkError.socketFailure("configure socket")
        }

        if allowsBroadcast {
            let broadcastResult = withUnsafePointer(to: &enabled) {
                setsockopt(socketDescriptor, SOL_SOCKET, SO_BROADCAST, $0, optionSize)
            }
            guard broadcastResult == 0 else {
                Darwin.close(socketDescriptor)
                throw WizNetworkError.socketFailure("enable broadcast")
            }
        }

        return socketDescriptor
    }

    private static func socketAddress(for host: String) throws -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian

        let conversionResult = host.withCString {
            inet_pton(AF_INET, $0, &address.sin_addr)
        }
        guard conversionResult == 1 else {
            throw WizNetworkError.invalidAddress(host)
        }
        return address
    }

    private static func localBroadcastAddresses() throws -> [sockaddr_in] {
        var addresses: [String: sockaddr_in] = [:]
        var interfaceList: UnsafeMutablePointer<ifaddrs>?

        if getifaddrs(&interfaceList) == 0, let firstInterface = interfaceList {
            defer { freeifaddrs(interfaceList) }
            var current: UnsafeMutablePointer<ifaddrs>? = firstInterface

            while let interface = current {
                defer { current = interface.pointee.ifa_next }

                let flags = Int32(interface.pointee.ifa_flags)
                guard
                    flags & IFF_UP != 0,
                    flags & IFF_BROADCAST != 0,
                    flags & IFF_LOOPBACK == 0,
                    let addressPointer = interface.pointee.ifa_addr,
                    let netmaskPointer = interface.pointee.ifa_netmask,
                    addressPointer.pointee.sa_family == sa_family_t(AF_INET)
                else {
                    continue
                }

                let address = addressPointer.withMemoryRebound(
                    to: sockaddr_in.self,
                    capacity: 1
                ) { $0.pointee }
                let netmask = netmaskPointer.withMemoryRebound(
                    to: sockaddr_in.self,
                    capacity: 1
                ) { $0.pointee }

                var broadcast = address
                broadcast.sin_port = port.bigEndian
                broadcast.sin_addr.s_addr = address.sin_addr.s_addr | ~netmask.sin_addr.s_addr

                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                let converted = withUnsafePointer(to: &broadcast.sin_addr) { pointer in
                    buffer.withUnsafeMutableBufferPointer {
                        inet_ntop(AF_INET, pointer, $0.baseAddress, socklen_t(INET_ADDRSTRLEN))
                    }
                }
                if converted != nil {
                    addresses[String(cString: buffer)] = broadcast
                }
            }
        }

        let limitedBroadcast = try socketAddress(for: "255.255.255.255")
        addresses["255.255.255.255"] = limitedBroadcast
        return Array(addresses.values)
    }

    private static func send(
        _ payload: Data,
        using socketDescriptor: Int32,
        to destination: sockaddr_in
    ) throws {
        var address = destination
        let sentByteCount = payload.withUnsafeBytes { payloadBuffer in
            withUnsafePointer(to: &address) { addressPointer in
                addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.sendto(
                        socketDescriptor,
                        payloadBuffer.baseAddress,
                        payloadBuffer.count,
                        0,
                        $0,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
        }

        guard sentByteCount == payload.count else {
            throw WizNetworkError.socketFailure("send request")
        }
    }

    private static func receive(
        using socketDescriptor: Int32,
        timeoutMilliseconds: Int32
    ) throws -> UDPResponse? {
        var pollDescriptor = pollfd(
            fd: socketDescriptor,
            events: Int16(POLLIN),
            revents: 0
        )
        let pollResult = Darwin.poll(&pollDescriptor, 1, timeoutMilliseconds)
        guard pollResult >= 0 else {
            throw WizNetworkError.socketFailure("wait for response")
        }
        guard pollResult > 0, pollDescriptor.revents & Int16(POLLIN) != 0 else {
            return nil
        }

        var sourceAddress = sockaddr_in()
        var sourceAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        var responseBuffer = [UInt8](repeating: 0, count: 65_535)
        let responseCapacity = responseBuffer.count

        let receivedByteCount = responseBuffer.withUnsafeMutableBytes { responseBytes in
            withUnsafeMutablePointer(to: &sourceAddress) { sourcePointer in
                sourcePointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.recvfrom(
                        socketDescriptor,
                        responseBytes.baseAddress,
                        responseCapacity,
                        0,
                        $0,
                        &sourceAddressLength
                    )
                }
            }
        }
        guard receivedByteCount > 0 else {
            throw WizNetworkError.socketFailure("receive response")
        }

        var sourceIPBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        let sourceIP = withUnsafePointer(to: &sourceAddress.sin_addr) { pointer in
            sourceIPBuffer.withUnsafeMutableBufferPointer { buffer in
                inet_ntop(
                    AF_INET,
                    pointer,
                    buffer.baseAddress,
                    socklen_t(INET_ADDRSTRLEN)
                )
            }
        }
        guard sourceIP != nil else {
            throw WizNetworkError.socketFailure("read response address")
        }

        return UDPResponse(
            data: Data(responseBuffer.prefix(receivedByteCount)),
            sourceIP: String(cString: sourceIPBuffer)
        )
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String, !string.isEmpty {
            return string
        }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let boolean = value as? Bool {
            return boolean
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        return nil
    }
}

@MainActor
final class BulbService: ObservableObject {
    @Published private(set) var bulbs: [WizBulb] = []
    @Published private(set) var isScanning = false
    @Published private(set) var pendingBulbIDs: Set<String> = []
    @Published private(set) var statusMessage = "Ready to find your WiZ lights."

    init(autoConnect: Bool = false) {
        guard autoConnect else { return }

        Task { @MainActor [weak self] in
            await Task.yield()
            self?.connectBulbs()
        }
    }

    func connectBulbs() {
        guard !isScanning else { return }

        isScanning = true
        statusMessage = "Looking for all WiZ lights on this LAN…"

        Task {
            defer { isScanning = false }

            do {
                let discoveredBulbs = try await Task.detached(priority: .userInitiated) {
                    try WizUDPClient.discover()
                }.value

                bulbs = discoveredBulbs
                switch discoveredBulbs.count {
                case 0:
                    statusMessage = "No WiZ lights replied. Check Local Network access and router isolation."
                case 1:
                    statusMessage = "Found 1 WiZ light."
                default:
                    statusMessage = "Found \(discoveredBulbs.count) WiZ lights."
                }
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    func setPower(for bulbID: String, to requestedState: Bool) {
        guard
            !pendingBulbIDs.contains(bulbID),
            let bulb = bulbs.first(where: { $0.id == bulbID })
        else {
            return
        }

        pendingBulbIDs.insert(bulbID)
        statusMessage = requestedState
            ? "Turning on \(bulb.ipAddress)…"
            : "Turning off \(bulb.ipAddress)…"

        Task {
            defer { pendingBulbIDs.remove(bulbID) }

            do {
                let updatedBulb = try await Task.detached(priority: .userInitiated) {
                    try WizUDPClient.setPower(requestedState, for: bulb)
                }.value

                guard let index = bulbs.firstIndex(where: { $0.id == bulbID }) else { return }
                bulbs[index] = updatedBulb
                statusMessage = requestedState
                    ? "Confirmed: \(bulb.ipAddress) is on."
                    : "Confirmed: \(bulb.ipAddress) is off."
            } catch {
                if let index = bulbs.firstIndex(where: { $0.id == bulbID }) {
                    bulbs[index].lastError = error.localizedDescription
                }
                statusMessage = "\(bulb.ipAddress): \(error.localizedDescription)"
            }
        }
    }
}
