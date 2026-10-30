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

/// A firmware package (`.POVC`) header, following the original `App.initPackage`: byte 0 is 0xFF,
/// byte 1 the model (0xAA stands for model 1), and the version is `byte2 * 100 + byte3`.
/// The rest of the file after the 8-byte header is what the fan receives.
public struct FirmwarePackageInfo: Equatable, Sendable {
    public static let headerLength = 8

    public let model: Int
    public let version: Int
    public let payloadLength: Int

    public init(model: Int, version: Int, payloadLength: Int) {
        self.model = model
        self.version = version
        self.payloadLength = payloadLength
    }

    public static func parse(header: [UInt8], fileLength: Int) -> FirmwarePackageInfo? {
        guard header.count >= headerLength, header[0] == 0xff, fileLength > headerLength else { return nil }
        let model = header[1] == 0xaa ? 1 : Int(header[1])
        guard model != 0 else { return nil }
        return FirmwarePackageInfo(
            model: model,
            version: Int(header[2]) * 100 + Int(header[3]),
            payloadLength: fileLength - headerLength
        )
    }

    /// The original's automatic update rule (`App.UpdateFirmware`): same model and a newer version.
    public func isAutomaticUpdate(forModel fanModel: Int, firmware fanFirmware: Int) -> Bool {
        model == fanModel && version > fanFirmware
    }
}

/// LED transcoding parameters for content-type-3 fans (`0x3B`, original `Receive.AnalyticTranscoding`).
public struct FanTranscoding: Equatable, Sendable {
    public let ledCount: Int
    public let rows: Int
    public let direction: Int
    public let deliveryTimes: Int
    public let lightBarCount: Int
    public let quality: Int
    public let adjust: [UInt8]
    public let ratio: [UInt8]

    public init(ledCount: Int, rows: Int, direction: Int, deliveryTimes: Int, lightBarCount: Int, quality: Int, adjust: [UInt8], ratio: [UInt8]) {
        self.ledCount = ledCount
        self.rows = rows
        self.direction = direction
        self.deliveryTimes = deliveryTimes
        self.lightBarCount = lightBarCount
        self.quality = quality
        self.adjust = adjust
        self.ratio = ratio
    }
}

/// Bin-encoding parameters for content-type-1 fans (`0x39`, original `Receive.GetBinParam`).
public struct FanBinConfiguration: Equatable, Sendable {
    public let ledCount: Int
    public let subsection: Int
    public let lamps: Int
    public let rows: Int
    public let color: Int
    public let bit: Int
    public let orientation: Int
    public let perBar: Int
    public let adjust: [UInt8]
    /// Per-LED brightness factors (1.0 unless the fan reports a value).
    public let lights: [Double]

    public init(ledCount: Int, subsection: Int, lamps: Int, rows: Int, color: Int, bit: Int, orientation: Int, perBar: Int, adjust: [UInt8], lights: [Double]) {
        self.ledCount = ledCount
        self.subsection = subsection
        self.lamps = lamps
        self.rows = rows
        self.color = color
        self.bit = bit
        self.orientation = orientation
        self.perBar = perBar
        self.adjust = adjust
        self.lights = lights
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
    public static let firmwareUpdateCommand: UInt8 = 0x15
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
    public static let binSendCommand: UInt8 = 0x38
    public static let setCoordinateCommand: UInt8 = 0x50
    public static let syncGroupCommand: UInt8 = 0x51
    public static let jointModeCommand: UInt8 = 0x52
    public static let selectDeviceCommand: UInt8 = 0x53
    public static let binParameterCommand: UInt8 = 0x39
    public static let noticeAudioCommand: UInt8 = 0x3a
    public static let transcodingCommand: UInt8 = 0x3b
    /// Factory Test window "Speed" query (`Protocol.GetSpeed`).
    public static let rotationSpeedCommand: UInt8 = 0xe0
    /// Factory Test window lamp test (`Protocol.LampTest`).
    public static let lampTestCommand: UInt8 = 0xe1
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

    /// Original `Send.GetSpeed`: a read-only rotation-speed query with no payload.
    /// Original `Send.LampTest`: 1 starts the LED test pattern, 0 ends it. The Test window powers the
    /// fan off (`0x17 0`) and waits 100 ms before each lamp-test command.
    public static func lampTestRequest(isOn: Bool) -> [UInt8] {
        frame(command: lampTestCommand, payload: [isOn ? 1 : 0])
    }

    /// Original Test window raw sender: hex bytes (spaces ignored) with the CRC-16 appended.
    /// Expects at least the header, command, and 2-byte length.
    public static func rawPacket(hex: String) -> [UInt8]? {
        let digits = hex.filter { !$0.isWhitespace }
        guard !digits.isEmpty, digits.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            guard let byte = UInt8(digits[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        guard bytes.count >= 4, bytes[0] == header else { return nil }
        let checksum = crc16(bytes)
        return bytes + [UInt8(checksum & 0xff), UInt8(checksum >> 8)]
    }

    /// Original `Send.FOTA`: announces a firmware payload of `length` bytes (file length minus the 8-byte
    /// header). The fan answers 0 when ready for the data channel and 2 when the upgrade completes.
    public static func firmwareUpdateRequest(length: Int) -> [UInt8]? {
        guard length > 0, length <= Int(Int32.max) else { return nil }
        let value = UInt32(length)
        return frame(command: firmwareUpdateCommand, payload: [
            UInt8(value & 0xff), UInt8((value >> 8) & 0xff), UInt8((value >> 16) & 0xff), UInt8(value >> 24)
        ])
    }

    // MARK: - Sync groups and splicing

    /// Original `Send.SetGroup`: group 0 (ungrouped) to 20; `isHost` only applies to a grouped fan.
    public static func syncGroupRequest(group: Int, isHost: Bool) -> [UInt8]? {
        guard (0...20).contains(group) else { return nil }
        return frame(command: syncGroupCommand, payload: [UInt8(group), group != 0 && isHost ? 1 : 0])
    }

    /// Original `Send.SetCoord`: the fan's splicing position (x, y as little-endian 16-bit), level, and model.
    public static func setCoordinateRequest(x: Int, y: Int, level: Int, model: Int) -> [UInt8] {
        let x16 = UInt16(truncatingIfNeeded: x), y16 = UInt16(truncatingIfNeeded: y)
        return frame(command: setCoordinateCommand, payload: [
            UInt8(x16 & 0xff), UInt8(x16 >> 8), UInt8(y16 & 0xff), UInt8(y16 >> 8),
            UInt8(truncatingIfNeeded: level), UInt8(truncatingIfNeeded: model)
        ])
    }

    /// Original `Send.JointModel`: splicing (joint) display mode on or off.
    public static func jointModeRequest(_ status: Int) -> [UInt8] {
        frame(command: jointModeCommand, payload: [UInt8(truncatingIfNeeded: status)])
    }

    /// Original `Send.SelectDevice`: 1 highlights the fan (used while pointing at it in a layout), 0 clears it.
    public static func selectDeviceRequest(isSelected: Bool) -> [UInt8] {
        frame(command: selectDeviceCommand, payload: [isSelected ? 1 : 0])
    }

    // MARK: - LED transcoding and bin transfer (content types 3 and 1)

    /// Original `Send.QueryTranscodingParameter`, sent at connect to content-type-3 fans.
    public static func transcodingQuery() -> [UInt8] { frame(command: transcodingCommand) }

    /// Original `Send.GetBinParam`, sent once to content-type-1 fans.
    public static func binParameterQuery() -> [UInt8] { frame(command: binParameterCommand) }

    /// Original `Send.NoticAudio`: sent after bin frames when no audio is available.
    public static func noticeAudioRequest() -> [UInt8] { frame(command: noticeAudioCommand) }

    /// Original `Send.BinSending`: name (20 UTF-8 bytes), frame duration in µs, frame count, audio flag,
    /// then a random key byte; bytes 4–32 are XORed with the key.
    public static func binSendRequest(name: String, frameDuration: Int, frames: Int, hasAudio: Bool, key: UInt8) -> [UInt8]? {
        guard key != 0, frames > 0, frameDuration >= 0 else { return nil }
        // TypeConversion.GetBytes(string, 20) truncates on a character boundary.
        var trimmed = name
        while trimmed.utf8.count > 20 { trimmed.removeLast() }
        let nameBytes = Array(trimmed.utf8)
        var payload = [UInt8](repeating: 0, count: 30)
        payload.replaceSubrange(0..<nameBytes.count, with: nameBytes)
        payload.replaceSubrange(20..<24, with: littleEndian32(frameDuration))
        payload.replaceSubrange(24..<28, with: littleEndian32(frames))
        payload[28] = hasAudio ? 1 : 0
        payload[29] = key
        for index in 0..<29 { payload[index] ^= key }
        return frame(command: binSendCommand, payload: payload)
    }

    public static func parseTranscoding(_ frame: [UInt8]) -> FanTranscoding? {
        guard frame.count >= 268, frame[0] == header, frame[1] == transcodingCommand else { return nil }
        let ledCount = Int(Int16(bitPattern: UInt16(frame[4]) | UInt16(frame[5]) << 8))
        let ratioEnd = min(frame.count, 268 + max(0, ledCount))
        return FanTranscoding(
            ledCount: ledCount,
            rows: Int(Int16(bitPattern: UInt16(frame[6]) | UInt16(frame[7]) << 8)),
            direction: Int(frame[8]),
            deliveryTimes: Int(frame[9]),
            lightBarCount: Int(frame[10]),
            quality: Int(frame[11]),
            adjust: Array(frame[12..<268]),
            ratio: Array(frame[268..<ratioEnd])
        )
    }

    public static func parseBinConfiguration(_ frame: [UInt8]) -> FanBinConfiguration? {
        guard frame.count >= 273, frame[0] == header, frame[1] == binParameterCommand else { return nil }
        let length = Int(Int16(bitPattern: UInt16(frame[2]) | UInt16(frame[3]) << 8))
        guard length + 6 == frame.count else { return nil }
        let lightCount = length - 266
        let ledCount = Int(Int16(bitPattern: UInt16(frame[4]) | UInt16(frame[5]) << 8))
        guard ledCount > 0 else { return nil }
        var lights = [Double](repeating: 1, count: ledCount)
        let offset = max(0, ledCount - lightCount)
        for index in 0..<max(0, lightCount) where offset + index < ledCount {
            lights[offset + index] = Double(frame[270 + index]) * 0.01
        }
        return FanBinConfiguration(
            ledCount: ledCount,
            subsection: Int(frame[6]),
            lamps: Int(frame[7]),
            rows: Int(Int16(bitPattern: UInt16(frame[8]) | UInt16(frame[9]) << 8)),
            color: Int(frame[10]),
            bit: Int(frame[11]),
            orientation: Int(frame[12]),
            perBar: Int(frame[13]),
            adjust: Array(frame[14..<270]),
            lights: lights
        )
    }

    private static func littleEndian32(_ value: Int) -> [UInt8] {
        let raw = UInt32(truncatingIfNeeded: value)
        return [UInt8(raw & 0xff), UInt8((raw >> 8) & 0xff), UInt8((raw >> 16) & 0xff), UInt8(raw >> 24)]
    }

    public static func rotationSpeedRequest() -> [UInt8] {
        frame(command: rotationSpeedCommand)
    }

    /// Original `Receive.GetSpeed`: payload bytes 0–3 are a little-endian value.
    public static func parseRotationSpeedValue(_ frame: [UInt8]) -> Int? {
        guard frame.count >= 10, frame[0] == header, frame[1] == rotationSpeedCommand else { return nil }
        return Int(Int32(bitPattern: UInt32(frame[4]) | UInt32(frame[5]) << 8 | UInt32(frame[6]) << 16 | UInt32(frame[7]) << 24))
    }

    /// The original Test window's display, `60,000,000 / value` (0 when the value is 0). It treats the
    /// value as microseconds per revolution, but on the user's fan the value is about 680 while running and
    /// falls to 0 after power-off, so it behaves like RPM and this formula does not apply.
    public static func parseRotationSpeedRPM(_ frame: [UInt8]) -> Int? {
        guard let value = parseRotationSpeedValue(frame) else { return nil }
        return value == 0 ? 0 : 60_000_000 / value
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
