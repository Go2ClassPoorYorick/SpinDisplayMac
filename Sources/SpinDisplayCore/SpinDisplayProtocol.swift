import Foundation

public struct FanDevice: Identifiable, Hashable, Sendable {
    public let name: String
    public let address: String
    public let macAddress: String
    public let deviceType: UInt8
    public let firmwareVersion: UInt8
    public let passwordProtected: Bool
    public let challenge: UInt32

    public var id: String { macAddress }
}

public struct FanFile: Identifiable, Hashable, Sendable {
    public let name: String
    public let type: UInt8
    public let durationSeconds: Int
    public let repeating: UInt8
    public let isShown: UInt8
    public let fileID: String
    public let status: UInt8
    public let timeSlots: [PlaybackTimeSlot]

    public var id: String { fileID.isEmpty ? name : fileID }
    public var displayMode: FileDisplayMode? { FileDisplayMode(rawValue: isShown) }
}

/// The original File Edit window's radio buttons, in protocol order.
public enum FileDisplayMode: UInt8, CaseIterable, Sendable {
    case allDay = 0
    case hidden = 1
    case scheduled = 2
}

/// One of the eight per-file playback windows. Byte 0 packs the enabled flag in bit 0
/// and the weekdays in bits 1–7 (Mon = 0x02 … Sat = 0x40, Sun = 0x80).
public struct PlaybackTimeSlot: Equatable, Hashable, Sendable {
    public static let count = 8
    public static let weekdayBits: [(name: String, bit: UInt8)] = [
        ("Mon", 0x02), ("Tue", 0x04), ("Wed", 0x08), ("Thu", 0x10),
        ("Fri", 0x20), ("Sat", 0x40), ("Sun", 0x80)
    ]

    public var isEnabled: Bool
    public var weekdays: UInt8
    public var startHour: UInt8
    public var startMinute: UInt8
    public var endHour: UInt8
    public var endMinute: UInt8

    public init(isEnabled: Bool, weekdays: UInt8, startHour: UInt8, startMinute: UInt8, endHour: UInt8, endMinute: UInt8) {
        self.isEnabled = isEnabled
        self.weekdays = weekdays & 0xfe
        self.startHour = startHour
        self.startMinute = startMinute
        self.endHour = endHour
        self.endMinute = endMinute
    }

    public init(encoded bytes: ArraySlice<UInt8>) {
        let start = bytes.startIndex
        self.init(
            isEnabled: bytes[start] & 1 == 1,
            weekdays: bytes[start],
            startHour: bytes[start + 1],
            startMinute: bytes[start + 2],
            endHour: bytes[start + 3],
            endMinute: bytes[start + 4]
        )
    }

    public static let empty = PlaybackTimeSlot(isEnabled: false, weekdays: 0, startHour: 0, startMinute: 0, endHour: 0, endMinute: 0)

    public var encoded: [UInt8] {
        [(isEnabled ? 1 : 0) | (weekdays & 0xfe), startHour, startMinute, endHour, endMinute]
    }

    /// The original editor rejects windows whose start is not earlier than their end.
    public var isValid: Bool {
        startHour < 24 && endHour < 24 && startMinute < 60 && endMinute < 60
            && (Int(startHour) * 60 + Int(startMinute)) < (Int(endHour) * 60 + Int(endMinute))
    }
}

/// Feature-unsupported flags reported by the fan in its parameter response.
public struct FanFeatureRestrictions: OptionSet, Hashable, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let autoOn = Self(rawValue: 1 << 0)
    public static let timingSwitch = Self(rawValue: 1 << 1)
    public static let timingPlay = Self(rawValue: 1 << 2)
    public static let projection = Self(rawValue: 1 << 3)
    public static let sync = Self(rawValue: 1 << 4)
    public static let remote = Self(rawValue: 1 << 5)
    public static let router = Self(rawValue: 1 << 6)
    public static let clock = Self(rawValue: 1 << 7)
    public static let voice = Self(rawValue: 1 << 8)
}

/// The fan's full parameter response (command 0x12), following the original `Receive.AnalyticInfo`.
/// Credentials that the fan echoes back are intentionally not retained.
public struct FanDeviceInfo: Equatable, Sendable {
    public let sdCapacityTotal: Int
    public let sdCapacityAvailable: Int
    public let serialNumber: String
    public let deviceName: String
    public let deviceModel: String
    public let isOn: Bool
    public let factoryDate: DateComponents
    public let maxFPS: Int
    public let contentType: UInt8
    public let diameter: Int
    public let imageSize: Int
    public let imageWidth: Int
    public let restrictions: FanFeatureRestrictions
    public let hotspotName: String
    public let routerName: String
    public let isRouterConnected: Bool
    public let isHotspotShown: Bool
    public let isLoginVerificationEnabled: Bool
    public let isThirdPartyControlEnabled: Bool
    public let isShutdownScheduled: Bool
    public let isBootScheduled: Bool
    public let shutdownHour: UInt8
    public let shutdownMinute: UInt8
    public let bootHour: UInt8
    public let bootMinute: UInt8
    public let isAutoOn: Bool
    public let isBluetoothEnabled: Bool
    public let volume: UInt8
    public let angleDegrees: Int
    public let brightness: UInt8
    public let displayMode: UInt8
    public let coordinateX: Int
    public let coordinateY: Int
    public let coordinateLevel: UInt8
    public let syncFlag: UInt8
    public let groupNumber: UInt8
    public let jointModel: UInt8

    public var sdUsablePercent: Double? {
        guard sdCapacityTotal > 0 else { return nil }
        return (Double(sdCapacityAvailable) / Double(sdCapacityTotal) * 1000).rounded() / 10
    }
}

/// The fan's version response (command 0x11).
public struct FanVersionInfo: Equatable, Sendable {
    public let firmware: Int
    public let model: UInt8
    public let agreement: UInt8

    public init(firmware: Int, model: UInt8, agreement: UInt8) {
        self.firmware = firmware
        self.model = model
        self.agreement = agreement
    }
}

/// Display mode values from the original Settings window (`Radio_HighLight` / `Radio_TrueColor`).
public enum FanDisplayMode: UInt8, CaseIterable, Sendable {
    case highlight = 0
    case trueColor = 1
}

public struct PlaybackStatusResponse: Equatable, Sendable {
    public let responseField: UInt8
    public let playlistSlot: UInt8

    public init(responseField: UInt8, playlistSlot: UInt8) {
        self.responseField = responseField
        self.playlistSlot = playlistSlot
    }
}

public struct FTLVFileInfo: Equatable, Sendable {
    public let deviceType: UInt8
    public let version: UInt8
    public let fileLength: Int
    public let headerLength: Int
    public let dataLength: Int
    public let audioLength: Int
    public let indexLength: Int
    public let frameDuration: Int
    public let frameCount: Int

    public var durationSeconds: Int {
        guard frameDuration > 0, frameCount > 0 else { return 0 }
        let (duration, overflow) = frameDuration.multipliedReportingOverflow(by: frameCount)
        guard !overflow else { return 0 }
        return duration / 1_000_000
    }

    public static func parse(header: [UInt8], actualFileLength: Int) -> FTLVFileInfo? {
        guard header.count >= 48,
              actualFileLength >= 512,
              Array(header[0..<3]) == Array("FTL".utf8),
              let fileLength = header.littleEndianInt32(at: 8),
              let headerLength = header.littleEndianInt32(at: 12),
              let dataLength = header.littleEndianInt32(at: 16),
              let audioLength = header.littleEndianInt32(at: 20),
              let indexLength = header.littleEndianInt32(at: 24),
              let frameDuration = header.littleEndianInt32(at: 36),
              let frameCount = header.littleEndianInt32(at: 40),
              fileLength == actualFileLength,
              headerLength == 512,
              dataLength >= 0,
              audioLength >= 0,
              indexLength >= 8,
              frameDuration >= 0,
              frameCount > 0,
              headerLength <= actualFileLength,
              dataLength <= actualFileLength - headerLength,
              audioLength <= actualFileLength - headerLength - dataLength,
              indexLength == actualFileLength - headerLength - dataLength - audioLength else {
            return nil
        }

        return FTLVFileInfo(
            deviceType: header[3],
            version: header[4],
            fileLength: fileLength,
            headerLength: headerLength,
            dataLength: dataLength,
            audioLength: audioLength,
            indexLength: indexLength,
            frameDuration: frameDuration,
            frameCount: frameCount
        )
    }

    public func isCompatible(with deviceType: UInt8) -> Bool {
        self.deviceType == deviceType
            || (![25, 26].contains(self.deviceType) && ![25, 26].contains(deviceType))
    }
}

public enum SpinDisplayProtocol {
    public static let header: UInt8 = 0x68
    public static let discoveryCommand: UInt8 = 0x00
    public static let deviceResponseCommand: UInt8 = 0x01
    public static let passwordCommand: UInt8 = 0x02
    public static let loginVerificationCommand: UInt8 = 0x05
    public static let thirdPartyControlCommand: UInt8 = 0x06
    public static let wifiConfigurationCommand: UInt8 = 0x07
    public static let connectCommand: UInt8 = 0x10
    public static let versionCommand: UInt8 = 0x11
    public static let parameterCommand: UInt8 = 0x12
    public static let brightnessCommand: UInt8 = 0x13
    public static let heartbeatCommand: UInt8 = 0x14
    public static let deviceNameCommand: UInt8 = 0x16
    public static let powerCommand: UInt8 = 0x17
    public static let angleCommand: UInt8 = 0x18
    public static let resetCommand: UInt8 = 0x19
    public static let scheduleCommand: UInt8 = 0x20
    public static let clockCommand: UInt8 = 0x21
    public static let remoteMatchCommand: UInt8 = 0x22
    public static let bleVolumeCommand: UInt8 = 0x23
    public static let displayModeCommand: UInt8 = 0x24
    public static let fileSendCommand: UInt8 = 0x30
    public static let playlistCommand: UInt8 = 0x31
    public static let deleteFileCommand: UInt8 = 0x32
    public static let moveFileCommand: UInt8 = 0x33
    public static let changeFileCommand: UInt8 = 0x34
    public static let playControlCommand: UInt8 = 0x35
    public static let fileHeaderSendCommand: UInt8 = 0x36
    public static let projectionCommand: UInt8 = 0x37
    /// Marker byte that starts each projection frame on the data channel (`Protocol.ProHeader`).
    public static let projectionFrameMarker: UInt8 = 0xfa

    public static func frame(command: UInt8, payload: [UInt8] = []) -> [UInt8] {
        precondition(payload.count <= Int(UInt16.max))
        var result: [UInt8] = [
            header,
            command,
            UInt8(payload.count & 0xff),
            UInt8((payload.count >> 8) & 0xff)
        ]
        result.append(contentsOf: payload)
        let checksum = crc16(result)
        result.append(UInt8(checksum & 0xff))
        result.append(UInt8((checksum >> 8) & 0xff))
        return result
    }

    public static func discoveryRequest(challenge: UInt32) -> [UInt8] {
        frame(command: discoveryCommand, payload: challenge.littleEndianBytes)
    }

    public static func passwordRequest(password: String, challenge: UInt32) -> [UInt8] {
        var passwordBytes = Array(password.utf8.prefix(8))
        passwordBytes.append(contentsOf: repeatElement(0, count: 8 - passwordBytes.count))
        let challengeBytes = challenge.littleEndianBytes
        let encrypted = passwordBytes.enumerated().map { index, byte in
            byte ^ challengeBytes[index % challengeBytes.count]
        }
        return frame(command: passwordCommand, payload: encrypted + [0])
    }

    public static func wifiConfigurationRequest(ssid: String, password: String) -> [UInt8]? {
        let ssidBytes = Array(ssid.utf8)
        let passwordBytes = Array(password.utf8)
        guard !ssidBytes.isEmpty, ssidBytes.count <= 32, passwordBytes.count <= 64 else {
            return nil
        }

        var payload: [UInt8] = [1]
        payload.append(contentsOf: ssidBytes)
        payload.append(contentsOf: repeatElement(0, count: 32 - ssidBytes.count))
        payload.append(0)
        payload.append(contentsOf: passwordBytes)
        payload.append(contentsOf: repeatElement(0, count: 64 - passwordBytes.count))
        payload.append(0)
        return frame(command: wifiConfigurationCommand, payload: payload)
    }

    /// Original `Send.LanChange(0, …)`: leave the router and return to the fan's own hotspot.
    /// The original sends whatever the network fields contain; this sends the current router name only.
    public static func routerDisconnectRequest(currentSSID: String) -> [UInt8] {
        let ssidBytes = Array(currentSSID.utf8.prefix(32))
        var payload: [UInt8] = [0]
        payload.append(contentsOf: ssidBytes)
        payload.append(contentsOf: repeatElement(0, count: 32 - ssidBytes.count))
        payload.append(contentsOf: repeatElement(0, count: 1 + 64 + 1))
        return frame(command: wifiConfigurationCommand, payload: payload)
    }

    /// Original `Send.Reset(bool)`: 0x55 restores parameters and keeps content (the Settings button);
    /// 0x58 is the unused "clear" variant.
    public static func factoryResetRequest(clearContent: Bool = false) -> [UInt8] {
        frame(command: resetCommand, payload: [clearContent ? 0x58 : 0x55])
    }

    /// Original `Send.MatchCode`: 0 starts remote-control pairing, 1 cancels it. The fan answers 2 when matched.
    public static func remoteMatchRequest(start: Bool) -> [UInt8] {
        frame(command: remoteMatchCommand, payload: [start ? 0 : 1])
    }

    /// Original `Send.Projection`: 1 asks the fan to accept live frames on the data channel, 0 ends projection.
    public static func projectionRequest(isOn: Bool) -> [UInt8] {
        frame(command: projectionCommand, payload: [isOn ? 1 : 0])
    }

    /// Original `TcpServer.ProjectionSend`: `FA` and a 3-byte little-endian length precede each JPEG frame.
    public static func projectionFrameHeader(length: Int) -> [UInt8]? {
        guard (0..<(1 << 24)).contains(length) else { return nil }
        return [projectionFrameMarker, UInt8(length & 0xff), UInt8((length >> 8) & 0xff), UInt8((length >> 16) & 0xff)]
    }

    public static func powerRequest(isOn: Bool) -> [UInt8] {
        frame(command: powerCommand, payload: [isOn ? 1 : 0])
    }

    public static func brightnessRequest(level: UInt8) -> [UInt8] {
        frame(command: brightnessCommand, payload: [level])
    }

    public static func deviceNameRequest(_ name: String) -> [UInt8]? {
        let nameBytes = Array(name.utf8)
        guard !nameBytes.isEmpty, nameBytes.count <= 24 else { return nil }
        var payload = nameBytes
        payload.append(contentsOf: repeatElement(0, count: 24 - nameBytes.count))
        payload.append(0)
        payload.append(0)
        return frame(command: deviceNameCommand, payload: payload)
    }

    public static func angleRequest(degrees: Int) -> [UInt8]? {
        guard (-360...360).contains(degrees) else { return nil }
        let encoded = degrees < 0 ? degrees + 720 : degrees
        let value = UInt16(encoded)
        return frame(command: angleCommand, payload: [
            UInt8(value & 0xff),
            UInt8(value >> 8)
        ])
    }

    public static func scheduleRequest(
        autoOn: Bool,
        shutdownEnabled: Bool,
        bootEnabled: Bool,
        shutdownHour: UInt8,
        shutdownMinute: UInt8,
        bootHour: UInt8,
        bootMinute: UInt8
    ) -> [UInt8]? {
        guard shutdownHour < 24, bootHour < 24, shutdownMinute < 60, bootMinute < 60 else {
            return nil
        }
        return frame(command: scheduleCommand, payload: [
            autoOn ? 1 : 0,
            shutdownEnabled ? 1 : 0,
            bootEnabled ? 1 : 0,
            shutdownHour,
            shutdownMinute,
            bootHour,
            bootMinute
        ])
    }

    public static func clockSyncRequest(date: Date = Date(), calendar: Calendar = .current) -> [UInt8] {
        let components = calendar.dateComponents(
            [.year, .month, .day, .weekday, .hour, .minute, .second],
            from: date
        )
        let weekday = components.weekday == 1 ? 7 : (components.weekday ?? 2) - 1
        return frame(command: clockCommand, payload: [
            1,
            UInt8((components.year ?? 2000) % 100),
            UInt8(components.month ?? 1),
            UInt8(components.day ?? 1),
            UInt8(weekday),
            UInt8(components.hour ?? 0),
            UInt8(components.minute ?? 0),
            UInt8(components.second ?? 0)
        ])
    }

    public static func bleVolumeRequest(control: UInt8, volume: UInt8 = 0) -> [UInt8] {
        frame(command: bleVolumeCommand, payload: [control, volume])
    }

    public static func displayModeRequest(_ mode: FanDisplayMode) -> [UInt8] {
        frame(command: displayModeCommand, payload: [mode.rawValue])
    }

    public static func thirdPartyControlRequest(isEnabled: Bool) -> [UInt8] {
        frame(command: thirdPartyControlCommand, payload: [isEnabled ? 1 : 0])
    }

    /// Original `Send.UdpCheckChange`: status byte, then up to 8 UTF-8 password bytes and a terminator.
    public static func loginVerificationRequest(isEnabled: Bool, password: String) -> [UInt8]? {
        let passwordBytes = Array(password.utf8)
        guard passwordBytes.count <= 8, !isEnabled || !passwordBytes.isEmpty else { return nil }
        var payload = [UInt8](repeating: 0, count: 10)
        payload[0] = isEnabled ? 1 : 0
        payload.replaceSubrange(1..<(1 + passwordBytes.count), with: passwordBytes)
        return frame(command: loginVerificationCommand, payload: payload)
    }

    /// Original `Send.AlterFile`, sent by the File Edit window. `index` is zero-based; the packet is one-based.
    public static func changeFileRequest(
        index: Int,
        name: String,
        repeatCount: UInt8,
        displayMode: FileDisplayMode,
        timeSlots: [PlaybackTimeSlot]
    ) -> [UInt8]? {
        let nameBytes = Array(name.utf8)
        guard (0..<Int(UInt8.max)).contains(index),
              !nameBytes.isEmpty, nameBytes.count <= 100,
              timeSlots.count == PlaybackTimeSlot.count else {
            return nil
        }
        var payload = [UInt8](repeating: 0, count: 144)
        payload[0] = UInt8(index + 1)
        payload.replaceSubrange(1..<(1 + nameBytes.count), with: nameBytes)
        payload[102] = repeatCount
        payload[103] = displayMode.rawValue
        for (slot, timeSlot) in timeSlots.enumerated() {
            payload.replaceSubrange((104 + slot * 5)..<(109 + slot * 5), with: timeSlot.encoded)
        }
        return frame(command: changeFileCommand, payload: payload)
    }

    /// Settings acknowledgements put their status in the first payload byte; the original treats 0 as success.
    public static func parseSettingStatus(_ frame: [UInt8], command: UInt8) -> UInt8? {
        guard frame.count >= 7, frame[0] == header, frame[1] == command else { return nil }
        return frame[4]
    }

    /// Original `Send_Result_Error_N` messages for file-transfer statuses 1–5.
    public static func fileTransferErrorDescription(status: UInt8) -> String? {
        switch status {
        case 1: return "Not enough space on the device."
        case 2: return "A file with this name already exists on the device."
        case 3: return "The device's SD card has failed."
        case 4: return "The device could not write the file."
        case 5: return "The device has reached its maximum number of files."
        default: return nil
        }
    }

    public static func fileSendRequest(
        name: String,
        repeating: UInt8,
        id: String,
        type: UInt8,
        headerLength: UInt16 = 512
    ) -> [UInt8]? {
        let nameBytes = Array(name.utf8)
        let idBytes = Array(id.utf8)
        guard !nameBytes.isEmpty, nameBytes.count <= 100,
              idBytes.count == 8 else {
            return nil
        }
        var payload = [UInt8](repeating: 0, count: 114)
        payload.replaceSubrange(0..<nameBytes.count, with: nameBytes)
        payload[101] = repeating
        payload.replaceSubrange(102..<110, with: idBytes)
        payload[111] = type
        payload[112] = UInt8(headerLength & 0xff)
        payload[113] = UInt8(headerLength >> 8)
        return frame(command: fileSendCommand, payload: payload)
    }

    public static func fileHeaderSendRequest(header: [UInt8]) -> [UInt8]? {
        guard header.count == 48 else { return nil }
        return frame(command: fileHeaderSendCommand, payload: header)
    }

    public static func parseFileSendStatus(_ frame: [UInt8]) -> UInt8? {
        guard frame.count >= 7,
              frame[0] == header,
              frame[1] == fileSendCommand else {
            return nil
        }
        return frame[4]
    }

    /// Original `Button_Click_Delecte` stores `selectedIndex + 1`: `index` is zero-based, the packet one-based.
    public static func deleteFileRequest(index: Int) -> [UInt8]? {
        guard (0..<Int(UInt8.max)).contains(index) else { return nil }
        return frame(command: deleteFileCommand, payload: [0, UInt8(index + 1)])
    }

    /// Original Settings "Format" button (`Send.DeleteFile(1, 0)`): deletes every file on the fan.
    public static func deleteAllFilesRequest() -> [UInt8] {
        frame(command: deleteFileCommand, payload: [1, 0])
    }

    public static func moveFileRequest(from source: Int, to destination: Int) -> [UInt8]? {
        guard (0..<Int(UInt8.max)).contains(source),
              (0..<Int(UInt8.max)).contains(destination) else {
            return nil
        }
        return frame(command: moveFileCommand, payload: [UInt8(source + 1), UInt8(destination + 1)])
    }

    public static func heartbeatRequest() -> [UInt8] {
        frame(command: heartbeatCommand)
    }

    public static func playlistRequest() -> [UInt8] {
        frame(command: playlistCommand)
    }

    public static func playControlRequest(control: UInt8, index: UInt8) -> [UInt8] {
        frame(command: playControlCommand, payload: [control, index])
    }

    /// Original `Button_Click_Loop` ("Cycleplay"): play the slot, then set it to loop.
    public static func repeatFileRequests(index: UInt8) -> [[UInt8]] {
        [
            playControlRequest(control: 1, index: index),
            playControlRequest(control: 2, index: index)
        ]
    }

    public static func playbackStatusRequest() -> [UInt8] {
        playControlRequest(control: 0, index: 0)
    }

    public static func parseDeviceStatus(_ frame: [UInt8]) -> (isOn: Bool, brightness: UInt8)? {
        guard frame.count >= 330,
              frame[0] == header,
              frame[1] == parameterCommand else {
            return nil
        }
        return (frame[68] != 0, frame[294])
    }

    public static func parseDeviceInfo(_ frame: [UInt8]) -> FanDeviceInfo? {
        guard frame.count >= 330,
              frame[0] == header,
              frame[1] == parameterCommand,
              let sdTotal = frame.littleEndianInt32(at: 4),
              let sdAvailable = frame.littleEndianInt32(at: 8) else {
            return nil
        }
        func text(_ offset: Int, _ length: Int) -> String {
            String(decoding: frame[offset..<(offset + length)].prefix { $0 != 0 }, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func uint16(_ offset: Int) -> Int { Int(frame[offset]) | (Int(frame[offset + 1]) << 8) }
        func int16(_ offset: Int) -> Int { Int(Int16(bitPattern: UInt16(uint16(offset)))) }

        let rawAngle = int16(292)
        return FanDeviceInfo(
            sdCapacityTotal: sdTotal,
            sdCapacityAvailable: sdAvailable,
            serialNumber: frame[12..<18].map { String(format: "%02X", $0) }.joined(separator: "-"),
            deviceName: text(18, 24),
            deviceModel: text(43, 24),
            isOn: frame[68] != 0,
            factoryDate: DateComponents(year: 2000 + Int(frame[69]), month: Int(frame[70]), day: Int(frame[71])),
            maxFPS: frame[72] == 0 ? 20 : Int(frame[72]),
            contentType: frame[73],
            diameter: int16(74),
            imageSize: uint16(76) == 0 ? 672 : int16(76),
            imageWidth: uint16(78) == 0 ? 672 : int16(78),
            restrictions: FanFeatureRestrictions(rawValue: UInt16(uint16(80))),
            hotspotName: text(92, 24),
            routerName: text(142, 32),
            isRouterConnected: frame[249] != 0,
            isHotspotShown: frame[250] != 0,
            isLoginVerificationEnabled: frame[251] != 0,
            isThirdPartyControlEnabled: frame[252] != 0,
            isShutdownScheduled: frame[268] != 0,
            isBootScheduled: frame[269] != 0,
            shutdownHour: frame[270],
            shutdownMinute: frame[271],
            bootHour: frame[272],
            bootMinute: frame[273],
            isAutoOn: frame[274] != 0,
            isBluetoothEnabled: frame[276] >> 7 != 0,
            volume: frame[276] & 31,
            angleDegrees: rawAngle > 360 ? rawAngle - 720 : rawAngle,
            brightness: frame[294],
            displayMode: frame[295],
            coordinateX: int16(316),
            coordinateY: int16(318),
            coordinateLevel: frame[320],
            syncFlag: frame[321],
            groupNumber: frame[322],
            jointModel: frame[323]
        )
    }

    public static func parseVersion(_ frame: [UInt8]) -> FanVersionInfo? {
        guard frame.count >= 10, frame[0] == header, frame[1] == versionCommand else { return nil }
        return FanVersionInfo(firmware: Int(frame[4]) * 100 + Int(frame[5]), model: frame[6], agreement: frame[7])
    }

    public static func parsePlaybackStatus(_ frame: [UInt8]) -> PlaybackStatusResponse? {
        guard frame.count >= 8,
              frame[0] == header,
              frame[1] == playControlCommand else {
            return nil
        }
        return PlaybackStatusResponse(responseField: frame[4], playlistSlot: frame[5])
    }

    public static func parsePlaylistRecords(_ data: [UInt8]) -> [FanFile] {
        let recordSize = 180
        guard data.count >= recordSize else { return [] }

        return stride(from: 0, through: data.count - recordSize, by: recordSize).compactMap { offset in
            let record = Array(data[offset..<(offset + recordSize)])
            let nameBytes = record.prefix(101)
            let name = String(decoding: nameBytes.prefix { $0 != 0 }, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            let duration = Int(record[104]) | (Int(record[105]) << 8)
            let fileID = String(decoding: record[108..<116].prefix { $0 != 0 }, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return FanFile(
                name: name,
                type: record[101],
                durationSeconds: duration,
                repeating: record[106],
                isShown: record[107],
                fileID: fileID,
                status: record[117],
                timeSlots: (0..<PlaybackTimeSlot.count).map {
                    PlaybackTimeSlot(encoded: record[(118 + $0 * 5)..<(123 + $0 * 5)])
                }
            )
        }
    }

    public static func parseDeviceResponse(_ data: [UInt8], sourceAddress: String, challenge: UInt32) -> FanDevice? {
        guard data.count >= 45,
              data[0] == header,
              data[1] == deviceResponseCommand else {
            return nil
        }

        let nameBytes = data[6..<30]
        let name = String(decoding: nameBytes.prefix { $0 != 0 }, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let macAddress = data[31..<37]
            .map { String(format: "%02X", $0) }
            .joined(separator: ":")
        return FanDevice(
            name: name.isEmpty ? "SpinDisplay" : name,
            address: sourceAddress,
            macAddress: macAddress,
            deviceType: data[37],
            firmwareVersion: data[38],
            passwordProtected: data[5] == 1,
            challenge: challenge
        )
    }

    public static func frameLength(in bytes: [UInt8], maximumPayload: Int = 1_048_576) -> Int? {
        guard bytes.count >= 4, bytes[0] == header else { return nil }
        let payloadLength = Int(bytes[2]) | (Int(bytes[3]) << 8)
        guard payloadLength <= maximumPayload else { return nil }
        return payloadLength + 6
    }

    public static func crc16(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xffff
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xa001 : crc >> 1
            }
        }
        return crc
    }
}

private extension UInt32 {
    var littleEndianBytes: [UInt8] {
        [
            UInt8(self & 0xff),
            UInt8((self >> 8) & 0xff),
            UInt8((self >> 16) & 0xff),
            UInt8((self >> 24) & 0xff)
        ]
    }
}

private extension Array where Element == UInt8 {
    func littleEndianInt32(at offset: Int) -> Int? {
        guard offset >= 0, offset <= count - 4 else { return nil }
        let value = UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
        return Int(value)
    }
}
