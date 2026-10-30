import Darwin
import Foundation
import SpinDisplayCore

final class DeviceScanner {
    var onDevice: ((FanDevice) -> Void)?
    var onAuthenticationResult: ((String, Bool) -> Void)?
    var onStatus: ((String) -> Void)?

    private let stateLock = NSLock()
    private var running = false
    private var socketDescriptor: Int32 = -1
    private var challenge: UInt32 = UInt32.random(in: 0...UInt32(Int32.max))

    func start() {
        stateLock.lock()
        guard !running else {
            stateLock.unlock()
            return
        }
        running = true
        challenge = UInt32.random(in: 0...UInt32(Int32.max))
        stateLock.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.scanLoop()
        }
    }

    func stop() {
        stateLock.lock()
        running = false
        stateLock.unlock()
    }

    func authenticate(device: FanDevice, password: String) {
        stateLock.lock()
        let descriptor = socketDescriptor
        stateLock.unlock()

        guard descriptor >= 0 else {
            onStatus?("Discovery socket is not available. Start scanning and try again.")
            return
        }
        let address = in_addr(s_addr: inet_addr(device.address))
        guard address.s_addr != in_addr_t(INADDR_NONE) else {
            onStatus?("The device has an invalid IPv4 address.")
            return
        }

        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = in_port_t(50100).bigEndian
        destination.sin_addr = address

        let packet = SpinDisplayProtocol.passwordRequest(password: password, challenge: device.challenge)
        let sent = packet.withUnsafeBytes { bytes in
            withUnsafePointer(to: &destination) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    sendto(
                        descriptor,
                        bytes.baseAddress,
                        packet.count,
                        0,
                        socketAddress,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
        }
        if sent != packet.count {
            onStatus?("Could not send the device password check: \(String(cString: strerror(errno))).")
        } else {
            onStatus?("Checking the device password…")
        }
    }

    private func scanLoop() {
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else {
            finish(with: "Could not create the discovery socket: \(String(cString: strerror(errno))).")
            return
        }

        var reuse: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var broadcast: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_BROADCAST, &broadcast, socklen_t(MemoryLayout<Int32>.size))

        var localAddress = sockaddr_in()
        localAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        localAddress.sin_family = sa_family_t(AF_INET)
        localAddress.sin_port = in_port_t(50105).bigEndian
        localAddress.sin_addr = in_addr(s_addr: in_addr_t(INADDR_ANY))

        let bindResult = withUnsafePointer(to: &localAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let message = "Could not listen on UDP port 50105: \(String(cString: strerror(errno)))."
            close(descriptor)
            finish(with: message)
            return
        }

        stateLock.lock()
        socketDescriptor = descriptor
        stateLock.unlock()
        onStatus?("Scanning the local network for SpinDisplay devices…")

        var nextBroadcast = Date.distantPast
        var buffer = [UInt8](repeating: 0, count: 2048)
        var sentProbeCount = 0
        var responseCount = 0
        var waitingStatusReported = false
        var previousDestinations: [String] = []
        while isRunning {
            if Date() >= nextBroadcast {
                let broadcasts = broadcastAddresses()
                let destinations = broadcasts.map { addressString($0.sin_addr) }
                if destinations != previousDestinations {
                    if destinations.isEmpty {
                        onStatus?("No active IPv4 broadcast interfaces were found.")
                    } else {
                        onStatus?("Scanning via \(destinations.joined(separator: ", ")) on UDP 50100…")
                    }
                    previousDestinations = destinations
                }

                let request = SpinDisplayProtocol.discoveryRequest(challenge: currentChallenge)
                for address in broadcasts {
                    var destination = address
                    destination.sin_port = in_port_t(50100).bigEndian
                    let sent = request.withUnsafeBytes { bytes in
                        withUnsafePointer(to: &destination) { pointer in
                            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                                sendto(
                                    descriptor,
                                    bytes.baseAddress,
                                    request.count,
                                    0,
                                    $0,
                                    socklen_t(MemoryLayout<sockaddr_in>.size)
                                )
                            }
                        }
                    }
                    if sent == request.count {
                        sentProbeCount += 1
                    } else {
                        onStatus?("Could not send discovery probe to \(addressString(destination.sin_addr)): \(String(cString: strerror(errno))).")
                    }
                }
                if !destinations.isEmpty && sentProbeCount > 0 && responseCount == 0 && !waitingStatusReported {
                    onStatus?("Sent \(sentProbeCount) discovery probes via \(destinations.joined(separator: ", ")); waiting for fan replies…")
                    waitingStatusReported = true
                }
                nextBroadcast = Date().addingTimeInterval(2)
            }

            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&pollDescriptor, 1, 250) >= 0 else {
                if errno == EINTR { continue }
                finish(with: "Network discovery failed: \(String(cString: strerror(errno))).")
                return
            }
            guard pollDescriptor.revents & Int16(POLLIN) != 0 else { continue }

            var source = sockaddr_in()
            var sourceLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let received = buffer.withUnsafeMutableBytes { bytes in
                withUnsafeMutablePointer(to: &source) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(descriptor, bytes.baseAddress, bytes.count, 0, $0, &sourceLength)
                    }
                }
            }
            guard received >= 0 else {
                if errno == EINTR { continue }
                finish(with: "Could not receive discovery responses: \(String(cString: strerror(errno))).")
                return
            }
            let response = Array(buffer.prefix(received))
            let sourceIP = withUnsafePointer(to: &source.sin_addr) {
                String(cString: inet_ntoa($0.pointee))
            }
            responseCount += 1

            if let device = SpinDisplayProtocol.parseDeviceResponse(
                response,
                sourceAddress: sourceIP,
                challenge: currentChallenge
            ) {
                onDevice?(device)
                onStatus?("Found a SpinDisplay device at \(device.address).")
            } else if response.count >= 5,
                      response[0] == SpinDisplayProtocol.header,
                      response[1] == SpinDisplayProtocol.passwordCommand {
                onAuthenticationResult?(sourceIP, response[4] == 0)
            } else {
                let command = response.count > 1 ? String(format: "%02X", response[1]) : "unknown"
                onStatus?("Received \(response.count) bytes from \(sourceIP), but it was not a recognized device reply (command \(command)).")
            }
        }

        close(descriptor)
        stateLock.lock()
        socketDescriptor = -1
        stateLock.unlock()
        onStatus?("Discovery stopped.")
    }

    private var currentChallenge: UInt32 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return challenge
    }

    private var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    private func finish(with message: String) {
        stateLock.lock()
        running = false
        let descriptor = socketDescriptor
        socketDescriptor = -1
        stateLock.unlock()
        if descriptor >= 0 {
            close(descriptor)
        }
        onStatus?(message)
    }

    private func broadcastAddresses() -> [sockaddr_in] {
        var firstInterface: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstInterface) == 0, let firstInterface else { return [] }
        defer { freeifaddrs(firstInterface) }

        var result: [sockaddr_in] = []
        var current: UnsafeMutablePointer<ifaddrs>? = firstInterface
        while let interface = current {
            defer { current = interface.pointee.ifa_next }
            guard let address = interface.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  interface.pointee.ifa_flags & UInt32(IFF_UP | IFF_BROADCAST) != 0,
                  interface.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let broadcastAddress = interface.pointee.ifa_dstaddr else {
                continue
            }
            var destination = broadcastAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                $0.pointee
            }
            destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            result.append(destination)
        }
        return result
    }

    private func addressString(_ address: in_addr) -> String {
        var address = address
        return withUnsafePointer(to: &address) {
            String(cString: inet_ntoa($0.pointee))
        }
    }
}
