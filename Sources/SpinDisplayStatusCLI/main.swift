import Darwin
import Foundation
import SpinDisplayCore

@main
enum SpinDisplayStatusCLI {
    static func main() {
        do {
            let options = try parseArguments(Array(CommandLine.arguments.dropFirst()))
            try poll(address: options.address, duration: options.duration)
        } catch {
            fputs("SpinDisplayStatusCLI: \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    private static func parseArguments(_ arguments: [String]) throws -> (address: String, duration: TimeInterval) {
        guard let address = arguments.first else {
            throw CLIError.usage
        }
        guard arguments.count == 1 || arguments.count == 3,
              arguments.count == 1 || arguments[1] == "--duration" else {
            throw CLIError.usage
        }

        let duration: TimeInterval
        if arguments.count == 3 {
            guard let seconds = Double(arguments[2]), seconds > 0 else {
                throw CLIError.invalidDuration
            }
            duration = seconds
        } else {
            duration = 30
        }
        return (address, duration)
    }

    private static func poll(address: String, duration: TimeInterval) throws {
        let descriptor = try connectWithRetries(address: address)
        defer {
            _ = shutdown(descriptor, SHUT_RDWR)
            _ = close(descriptor)
        }

        print("Connected to \(address):50110; polling read-only status for \(Int(duration)) seconds.")
        try send(SpinDisplayProtocol.heartbeatRequest(), on: descriptor)
        try send(SpinDisplayProtocol.frame(command: SpinDisplayProtocol.parameterCommand), on: descriptor)
        try send(SpinDisplayProtocol.playbackStatusRequest(), on: descriptor)

        var buffer: [UInt8] = []
        let start = Date()
        var nextHeartbeat = start.addingTimeInterval(2)
        var nextPlaybackQuery = start.addingTimeInterval(1)
        var nextParameterQuery = start.addingTimeInterval(5)

        while Date().timeIntervalSince(start) < duration {
            let now = Date()
            if now >= nextHeartbeat {
                try send(SpinDisplayProtocol.heartbeatRequest(), on: descriptor)
                nextHeartbeat = now.addingTimeInterval(2)
            }
            if now >= nextPlaybackQuery {
                try send(SpinDisplayProtocol.playbackStatusRequest(), on: descriptor)
                nextPlaybackQuery = now.addingTimeInterval(1)
            }
            if now >= nextParameterQuery {
                try send(SpinDisplayProtocol.frame(command: SpinDisplayProtocol.parameterCommand), on: descriptor)
                nextParameterQuery = now.addingTimeInterval(5)
            }

            var incoming = [UInt8](repeating: 0, count: 4096)
            let count = recv(descriptor, &incoming, incoming.count, 0)
            if count > 0 {
                buffer.append(contentsOf: incoming.prefix(count))
                while let frame = takeFrame(from: &buffer) {
                    report(frame)
                }
            } else if count == 0 {
                throw CLIError.connectionClosed
            } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                throw CLIError.socketOperation("TCP receive failed", errno)
            }
        }
    }

    private static func connectWithRetries(address: String) throws -> Int32 {
        for attempt in 1...5 {
            do {
                return try connect(address: address)
            } catch {
                guard attempt < 5, isRetryableConnectionError(error) else { throw error }
                fputs("Connection attempt \(attempt)/5 failed: \(error.localizedDescription). Retrying in 0.25 seconds.\n", stderr)
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        throw CLIError.handshakeTimedOut
    }

    private static func isRetryableConnectionError(_ error: Error) -> Bool {
        guard let error = error as? CLIError else { return false }
        switch error {
        case .connectionClosed, .handshakeTimedOut:
            return true
        case .socketOperation(_, let code):
            return [ECONNRESET, ECONNREFUSED, ETIMEDOUT, EPIPE, EHOSTUNREACH, ENETUNREACH].contains(code)
        default:
            return false
        }
    }

    private static func connect(address: String) throws -> Int32 {
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = in_port_t(50110).bigEndian
        let conversion = address.withCString { inet_pton(AF_INET, $0, &destination.sin_addr) }
        guard conversion == 1 else { throw CLIError.invalidAddress(address) }

        let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { throw CLIError.socketOperation("Could not create TCP socket", errno) }

        var noSignal: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            let code = errno
            close(descriptor)
            throw CLIError.socketOperation("Could not configure TCP socket", code)
        }

        if var localAddress = localAddress(for: destination.sin_addr) {
            let bindResult = withUnsafePointer(to: &localAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult == 0 else {
                let code = errno
                close(descriptor)
                throw CLIError.socketOperation("Could not bind to the fan's local network interface", code)
            }
        }

        let connectResult = withUnsafePointer(to: &destination) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else {
            let code = errno
            close(descriptor)
            throw CLIError.socketOperation("Could not connect to \(address):50110", code)
        }

        var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else {
            let code = errno
            close(descriptor)
            throw CLIError.socketOperation("Could not configure receive timeout", code)
        }

        do {
            try performHandshake(on: descriptor)
        } catch {
            close(descriptor)
            throw error
        }
        return descriptor
    }

    private static func localAddress(for destination: in_addr) -> sockaddr_in? {
        var firstInterface: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstInterface) == 0, let firstInterface else { return nil }
        defer { freeifaddrs(firstInterface) }

        var current: UnsafeMutablePointer<ifaddrs>? = firstInterface
        while let interface = current {
            defer { current = interface.pointee.ifa_next }
            guard interface.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  interface.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let address = interface.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  let netmask = interface.pointee.ifa_netmask else {
                continue
            }

            let local = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            let mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                $0.pointee.sin_addr.s_addr
            }
            guard (local.sin_addr.s_addr & mask) == (destination.s_addr & mask) else { continue }

            var result = sockaddr_in()
            result.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            result.sin_family = sa_family_t(AF_INET)
            result.sin_addr = local.sin_addr
            return result
        }
        return nil
    }

    private static func performHandshake(on descriptor: Int32) throws {
        var buffer: [UInt8] = []
        let deadline = Date().addingTimeInterval(10)
        var nextRequest = Date.distantPast

        while Date() < deadline {
            if Date() >= nextRequest {
                try send(
                    SpinDisplayProtocol.frame(command: SpinDisplayProtocol.connectCommand, payload: [1]),
                    on: descriptor
                )
                nextRequest = Date().addingTimeInterval(0.2)
            }

            var incoming = [UInt8](repeating: 0, count: 4096)
            let count = recv(descriptor, &incoming, incoming.count, 0)
            if count > 0 {
                buffer.append(contentsOf: incoming.prefix(count))
                while let frame = takeFrame(from: &buffer) {
                    guard frame.count >= 6 else { continue }
                    if frame[1] == SpinDisplayProtocol.connectCommand { return }
                    print("Handshake response: command 0x\(String(format: "%02X", frame[1])), \(frame.count) bytes")
                }
            } else if count == 0 {
                throw CLIError.connectionClosed
            } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                throw CLIError.socketOperation("TCP handshake receive failed", errno)
            }
        }
        throw CLIError.handshakeTimedOut
    }

    private static func send(_ packet: [UInt8], on descriptor: Int32) throws {
        var sent = 0
        while sent < packet.count {
            let count = packet.withUnsafeBytes { bytes in
                Darwin.send(descriptor, bytes.baseAddress?.advanced(by: sent), packet.count - sent, 0)
            }
            guard count > 0 else {
                throw CLIError.socketOperation("TCP send failed", errno)
            }
            sent += count
        }
    }

    private static func takeFrame(from buffer: inout [UInt8]) -> [UInt8]? {
        while let headerIndex = buffer.firstIndex(of: SpinDisplayProtocol.header), headerIndex > 0 {
            buffer.removeFirst(headerIndex)
        }
        guard let length = SpinDisplayProtocol.frameLength(in: buffer) else {
            if buffer.count > 3 { buffer.removeFirst(buffer.count - 3) }
            return nil
        }
        guard buffer.count >= length else { return nil }
        let frame = Array(buffer.prefix(length))
        buffer.removeFirst(length)
        return frame
    }

    private static func report(_ frame: [UInt8]) {
        guard frame.count >= 6 else { return }
        let command = frame[1]
        let commandText = String(format: "0x%02X", command)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        switch command {
        case SpinDisplayProtocol.parameterCommand:
            if let status = SpinDisplayProtocol.parseDeviceStatus(frame) {
                print("\(timestamp) command \(commandText), \(frame.count) bytes: power=\(status.isOn ? "on" : "off"), brightness=\(status.brightness)")
            } else {
                print("\(timestamp) command \(commandText), \(frame.count) bytes: incomplete device parameters")
            }
        case SpinDisplayProtocol.playControlCommand:
            if let status = SpinDisplayProtocol.parsePlaybackStatus(frame) {
                print("\(timestamp) command \(commandText), \(frame.count) bytes: responseField=\(status.responseField), playlistSlot=\(status.playlistSlot)")
            } else {
                print("\(timestamp) command \(commandText), \(frame.count) bytes: incomplete playback response")
            }
        default:
            print("\(timestamp) command \(commandText), \(frame.count) bytes")
        }
    }

    private enum CLIError: LocalizedError {
        case usage
        case invalidDuration
        case invalidAddress(String)
        case socketOperation(String, Int32)
        case connectionClosed
        case handshakeTimedOut

        var errorDescription: String? {
            switch self {
            case .usage:
                return "Usage: swift run SpinDisplayStatusCLI <fan-ipv4> [--duration seconds]"
            case .invalidDuration:
                return "Duration must be a positive number of seconds."
            case .invalidAddress(let address):
                return "Invalid IPv4 address: \(address)"
            case .socketOperation(let operation, let code):
                return "\(operation): \(String(cString: strerror(code)))"
            case .connectionClosed:
                return "The device closed the TCP connection."
            case .handshakeTimedOut:
                return "The device did not complete its TCP handshake within 10 seconds."
            }
        }
    }
}
