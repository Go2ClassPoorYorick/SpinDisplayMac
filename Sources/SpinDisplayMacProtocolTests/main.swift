import Foundation
import SpinDisplayCore

@main
enum SpinDisplayProtocolTests {
    static func main() {
        testCRC16()
        testDiscoveryRequest()
        testPasswordRequest()
        testWiFiConfigurationRequest()
        testDeviceResponse()
        testControlRequests()
        testDeviceStatus()
        testConfigurationRequests()
        testFileManagementRequests()
        testFTLVValidation()
        testFileTransferRequests()
        testPlaylistRecords()
        testRecoveredSettingRequests()
        testChangeFileRequest()
        testDeviceInfo()
        testVersionAndStatusResponses()
        print("All SpinDisplay protocol tests passed.")
    }

    private static func testCRC16() {
        precondition(SpinDisplayProtocol.crc16(Array("123456789".utf8)) == 0x4b37)
    }

    private static func testDiscoveryRequest() {
        let packet = SpinDisplayProtocol.discoveryRequest(challenge: 0x12345678)
        precondition(Array(packet.prefix(8)) == [0x68, 0x00, 0x04, 0x00, 0x78, 0x56, 0x34, 0x12])
        precondition(packet.count == 10)
        let checksum = SpinDisplayProtocol.crc16(Array(packet.dropLast(2)))
        precondition(Array(packet.suffix(2)) == [UInt8(checksum & 0xff), UInt8(checksum >> 8)])
    }

    private static func testPasswordRequest() {
        let packet = SpinDisplayProtocol.passwordRequest(password: "12345678", challenge: 0x12345678)
        precondition(Array(packet[4..<12]) == [0x49, 0x64, 0x07, 0x26, 0x4d, 0x60, 0x03, 0x2a])
        precondition(packet[12] == 0)
        precondition(packet.count == 15)
    }

    private static func testWiFiConfigurationRequest() {
        let packet = SpinDisplayProtocol.wifiConfigurationRequest(ssid: "CatToys", password: "secret")
        precondition(packet?.count == 105)
        precondition(packet?[0] == 0x68)
        precondition(packet?[1] == SpinDisplayProtocol.wifiConfigurationCommand)
        precondition(packet?[2] == 99 && packet?[3] == 0)
        precondition(packet?[4] == 1)
        precondition(Array(packet![5..<12]) == Array("CatToys".utf8))
        precondition(packet?[12] == 0)
        precondition(Array(packet![38..<44]) == Array("secret".utf8))
        precondition(packet?[44] == 0)
        let checksum = SpinDisplayProtocol.crc16(Array(packet!.dropLast(2)))
        precondition(Array(packet!.suffix(2)) == [UInt8(checksum & 0xff), UInt8(checksum >> 8)])
        precondition(SpinDisplayProtocol.wifiConfigurationRequest(ssid: "", password: "") == nil)
        precondition(SpinDisplayProtocol.wifiConfigurationRequest(ssid: "network", password: String(repeating: "a", count: 65)) == nil)
    }

    private static func testDeviceResponse() {
        var payload = [UInt8](repeating: 0, count: 39)
        payload[0] = 0xff
        payload[1] = 1
        payload.replaceSubrange(2..<8, with: Array("Fan A".utf8) + [0])
        payload.replaceSubrange(27..<33, with: [0x10, 0x20, 0x30, 0x40, 0x50, 0x60])
        payload[33] = 7
        payload[34] = 12
        payload.replaceSubrange(35..<39, with: [192, 168, 1, 77])
        let response = SpinDisplayProtocol.frame(command: SpinDisplayProtocol.deviceResponseCommand, payload: payload)
        let device = SpinDisplayProtocol.parseDeviceResponse(
            response,
            sourceAddress: "192.168.1.1",
            challenge: 0x10203040
        )
        precondition(device?.name == "Fan A")
        precondition(device?.address == "192.168.1.1")
        precondition(device?.macAddress == "10:20:30:40:50:60")
        precondition(device?.deviceType == 7)
        precondition(device?.firmwareVersion == 12)
        precondition(device?.passwordProtected == true)
        precondition(device?.challenge == 0x10203040)
    }

    private static func testControlRequests() {
        let power = SpinDisplayProtocol.powerRequest(isOn: true)
        precondition(power[0] == 0x68 && power[1] == SpinDisplayProtocol.powerCommand)
        precondition(power[2] == 1 && power[3] == 0 && power[4] == 1)

        let brightness = SpinDisplayProtocol.brightnessRequest(level: 4)
        precondition(brightness[1] == SpinDisplayProtocol.brightnessCommand)
        precondition(brightness[4] == 4)

        let heartbeat = SpinDisplayProtocol.heartbeatRequest()
        precondition(heartbeat == SpinDisplayProtocol.frame(command: SpinDisplayProtocol.heartbeatCommand))
        precondition(heartbeat.count == 6)

        let playlist = SpinDisplayProtocol.playlistRequest()
        precondition(playlist == SpinDisplayProtocol.frame(command: SpinDisplayProtocol.playlistCommand))

        let play = SpinDisplayProtocol.playControlRequest(control: 1, index: 3)
        precondition(play[1] == SpinDisplayProtocol.playControlCommand)
        precondition(Array(play[4..<6]) == [1, 3])
        let repeatRequests = SpinDisplayProtocol.repeatFileRequests(index: 3)
        precondition(repeatRequests.count == 2)
        precondition(Array(repeatRequests[0][4..<6]) == [2, 3])
        precondition(Array(repeatRequests[1][4..<6]) == [1, 3])

        let playbackStatusQuery = SpinDisplayProtocol.playControlRequest(control: 0, index: 0)
        precondition(playbackStatusQuery[1] == SpinDisplayProtocol.playControlCommand)
        precondition(Array(playbackStatusQuery[4..<6]) == [0, 0])
        precondition(SpinDisplayProtocol.playbackStatusRequest() == playbackStatusQuery)
        let playbackResponse = SpinDisplayProtocol.frame(
            command: SpinDisplayProtocol.playControlCommand,
            payload: [1, 3]
        )
        let playbackStatus = SpinDisplayProtocol.parsePlaybackStatus(playbackResponse)
        precondition(playbackStatus == PlaybackStatusResponse(responseField: 1, playlistSlot: 3))
        let idleResponse = SpinDisplayProtocol.frame(
            command: SpinDisplayProtocol.playControlCommand,
            payload: [0, 0]
        )
        precondition(
            SpinDisplayProtocol.parsePlaybackStatus(idleResponse)
                == PlaybackStatusResponse(responseField: 0, playlistSlot: 0)
        )
    }

    private static func testConfigurationRequests() {
        let deviceName = SpinDisplayProtocol.deviceNameRequest("Fan A")
        precondition(deviceName?.count == 32)
        precondition(deviceName?[1] == SpinDisplayProtocol.deviceNameCommand)
        precondition(deviceName?[2] == 26 && deviceName?[3] == 0)
        precondition(Array(deviceName![4..<9]) == Array("Fan A".utf8))
        precondition(deviceName?[28] == 0)
        precondition(deviceName?[29] == 0)
        precondition(SpinDisplayProtocol.deviceNameRequest(String(repeating: "x", count: 25)) == nil)

        let positiveAngle = SpinDisplayProtocol.angleRequest(degrees: 90)
        precondition(positiveAngle?[1] == SpinDisplayProtocol.angleCommand)
        precondition(Array(positiveAngle![4..<6]) == [90, 0])
        let negativeAngle = SpinDisplayProtocol.angleRequest(degrees: -90)
        precondition(Array(negativeAngle![4..<6]) == [118, 2])
        precondition(SpinDisplayProtocol.angleRequest(degrees: 361) == nil)

        let schedule = SpinDisplayProtocol.scheduleRequest(
            autoOn: true,
            shutdownEnabled: true,
            bootEnabled: false,
            shutdownHour: 22,
            shutdownMinute: 30,
            bootHour: 7,
            bootMinute: 15
        )
        precondition(schedule?[1] == SpinDisplayProtocol.scheduleCommand)
        precondition(Array(schedule![4..<11]) == [1, 1, 0, 22, 30, 7, 15])
        precondition(SpinDisplayProtocol.scheduleRequest(
            autoOn: false,
            shutdownEnabled: false,
            bootEnabled: false,
            shutdownHour: 24,
            shutdownMinute: 0,
            bootHour: 0,
            bootMinute: 0
        ) == nil)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(
            year: 2026,
            month: 10,
            day: 30,
            hour: 9,
            minute: 38,
            second: 5
        ))!
        let clock = SpinDisplayProtocol.clockSyncRequest(date: date, calendar: calendar)
        precondition(clock[1] == SpinDisplayProtocol.clockCommand)
        precondition(Array(clock[4..<12]) == [1, 26, 10, 30, 5, 9, 38, 5])

        let bluetoothSwitch = SpinDisplayProtocol.bleVolumeRequest(control: 1)
        precondition(bluetoothSwitch[1] == SpinDisplayProtocol.bleVolumeCommand)
        precondition(Array(bluetoothSwitch[4..<6]) == [1, 0])
        let bluetoothVolume = SpinDisplayProtocol.bleVolumeRequest(control: 3, volume: 31)
        precondition(Array(bluetoothVolume[4..<6]) == [3, 31])
    }

    private static func testFileManagementRequests() {
        let delete = SpinDisplayProtocol.deleteFileRequest(index: 4)
        precondition(delete?[1] == SpinDisplayProtocol.deleteFileCommand)
        precondition(Array(delete![4..<6]) == [0, 4])
        precondition(SpinDisplayProtocol.deleteFileRequest(index: 255) == nil)

        let move = SpinDisplayProtocol.moveFileRequest(from: 4, to: 2)
        precondition(move?[1] == SpinDisplayProtocol.moveFileCommand)
        precondition(Array(move![4..<6]) == [5, 3])
        let lastMove = SpinDisplayProtocol.moveFileRequest(from: 254, to: 0)
        precondition(Array(lastMove![4..<6]) == [255, 1])
        precondition(SpinDisplayProtocol.moveFileRequest(from: -1, to: 0) == nil)
        precondition(SpinDisplayProtocol.moveFileRequest(from: 255, to: 0) == nil)
    }

    private static func testFTLVValidation() {
        let actualLength = 525
        var header = [UInt8](repeating: 0, count: 512)
        header.replaceSubrange(0..<3, with: Array("FTL".utf8))
        header[3] = 7
        header[4] = 1
        setLittleEndian(actualLength, in: &header, at: 8)
        setLittleEndian(512, in: &header, at: 12)
        setLittleEndian(3, in: &header, at: 16)
        setLittleEndian(2, in: &header, at: 20)
        setLittleEndian(8, in: &header, at: 24)
        setLittleEndian(500_000, in: &header, at: 36)
        setLittleEndian(2, in: &header, at: 40)

        let info = FTLVFileInfo.parse(header: header, actualFileLength: actualLength)
        precondition(info?.deviceType == 7)
        precondition(info?.durationSeconds == 1)
        precondition(info?.isCompatible(with: 7) == true)
        precondition(info?.isCompatible(with: 25) == false)
        precondition(info?.isCompatible(with: 26) == false)
        precondition(info?.isCompatible(with: 8) == true)
        precondition(FTLVFileInfo.parse(header: Array(header.prefix(47)), actualFileLength: actualLength) == nil)
        precondition(FTLVFileInfo.parse(header: header, actualFileLength: actualLength + 1) == nil)

        var alternateVersion = header
        alternateVersion[4] = 2
        precondition(FTLVFileInfo.parse(header: alternateVersion, actualFileLength: actualLength) != nil)
        var specialFileType = header
        specialFileType[3] = 25
        let specialInfo = FTLVFileInfo.parse(header: specialFileType, actualFileLength: actualLength)
        precondition(specialInfo?.isCompatible(with: 7) == false)
        precondition(specialInfo?.isCompatible(with: 25) == true)
        precondition(specialInfo?.isCompatible(with: 26) == false)

        var invalidHeader = header
        invalidHeader[0] = 0
        precondition(FTLVFileInfo.parse(header: invalidHeader, actualFileLength: actualLength) == nil)
        invalidHeader = header
        setLittleEndian(0, in: &invalidHeader, at: 12)
        precondition(FTLVFileInfo.parse(header: invalidHeader, actualFileLength: actualLength) == nil)
        invalidHeader = header
        setLittleEndian(Int.max, in: &invalidHeader, at: 8)
        precondition(FTLVFileInfo.parse(header: invalidHeader, actualFileLength: actualLength) == nil)
    }

    private static func testFileTransferRequests() {
        let request = SpinDisplayProtocol.fileSendRequest(
            name: "demo",
            repeating: 1,
            id: "ABCDEFGH",
            type: 2
        )
        precondition(request?.count == 120)
        precondition(request?[1] == SpinDisplayProtocol.fileSendCommand)
        precondition(request?[2] == 114 && request?[3] == 0)
        precondition(Array(request![4..<8]) == Array("demo".utf8))
        precondition(request?[105] == 1)
        precondition(Array(request![106..<114]) == Array("ABCDEFGH".utf8))
        precondition(request?[115] == 2)
        precondition(Array(request![116..<118]) == [0, 2])
        precondition(SpinDisplayProtocol.fileSendRequest(
            name: String(repeating: "x", count: 101),
            repeating: 1,
            id: "ABCDEFGH",
            type: 2
        ) == nil)
        precondition(SpinDisplayProtocol.fileSendRequest(
            name: "demo",
            repeating: 1,
            id: "SHORT",
            type: 2
        ) == nil)

        let header = [UInt8](repeating: 0x5a, count: 48)
        let headerRequest = SpinDisplayProtocol.fileHeaderSendRequest(header: header)
        precondition(headerRequest?.count == 54)
        precondition(headerRequest?[1] == SpinDisplayProtocol.fileHeaderSendCommand)
        precondition(Array(headerRequest![4..<52]) == header)
        precondition(SpinDisplayProtocol.fileHeaderSendRequest(header: Array(header.prefix(47))) == nil)

        let readyResponse = SpinDisplayProtocol.frame(command: SpinDisplayProtocol.fileSendCommand, payload: [0])
        let busyResponse = SpinDisplayProtocol.frame(command: SpinDisplayProtocol.fileSendCommand, payload: [6])
        let completeResponse = SpinDisplayProtocol.frame(command: SpinDisplayProtocol.fileSendCommand, payload: [255])
        precondition(SpinDisplayProtocol.parseFileSendStatus(readyResponse) == 0)
        precondition(SpinDisplayProtocol.parseFileSendStatus(busyResponse) == 6)
        precondition(SpinDisplayProtocol.parseFileSendStatus(completeResponse) == 255)
        precondition(SpinDisplayProtocol.parseFileSendStatus([0x68, 0x30, 0, 0, 0, 0]) == nil)
    }

    private static func setLittleEndian(_ value: Int, in bytes: inout [UInt8], at offset: Int) {
        let value = UInt32(truncatingIfNeeded: value)
        bytes[offset] = UInt8(value & 0xff)
        bytes[offset + 1] = UInt8((value >> 8) & 0xff)
        bytes[offset + 2] = UInt8((value >> 16) & 0xff)
        bytes[offset + 3] = UInt8((value >> 24) & 0xff)
    }

    private static func testDeviceStatus() {
        var response = [UInt8](repeating: 0, count: 330)
        response[0] = SpinDisplayProtocol.header
        response[1] = SpinDisplayProtocol.parameterCommand
        response[68] = 1
        response[294] = 5
        let status = SpinDisplayProtocol.parseDeviceStatus(response)
        precondition(status?.isOn == true)
        precondition(status?.brightness == 5)
        precondition(SpinDisplayProtocol.parseDeviceStatus(Array(response.prefix(329))) == nil)
    }

    private static func testPlaylistRecords() {
        func makeRecord(name: String, fileID: String, type: UInt8, duration: UInt16) -> [UInt8] {
            var record = [UInt8](repeating: 0, count: 180)
            record.replaceSubrange(0..<name.utf8.count, with: Array(name.utf8))
            record[101] = type
            record[104] = UInt8(duration & 0xff)
            record[105] = UInt8(duration >> 8)
            record[106] = 1
            record[107] = 1
            record.replaceSubrange(108..<116, with: Array(fileID.utf8))
            record[117] = 3
            record.replaceSubrange(118..<123, with: [0x03, 8, 0, 12, 30])
            return record
        }

        let files = SpinDisplayProtocol.parsePlaylistRecords(
            makeRecord(name: "demo.gif", fileID: "FILE0001", type: 2, duration: 300)
                + makeRecord(name: "second.gif", fileID: "FILE0002", type: 4, duration: 120)
        )
        precondition(files.count == 2)
        precondition(files[0].name == "demo.gif")
        precondition(files[0].type == 2)
        precondition(files[0].durationSeconds == 300)
        precondition(files[0].repeating == 1 && files[0].isShown == 1)
        precondition(files[0].fileID == "FILE0001" && files[0].status == 3)
        precondition(files[1].name == "second.gif")
        precondition(files[1].type == 4)
        precondition(files[1].durationSeconds == 120)
        precondition(files[1].fileID == "FILE0002")
        precondition(files[0].timeSlots.count == 8)
        precondition(files[0].timeSlots[0] == PlaybackTimeSlot(isEnabled: true, weekdays: 0x02, startHour: 8, startMinute: 0, endHour: 12, endMinute: 30))
        precondition(files[0].timeSlots[1] == .empty)
        precondition(files[0].displayMode == .hidden)
    }

    // Expected bytes follow the original Send.* builders' array layouts in the recovered IL.
    private static func assertFrame(_ packet: [UInt8]?, command: UInt8, payloadLength: Int) {
        guard let packet else { preconditionFailure("missing packet") }
        precondition(packet.count == payloadLength + 6)
        precondition(packet[0] == 0x68 && packet[1] == command)
        precondition(Int(packet[2]) | (Int(packet[3]) << 8) == payloadLength)
        let checksum = SpinDisplayProtocol.crc16(Array(packet.dropLast(2)))
        precondition(Array(packet.suffix(2)) == [UInt8(checksum & 0xff), UInt8(checksum >> 8)])
    }

    private static func testRecoveredSettingRequests() {
        let highlight = SpinDisplayProtocol.displayModeRequest(.highlight)
        assertFrame(highlight, command: 0x24, payloadLength: 1)
        precondition(highlight[4] == 0)
        precondition(SpinDisplayProtocol.displayModeRequest(.trueColor)[4] == 1)

        let thirdParty = SpinDisplayProtocol.thirdPartyControlRequest(isEnabled: true)
        assertFrame(thirdParty, command: 0x06, payloadLength: 1)
        precondition(thirdParty[4] == 1)
        precondition(SpinDisplayProtocol.thirdPartyControlRequest(isEnabled: false)[4] == 0)

        let login = SpinDisplayProtocol.loginVerificationRequest(isEnabled: true, password: "1234")
        assertFrame(login, command: 0x05, payloadLength: 10)
        precondition(login![4] == 1)
        precondition(Array(login![5..<9]) == Array("1234".utf8))
        precondition(login![9..<14].allSatisfy { $0 == 0 })
        let disabled = SpinDisplayProtocol.loginVerificationRequest(isEnabled: false, password: "")
        assertFrame(disabled, command: 0x05, payloadLength: 10)
        precondition(disabled![4] == 0)
        precondition(SpinDisplayProtocol.loginVerificationRequest(isEnabled: true, password: "") == nil)
        precondition(SpinDisplayProtocol.loginVerificationRequest(isEnabled: true, password: "123456789") == nil)

        let deleteAll = SpinDisplayProtocol.deleteAllFilesRequest()
        assertFrame(deleteAll, command: 0x32, payloadLength: 2)
        precondition(Array(deleteAll[4..<6]) == [1, 0])

        precondition(SpinDisplayProtocol.fileTransferErrorDescription(status: 1) != nil)
        precondition(SpinDisplayProtocol.fileTransferErrorDescription(status: 5) != nil)
        precondition(SpinDisplayProtocol.fileTransferErrorDescription(status: 6) == nil)
    }

    private static func testChangeFileRequest() {
        var slots = Array(repeating: PlaybackTimeSlot.empty, count: 8)
        slots[0] = PlaybackTimeSlot(isEnabled: true, weekdays: 0x02 | 0x80, startHour: 9, startMinute: 30, endHour: 17, endMinute: 45)
        slots[7] = PlaybackTimeSlot(isEnabled: false, weekdays: 0x40, startHour: 1, startMinute: 2, endHour: 3, endMinute: 4)
        let packet = SpinDisplayProtocol.changeFileRequest(
            index: 2, name: "demo", repeatCount: 7, displayMode: .scheduled, timeSlots: slots
        )
        // Original AlterFile: 150-byte array, length 0x90, [4]=one-based slot, [5..104]=name,
        // [106]=repeat, [107]=show, [108 + 5i]=time windows.
        assertFrame(packet, command: 0x34, payloadLength: 144)
        let p = packet!
        precondition(p[4] == 3)
        precondition(Array(p[5..<9]) == Array("demo".utf8) && p[9] == 0)
        precondition(p[106] == 7 && p[107] == 2)
        precondition(Array(p[108..<113]) == [0x83, 9, 30, 17, 45])
        precondition(Array(p[143..<148]) == [0x40, 1, 2, 3, 4])
        precondition(SpinDisplayProtocol.changeFileRequest(
            index: 0, name: "", repeatCount: 1, displayMode: .allDay, timeSlots: slots) == nil)
        precondition(SpinDisplayProtocol.changeFileRequest(
            index: 0, name: "x", repeatCount: 1, displayMode: .allDay, timeSlots: Array(slots.prefix(7))) == nil)

        precondition(slots[0].isValid)
        precondition(!PlaybackTimeSlot(isEnabled: true, weekdays: 0, startHour: 10, startMinute: 0, endHour: 10, endMinute: 0).isValid)
        let decoded = PlaybackTimeSlot(encoded: [0x83, 9, 30, 17, 45][...])
        precondition(decoded == slots[0])
    }

    private static func testDeviceInfo() {
        // Offsets follow the original Receive.AnalyticInfo walk over the 0x12 response.
        var frame = [UInt8](repeating: 0, count: 330)
        frame[0] = 0x68
        frame[1] = SpinDisplayProtocol.parameterCommand
        frame.replaceSubrange(4..<8, with: [0x00, 0x04, 0x00, 0x00])   // total 1024
        frame.replaceSubrange(8..<12, with: [0x00, 0x01, 0x00, 0x00])  // available 256
        frame.replaceSubrange(12..<18, with: [0xAB, 0xCD, 0xEF, 0x01, 0x23, 0x45])
        frame.replaceSubrange(18..<22, with: Array("Desk".utf8))
        frame.replaceSubrange(43..<47, with: Array("F20A".utf8))
        frame[68] = 1
        frame[69] = 23; frame[70] = 6; frame[71] = 15
        frame[72] = 0
        frame.replaceSubrange(74..<76, with: [0x41, 0x00])
        frame[80] = 0b0000_0100
        frame[81] = 0b0000_0001
        frame.replaceSubrange(142..<146, with: Array("Home".utf8))
        frame[249] = 1
        frame[251] = 1
        frame[252] = 0
        frame[268] = 1; frame[269] = 0
        frame[270] = 22; frame[271] = 15; frame[272] = 7; frame[273] = 5
        frame[274] = 1
        frame[276] = 0x80 | 12
        frame.replaceSubrange(292..<294, with: [0xC6, 0x02])  // 710 -> -10 degrees
        frame[294] = 4
        frame[295] = 1
        frame.replaceSubrange(316..<318, with: [0xFF, 0xFF])
        frame[322] = 3

        guard let info = SpinDisplayProtocol.parseDeviceInfo(frame) else { preconditionFailure("device info") }
        precondition(info.sdCapacityTotal == 1024 && info.sdCapacityAvailable == 256)
        precondition(info.sdUsablePercent == 25)
        precondition(info.serialNumber == "AB-CD-EF-01-23-45")
        precondition(info.deviceName == "Desk" && info.deviceModel == "F20A")
        precondition(info.isOn)
        precondition(info.factoryDate.year == 2023 && info.factoryDate.month == 6 && info.factoryDate.day == 15)
        precondition(info.maxFPS == 20)
        precondition(info.diameter == 65)
        precondition(info.imageSize == 672 && info.imageWidth == 672)
        precondition(info.restrictions == [.timingPlay, .voice])
        precondition(info.routerName == "Home" && info.isRouterConnected)
        precondition(info.isLoginVerificationEnabled && !info.isThirdPartyControlEnabled)
        precondition(info.isShutdownScheduled && !info.isBootScheduled)
        precondition(info.shutdownHour == 22 && info.shutdownMinute == 15 && info.bootHour == 7 && info.bootMinute == 5)
        precondition(info.isAutoOn)
        precondition(info.isBluetoothEnabled && info.volume == 12)
        precondition(info.angleDegrees == -10)
        precondition(info.brightness == 4 && info.displayMode == 1)
        precondition(info.coordinateX == -1 && info.groupNumber == 3)
        precondition(SpinDisplayProtocol.parseDeviceInfo(Array(frame.prefix(329))) == nil)
    }

    private static func testVersionAndStatusResponses() {
        let version = SpinDisplayProtocol.frame(command: SpinDisplayProtocol.versionCommand, payload: [2, 15, 1, 3])
        let parsed = SpinDisplayProtocol.parseVersion(version)
        precondition(parsed == FanVersionInfo(firmware: 215, model: 1, agreement: 3))

        let ack = SpinDisplayProtocol.frame(command: SpinDisplayProtocol.displayModeCommand, payload: [0])
        precondition(SpinDisplayProtocol.parseSettingStatus(ack, command: SpinDisplayProtocol.displayModeCommand) == 0)
        precondition(SpinDisplayProtocol.parseSettingStatus(ack, command: SpinDisplayProtocol.changeFileCommand) == nil)
    }
}
