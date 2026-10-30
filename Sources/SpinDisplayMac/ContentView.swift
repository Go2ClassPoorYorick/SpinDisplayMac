import AppKit
import SwiftUI
import SpinDisplayCore
import SpinDisplayMedia
import UniformTypeIdentifiers

@MainActor
final class DeviceViewModel: ObservableObject {
    @Published var devices: [FanDevice] = []
    @Published var status = "Starting network discovery…"
    @Published var manualAddress = ""
    @Published var password = ""
    @Published var targetWiFiName = "CatToys"
    @Published var targetWiFiPassword = ""
    @Published var configuredDeviceName = ""
    @Published var fanAngleDegrees = 0.0
    @Published var autoPowerOn = false
    @Published var shutdownScheduleEnabled = false
    @Published var bootScheduleEnabled = false
    @Published var shutdownTime = Calendar.current.date(from: DateComponents(hour: 22, minute: 0)) ?? Date()
    @Published var bootTime = Calendar.current.date(from: DateComponents(hour: 8, minute: 0)) ?? Date()
    @Published var bluetoothEnabled = false
    @Published var bluetoothVolume = 0.0
    @Published var bluetoothMessage = "The fan's Bluetooth state has not been checked."
    @Published var deletionCandidate: Int?
    @Published var connectedDevice: FanDevice?
    @Published var connectionMessage = ""
    @Published var isConnecting = false
    @Published var isConnected = false
    @Published var isPowered: Bool?
    @Published var brightnessLevel = 0
    @Published var playlist: [FanFile] = []
    @Published var currentPlaylistIndex: Int?
    @Published var playbackStatus: PlaybackStatusResponse?
    @Published var showFTLVImporter = false
    @Published var isUploadingFTLV = false
    @Published var ftlvUploadProgress = 0.0
    @Published var ftlvUploadMessage = ""
    @Published var deviceInfo: FanDeviceInfo?
    @Published var versionInfo: FanVersionInfo?
    @Published var displayMode: FanDisplayMode = .highlight
    @Published var thirdPartyControlEnabled = false
    @Published var loginVerificationEnabled = false
    @Published var loginPassword = ""
    @Published var showDeleteAllConfirmation = false
    @Published var fileEditor: FileEditorState?
    @Published var mediaConversion: MediaConversionState?
    @Published var showMediaImporter = false

    final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }

    struct MediaConversionState: Identifiable {
        let id = UUID()
        let sourceURL: URL
        let hasSecurityScope: Bool
        let kind: MediaConverter.MediaKind
        var framing: MediaConverter.Framing = .fill
        var includeAudio = true
        var startSecond = 0
        var endSecond: Int?
        var holdLastFrame = true
        var preview: CGImage?
        var isWorking = false
        var progress = 0.0
        var message = ""
        let cancellation = Cancellation()
    }

    struct FileEditorState: Identifiable {
        let index: Int
        let originalName: String
        var name: String
        var repeatCount: Int
        var displayMode: FileDisplayMode
        var timeSlots: [PlaybackTimeSlot]
        var id: Int { index }
    }

    private let scanner = DeviceScanner()
    private var connection: DeviceConnection?
    private var hasLoadedSettings = false

    /// The original File Edit window hides "Set-time" for version model 1 and shades it when the fan reports it unsupported.
    var supportsScheduledPlayback: Bool {
        versionInfo?.model != 1 && deviceInfo?.restrictions.contains(.timingPlay) != true
    }

    init() {
        scanner.onDevice = { [weak self] device in
            Task { @MainActor in
                guard let self else { return }
                if let index = self.devices.firstIndex(where: { $0.id == device.id }) {
                    self.devices[index] = device
                } else {
                    self.devices.append(device)
                    self.devices.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                }
            }
        }
        scanner.onStatus = { [weak self] message in
            Task { @MainActor in self?.status = message }
        }
        scanner.onAuthenticationResult = { [weak self] address, succeeded in
            Task { @MainActor in
                guard let self, let device = self.devices.first(where: { $0.address == address }) else { return }
                if succeeded {
                    self.status = "Password accepted. Connecting to \(device.name)…"
                    self.connect(to: device)
                } else {
                    self.status = "The device rejected the password."
                }
            }
        }
    }

    func startScanning() {
        scanner.start()
    }

    func authenticate(_ device: FanDevice) {
        guard !password.isEmpty else {
            status = "Enter the device password to continue."
            return
        }
        scanner.authenticate(device: device, password: password)
    }

    func connect(_ device: FanDevice) {
        connect(to: device.address, device: device)
    }

    func connectManually() {
        let address = manualAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        connect(to: address)
    }

    func disconnect() {
        connection?.disconnect()
        connection = nil
        resetConnectionState()
        connectionMessage = "Disconnected."
    }

    private func resetConnectionState() {
        connectedDevice = nil
        isConnected = false
        isPowered = nil
        playlist = []
        currentPlaylistIndex = nil
        playbackStatus = nil
        isUploadingFTLV = false
        deviceInfo = nil
        versionInfo = nil
        fileEditor = nil
        hasLoadedSettings = false
    }

    /// Fills the editable settings from the fan once per connection so periodic refreshes don't overwrite edits.
    private func applyDeviceInfo(_ info: FanDeviceInfo) {
        deviceInfo = info
        guard !hasLoadedSettings else { return }
        hasLoadedSettings = true
        if !info.deviceName.isEmpty { configuredDeviceName = info.deviceName }
        fanAngleDegrees = Double(max(-360, min(360, info.angleDegrees)))
        autoPowerOn = info.isAutoOn
        shutdownScheduleEnabled = info.isShutdownScheduled
        bootScheduleEnabled = info.isBootScheduled
        if let time = Calendar.current.date(from: DateComponents(hour: Int(info.shutdownHour), minute: Int(info.shutdownMinute))) {
            shutdownTime = time
        }
        if let time = Calendar.current.date(from: DateComponents(hour: Int(info.bootHour), minute: Int(info.bootMinute))) {
            bootTime = time
        }
        bluetoothEnabled = info.isBluetoothEnabled
        bluetoothVolume = Double(info.volume)
        bluetoothMessage = "Bluetooth audio is \(info.isBluetoothEnabled ? "enabled" : "disabled") on the fan (volume \(info.volume)/31)."
        displayMode = FanDisplayMode(rawValue: info.displayMode) ?? .highlight
        thirdPartyControlEnabled = info.isThirdPartyControlEnabled
        loginVerificationEnabled = info.isLoginVerificationEnabled
    }

    private func describeAcknowledgement(command: UInt8, status: UInt8) -> String {
        let accepted = status == 0
        switch command {
        case SpinDisplayProtocol.displayModeCommand:
            return accepted ? "Display mode set successfully." : "The fan rejected the display mode (status \(status))."
        case SpinDisplayProtocol.thirdPartyControlCommand:
            return accepted ? "Third-party control setting saved." : "The fan rejected the third-party control setting (status \(status))."
        case SpinDisplayProtocol.loginVerificationCommand:
            return accepted
                ? "Login verification saved. Reconnect for it to take effect."
                : "The fan rejected the login verification setting (status \(status))."
        case SpinDisplayProtocol.changeFileCommand:
            return accepted ? "File changes saved." : "The fan rejected the file changes (status \(status))."
        case SpinDisplayProtocol.deleteFileCommand:
            return accepted ? "The fan accepted the delete request." : "The fan rejected the delete request (status \(status))."
        default:
            return "Response 0x\(String(format: "%02X", command)) status \(status)."
        }
    }

    func setDisplayMode(_ mode: FanDisplayMode) {
        guard isConnected, let connection else {
            connectionMessage = "Connect to the fan before changing its display mode."
            return
        }
        do {
            try connection.setDisplayMode(mode)
            displayMode = mode
            connectionMessage = "Display mode command sent."
        } catch {
            connectionMessage = error.localizedDescription
        }
    }

    func setThirdPartyControl(_ isEnabled: Bool) {
        guard isConnected, let connection else {
            connectionMessage = "Connect to the fan before changing third-party control."
            return
        }
        do {
            try connection.setThirdPartyControl(isEnabled)
            thirdPartyControlEnabled = isEnabled
            connectionMessage = "Third-party control \(isEnabled ? "enable" : "disable") command sent."
        } catch {
            connectionMessage = error.localizedDescription
        }
    }

    func applyLoginVerification() {
        guard isConnected, let connection else {
            connectionMessage = "Connect to the fan before changing login verification."
            return
        }
        do {
            try connection.setLoginVerification(isEnabled: loginVerificationEnabled, password: loginPassword)
            connectionMessage = "Login verification command sent."
            loginPassword = ""
        } catch {
            connectionMessage = error.localizedDescription
        }
    }

    func deleteAllFiles() {
        guard isConnected, let connection else {
            connectionMessage = "Connect to the fan before deleting its files."
            return
        }
        do {
            try connection.deleteAllFiles()
            currentPlaylistIndex = nil
            try connection.refreshPlaylist()
            connectionMessage = "Delete-all command sent; playlist refresh requested."
        } catch {
            connectionMessage = error.localizedDescription
        }
    }

    func beginEditingFile(at index: Int) {
        guard playlist.indices.contains(index) else { return }
        let file = playlist[index]
        var slots = file.timeSlots
        if slots.count != PlaybackTimeSlot.count { slots = Array(repeating: .empty, count: PlaybackTimeSlot.count) }
        fileEditor = FileEditorState(
            index: index,
            originalName: file.name,
            name: file.name,
            repeatCount: Int(file.repeating),
            displayMode: file.displayMode ?? .allDay,
            timeSlots: slots
        )
    }

    /// Mirrors the original File Edit window's checks before sending `AlterFile`.
    func fileEditorProblem(_ editor: FileEditorState) -> String? {
        let name = editor.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name.utf8.count > 100 { return "The file name must be 1–100 UTF-8 bytes." }
        if playlist.enumerated().contains(where: { $0.offset != editor.index && $0.element.name == name }) {
            return "The device already contains a file named \"\(name)\"."
        }
        if !(0...255).contains(editor.repeatCount) { return "Repetition must be between 0 and 255." }
        if editor.timeSlots.contains(where: { $0.isEnabled && !$0.isValid }) {
            return "Each enabled time window must start before it ends."
        }
        return nil
    }

    func saveFileEditor() {
        guard let editor = fileEditor else { return }
        if let problem = fileEditorProblem(editor) {
            connectionMessage = problem
            return
        }
        guard isConnected, let connection else {
            connectionMessage = "Connect to the fan before editing a file."
            return
        }
        guard playlist.indices.contains(editor.index), playlist[editor.index].name == editor.originalName else {
            connectionMessage = "The playlist changed while editing. Refresh and try again."
            fileEditor = nil
            return
        }
        do {
            try connection.changeFile(
                at: editor.index,
                name: editor.name.trimmingCharacters(in: .whitespacesAndNewlines),
                repeatCount: UInt8(editor.repeatCount),
                displayMode: editor.displayMode,
                timeSlots: editor.timeSlots
            )
            fileEditor = nil
            try connection.refreshPlaylist()
            connectionMessage = "File edit sent for item \(editor.index + 1); playlist refresh requested."
        } catch {
            connectionMessage = error.localizedDescription
        }
    }

    func setPower(_ isOn: Bool) {
        guard isConnected, let connection else {
            connectionMessage = "Connect to the fan before changing its power."
            return
        }
        do {
            try connection.setPower(isOn: isOn)
            connectionMessage = "Power \(isOn ? "on" : "off") command sent."
        } catch {
            connectionMessage = error.localizedDescription
        }
    }

    func setBrightness(_ level: Double) {
        guard isConnected, let connection else {
            connectionMessage = "Connect to the fan before changing brightness."
            return
        }
        guard level.isFinite else {
            connectionMessage = "Brightness must be a finite value."
            return
        }
        let value = max(0, min(5, Int(level)))
        do {
            try connection.setBrightness(level: UInt8(value))
            brightnessLevel = value
            connectionMessage = "Brightness command sent."
        } catch {
            connectionMessage = error.localizedDescription
        }
    }

    func refreshPlaylist() {
        guard isConnected, let connection else {
            connectionMessage = "Connect to the fan before requesting its playlist."
            return
        }
        do {
            try connection.refreshPlaylist()
            connectionMessage = "Requesting the fan playlist…"
        } catch {
            connectionMessage = error.localizedDescription
        }
    }

    func playFile(at index: Int) {
        guard isConnected, let connection else {
            connectionMessage = "Connect to the fan before starting playback."
            return
        }
        guard playlist.indices.contains(index) else {
            connectionMessage = "Select a valid playlist item before starting playback."
            return
        }
        do {
            try connection.playFile(at: index)
            currentPlaylistIndex = index
            connectionMessage = "Playback command sent for playlist item \(index + 1)."
        } catch {
            connectionMessage = error.localizedDescription
        }
    }

    func repeatPlaylistItem(at index: Int) {
        guard isConnected, let connection else {
            connectionMessage = "Connect to the fan before repeating a playlist item."
            return
        }
        guard playlist.indices.contains(index) else {
            connectionMessage = "Select a valid playlist item before repeating it."
            return
        }
        do {
            try connection.repeatFile(at: index)
            currentPlaylistIndex = index
            connectionMessage = "Repeat command sent for playlist item \(index + 1)."
        } catch {
            connectionMessage = error.localizedDescription
        }
    }

    func uploadFTLV(from result: Result<URL, Error>) {
        let url: URL
        switch result {
        case .success(let selectedURL):
            url = selectedURL
        case .failure(let error):
            let cocoaError = error as NSError
            guard cocoaError.domain == NSCocoaErrorDomain, cocoaError.code == NSUserCancelledError else {
                ftlvUploadMessage = error.localizedDescription
                return
            }
            return
        }
        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        startUpload(of: url, validatingMessage: "Validating FTLV file…") {
            if hasSecurityScope { url.stopAccessingSecurityScopedResource() }
        }
    }

    /// Uploads an FTLV file with the recovered 0x30/0x36 transfer; `cleanup` runs when the transfer ends.
    @discardableResult
    private func startUpload(of url: URL, validatingMessage: String, cleanup: @escaping () -> Void) -> Bool {
        guard isConnected, let connection else {
            ftlvUploadMessage = "Connect to the fan before uploading media."
            cleanup()
            return false
        }
        guard let device = connectedDevice else {
            ftlvUploadMessage = "Select the fan from discovery before uploading so its device type can be checked."
            cleanup()
            return false
        }
        guard !isUploadingFTLV else {
            cleanup()
            return false
        }

        isUploadingFTLV = true
        ftlvUploadProgress = 0
        ftlvUploadMessage = validatingMessage
        let connectionID = connection.id
        connection.uploadFTLV(
            at: url,
            deviceType: device.deviceType,
            progress: { [weak self] progress, message in
                Task { @MainActor in
                    guard let self, self.connection?.id == connectionID else { return }
                    self.ftlvUploadProgress = progress
                    self.ftlvUploadMessage = message
                }
            },
            completion: { [weak self] result in
                Task { @MainActor in
                    cleanup()
                    guard let self, self.connection?.id == connectionID else { return }
                    self.isUploadingFTLV = false
                    switch result {
                    case .success:
                        self.ftlvUploadProgress = 1
                        self.ftlvUploadMessage = "Upload complete. The playlist has been refreshed."
                    case .failure(let error):
                        self.ftlvUploadMessage = error.localizedDescription
                    }
                }
            }
        )
        return true
    }

    // MARK: - Media conversion

    var conversionTarget: MediaConverter.Target {
        guard let info = deviceInfo else { return .generic }
        return MediaConverter.Target(imageSize: info.imageSize, maxFPS: info.maxFPS)
    }

    var conversionUnsupportedReason: String? {
        MediaConverter.unsupportedReason(deviceType: connectedDevice?.deviceType, contentType: deviceInfo?.contentType)
    }

    func chooseMedia(from result: Result<URL, Error>) {
        guard case .success(let url) = result else {
            if case .failure(let error) = result,
               !((error as NSError).domain == NSCocoaErrorDomain && (error as NSError).code == NSUserCancelledError) {
                ftlvUploadMessage = error.localizedDescription
            }
            return
        }
        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        Task {
            do {
                let kind = try await MediaConverter.inspect(url)
                let state = MediaConversionState(sourceURL: url, hasSecurityScope: hasSecurityScope, kind: kind)
                mediaConversion = state
                refreshMediaPreview()
            } catch {
                if hasSecurityScope { url.stopAccessingSecurityScopedResource() }
                ftlvUploadMessage = error.localizedDescription
            }
        }
    }

    func closeMediaConversion() {
        guard let state = mediaConversion else { return }
        state.cancellation.cancel()
        if state.hasSecurityScope { state.sourceURL.stopAccessingSecurityScopedResource() }
        mediaConversion = nil
    }

    func refreshMediaPreview() {
        guard let state = mediaConversion else { return }
        let target = conversionTarget
        Task {
            do {
                let image = try await MediaConverter.preview(
                    state.sourceURL, kind: state.kind, target: target, framing: state.framing, startSecond: state.startSecond
                )
                guard mediaConversion?.id == state.id else { return }
                mediaConversion?.preview = image
            } catch {
                mediaConversion?.message = error.localizedDescription
            }
        }
    }

    /// Converts the selected media, then either uploads it or saves it to `exportURL`.
    func runMediaConversion(exportTo exportURL: URL? = nil) {
        guard var state = mediaConversion, !state.isWorking else { return }
        if let reason = conversionUnsupportedReason {
            mediaConversion?.message = reason
            return
        }
        if exportURL == nil {
            guard isConnected, connectedDevice != nil else {
                mediaConversion?.message = "Connect to a discovered fan before uploading."
                return
            }
            guard !isUploadingFTLV else {
                mediaConversion?.message = "Another upload is in progress."
                return
            }
        }
        state.isWorking = true
        state.progress = 0
        state.message = "Converting…"
        mediaConversion = state

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpinDisplayConversion-\(UUID().uuidString)", isDirectory: true)
        let output = directory.appendingPathComponent(uploadName(for: state.sourceURL)).appendingPathExtension("ftlv")
        let options = MediaConverter.Options(
            framing: state.framing,
            includeAudio: state.includeAudio,
            startSecond: state.startSecond,
            endSecond: state.endSecond,
            holdLastFrame: state.holdLastFrame
        )
        let target = conversionTarget
        let cancellation = state.cancellation
        let id = state.id
        let report: @Sendable (Double, String) -> Void = { [weak self] progress, message in
            Task { @MainActor in
                guard let self, self.mediaConversion?.id == id else { return }
                self.mediaConversion?.progress = progress
                self.mediaConversion?.message = message
            }
        }
        Task {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let result = try await Task.detached(priority: .userInitiated) {
                    try await MediaConverter.convert(
                        state.sourceURL, kind: state.kind, target: target, options: options, output: output,
                        isCancelled: { cancellation.isCancelled },
                        progress: report
                    )
                }.value
                guard mediaConversion?.id == id else {
                    try? FileManager.default.removeItem(at: directory)
                    return
                }
                let summary = "\(result.frameCount) frame(s)\(result.fps.map { " at \($0) fps" } ?? "")\(result.hasAudio ? " with audio" : "")"
                if let exportURL {
                    if FileManager.default.fileExists(atPath: exportURL.path) {
                        try FileManager.default.removeItem(at: exportURL)
                    }
                    try FileManager.default.moveItem(at: output, to: exportURL)
                    try? FileManager.default.removeItem(at: directory)
                    mediaConversion?.isWorking = false
                    mediaConversion?.message = "Exported \(exportURL.lastPathComponent): \(summary)."
                } else {
                    let started = startUpload(of: output, validatingMessage: "Uploading converted media (\(summary))…") {
                        try? FileManager.default.removeItem(at: directory)
                    }
                    if started { closeMediaConversion() } else { mediaConversion?.isWorking = false }
                }
            } catch {
                try? FileManager.default.removeItem(at: directory)
                guard mediaConversion?.id == id else { return }
                mediaConversion?.isWorking = false
                mediaConversion?.message = error.localizedDescription
            }
        }
    }

    func exportMediaConversion() {
        guard let state = mediaConversion else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ftlv") ?? .data]
        panel.nameFieldStringValue = uploadName(for: state.sourceURL) + ".ftlv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        runMediaConversion(exportTo: url)
    }

    /// The fan rejects duplicate names (status 2); like the original, pick an unused name instead.
    private func uploadName(for source: URL) -> String {
        var base = source.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = "media" }
        while base.utf8.count > 90 { base.removeLast() }
        let existing = Set(playlist.map(\.name))
        var candidate = base
        var counter = 1
        while existing.contains(candidate) {
            candidate = "\(base)(\(counter))"
            counter += 1
        }
        return candidate
    }

    func deletePlaylistItem(at index: Int) {
        guard isConnected, let connection else {
            connectionMessage = "Connect to the fan before deleting a playlist item."
            return
        }
        guard playlist.indices.contains(index) else {
            connectionMessage = "Select a valid playlist item before deleting it."
            return
        }
        do {
            try connection.deleteFile(at: index)
            currentPlaylistIndex = nil
            try connection.refreshPlaylist()
            connectionMessage = "Delete command sent for item \(index + 1); playlist refresh requested."
        } catch {
            connectionMessage = error.localizedDescription
        }
    }

    func movePlaylistItem(from source: Int, to destination: Int) {
        guard isConnected, let connection else {
            connectionMessage = "Connect to the fan before reordering the playlist."
            return
        }
        guard playlist.indices.contains(source), playlist.indices.contains(destination) else {
            connectionMessage = "Select valid playlist positions before reordering."
            return
        }
        do {
            try connection.moveFile(from: source, to: destination)
            var reorderedPlaylist = playlist
            reorderedPlaylist.swapAt(source, destination)
            playlist = reorderedPlaylist
            if currentPlaylistIndex == source {
                currentPlaylistIndex = destination
            } else if currentPlaylistIndex == destination {
                currentPlaylistIndex = source
            }
            connectionMessage = "Move command sent. The displayed order is updated; refresh to confirm the fan saved it."
        } catch {
            connectionMessage = error.localizedDescription
        }
    }

    func setConfiguredDeviceName() {
        guard isConnected, let connection else {
            connectionMessage = "Connect to the fan before changing its name."
            return
        }
        do {
            try connection.setDeviceName(configuredDeviceName)
            connectionMessage = "Device name setting sent. The change may require reconnecting to appear."
        } catch {
            connectionMessage = error.localizedDescription
        }
    }

    func setFanAngle() {
        guard isConnected, let connection else {
            connectionMessage = "Connect to the fan before changing its angle."
            return
        }
        guard fanAngleDegrees.isFinite else {
            connectionMessage = "Angle must be a finite value."
            return
        }
        do {
            try connection.setFanAngle(degrees: Int(fanAngleDegrees))
            connectionMessage = "Fan angle command sent."
        } catch {
            connectionMessage = error.localizedDescription
        }
    }

    func setPowerSchedule() {
        guard isConnected, let connection else {
            connectionMessage = "Connect to the fan before configuring its power schedule."
            return
        }
        let shutdown = Calendar.current.dateComponents([.hour, .minute], from: shutdownTime)
        let boot = Calendar.current.dateComponents([.hour, .minute], from: bootTime)
        guard let shutdownHour = shutdown.hour,
              let shutdownMinute = shutdown.minute,
              let bootHour = boot.hour,
              let bootMinute = boot.minute,
              let shutdownHourByte = UInt8(exactly: shutdownHour),
              let shutdownMinuteByte = UInt8(exactly: shutdownMinute),
              let bootHourByte = UInt8(exactly: bootHour),
              let bootMinuteByte = UInt8(exactly: bootMinute) else {
            connectionMessage = "Could not read the selected schedule times."
            return
        }
        do {
            try connection.setPowerSchedule(
                autoOn: autoPowerOn,
                shutdownEnabled: shutdownScheduleEnabled,
                bootEnabled: bootScheduleEnabled,
                shutdownHour: shutdownHourByte,
                shutdownMinute: shutdownMinuteByte,
                bootHour: bootHourByte,
                bootMinute: bootMinuteByte
            )
            connectionMessage = "Power schedule command sent."
        } catch {
            connectionMessage = error.localizedDescription
        }
    }

    func syncClock() {
        guard isConnected, let connection else {
            connectionMessage = "Connect to the fan before synchronizing its clock."
            return
        }
        do {
            try connection.syncClock()
            connectionMessage = "Mac date and time sent to the fan."
        } catch {
            connectionMessage = error.localizedDescription
        }
    }

    /// The original refuses Bluetooth changes on a fan that is in a sync group but is not its host.
    private var bluetoothBlockedBySyncGroup: Bool {
        guard let info = deviceInfo else { return false }
        return info.groupNumber != 0 && info.syncFlag != 1
    }

    func setBluetoothEnabled(_ isEnabled: Bool) {
        guard isConnected, let connection else {
            bluetoothMessage = "Connect to the fan before changing Bluetooth settings."
            connectionMessage = bluetoothMessage
            return
        }
        guard !bluetoothBlockedBySyncGroup else {
            bluetoothMessage = "This fan is in a sync group but is not its host, so it cannot use Bluetooth audio."
            connectionMessage = bluetoothMessage
            return
        }
        do {
            try connection.setBluetoothEnabled(isEnabled)
            bluetoothEnabled = isEnabled
            bluetoothMessage = isEnabled
                ? "Bluetooth enabled. Put your Bluetooth speaker in pairing mode, then press Search and connect."
                : "Bluetooth disabled."
            connectionMessage = bluetoothMessage
        } catch {
            bluetoothMessage = error.localizedDescription
            connectionMessage = error.localizedDescription
        }
    }

    func setBluetoothVolume(_ volume: Double) {
        guard isConnected, let connection else {
            bluetoothMessage = "Connect to the fan before changing Bluetooth volume."
            connectionMessage = bluetoothMessage
            return
        }
        guard volume.isFinite else {
            bluetoothMessage = "Bluetooth volume must be a finite value."
            connectionMessage = bluetoothMessage
            return
        }
        let level = max(0, min(31, Int(volume)))
        do {
            try connection.setBluetoothVolume(UInt8(level))
            bluetoothVolume = Double(level)
            bluetoothMessage = "Volume \(level)/31 command sent to the fan's Bluetooth speaker output."
            connectionMessage = bluetoothMessage
        } catch {
            bluetoothMessage = error.localizedDescription
            connectionMessage = error.localizedDescription
        }
    }

    /// Original "Search and connect" button (`BleVolumeSetting(2, 0)`): the fan searches for and pairs with
    /// a nearby Bluetooth speaker. The fan is the audio source; it does not appear as a speaker to the Mac.
    func searchForBluetoothSpeaker() {
        guard isConnected, let connection else {
            bluetoothMessage = "Connect to the fan before searching for a Bluetooth speaker."
            connectionMessage = bluetoothMessage
            return
        }
        guard !bluetoothBlockedBySyncGroup else {
            bluetoothMessage = "This fan is in a sync group but is not its host, so it cannot use Bluetooth audio."
            connectionMessage = bluetoothMessage
            return
        }
        do {
            try connection.searchForBluetoothSpeaker()
            bluetoothMessage = "Search started. The fan connects to a nearby speaker in pairing mode; the app gets no confirmation, so listen for the speaker's pairing tone."
            connectionMessage = bluetoothMessage
        } catch {
            bluetoothMessage = error.localizedDescription
            connectionMessage = error.localizedDescription
        }
    }

    func skipPlaylist(by offset: Int) {
        guard !playlist.isEmpty else { return }
        let currentIndex = currentPlaylistIndex ?? (offset > 0 ? -1 : 0)
        let nextIndex = max(0, min(playlist.count - 1, currentIndex + offset))
        playFile(at: nextIndex)
    }

    func configureFanWiFi() {
        guard isConnected, let connection else {
            status = "Connect to the fan before changing its Wi-Fi settings."
            return
        }
        do {
            try connection.configureWiFi(ssid: targetWiFiName, password: targetWiFiPassword)
            status = "Wi-Fi settings sent for \(targetWiFiName). The fan may disconnect while it joins that network."
            connectionMessage = status
        } catch {
            status = error.localizedDescription
        }
    }

    private func connect(to device: FanDevice) {
        connect(to: device.address, device: device)
    }

    private func connect(to address: String, device: FanDevice? = nil) {
        guard !isConnecting else { return }
        isConnecting = true
        status = "Connecting to \(address):50110…"
        DeviceConnection.connect(to: address) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isConnecting = false
                switch result {
                case .success(let connection):
                    self.connection?.disconnect()
                    self.connection = connection
                    let connectionID = connection.id
                    self.resetConnectionState()
                    self.connectedDevice = device
                    if let device {
                        self.configuredDeviceName = device.name
                    }
                    self.isConnected = true
                    self.playbackStatus = nil
                    self.connectionMessage = "Connected to \(address)."
                    self.status = self.connectionMessage
                    connection.onMessage = { [weak self] message in
                        Task { @MainActor in self?.connectionMessage = message }
                    }
                    connection.onDisconnected = { [weak self] message in
                        Task { @MainActor in
                            guard let self, self.connection?.id == connectionID else { return }
                            self.connection = nil
                            self.resetConnectionState()
                            self.connectionMessage = message
                            self.status = message
                        }
                    }
                    connection.onPowerChanged = { [weak self] isOn in
                        Task { @MainActor in self?.isPowered = isOn }
                    }
                    connection.onBrightnessChanged = { [weak self] level in
                        Task { @MainActor in self?.brightnessLevel = Int(level) }
                    }
                    connection.onPlaylistChanged = { [weak self] files in
                        Task { @MainActor in self?.playlist = files }
                    }
                    connection.onPlaybackStatusChanged = { [weak self] playbackStatus in
                        Task { @MainActor in
                            self?.playbackStatus = playbackStatus
                        }
                    }
                    connection.onDeviceInfoChanged = { [weak self] info in
                        Task { @MainActor in
                            guard let self, self.connection?.id == connectionID else { return }
                            self.applyDeviceInfo(info)
                        }
                    }
                    connection.onVersionChanged = { [weak self] version in
                        Task { @MainActor in
                            guard let self, self.connection?.id == connectionID else { return }
                            self.versionInfo = version
                        }
                    }
                    connection.onSettingAcknowledged = { [weak self] command, status in
                        Task { @MainActor in
                            guard let self, self.connection?.id == connectionID else { return }
                            self.connectionMessage = self.describeAcknowledgement(command: command, status: status)
                            if status == 0, command != SpinDisplayProtocol.deleteFileCommand {
                                try? self.connection?.refreshDeviceInfo()
                            }
                        }
                    }
                    connection.startReceiving()
                case .failure(let error):
                    self.status = error.localizedDescription
                }
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var model = DeviceViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SpinDisplay")
                        .font(.largeTitle.bold())
                    Text("Fan control")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Scan") { model.startScanning() }
                    .keyboardShortcut("r", modifiers: .command)
            }

            Label(model.status, systemImage: "network")
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            TabView {
                connectionPage
                    .tabItem { Label("Connection", systemImage: "network") }
                playlistPage
                    .tabItem { Label("Playlist & Control", systemImage: "play.rectangle") }
                wifiPage
                    .tabItem { Label("Wi-Fi", systemImage: "wifi") }
                configurationPage
                    .tabItem { Label("Configuration", systemImage: "slider.horizontal.3") }
            }
            .confirmationDialog(
                "Delete this fan playlist item?",
                isPresented: Binding(
                    get: { model.deletionCandidate != nil },
                    set: { if !$0 { model.deletionCandidate = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete File", role: .destructive) {
                    if let deletionCandidate = model.deletionCandidate {
                        model.deletePlaylistItem(at: deletionCandidate)
                    }
                    model.deletionCandidate = nil
                }
                Button("Cancel", role: .cancel) {
                    model.deletionCandidate = nil
                }
            } message: {
                if let deletionCandidate = model.deletionCandidate,
                   model.playlist.indices.contains(deletionCandidate) {
                    Text("This removes \(model.playlist[deletionCandidate].name) from the fan.")
                }
            }
        }
        .padding(22)
        .frame(minWidth: 650, minHeight: 680)
        .onAppear { model.startScanning() }
        .sheet(item: $model.fileEditor) { _ in
            FileEditorSheet(model: model)
        }
        .sheet(item: $model.mediaConversion) { _ in
            MediaConversionSheet(model: model)
        }
        .confirmationDialog(
            "Delete all files on this fan?",
            isPresented: $model.showDeleteAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete All Files", role: .destructive) { model.deleteAllFiles() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every playlist item from \(model.deviceInfo?.deviceName ?? "the fan"). It cannot be undone from this app.")
        }
        .fileImporter(
            isPresented: $model.showFTLVImporter,
            allowedContentTypes: [UTType(filenameExtension: "ftlv") ?? .data]
        ) {
            model.uploadFTLV(from: $0)
        }
    }

    private var connectionPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("Discovered devices") {
                    if model.devices.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "fanblades")
                                .font(.system(size: 32))
                                .foregroundStyle(.secondary)
                            Text("No devices found yet")
                                .font(.headline)
                            Text("Check that the fan and Mac are on the same network, or connect by IP.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, minHeight: 130)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(model.devices) { device in
                                deviceRow(device)
                                if device.id != model.devices.last?.id {
                                    Divider()
                                }
                            }
                        }
                        .frame(maxHeight: 300)
                    }
                }

                GroupBox("Connect by IP address") {
                    HStack {
                        TextField("Fan IPv4 address", text: $model.manualAddress)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(model.connectManually)
                        Button(model.isConnecting ? "Connecting…" : "Connect") {
                            model.connectManually()
                        }
                        .disabled(model.isConnecting || model.manualAddress.isEmpty)
                    }
                    .padding(.vertical, 4)
                }

                GroupBox("Active connection") {
                    HStack {
                        Text(model.connectedDevice.map { "\($0.name) (\($0.address))" } ?? model.connectionMessage)
                            .textSelection(.enabled)
                        Spacer()
                        Button("Disconnect", role: .destructive) { model.disconnect() }
                            .disabled(!model.isConnected)
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(.vertical, 8)
        }
    }

    private var playlistPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !model.isConnected {
                    disconnectedNotice
                } else {
                    GroupBox("Fan controls") {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Label(
                                    model.isPowered.map { $0 ? "Powered on" : "Powered off" } ?? "Reading device status…",
                                    systemImage: model.isPowered == true ? "power" : "fanblades"
                                )
                                .foregroundStyle(.secondary)
                                Spacer()
                                Button("Power on") { model.setPower(true) }
                                Button("Power off", role: .destructive) { model.setPower(false) }
                            }

                            HStack(spacing: 12) {
                                Text("Brightness")
                                Slider(
                                    value: Binding(get: { Double(model.brightnessLevel) }, set: model.setBrightness),
                                    in: 0...5,
                                    step: 1
                                )
                                Text("\(50 + model.brightnessLevel * 10)%")
                                    .monospacedDigit()
                                    .frame(width: 48, alignment: .trailing)
                            }

                            HStack(spacing: 12) {
                                Button {
                                    model.skipPlaylist(by: -1)
                                } label: {
                                    Label("Back", systemImage: "backward.end.fill")
                                }
                                .disabled(model.playlist.isEmpty || model.currentPlaylistIndex == nil || model.currentPlaylistIndex == 0)
                                Button {
                                    model.playFile(at: model.currentPlaylistIndex ?? 0)
                                } label: {
                                    Label("Play from start", systemImage: "play.fill")
                                }
                                .disabled(model.playlist.isEmpty)
                                .help("Starts the selected item from its beginning.")
                                Button {
                                    if let index = model.currentPlaylistIndex {
                                        model.repeatPlaylistItem(at: index)
                                    }
                                } label: {
                                    Label("Repeat item", systemImage: "repeat")
                                }
                                .disabled(model.currentPlaylistIndex.map { !model.playlist.indices.contains($0) } ?? true)
                                .help("Plays the current item, then sets it to loop (the original app's Cycleplay).")
                                Button {
                                    model.skipPlaylist(by: 1)
                                } label: {
                                    Label("Skip", systemImage: "forward.end.fill")
                                }
                                .disabled(model.playlist.isEmpty || model.currentPlaylistIndex == model.playlist.count - 1)
                                Spacer(minLength: 0)
                            }

                            Label(
                                "Pause/resume and a reliable stop command are not mapped. The recovered stop sequence restarted playback on this fan.",
                                systemImage: "pause.circle"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }

                    GroupBox("Playlist") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("\(model.playlist.count) item(s)")
                                    .foregroundStyle(.secondary)
                                if let status = model.playbackStatus {
                                    Text("Response \(status.responseField), slot \(status.playlistSlot)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Refresh") { model.refreshPlaylist() }
                            }
                            if model.playlist.isEmpty {
                                Text("No playlist items reported yet.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, minHeight: 100)
                            } else {
                                VStack(spacing: 0) {
                                    ForEach(Array(model.playlist.enumerated()), id: \.offset) { index, file in
                                        HStack {
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(file.name)
                                                    .fontWeight(model.currentPlaylistIndex == index ? .semibold : .regular)
                                                    .lineLimit(1)
                                                Text("\(file.durationSeconds / 60):\(String(format: "%02d", file.durationSeconds % 60))  •  Type \(file.type)  •  Repeat \(file.repeating)  •  \(file.displayMode.map(Self.label) ?? "Show \(file.isShown)")")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            Button("Play from start") { model.playFile(at: index) }
                                            Button("Repeat") { model.repeatPlaylistItem(at: index) }
                                            Button {
                                                model.beginEditingFile(at: index)
                                            } label: {
                                                Image(systemName: "pencil")
                                            }
                                            .help("Edit name, repetition, and set-time playback")
                                            Button {
                                                model.movePlaylistItem(from: index, to: index - 1)
                                            } label: {
                                                Image(systemName: "arrow.up")
                                            }
                                            .disabled(index == 0)
                                            .help("Move earlier")
                                            Button {
                                                model.movePlaylistItem(from: index, to: index + 1)
                                            } label: {
                                                Image(systemName: "arrow.down")
                                            }
                                            .disabled(index == model.playlist.count - 1)
                                            .help("Move later")
                                            Button(role: .destructive) {
                                                model.deletionCandidate = index
                                            } label: {
                                                Image(systemName: "trash")
                                            }
                                            .help("Delete from fan")
                                        }
                                        .padding(.vertical, 7)
                                        if index < model.playlist.count - 1 { Divider() }
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    GroupBox("Upload media") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Convert an image, animated GIF, or video to the fan's format, or upload an existing .ftlv file.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let reason = model.conversionUnsupportedReason {
                                Text(reason)
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            Text(model.connectedDevice == nil
                                ? "Connect using a discovered fan so its device type can be checked."
                                : "The file's device type and length fields are validated before sending.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack {
                                if model.isUploadingFTLV {
                                    ProgressView(value: model.ftlvUploadProgress)
                                        .frame(maxWidth: 180)
                                    Text(model.ftlvUploadMessage)
                                        .font(.caption)
                                        .lineLimit(2)
                                } else {
                                    Text(model.ftlvUploadMessage)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer()
                                Button("Convert image or video…") {
                                    model.showMediaImporter = true
                                }
                                .disabled(model.isUploadingFTLV || model.mediaConversion != nil)
                                Button("Choose FTLV file") {
                                    model.showFTLVImporter = true
                                }
                                .disabled(
                                    !model.isConnected
                                        || model.connectedDevice == nil
                                        || model.isUploadingFTLV
                                )
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .fileImporter(
                        isPresented: $model.showMediaImporter,
                        allowedContentTypes: [.image, .movie, .gif]
                    ) {
                        model.chooseMedia(from: $0)
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    private var wifiPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !model.isConnected {
                disconnectedNotice
            }
            GroupBox("Configure fan Wi-Fi") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Wi-Fi network name (SSID)", text: $model.targetWiFiName)
                        .textFieldStyle(.roundedBorder)
                    SecureField("Wi-Fi password (leave blank if open)", text: $model.targetWiFiPassword)
                        .textFieldStyle(.roundedBorder)
                    Text("Applying these settings may disconnect the fan from its current network.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("Send Wi-Fi settings", role: .destructive) {
                            model.configureFanWiFi()
                        }
                        .disabled(!model.isConnected || model.targetWiFiName.isEmpty)
                    }
                }
                .padding(.vertical, 4)
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }

    private var configurationPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !model.isConnected {
                    disconnectedNotice
                }

                if model.isConnected {
                    deviceInformation
                }

                GroupBox("Device identity") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Device name (up to 24 UTF-8 bytes)", text: $model.configuredDeviceName)
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            Text("Renaming is sent to the connected fan.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Set name") { model.setConfiguredDeviceName() }
                                .disabled(!model.isConnected || model.configuredDeviceName.isEmpty)
                        }
                    }
                    .padding(.vertical, 4)
                }

                GroupBox("Orientation") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Angle")
                            Spacer()
                            Text("\(Int(model.fanAngleDegrees))°")
                                .monospacedDigit()
                        }
                        Slider(value: $model.fanAngleDegrees, in: -360...360, step: 1)
                        HStack {
                            Text("Angle commands follow the original app's -360°…360° encoding.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Apply angle") { model.setFanAngle() }
                                .disabled(!model.isConnected)
                        }
                    }
                    .padding(.vertical, 4)
                }

                GroupBox("Automatic power schedule") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Automatic power mode", isOn: $model.autoPowerOn)
                        Toggle("Scheduled shutdown", isOn: $model.shutdownScheduleEnabled)
                        DatePicker("Shutdown time", selection: $model.shutdownTime, displayedComponents: .hourAndMinute)
                            .disabled(!model.shutdownScheduleEnabled)
                        Toggle("Scheduled startup", isOn: $model.bootScheduleEnabled)
                        DatePicker("Startup time", selection: $model.bootTime, displayedComponents: .hourAndMinute)
                            .disabled(!model.bootScheduleEnabled)
                        HStack {
                            Spacer()
                            Button("Apply schedule") { model.setPowerSchedule() }
                                .disabled(!model.isConnected)
                        }
                    }
                    .padding(.vertical, 4)
                }

                GroupBox("Device clock") {
                    HStack {
                        Text("Send the Mac's current local date and time to the fan.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Sync clock") { model.syncClock() }
                            .disabled(!model.isConnected)
                    }
                    .padding(.vertical, 4)
                }

                GroupBox("Bluetooth audio") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("The fan plays video audio through an external Bluetooth speaker that it pairs with itself. It does not appear in the Mac's Bluetooth list.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Toggle(
                                "Turn on fan Bluetooth",
                                isOn: Binding(
                                    get: { model.bluetoothEnabled },
                                    set: model.setBluetoothEnabled
                                )
                            )
                            Spacer()
                            Button("Search and connect speaker") { model.searchForBluetoothSpeaker() }
                                .disabled(!model.isConnected || !model.bluetoothEnabled)
                        }
                        HStack {
                            Text("Volume")
                            Slider(value: $model.bluetoothVolume, in: 0...31, step: 1)
                            Text("\(Int(model.bluetoothVolume))")
                                .monospacedDigit()
                                .frame(width: 28, alignment: .trailing)
                        }
                        HStack {
                            Text("Choose a low level (for example 8) and send it before testing.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Set speaker volume") { model.setBluetoothVolume(model.bluetoothVolume) }
                                .disabled(!model.isConnected)
                        }
                        Text("To test: turn on fan Bluetooth, put a Bluetooth speaker in pairing mode near the fan, press Search and connect, then play a video that was converted with audio.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(model.bluetoothMessage)
                            .font(.callout)
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                        Text("The toggle starts from the fan's reported Bluetooth flag; it does not confirm that a speaker connection is active.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                GroupBox("Display mode") {
                    HStack {
                        Picker("Display mode", selection: $model.displayMode) {
                            Text("Highlight").tag(FanDisplayMode.highlight)
                            Text("True color").tag(FanDisplayMode.trueColor)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 260)
                        Spacer()
                        Button("Apply mode") { model.setDisplayMode(model.displayMode) }
                            .disabled(!model.isConnected)
                    }
                    .padding(.vertical, 4)
                }

                GroupBox("Login verification") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Require a password to connect", isOn: $model.loginVerificationEnabled)
                        SecureField("New password (1–8 characters)", text: $model.loginPassword)
                            .textFieldStyle(.roundedBorder)
                            .disabled(!model.loginVerificationEnabled)
                        HStack {
                            Text("Takes effect after reconnecting. Keep the password: discovery will ask for it before connecting.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Save verification") { model.applyLoginVerification() }
                                .disabled(
                                    !model.isConnected
                                        || (model.loginVerificationEnabled && model.loginPassword.isEmpty)
                                )
                        }
                    }
                    .padding(.vertical, 4)
                }

                GroupBox("Third-party control") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(
                            "Allow control through the third-party API",
                            isOn: Binding(get: { model.thirdPartyControlEnabled }, set: model.setThirdPartyControl)
                        )
                        .disabled(!model.isConnected)
                        Text("Intended for secondary development. The original app recommends leaving this off.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                GroupBox("Storage") {
                    HStack {
                        Text(model.deviceInfo?.sdUsablePercent.map { "\($0.formatted())% usable" } ?? "Capacity not reported.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Delete all files…", role: .destructive) { model.showDeleteAllConfirmation = true }
                            .disabled(!model.isConnected || model.isUploadingFTLV)
                    }
                    .padding(.vertical, 4)
                }

                Text("Not yet exposed: factory reset, remote-control pairing, router disconnect, image/video conversion, screen projection, multi-fan splicing and sync groups, and firmware updates.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
        }
    }

    static func label(_ mode: FileDisplayMode) -> String {
        switch mode {
        case .allDay: return "All day"
        case .hidden: return "Hidden"
        case .scheduled: return "Set-time"
        }
    }

    private var deviceInformation: some View {
        GroupBox("Device information") {
            if let info = model.deviceInfo {
                VStack(alignment: .leading, spacing: 4) {
                    infoRow("Model", info.deviceModel.isEmpty ? "—" : info.deviceModel)
                    infoRow("Firmware", model.versionInfo.map { "\($0.firmware) (model \($0.model), protocol \($0.agreement))" } ?? "—")
                    infoRow("Serial", info.serialNumber)
                    infoRow(
                        "Factory date",
                        String(format: "%04d-%02d-%02d", info.factoryDate.year ?? 0, info.factoryDate.month ?? 0, info.factoryDate.day ?? 0)
                    )
                    infoRow("Display", "\(info.imageWidth)×\(info.imageSize) px, diameter \(info.diameter), up to \(info.maxFPS) fps")
                    infoRow("Content type", "\(info.contentType)\(info.contentType == 3 ? " (LED transcoding; media conversion not yet supported)" : "")")
                    infoRow("Capacity", info.sdUsablePercent.map { "\($0.formatted())% usable" } ?? "—")
                    infoRow(
                        "Network",
                        info.isRouterConnected
                            ? "Connected to router \(info.routerName.isEmpty ? "" : "“\(info.routerName)”")"
                            : "Not connected to a router"
                    )
                    if !info.hotspotName.isEmpty {
                        infoRow("Hotspot", info.hotspotName)
                    }
                    if !info.restrictions.isEmpty {
                        infoRow("Unsupported", restrictionNames(info.restrictions))
                    }
                }
                .padding(.vertical, 4)
            } else {
                Text("Waiting for the fan's parameter response…")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.callout)
    }

    private func restrictionNames(_ restrictions: FanFeatureRestrictions) -> String {
        let names: [(FanFeatureRestrictions, String)] = [
            (.autoOn, "auto power-on"), (.timingSwitch, "timed power"), (.timingPlay, "set-time playback"),
            (.projection, "projection"), (.sync, "sync"), (.remote, "remote"), (.router, "router"),
            (.clock, "clock"), (.voice, "audio")
        ]
        return names.filter { restrictions.contains($0.0) }.map(\.1).joined(separator: ", ")
    }

    private var disconnectedNotice: some View {
        VStack(spacing: 8) {
            Image(systemName: "network.slash")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Not connected")
                .font(.headline)
            Text("Connect to a fan from the Connection page to use these settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 140)
    }

    @ViewBuilder
    private func deviceRow(_ device: FanDevice) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(device.name).font(.headline)
                    Text("\(device.address)  •  \(device.macAddress)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text("Type \(device.deviceType), firmware \(device.firmwareVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if device.passwordProtected {
                    Label("Password", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if device.passwordProtected {
                HStack {
                    SecureField("Device password", text: $model.password)
                        .textFieldStyle(.roundedBorder)
                    Button("Verify & connect") { model.authenticate(device) }
                        .disabled(model.isConnecting || model.password.isEmpty)
                }
            } else {
                HStack {
                    Spacer()
                    Button("Connect") {
                        model.connect(device)
                    }
                    .disabled(model.isConnecting)
                }
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 4)
    }
}

/// Mirrors the original File Edit window: name, repetition, display mode, and eight weekly set-time windows.
private struct FileEditorSheet: View {
    @ObservedObject var model: DeviceViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let editor = model.fileEditor {
            VStack(alignment: .leading, spacing: 14) {
                Text("Edit File").font(.title2.bold())
                Form {
                    TextField("File name", text: binding(\.name))
                    Stepper(value: binding(\.repeatCount), in: 0...255) {
                        Text("Repetition: \(editor.repeatCount)")
                    }
                    Picker("Playback", selection: binding(\.displayMode)) {
                        Text("All day").tag(FileDisplayMode.allDay)
                        Text("Hidden").tag(FileDisplayMode.hidden)
                        if model.supportsScheduledPlayback || editor.displayMode == .scheduled {
                            Text("Set-time").tag(FileDisplayMode.scheduled)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                if editor.displayMode == .scheduled {
                    if !model.supportsScheduledPlayback {
                        Text("This fan reports that set-time playback is not supported.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(0..<PlaybackTimeSlot.count, id: \.self) { slot in
                                timeSlotRow(slot)
                                if slot < PlaybackTimeSlot.count - 1 { Divider() }
                            }
                        }
                    }
                    .frame(minHeight: 220)
                }
                if let problem = model.fileEditorProblem(editor) {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) {
                        model.fileEditor = nil
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    Button("Save to fan") { model.saveFileEditor() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.fileEditorProblem(editor) != nil || !model.isConnected)
                }
            }
            .padding(20)
            .frame(width: 560)
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<DeviceViewModel.FileEditorState, Value>) -> Binding<Value> {
        // Bindings are only created while the sheet's state exists. SwiftUI may still read them after the
        // state is cleared during dismissal, so fall back to the value captured here instead of unwrapping.
        let fallback = model.fileEditor.map { $0[keyPath: keyPath] }
        return Binding(
            get: { model.fileEditor?[keyPath: keyPath] ?? fallback! },
            set: { model.fileEditor?[keyPath: keyPath] = $0 }
        )
    }

    private func slotBinding(_ slot: Int) -> Binding<PlaybackTimeSlot> {
        binding(\.timeSlots[slot])
    }

    private func timeBinding(_ slot: Int, hour: WritableKeyPath<PlaybackTimeSlot, UInt8>, minute: WritableKeyPath<PlaybackTimeSlot, UInt8>) -> Binding<Date> {
        Binding(
            get: {
                let value = slotBinding(slot).wrappedValue
                return Calendar.current.date(from: DateComponents(hour: Int(min(value[keyPath: hour], 23)), minute: Int(min(value[keyPath: minute], 59)))) ?? Date()
            },
            set: { date in
                let components = Calendar.current.dateComponents([.hour, .minute], from: date)
                slotBinding(slot).wrappedValue[keyPath: hour] = UInt8(components.hour ?? 0)
                slotBinding(slot).wrappedValue[keyPath: minute] = UInt8(components.minute ?? 0)
            }
        )
    }

    private func timeSlotRow(_ slot: Int) -> some View {
        let value = slotBinding(slot)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("Window \(slot + 1)", isOn: value.isEnabled)
                Spacer()
                DatePicker("Start", selection: timeBinding(slot, hour: \.startHour, minute: \.startMinute), displayedComponents: .hourAndMinute)
                    .labelsHidden()
                Text("–")
                DatePicker("End", selection: timeBinding(slot, hour: \.endHour, minute: \.endMinute), displayedComponents: .hourAndMinute)
                    .labelsHidden()
            }
            HStack(spacing: 6) {
                ForEach(PlaybackTimeSlot.weekdayBits, id: \.bit) { day in
                    Toggle(day.name, isOn: Binding(
                        get: { value.wrappedValue.weekdays & day.bit != 0 },
                        set: { isOn in
                            if isOn { value.wrappedValue.weekdays |= day.bit } else { value.wrappedValue.weekdays &= ~day.bit }
                        }
                    ))
                    .toggleStyle(.button)
                    .controlSize(.small)
                }
            }
        }
        .opacity(value.wrappedValue.isEnabled ? 1 : 0.6)
    }
}

/// Options and preview for converting an image, GIF, or video to FTLV.
private struct MediaConversionSheet: View {
    @ObservedObject var model: DeviceViewModel

    var body: some View {
        if let state = model.mediaConversion {
            VStack(alignment: .leading, spacing: 14) {
                Text("Convert Media").font(.title2.bold())
                HStack(alignment: .top, spacing: 18) {
                    preview(state)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(state.sourceURL.lastPathComponent)
                            .font(.headline)
                            .lineLimit(2)
                        Text(describe(state.kind))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("Framing", selection: binding(\.framing)) {
                            Text("Fill circle").tag(MediaConverter.Framing.fill)
                            Text("Fit whole image").tag(MediaConverter.Framing.fit)
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: state.framing) { _ in model.refreshMediaPreview() }
                        if case .video(let duration, _, let hasAudio) = state.kind {
                            let last = MediaConverter.availableSeconds(duration: duration, holdLastFrame: state.holdLastFrame)
                            Stepper(value: binding(\.startSecond), in: 0...(last - 1)) {
                                Text("Start: \(state.startSecond) s")
                            }
                            .onChange(of: state.startSecond) { start in
                                if (model.mediaConversion?.endSecond ?? last) <= start { model.mediaConversion?.endSecond = start + 1 }
                                model.refreshMediaPreview()
                            }
                            Stepper(value: Binding(
                                get: { state.endSecond ?? last },
                                set: { model.mediaConversion?.endSecond = $0 == last ? nil : $0 }
                            ), in: (state.startSecond + 1)...last) {
                                Text("End: \(state.endSecond ?? last) s")
                            }
                            Toggle("Hold last frame to finish the video", isOn: binding(\.holdLastFrame))
                                .onChange(of: state.holdLastFrame) { hold in
                                    let newLast = MediaConverter.availableSeconds(duration: duration, holdLastFrame: hold)
                                    model.mediaConversion?.endSecond = nil
                                    if (model.mediaConversion?.startSecond ?? 0) > newLast - 1 {
                                        model.mediaConversion?.startSecond = newLast - 1
                                    }
                                }
                                .help("On: the length rounds up to whole seconds and the final frame repeats. Off: the original app's behavior, which drops the last partial second.")
                            Toggle("Include audio", isOn: binding(\.includeAudio))
                                .disabled(!hasAudio)
                        }
                        Text(targetDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 260)
                }
                if state.isWorking {
                    ProgressView(value: state.progress)
                }
                if !state.message.isEmpty {
                    Text(state.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { model.closeMediaConversion() }
                        .keyboardShortcut(.cancelAction)
                    Button("Export .ftlv…") { model.exportMediaConversion() }
                        .disabled(state.isWorking || model.conversionUnsupportedReason != nil)
                    Button("Convert & upload") { model.runMediaConversion() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(
                            state.isWorking || !model.isConnected || model.connectedDevice == nil
                                || model.isUploadingFTLV || model.conversionUnsupportedReason != nil
                        )
                }
            }
            .padding(20)
            .frame(width: 560)
        }
    }

    private var targetDescription: String {
        let target = model.conversionTarget
        let source = model.deviceInfo == nil ? "default fan settings" : "the connected fan"
        return "Frames: \(target.imageSize)×\(target.imageSize) JPEG, up to \(target.maxFPS) fps (\(source)). Still images show for 10 s per loop."
    }

    private func preview(_ state: DeviceViewModel.MediaConversionState) -> some View {
        ZStack {
            Circle().fill(Color.black)
            if let image = state.preview {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .clipShape(Circle())
            } else {
                ProgressView()
            }
        }
        .frame(width: 220, height: 220)
    }

    private func describe(_ kind: MediaConverter.MediaKind) -> String {
        switch kind {
        case .image:
            return "Still image"
        case .animatedImage(let frames, let duration):
            return "Animation: \(frames) frames, \(String(format: "%.1f", duration)) s"
        case .video(let duration, let fps, let hasAudio):
            return "Video: \(String(format: "%.1f", duration)) s at \(String(format: "%.2f", fps)) fps\(hasAudio ? ", with audio" : "")"
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<DeviceViewModel.MediaConversionState, Value>) -> Binding<Value> {
        // Bindings are only created while the sheet's state exists. SwiftUI may still read them after the
        // state is cleared during dismissal, so fall back to the value captured here instead of unwrapping.
        let fallback = model.mediaConversion.map { $0[keyPath: keyPath] }
        return Binding(
            get: { model.mediaConversion?[keyPath: keyPath] ?? fallback! },
            set: { model.mediaConversion?[keyPath: keyPath] = $0 }
        )
    }
}
