import Darwin
import Foundation
import SpinDisplayCore

final class DeviceConnection {
    var onMessage: ((String) -> Void)?
    var onPowerChanged: ((Bool) -> Void)?
    var onBrightnessChanged: ((UInt8) -> Void)?
    var onPlaylistChanged: (([FanFile]) -> Void)?
    var onPlaybackStatusChanged: ((PlaybackStatusResponse) -> Void)?
    var onDeviceInfoChanged: ((FanDeviceInfo) -> Void)?
    var onVersionChanged: ((FanVersionInfo) -> Void)?
    var onSettingAcknowledged: ((UInt8, UInt8) -> Void)?
    var onDisconnected: ((String) -> Void)?

    let id = UUID()
    private let stateLock = NSLock()
    private let writeLock = NSLock()
    private let playlistLock = NSLock()
    private let uploadCondition = NSCondition()
    private var socketDescriptor: Int32
    private let address: String
    private var closed = false
    private var playlistPayload: [UInt8] = []
    private var uploadWaitStage: UploadWaitStage?
    private var uploadResponse: UInt8?
    private var uploadSocket: Int32?

    private init(socketDescriptor: Int32, address: String) {
        self.socketDescriptor = socketDescriptor
        self.address = address
    }

    static func connect(
        to address: String,
        completion: @escaping (Result<DeviceConnection, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            for attempt in 1...5 {
                do {
                    let connection = try Self.openAndHandshake(address: address)
                    completion(.success(connection))
                    return
                } catch {
                    guard attempt < 5, Self.isRetryableConnectionError(error) else {
                        completion(.failure(error))
                        return
                    }
                    Thread.sleep(forTimeInterval: 0.25)
                }
            }
        }
    }

    private static func isRetryableConnectionError(_ error: Error) -> Bool {
        guard let error = error as? ConnectionError else { return false }
        switch error {
        case .closedDuringHandshake, .handshakeTimedOut:
            return true
        case .systemCall(_, let code):
            return [ECONNRESET, ECONNREFUSED, ETIMEDOUT, EPIPE, EHOSTUNREACH, ENETUNREACH].contains(code)
        default:
            return false
        }
    }

    func disconnect() {
        stateLock.lock()
        guard !closed else {
            stateLock.unlock()
            return
        }
        closed = true
        let descriptor = socketDescriptor
        socketDescriptor = -1
        stateLock.unlock()
        cancelPendingUpload()
        _ = shutdown(descriptor, SHUT_RDWR)
        _ = close(descriptor)
    }

    func configureWiFi(ssid: String, password: String) throws {
        guard let packet = SpinDisplayProtocol.wifiConfigurationRequest(ssid: ssid, password: password) else {
            throw ConnectionError.invalidWiFiCredentials
        }
        try sendPacket(packet)
    }

    func setPower(isOn: Bool) throws {
        try sendPacket(SpinDisplayProtocol.powerRequest(isOn: isOn))
    }

    func setBrightness(level: UInt8) throws {
        try sendPacket(SpinDisplayProtocol.brightnessRequest(level: level))
    }

    func refreshPlaylist() throws {
        playlistLock.lock()
        playlistPayload.removeAll(keepingCapacity: true)
        playlistLock.unlock()
        try sendPacket(SpinDisplayProtocol.playlistRequest())
    }

    func playFile(at index: Int) throws {
        guard (0..<Int(UInt8.max)).contains(index) else { throw ConnectionError.invalidPlaylistIndex }
        try sendPacket(SpinDisplayProtocol.playControlRequest(control: 1, index: UInt8(index + 1)))
    }

    func repeatFile(at index: Int) throws {
        guard (0..<Int(UInt8.max)).contains(index) else { throw ConnectionError.invalidPlaylistIndex }
        try sendPackets(SpinDisplayProtocol.repeatFileRequests(index: UInt8(index + 1)))
    }

    func uploadFTLV(
        at url: URL,
        deviceType: UInt8,
        progress: @escaping (Double, String) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                try performFTLVUpload(at: url, deviceType: deviceType, progress: progress)
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func deleteFile(at index: Int) throws {
        guard let packet = SpinDisplayProtocol.deleteFileRequest(index: index) else {
            throw ConnectionError.invalidPlaylistIndex
        }
        try sendPacket(packet)
    }

    func moveFile(from source: Int, to destination: Int) throws {
        guard let packet = SpinDisplayProtocol.moveFileRequest(from: source, to: destination) else {
            throw ConnectionError.invalidPlaylistIndex
        }
        try sendPacket(packet)
    }

    func setDeviceName(_ name: String) throws {
        guard let packet = SpinDisplayProtocol.deviceNameRequest(name) else {
            throw ConnectionError.invalidDeviceName
        }
        try sendPacket(packet)
    }

    func setFanAngle(degrees: Int) throws {
        guard let packet = SpinDisplayProtocol.angleRequest(degrees: degrees) else {
            throw ConnectionError.invalidAngle
        }
        try sendPacket(packet)
    }

    func setPowerSchedule(
        autoOn: Bool,
        shutdownEnabled: Bool,
        bootEnabled: Bool,
        shutdownHour: UInt8,
        shutdownMinute: UInt8,
        bootHour: UInt8,
        bootMinute: UInt8
    ) throws {
        guard let packet = SpinDisplayProtocol.scheduleRequest(
            autoOn: autoOn,
            shutdownEnabled: shutdownEnabled,
            bootEnabled: bootEnabled,
            shutdownHour: shutdownHour,
            shutdownMinute: shutdownMinute,
            bootHour: bootHour,
            bootMinute: bootMinute
        ) else {
            throw ConnectionError.invalidSchedule
        }
        try sendPacket(packet)
    }

    func syncClock() throws {
        try sendPacket(SpinDisplayProtocol.clockSyncRequest())
    }

    func setBluetoothEnabled(_ isEnabled: Bool) throws {
        try sendPacket(SpinDisplayProtocol.bleVolumeRequest(control: isEnabled ? 1 : 0))
    }

    func searchForBluetoothSpeaker() throws {
        try sendPacket(SpinDisplayProtocol.bleVolumeRequest(control: 2))
    }

    func setBluetoothVolume(_ volume: UInt8) throws {
        try sendPacket(SpinDisplayProtocol.bleVolumeRequest(control: 3, volume: volume))
    }

    func setDisplayMode(_ mode: FanDisplayMode) throws {
        try sendPacket(SpinDisplayProtocol.displayModeRequest(mode))
    }

    func setThirdPartyControl(_ isEnabled: Bool) throws {
        try sendPacket(SpinDisplayProtocol.thirdPartyControlRequest(isEnabled: isEnabled))
    }

    func setLoginVerification(isEnabled: Bool, password: String) throws {
        guard let packet = SpinDisplayProtocol.loginVerificationRequest(isEnabled: isEnabled, password: password) else {
            throw ConnectionError.invalidLoginPassword
        }
        try sendPacket(packet)
    }

    func changeFile(
        at index: Int,
        name: String,
        repeatCount: UInt8,
        displayMode: FileDisplayMode,
        timeSlots: [PlaybackTimeSlot]
    ) throws {
        guard let packet = SpinDisplayProtocol.changeFileRequest(
            index: index,
            name: name,
            repeatCount: repeatCount,
            displayMode: displayMode,
            timeSlots: timeSlots
        ) else {
            throw ConnectionError.invalidFileEdit
        }
        try sendPacket(packet)
    }

    func deleteAllFiles() throws {
        try sendPacket(SpinDisplayProtocol.deleteAllFilesRequest())
    }

    func refreshDeviceInfo() throws {
        try sendPacket(SpinDisplayProtocol.frame(command: SpinDisplayProtocol.parameterCommand))
    }

    deinit {
        disconnect()
    }

    private static func openAndHandshake(address: String) throws -> DeviceConnection {
        let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else {
            throw ConnectionError.systemCall("Could not create the TCP socket", errno)
        }

        var noSignal: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            let code = errno
            close(descriptor)
            throw ConnectionError.systemCall("Could not configure the TCP socket", code)
        }

        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = in_port_t(50110).bigEndian
        let conversion = address.withCString { inet_pton(AF_INET, $0, &destination.sin_addr) }
        guard conversion == 1 else {
            close(descriptor)
            throw ConnectionError.invalidAddress(address)
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
                throw ConnectionError.systemCall("Could not bind to the fan's local Wi-Fi interface", code)
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
            throw ConnectionError.systemCall("Could not connect to \(address):50110", code)
        }

        var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var buffer: [UInt8] = []
        let deadline = Date().addingTimeInterval(10)
        var nextHandshake = Date.distantPast
        var connected = false
        while Date() < deadline {
            if Date() >= nextHandshake {
                do {
                    try sendPacket(
                        SpinDisplayProtocol.frame(command: SpinDisplayProtocol.connectCommand, payload: [1]),
                        on: descriptor
                    )
                } catch {
                    close(descriptor)
                    throw error
                }
                nextHandshake = Date().addingTimeInterval(0.2)
            }

            var incoming = [UInt8](repeating: 0, count: 4096)
            let count = recv(descriptor, &incoming, incoming.count, 0)
            if count > 0 {
                buffer.append(contentsOf: incoming.prefix(count))
                while let frame = takeFrame(from: &buffer) {
                    if frame[1] == SpinDisplayProtocol.connectCommand {
                        connected = true
                        break
                    }
                }
                if connected { break }
            } else if count == 0 {
                close(descriptor)
                throw ConnectionError.closedDuringHandshake
            } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                let code = errno
                close(descriptor)
                throw ConnectionError.systemCall("Could not read the TCP handshake", code)
            }
        }

        guard connected else {
            close(descriptor)
            throw ConnectionError.handshakeTimedOut
        }

        let connection = DeviceConnection(socketDescriptor: descriptor, address: address)
        try sendPacket(SpinDisplayProtocol.heartbeatRequest(), on: descriptor)
        try sendPacket(
            SpinDisplayProtocol.frame(command: SpinDisplayProtocol.versionCommand),
            on: descriptor
        )
        try sendPacket(
            SpinDisplayProtocol.frame(command: SpinDisplayProtocol.parameterCommand),
            on: descriptor
        )
        try sendPacket(SpinDisplayProtocol.playlistRequest(), on: descriptor)
        return connection
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
            let mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            guard (local.sin_addr.s_addr & mask) == (destination.s_addr & mask) else { continue }

            var result = sockaddr_in()
            result.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            result.sin_family = sa_family_t(AF_INET)
            result.sin_addr = local.sin_addr
            return result
        }
        return nil
    }

    func startReceiving() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.receiveLoop()
        }
    }

    private func receiveLoop() {
        var buffer: [UInt8] = []
        var nextHeartbeat = Date().addingTimeInterval(2)
        var nextPlaybackStatusQuery = Date().addingTimeInterval(1)
        var nextDeviceStatusQuery = Date().addingTimeInterval(5)
        while true {
            stateLock.lock()
            let descriptor = socketDescriptor
            let shouldStop = closed
            stateLock.unlock()
            guard !shouldStop, descriptor >= 0 else { return }

            if Date() >= nextHeartbeat {
                do {
                    try sendPacket(SpinDisplayProtocol.heartbeatRequest())
                    nextHeartbeat = Date().addingTimeInterval(2)
                } catch {
                    terminate(message: "Could not keep the TCP connection alive: \(error.localizedDescription)")
                    return
                }
            }

            if Date() >= nextPlaybackStatusQuery {
                do {
                    try sendPacket(SpinDisplayProtocol.playbackStatusRequest())
                    nextPlaybackStatusQuery = Date().addingTimeInterval(1)
                } catch {
                    terminate(message: "Could not query playback status: \(error.localizedDescription)")
                    return
                }
            }

            if Date() >= nextDeviceStatusQuery {
                do {
                    try sendPacket(SpinDisplayProtocol.frame(command: SpinDisplayProtocol.parameterCommand))
                    nextDeviceStatusQuery = Date().addingTimeInterval(5)
                } catch {
                    terminate(message: "Could not refresh device status: \(error.localizedDescription)")
                    return
                }
            }

            var incoming = [UInt8](repeating: 0, count: 4096)
            let count = recv(descriptor, &incoming, incoming.count, 0)
            if count > 0 {
                buffer.append(contentsOf: incoming.prefix(count))
                while let frame = Self.takeFrame(from: &buffer) {
                    handle(frame)
                }
            } else if count == 0 {
                terminate(message: "The device closed the TCP connection.")
                return
            } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                terminate(message: "TCP receive failed: \(String(cString: strerror(errno))).")
                return
            }
        }
    }

    private func terminate(message: String) {
        stateLock.lock()
        guard !closed else {
            stateLock.unlock()
            return
        }
        closed = true
        let descriptor = socketDescriptor
        socketDescriptor = -1
        stateLock.unlock()

        cancelPendingUpload()
        _ = shutdown(descriptor, SHUT_RDWR)
        _ = close(descriptor)
        onDisconnected?(message)
    }

    private func handle(_ frame: [UInt8]) {
        guard frame.count >= 6 else { return }
        switch frame[1] {
        case SpinDisplayProtocol.fileSendCommand:
            guard let status = SpinDisplayProtocol.parseFileSendStatus(frame) else {
                onMessage?("Received an invalid file-transfer response.")
                return
            }
            uploadCondition.lock()
            let isUploading = uploadWaitStage != nil
            if isUploading {
                uploadResponse = status
                uploadCondition.signal()
            }
            uploadCondition.unlock()
            if !isUploading {
                onMessage?("Received an unsolicited file-transfer status \(status).")
            }
        case SpinDisplayProtocol.powerCommand where frame.count >= 7:
            let isOn = frame[4] != 0
            onPowerChanged?(isOn)
            onMessage?("Fan power is \(isOn ? "on" : "off").")
        case SpinDisplayProtocol.brightnessCommand where frame.count >= 7:
            onBrightnessChanged?(frame[4])
            onMessage?("Fan brightness level: \(frame[4]).")
        case SpinDisplayProtocol.parameterCommand:
            guard let info = SpinDisplayProtocol.parseDeviceInfo(frame) else {
                onMessage?("Received device parameters, but the response was incomplete.")
                return
            }
            onPowerChanged?(info.isOn)
            onBrightnessChanged?(info.brightness)
            onDeviceInfoChanged?(info)
        case SpinDisplayProtocol.versionCommand:
            if let version = SpinDisplayProtocol.parseVersion(frame) {
                onVersionChanged?(version)
            }
        case SpinDisplayProtocol.displayModeCommand,
             SpinDisplayProtocol.thirdPartyControlCommand,
             SpinDisplayProtocol.loginVerificationCommand,
             SpinDisplayProtocol.changeFileCommand,
             SpinDisplayProtocol.deleteFileCommand:
            if let status = SpinDisplayProtocol.parseSettingStatus(frame, command: frame[1]) {
                onSettingAcknowledged?(frame[1], status)
            }
        case SpinDisplayProtocol.playlistCommand where frame.count >= 8:
            receivePlaylistChunk(frame)
        case SpinDisplayProtocol.playControlCommand:
            if let status = SpinDisplayProtocol.parsePlaybackStatus(frame) {
                onPlaybackStatusChanged?(status)
                onMessage?("Playback response: field \(status.responseField), playlist slot \(status.playlistSlot).")
            }
        default:
            onMessage?("Received device response 0x\(String(format: "%02X", frame[1])).")
        }
    }

    private func receivePlaylistChunk(_ frame: [UInt8]) {
        let chunkCount = Int(frame[4])
        let chunkIndex = Int(frame[5])
        guard chunkCount > 0, chunkIndex < chunkCount else {
            onMessage?("Received an invalid playlist chunk.")
            return
        }
        playlistLock.lock()
        if chunkIndex == 0 { playlistPayload.removeAll(keepingCapacity: true) }
        playlistPayload.append(contentsOf: frame[6..<(frame.count - 2)])
        guard chunkIndex + 1 == chunkCount else {
            playlistLock.unlock()
            return
        }

        let payload = playlistPayload
        playlistPayload.removeAll(keepingCapacity: true)
        playlistLock.unlock()
        let files = SpinDisplayProtocol.parsePlaylistRecords(payload)
        onPlaylistChanged?(files)
        onMessage?("Playlist loaded: \(files.count) file(s).")
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

    private static func sendPacket(_ packet: [UInt8], on descriptor: Int32) throws {
        var sent = 0
        while sent < packet.count {
            let count = packet.withUnsafeBytes { bytes in
                Darwin.send(descriptor, bytes.baseAddress?.advanced(by: sent), packet.count - sent, 0)
            }
            guard count > 0 else {
                throw ConnectionError.systemCall("Could not send a device command", errno)
            }
            sent += count
        }
    }

    private func sendPacket(_ packet: [UInt8]) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        stateLock.lock()
        let descriptor = socketDescriptor
        let shouldStop = closed
        stateLock.unlock()
        guard !shouldStop, descriptor >= 0 else { throw ConnectionError.disconnected }
        do {
            try Self.sendPacket(packet, on: descriptor)
        } catch {
            terminate(message: "TCP send failed: \(error.localizedDescription)")
            throw error
        }
    }

    private func sendPackets(_ packets: [[UInt8]]) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        stateLock.lock()
        let descriptor = socketDescriptor
        let shouldStop = closed
        stateLock.unlock()
        guard !shouldStop, descriptor >= 0 else { throw ConnectionError.disconnected }
        do {
            for packet in packets {
                try Self.sendPacket(packet, on: descriptor)
            }
        } catch {
            terminate(message: "TCP send failed: \(error.localizedDescription)")
            throw error
        }
    }

    private func performFTLVUpload(
        at url: URL,
        deviceType: UInt8,
        progress: @escaping (Double, String) -> Void
    ) throws {
        guard url.pathExtension.lowercased() == "ftlv" else {
            throw ConnectionError.invalidFTLVFile
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let fileSize = (attributes[.size] as? NSNumber)?.intValue,
              fileSize >= 512 else {
            throw ConnectionError.invalidFTLVFile
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }

        let header = Array((try file.read(upToCount: 512) ?? Data()))
        guard let info = FTLVFileInfo.parse(header: header, actualFileLength: fileSize) else {
            throw ConnectionError.invalidFTLVFile
        }
        guard info.isCompatible(with: deviceType) else {
            throw ConnectionError.incompatibleFTLVDevice(fileType: info.deviceType, deviceType: deviceType)
        }
        let name = url.deletingPathExtension().lastPathComponent
        let identifier = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))
        let type: UInt8 = info.frameCount == 1 ? 0 : 2
        guard let request = SpinDisplayProtocol.fileSendRequest(
            name: name,
            repeating: 1,
            id: identifier,
            type: type,
            headerLength: UInt16(info.headerLength)
        ),
        let headerRequest = SpinDisplayProtocol.fileHeaderSendRequest(header: Array(header.prefix(48))) else {
            throw ConnectionError.invalidFTLVFile
        }

        progress(0, "Opening the fan's media-transfer connection…")
        let dataSocket = try openDataSocket()
        do {
            try beginUpload(dataSocket)
            try waitForUploadReady(request: request)

            try file.seek(toOffset: 512)
            var sent = 512
            var lastReported = sent
            progress(Double(sent) / Double(fileSize), "Sending media data…")
            while true {
                let chunk = try file.read(upToCount: 1024) ?? Data()
                guard !chunk.isEmpty else { break }
                try Self.sendData(chunk, on: dataSocket)
                sent += chunk.count
                if sent == fileSize || sent - lastReported >= 64 * 1024 {
                    progress(Double(sent) / Double(fileSize), "Sending media data…")
                    lastReported = sent
                }
            }
            guard sent == fileSize else { throw ConnectionError.fileChangedDuringUpload }

            Thread.sleep(forTimeInterval: 1)
            try setUploadWaitStage(.waitingForCompletion)
            try sendPacket(headerRequest)
            try waitForUploadCompletion(timeout: 120)
            try refreshPlaylist()
            progress(1, "Upload complete. Playlist refresh requested.")
            finishUpload(socketDescriptor: dataSocket)
        } catch {
            finishUpload(socketDescriptor: dataSocket)
            throw error
        }
    }

    private func openDataSocket() throws -> Int32 {
        let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else {
            throw ConnectionError.systemCall("Could not create the media-transfer socket", errno)
        }
        var noSignal: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            let code = errno
            close(descriptor)
            throw ConnectionError.systemCall("Could not configure the media-transfer socket", code)
        }

        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = in_port_t(50115).bigEndian
        let conversion = address.withCString { inet_pton(AF_INET, $0, &destination.sin_addr) }
        guard conversion == 1 else {
            close(descriptor)
            throw ConnectionError.invalidAddress(address)
        }
        if var localAddress = Self.localAddress(for: destination.sin_addr) {
            let bindResult = withUnsafePointer(to: &localAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult == 0 else {
                let code = errno
                close(descriptor)
                throw ConnectionError.systemCall("Could not bind to the fan's local Wi-Fi interface", code)
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
            throw ConnectionError.systemCall("Could not connect to \(address):50115", code)
        }
        return descriptor
    }

    private func beginUpload(_ descriptor: Int32) throws {
        uploadCondition.lock()
        defer { uploadCondition.unlock() }
        guard uploadWaitStage == nil else { throw ConnectionError.uploadInProgress }
        uploadWaitStage = .waitingForReady
        uploadResponse = nil
        uploadSocket = descriptor
    }

    private func setUploadWaitStage(_ stage: UploadWaitStage) throws {
        uploadCondition.lock()
        defer { uploadCondition.unlock() }
        guard uploadWaitStage != nil else { throw ConnectionError.disconnected }
        uploadWaitStage = stage
        uploadResponse = nil
    }

    private func waitForUploadReady(request: [UInt8]) throws {
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            try sendPacket(request)
            let timeout = min(1, max(0, deadline.timeIntervalSinceNow))
            guard let status = try waitForUploadStatus(timeout: timeout) else { continue }
            if status == 0 { return }
            if status != 6 { throw ConnectionError.fileTransferRejected(status: status) }
        }
        throw ConnectionError.fileTransferTimedOut
    }

    private func waitForUploadCompletion(timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let waitInterval = min(1, max(0, deadline.timeIntervalSinceNow))
            guard let status = try waitForUploadStatus(timeout: waitInterval) else { continue }
            if status == 255 { return }
            if status != 6 { throw ConnectionError.fileTransferRejected(status: status) }
        }
        throw ConnectionError.fileTransferTimedOut
    }

    private func waitForUploadStatus(timeout: TimeInterval) throws -> UInt8? {
        uploadCondition.lock()
        defer { uploadCondition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while uploadResponse == nil, uploadWaitStage != nil {
            if !uploadCondition.wait(until: deadline), uploadResponse == nil { return nil }
        }
        guard uploadWaitStage != nil, let response = uploadResponse else {
            throw ConnectionError.disconnected
        }
        uploadResponse = nil
        return response
    }

    private func finishUpload(socketDescriptor: Int32) {
        uploadCondition.lock()
        let shouldClose = uploadSocket == socketDescriptor
        if shouldClose { uploadSocket = nil }
        uploadWaitStage = nil
        uploadResponse = nil
        uploadCondition.broadcast()
        uploadCondition.unlock()
        if shouldClose {
            _ = shutdown(socketDescriptor, SHUT_RDWR)
            _ = close(socketDescriptor)
        }
    }

    private func cancelPendingUpload() {
        uploadCondition.lock()
        let descriptor = uploadSocket
        uploadSocket = nil
        uploadWaitStage = nil
        uploadResponse = nil
        uploadCondition.broadcast()
        uploadCondition.unlock()
        if let descriptor {
            _ = shutdown(descriptor, SHUT_RDWR)
            _ = close(descriptor)
        }
    }

    private static func sendData(_ data: Data, on descriptor: Int32) throws {
        var sent = 0
        while sent < data.count {
            let count = data.withUnsafeBytes { bytes in
                Darwin.send(descriptor, bytes.baseAddress!.advanced(by: sent), data.count - sent, 0)
            }
            guard count > 0 else {
                throw ConnectionError.systemCall("Could not send media data", errno == 0 ? EPIPE : errno)
            }
            sent += count
        }
    }

    private enum UploadWaitStage {
        case waitingForReady
        case waitingForCompletion
    }

    private enum ConnectionError: LocalizedError {
        case invalidAddress(String)
        case systemCall(String, Int32)
        case invalidWiFiCredentials
        case invalidDeviceName
        case invalidAngle
        case invalidSchedule
        case invalidPlaylistIndex
        case invalidLoginPassword
        case invalidFileEdit
        case closedDuringHandshake
        case handshakeTimedOut
        case disconnected
        case invalidFTLVFile
        case incompatibleFTLVDevice(fileType: UInt8, deviceType: UInt8)
        case fileTransferRejected(status: UInt8)
        case fileTransferTimedOut
        case fileChangedDuringUpload
        case uploadInProgress

        var errorDescription: String? {
            switch self {
            case .invalidAddress(let address):
                return "Invalid IPv4 address: \(address)"
            case .systemCall(let operation, let code):
                return "\(operation): \(String(cString: strerror(code)))"
            case .invalidWiFiCredentials:
                return "SSID must be 1–32 UTF-8 bytes and the Wi-Fi password must be at most 64 UTF-8 bytes."
            case .invalidDeviceName:
                return "The device name must contain 1–24 UTF-8 bytes."
            case .invalidAngle:
                return "The angle must be between -360 and 360 degrees."
            case .invalidSchedule:
                return "The power schedule contains an invalid hour or minute."
            case .invalidPlaylistIndex:
                return "The selected playlist item index is out of range."
            case .invalidLoginPassword:
                return "The login password must be 1–8 UTF-8 bytes when verification is enabled."
            case .invalidFileEdit:
                return "The file name must be 1–100 UTF-8 bytes and the item must be in the playlist."
            case .closedDuringHandshake:
                return "The device closed the connection during its handshake."
            case .handshakeTimedOut:
                return "The device did not complete its TCP handshake within 10 seconds."
            case .disconnected:
                return "The device is disconnected."
            case .invalidFTLVFile:
                return "This is not a valid, supported FTLV file."
            case .incompatibleFTLVDevice(let fileType, let deviceType):
                return "FTLV device type \(fileType) is not compatible with connected fan type \(deviceType)."
            case .fileTransferRejected(let status):
                if let reason = SpinDisplayProtocol.fileTransferErrorDescription(status: status) {
                    return "The fan rejected the media transfer: \(reason)"
                }
                return "The fan rejected the media transfer with status \(status)."
            case .fileTransferTimedOut:
                return "The fan did not respond before the media-transfer timeout."
            case .fileChangedDuringUpload:
                return "The FTLV file changed while it was being uploaded."
            case .uploadInProgress:
                return "A media upload is already in progress."
            }
        }
    }
}
