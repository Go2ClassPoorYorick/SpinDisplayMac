import CoreGraphics
import Foundation
import ImageIO
import SpinDisplayCore
import SpinDisplayMedia

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
        testFTLVWriter()
        testFTLVTimingAndAudio()
        testBaselineJPEGEncoder()
        testLEDTranscoding()
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
        precondition(Array(repeatRequests[0][4..<6]) == [1, 3])
        precondition(Array(repeatRequests[1][4..<6]) == [2, 3])

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
        precondition(Array(delete![4..<6]) == [0, 5])
        precondition(Array(SpinDisplayProtocol.deleteFileRequest(index: 0)![4..<6]) == [0, 1])
        precondition(Array(SpinDisplayProtocol.deleteFileRequest(index: 254)![4..<6]) == [0, 255])
        precondition(SpinDisplayProtocol.deleteFileRequest(index: 255) == nil)
        // Original Settings "Search and connect" Bluetooth-speaker button: BleVolumeSetting(2, 0).
        precondition(Array(SpinDisplayProtocol.bleVolumeRequest(control: 2)[4..<6]) == [2, 0])

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

        // Original Send.Reset(false) = 0x55; Send.MatchCode(0/1); Send.LanChange(0, name, password).
        let reset = SpinDisplayProtocol.factoryResetRequest()
        assertFrame(reset, command: 0x19, payloadLength: 1)
        precondition(reset[4] == 0x55 && SpinDisplayProtocol.factoryResetRequest(clearContent: true)[4] == 0x58)
        assertFrame(SpinDisplayProtocol.remoteMatchRequest(start: true), command: 0x22, payloadLength: 1)
        precondition(SpinDisplayProtocol.remoteMatchRequest(start: true)[4] == 0 && SpinDisplayProtocol.remoteMatchRequest(start: false)[4] == 1)
        let leave = SpinDisplayProtocol.routerDisconnectRequest(currentSSID: "Home")
        assertFrame(leave, command: 0x07, payloadLength: 99)
        precondition(leave[4] == 0 && Array(leave[5..<9]) == Array("Home".utf8) && leave[9..<103].allSatisfy { $0 == 0 })

        // Original Send.Projection(1/0) and ProjectionSend's FA + 3-byte little-endian length prefix.
        let projectionOn = SpinDisplayProtocol.projectionRequest(isOn: true)
        assertFrame(projectionOn, command: 0x37, payloadLength: 1)
        precondition(projectionOn[4] == 1 && SpinDisplayProtocol.projectionRequest(isOn: false)[4] == 0)
        precondition(SpinDisplayProtocol.projectionFrameHeader(length: 0x012345) == [0xfa, 0x45, 0x23, 0x01])
        precondition(SpinDisplayProtocol.projectionFrameHeader(length: 1 << 24) == nil)

        // Original Send.GetSpeed (no payload) and TestWindow's 60,000,000 / period display.
        assertFrame(SpinDisplayProtocol.rotationSpeedRequest(), command: 0xe0, payloadLength: 0)
        let speed = SpinDisplayProtocol.frame(command: 0xe0, payload: [0x20, 0x4e, 0x00, 0x00])  // 20,000 µs
        precondition(SpinDisplayProtocol.parseRotationSpeedRPM(speed) == 3000)
        precondition(SpinDisplayProtocol.parseRotationSpeedRPM(SpinDisplayProtocol.frame(command: 0xe0, payload: [0, 0, 0, 0])) == 0)
        precondition(SpinDisplayProtocol.parseRotationSpeedRPM(SpinDisplayProtocol.frame(command: 0xe0, payload: [1])) == nil)

        // Original Send.LampTest and the Test window's raw sender (CRC appended).
        assertFrame(SpinDisplayProtocol.lampTestRequest(isOn: true), command: 0xe1, payloadLength: 1)
        precondition(SpinDisplayProtocol.lampTestRequest(isOn: true)[4] == 1 && SpinDisplayProtocol.lampTestRequest(isOn: false)[4] == 0)
        precondition(SpinDisplayProtocol.rawPacket(hex: "68 11 00 00") == SpinDisplayProtocol.frame(command: 0x11))
        precondition(SpinDisplayProtocol.rawPacket(hex: "68 17 01 00 01") == SpinDisplayProtocol.powerRequest(isOn: true))
        precondition(SpinDisplayProtocol.rawPacket(hex: "68 1") == nil && SpinDisplayProtocol.rawPacket(hex: "11 00 00 00") == nil)
        precondition(SpinDisplayProtocol.rawPacket(hex: "68 zz 00 00") == nil)

        // Original FOTA: 4-byte little-endian payload length; .POVC header per App.initPackage.
        let fota = SpinDisplayProtocol.firmwareUpdateRequest(length: 57_120)
        assertFrame(fota, command: 0x15, payloadLength: 4)
        precondition(Array(fota![4..<8]) == [0x20, 0xdf, 0x00, 0x00])
        precondition(SpinDisplayProtocol.firmwareUpdateRequest(length: 0) == nil)
        let bundled = FirmwarePackageInfo.parse(header: [0xff, 0xaa, 0x01, 0x30, 0x20, 0xdf, 0x00, 0x00], fileLength: 57_128)
        precondition(bundled == FirmwarePackageInfo(model: 1, version: 148, payloadLength: 57_120))
        precondition(FirmwarePackageInfo.parse(header: [0xff, 0x03, 0x02, 0x05, 0, 0, 0, 0], fileLength: 100)?.model == 3)
        precondition(FirmwarePackageInfo.parse(header: [0x00, 0xaa, 0x01, 0x30, 0, 0, 0, 0], fileLength: 100) == nil)
        precondition(bundled!.isAutomaticUpdate(forModel: 1, firmware: 147))
        precondition(!bundled!.isAutomaticUpdate(forModel: 1, firmware: 148))
        precondition(!bundled!.isAutomaticUpdate(forModel: 2, firmware: 100))

        // Original Send.SetGroup / SetCoord / JointModel / SelectDevice.
        let group = SpinDisplayProtocol.syncGroupRequest(group: 3, isHost: true)
        assertFrame(group, command: 0x51, payloadLength: 2)
        precondition(Array(group![4..<6]) == [3, 1])
        precondition(Array(SpinDisplayProtocol.syncGroupRequest(group: 0, isHost: true)![4..<6]) == [0, 0])
        precondition(SpinDisplayProtocol.syncGroupRequest(group: 21, isHost: false) == nil)
        let coordinate = SpinDisplayProtocol.setCoordinateRequest(x: 300, y: -2, level: 1, model: 2)
        assertFrame(coordinate, command: 0x50, payloadLength: 6)
        precondition(Array(coordinate[4..<10]) == [0x2c, 0x01, 0xfe, 0xff, 1, 2])
        precondition(Array(SpinDisplayProtocol.jointModeRequest(1)[0..<5]) == [0x68, 0x52, 1, 0, 1])
        precondition(SpinDisplayProtocol.selectDeviceRequest(isSelected: true)[4] == 1)

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

    // Layout follows the original FTLV class: 512-byte header area, 4-byte-padded blocks,
    // index header A5 00…, (offset, unpadded length) pairs, totaltime in seconds.
    private static func testFTLVWriter() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("spindisplay-test-\(UUID().uuidString).ftlv")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try! FTLVWriter(url: url, magic: .standard, frameDuration: 50_000)
        try! writer.appendVideoFrame(Data([0xff, 0xd8, 1, 2, 3, 0xff, 0xd9]), duration: 600_000)
        try! writer.appendVideoFrame(Data([0xff, 0xd8, 0xff, 0xd9]), duration: 600_000)
        try! writer.appendAudio(Data([128, 129, 130]))
        let header = try! writer.finish()
        precondition((try? writer.finish()) == nil)

        let bytes = [UInt8](try! Data(contentsOf: url))
        precondition(header.count == 48)
        precondition(Array(bytes.prefix(48)) == header)
        precondition(bytes[48..<512].allSatisfy { $0 == 0 })
        precondition(Array(header[0..<8]) == Array("FTLV".utf8) + [1, 0, 0, 0])
        // frames: 7 -> 8 bytes at 512, 4 bytes at 520; audio: 3 -> 4 bytes at 524; index at 528
        precondition(bytes.count == 528 + 8 + 3 * 8)
        precondition(Array(bytes[512..<520]) == [0xff, 0xd8, 1, 2, 3, 0xff, 0xd9, 0])
        precondition(Array(bytes[524..<528]) == [128, 129, 130, 0])
        precondition(Array(bytes[528..<536]) == [0xa5, 0, 0, 0, 0, 0, 0, 0])
        precondition(Array(bytes[536..<560]) == [0, 2, 0, 0, 7, 0, 0, 0, 8, 2, 0, 0, 4, 0, 0, 0, 12, 2, 0, 0, 3, 0, 0, 0])

        guard let contents = FTLVContents.parse(bytes) else { preconditionFailure("FTLV reread") }
        precondition(contents.info.fileLength == 560 && contents.info.headerLength == 512)
        precondition(contents.info.dataLength == 12 && contents.info.audioLength == 4 && contents.info.indexLength == 32)
        precondition(contents.info.frameDuration == 50_000 && contents.info.frameCount == 2)
        precondition(contents.totalSeconds == 1)
        precondition(contents.videoBlocks.count == 2)
        precondition(contents.audioBlock == FTLVContents.Block(offset: 524, length: 3))
        precondition(contents.info.isCompatible(with: 1))

        let typedURL = url.deletingLastPathComponent().appendingPathComponent("spindisplay-typed-\(UUID().uuidString).ftlv")
        defer { try? FileManager.default.removeItem(at: typedURL) }
        let typed = try! FTLVWriter(url: typedURL, magic: .deviceTyped(7), frameDuration: FTLVWriter.stillImageFrameDuration)
        try! typed.appendVideoFrame(Data([1, 2, 3, 4]), duration: FTLVWriter.stillImageFrameDuration)
        let typedHeader = try! typed.finish()
        precondition(Array(typedHeader[0..<4]) == Array("FTL".utf8) + [7])
        precondition(Array(typedHeader[36..<48]) == [0x80, 0x96, 0x98, 0, 1, 0, 0, 0, 10, 0, 0, 0])
    }

    private static func testFTLVTimingAndAudio() {
        // SendWindow: min(source fps, max_fps), 20 outside 1...60; TcpServer: 1000 / (1000 / fps).
        precondition(FTLVTiming.videoFPS(sourceFPS: 29.97, maxFPS: 20) == 20)
        precondition(FTLVTiming.videoFPS(sourceFPS: 12, maxFPS: 20) == 12)
        precondition(FTLVTiming.videoFPS(sourceFPS: 30, maxFPS: 0) == 20)
        precondition(FTLVTiming.videoFPS(sourceFPS: 0.5, maxFPS: 20) == 20)
        precondition(FTLVTiming.effectiveFPS(24) == 24 && FTLVTiming.frameDuration(fps: 24) == 41_666)
        precondition(FTLVTiming.effectiveFPS(7) == 7)
        precondition(FTLVTiming.frameDuration(fps: 20) == 50_000)
        precondition(FTLVWriter.paddedLength(0) == 0 && FTLVWriter.paddedLength(5) == 8 && FTLVWriter.paddedLength(8) == 8)

        // FFmpeg S16 -> U8: (sample >> 8) + 128
        precondition(MediaConverter.pcm16ToUnsigned8([0x00, 0x00, 0xff, 0x7f, 0x00, 0x80, 0xff, 0xff]) == [128, 255, 0, 127])

        let fill = MediaConverter.cropSquare(width: 1920, height: 1080, framing: .fill)
        precondition(fill == CGRect(x: 420, y: 0, width: 1080, height: 1080))
        let fit = MediaConverter.cropSquare(width: 1920, height: 1080, framing: .fit)
        precondition(fit == CGRect(x: 0, y: -420, width: 1920, height: 1920))
        // Crop: default equals the original fill; zoom shrinks the circle; center is a top-left fraction.
        precondition(MediaConverter.cropRect(width: 1920, height: 1080, crop: .init()) == fill)
        precondition(MediaConverter.cropRect(width: 1920, height: 1080, crop: .init(framing: .fit)) == fit)
        precondition(MediaConverter.cropRect(width: 400, height: 200, crop: .init(zoom: 2, centerX: 0.25, centerY: 0.25))
            == CGRect(x: 50, y: 0, width: 100, height: 100))
        precondition(MediaConverter.cropRect(width: 400, height: 200, crop: .init(zoom: 100)).width == 200 / 20)
        precondition(MediaConverter.unsupportedReason(contentType: 0, hasTranscoding: false, hasBinConfiguration: false) == nil)
        precondition(MediaConverter.unsupportedReason(contentType: 3, hasTranscoding: false, hasBinConfiguration: false) != nil)
        precondition(MediaConverter.unsupportedReason(contentType: 3, hasTranscoding: true, hasBinConfiguration: false) == nil)
        precondition(MediaConverter.unsupportedReason(contentType: 1, hasTranscoding: false, hasBinConfiguration: false) != nil)
        precondition(MediaConverter.unsupportedReason(contentType: 1, hasTranscoding: false, hasBinConfiguration: true) == nil)

        // Splicing: two 100-unit fans side by side over a 400×200 source → each gets one 200×200 half.
        let splice = MediaConverter.spliceCrops(
            circles: [(id: "a", center: CGPoint(x: 50, y: 50), diameter: 100), (id: "b", center: CGPoint(x: 150, y: 50), diameter: 100)],
            sourceWidth: 400, sourceHeight: 200
        )
        precondition(MediaConverter.cropRect(width: 400, height: 200, crop: splice["a"]!) == CGRect(x: 0, y: 0, width: 200, height: 200))
        precondition(MediaConverter.cropRect(width: 400, height: 200, crop: splice["b"]!) == CGRect(x: 200, y: 0, width: 200, height: 200))

        // Original trims to whole seconds; holding the last frame rounds up instead.
        precondition(MediaConverter.availableSeconds(duration: 7.152, holdLastFrame: false) == 7)
        precondition(MediaConverter.availableSeconds(duration: 7.152, holdLastFrame: true) == 8)
        precondition(MediaConverter.availableSeconds(duration: 7.0004, holdLastFrame: true) == 7)
        precondition(MediaConverter.availableSeconds(duration: 0.4, holdLastFrame: false) == 1)
        precondition(MediaConverter.availableSeconds(duration: .nan, holdLastFrame: true) == 1)
    }

    // The original encodes frames with libjpeg-turbo: baseline, 4:4:4, quality 80, JFIF only, no restarts.
    private static func testBaselineJPEGEncoder() {
        precondition(BaselineJPEGEncoder.scaledTable(BaselineJPEGEncoder.standardLuminance, quality: 80).prefix(3) == [6, 4, 4])
        precondition(BaselineJPEGEncoder.scaledTable(BaselineJPEGEncoder.standardLuminance, quality: 50) == BaselineJPEGEncoder.standardLuminance)
        precondition(BaselineJPEGEncoder.acLuminance.values.count == 162 && BaselineJPEGEncoder.acChrominance.values.count == 162)

        let width = 37, height = 21  // not multiples of 8, to exercise edge padding
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                pixels[offset] = UInt8(x * 255 / (width - 1))
                pixels[offset + 1] = UInt8(y * 255 / (height - 1))
                pixels[offset + 2] = UInt8((x + y) % 2 == 0 ? 200 : 40)
            }
        }
        let jpeg = [UInt8](BaselineJPEGEncoder.encode(rgba: pixels, width: width, height: height, quality: 80))

        var markers: [UInt8] = []
        var index = 2
        while index + 3 < jpeg.count, jpeg[index] == 0xff {
            markers.append(jpeg[index + 1])
            if jpeg[index + 1] == 0xda { break }
            index += 2 + (Int(jpeg[index + 2]) << 8 | Int(jpeg[index + 3]))
        }
        precondition(Array(jpeg.prefix(2)) == [0xff, 0xd8] && Array(jpeg.suffix(2)) == [0xff, 0xd9])
        precondition(markers == [0xe0, 0xdb, 0xdb, 0xc0, 0xc4, 0xc4, 0xc4, 0xc4, 0xda])
        let sof = jpeg.firstIndex(of: 0xc0).map { $0 - 1 }!
        precondition(Array(jpeg[(sof + 10)..<(sof + 19)]) == [1, 0x11, 0, 2, 0x11, 1, 3, 0x11, 1])
        let entropy = jpeg[(index + 14)..<(jpeg.count - 2)]
        precondition(!zip(entropy, entropy.dropFirst()).contains { $0 == 0xff && (0xd0...0xd7).contains($1) })

        // Decode with ImageIO and require a close match (mean absolute error per channel).
        guard let source = CGImageSourceCreateWithData(Data(jpeg) as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil),
              decoded.width == width, decoded.height == height else {
            preconditionFailure("encoded JPEG did not decode")
        }
        var roundTrip = [UInt8](repeating: 0, count: width * height * 4)
        roundTrip.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.draw(decoded, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var totalError = 0, samples = 0
        for pixel in 0..<(width * height) {
            for channel in 0..<3 {
                totalError += abs(Int(pixels[pixel * 4 + channel]) - Int(roundTrip[pixel * 4 + channel]))
                samples += 1
            }
        }
        precondition(Double(totalError) / Double(samples) < 12, "JPEG round-trip error too high")

        // Projection frames: 4:2:0 at quality 30 (2×2 luma sampling in SOF0), still decodable by ImageIO.
        let subsampled = [UInt8](BaselineJPEGEncoder.encode(rgba: pixels, width: width, height: height, quality: 30, subsampling: .s420))
        let subsampledSOF = subsampled.indices.first { subsampled[$0] == 0xff && subsampled[$0 + 1] == 0xc0 }!
        precondition(Array(subsampled[(subsampledSOF + 10)..<(subsampledSOF + 19)]) == [1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1])
        guard let subsampledSource = CGImageSourceCreateWithData(Data(subsampled) as CFData, nil),
              let subsampledImage = CGImageSourceCreateImageAtIndex(subsampledSource, 0, nil),
              subsampledImage.width == width, subsampledImage.height == height else {
            preconditionFailure("4:2:0 JPEG did not decode")
        }
        var subsampledPixels = [UInt8](repeating: 0, count: width * height * 4)
        subsampledPixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.draw(subsampledImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var gradientError = 0
        for pixel in 0..<(width * height) {
            for channel in 0..<2 {  // red and green are smooth gradients; blue is a checkerboard lost to 4:2:0
                gradientError += abs(Int(pixels[pixel * 4 + channel]) - Int(subsampledPixels[pixel * 4 + channel]))
            }
        }
        precondition(Double(gradientError) / Double(width * height * 2) < 40, "4:2:0 round-trip error too high")
    }

    // JpgBinTool / BinTool reconstructions, plus the 0x3B / 0x39 / 0x38 packets.
    private static func testLEDTranscoding() {
        // Mold geometry: 30 LEDs pad to 32 (covering 2); 16 rows over 2 bars → perNum 8, times 1.
        let mold = MoldTranscoder(ledCount: 30, rows: 16, orientation: 0, adjust: nil, lights: nil,
                                  perBar: 1, lightBarCount: 2, quality: 90, imageWidth: 64)
        precondition(mold.outputWidth == 32 && mold.outputHeight == 16)
        precondition(mold.molds.count == 32 * 16)
        precondition(mold.molds.prefix(2).allSatisfy { $0 == -1 })
        // First LED of the first line sits on the rim at angle 0: x = round(29 + 33.5) = 62 (banker's), y = 33.5 → 34.
        precondition(mold.molds[2] == Int32((34 - 1) * 64 + 62 - 1))

        // A solid red frame: every LED slot is B 0, G 0, R 255 (BGR order); padding slots stay black.
        var red = [UInt8](repeating: 255, count: 64 * 64 * 4)
        for pixel in 0..<(64 * 64) { red[pixel * 4] = 255; red[pixel * 4 + 1] = 0; red[pixel * 4 + 2] = 0 }
        let bytes = mold.moldBytes(rgba: red, width: 64, height: 64)
        precondition(Array(bytes[0..<6]) == [0, 0, 0, 0, 0, 0])
        precondition(Array(bytes[6..<9]) == [0, 0, 255])
        let moldJPEG = [UInt8](mold.jpeg(rgba: red, width: 64, height: 64))
        guard let moldSource = CGImageSourceCreateWithData(Data(moldJPEG) as CFData, nil),
              let moldImage = CGImageSourceCreateImageAtIndex(moldSource, 0, nil) else {
            preconditionFailure("mold JPEG did not decode")
        }
        precondition(moldImage.width == 32 && moldImage.height == 16)
        precondition(MoldTranscoder.exportPreset(deviceType: 25, imageWidth: 672)?.outputWidth == 304)
        precondition(MoldTranscoder.exportPreset(deviceType: 26, imageWidth: 672)?.outputHeight == 1408)
        precondition(MoldTranscoder.exportPreset(deviceType: 1, imageWidth: 672) == nil)

        // Bin packing: 1 bar, 1 subsection, 1 bit, 2 LEDs × 1 row → 6 mold bytes → 6 bits, MSB first.
        let config = FanBinConfiguration(ledCount: 2, subsection: 1, lamps: 1, rows: 1, color: 1, bit: 1,
                                         orientation: 0, perBar: 1, adjust: (0..<256).map { UInt8($0) }, lights: [1, 1])
        precondition(BinTranscoder.pack([0x80, 0x00, 0xff, 0x00, 0x80, 0x00], configuration: config, perBar: 1) == [])
        let config8 = FanBinConfiguration(ledCount: 2, subsection: 1, lamps: 1, rows: 4, color: 1, bit: 1,
                                          orientation: 0, perBar: 1, adjust: (0..<256).map { UInt8($0) }, lights: [1, 1])
        // 4 rows × 6 bytes = 24 bytes → 3 output bytes; only bytes with bit 7 set produce 1 bits.
        var rowBytes = [UInt8](repeating: 0, count: 24)
        rowBytes[0] = 0x80; rowBytes[7] = 0xff; rowBytes[23] = 0x81
        precondition(BinTranscoder.pack(rowBytes, configuration: config8, perBar: 1) == [0x81, 0x00, 0x01])  // bits are taken in byte order, MSB first

        // 0x38: name, µs per frame, frames, audio flag, key; bytes 4–32 XORed with the key at byte 33.
        let bin = SpinDisplayProtocol.binSendRequest(name: "clip", frameDuration: 50_000, frames: 20, hasAudio: false, key: 0x5a)!
        assertFrame(bin, command: 0x38, payloadLength: 30)
        let decoded = (4..<33).map { bin[$0] ^ 0x5a }
        precondition(Array(decoded[0..<4]) == Array("clip".utf8) && decoded[4..<20].allSatisfy { $0 == 0 })
        precondition(Array(decoded[20..<24]) == [0x50, 0xc3, 0, 0] && Array(decoded[24..<28]) == [20, 0, 0, 0] && decoded[28] == 0)
        precondition(bin[33] == 0x5a)
        precondition(SpinDisplayProtocol.binSendRequest(name: "x", frameDuration: 1, frames: 1, hasAudio: false, key: 0) == nil)
        assertFrame(SpinDisplayProtocol.transcodingQuery(), command: 0x3b, payloadLength: 0)
        assertFrame(SpinDisplayProtocol.binParameterQuery(), command: 0x39, payloadLength: 0)
        assertFrame(SpinDisplayProtocol.noticeAudioRequest(), command: 0x3a, payloadLength: 0)

        // 0x3B parse: header fields, 256-byte adjust, then ledNum ratio bytes.
        var transcodingPayload = [UInt8](repeating: 0, count: 264 + 3)
        transcodingPayload[0] = 3; transcodingPayload[2] = 16; transcodingPayload[4] = 1
        transcodingPayload[5] = 2; transcodingPayload[6] = 2; transcodingPayload[7] = 80
        transcodingPayload[8] = 7; transcodingPayload[264] = 50; transcodingPayload[266] = 120
        let transcoding = SpinDisplayProtocol.parseTranscoding(SpinDisplayProtocol.frame(command: 0x3b, payload: transcodingPayload))
        precondition(transcoding?.ledCount == 3 && transcoding?.rows == 16 && transcoding?.direction == 1)
        precondition(transcoding?.deliveryTimes == 2 && transcoding?.lightBarCount == 2 && transcoding?.quality == 80)
        precondition(transcoding?.adjust.first == 7 && transcoding?.ratio == [50, 0, 120])

        // 0x39 parse: lights right-aligned (2 values for 4 LEDs → [1, 1, 0.5, 1.2]).
        var binPayload = [UInt8](repeating: 0, count: 266 + 2)
        binPayload[0] = 4; binPayload[2] = 3; binPayload[3] = 2; binPayload[4] = 64
        binPayload[6] = 4; binPayload[7] = 8; binPayload[8] = 1; binPayload[9] = 1
        binPayload[266] = 50; binPayload[267] = 120
        let binConfiguration = SpinDisplayProtocol.parseBinConfiguration(SpinDisplayProtocol.frame(command: 0x39, payload: binPayload))
        precondition(binConfiguration?.ledCount == 4 && binConfiguration?.subsection == 3 && binConfiguration?.lamps == 2)
        precondition(binConfiguration?.rows == 64 && binConfiguration?.color == 4 && binConfiguration?.bit == 8)
        precondition(binConfiguration?.lights == [1, 1, 0.5, 1.2])
    }
}
