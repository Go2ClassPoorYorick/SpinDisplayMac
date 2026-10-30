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
    @Published var transcoding: FanTranscoding?
    @Published var binConfiguration: FanBinConfiguration?
    /// Frame encoding for this fan's content type, rebuilt when its parameters arrive.
    private var fanEncoding: MediaConverter.FrameEncoding = .standard
    @Published var rotationSpeedRPM: Int?
    @Published var isLampTestActive = false
    @Published var firmwareCandidate: FirmwareCandidate?
    @Published var allowFirmwareModelMismatch = false
    @Published var isUpdatingFirmware = false
    @Published var firmwareProgress = 0.0
    @Published var firmwareMessage = ""

    struct FirmwareCandidate: Identifiable {
        let url: URL
        let package: FirmwarePackageInfo
        var id: URL { url }
    }
    @Published var rawCommandText = "68 11 00 00"
    @Published var consoleLines: [String] = []
    @Published var consoleHidesRoutine = true
    @Published var isMeasuringSpeed = false
    @Published var displayMode: FanDisplayMode = .highlight
    @Published var syncGroup = 0
    @Published var isSyncHost = false
    @Published var thirdPartyControlEnabled = false
    @Published var loginVerificationEnabled = false
    @Published var loginPassword = ""
    @Published var showDeleteAllConfirmation = false
    @Published var fileEditor: FileEditorState?
    @Published var mediaConversion: MediaConversionState?
    @Published var showMediaImporter = false
    let fleet = FleetModel()
    /// Crop at the start of a preview drag; the drag offsets are applied relative to it.
    var mediaDragStartCrop: MediaConverter.Crop?
    @Published var experimentalUnlocked = false
    @Published var isProjecting = false
    @Published var isStartingProjection = false
    @Published var projectionMessage = "Mirrors the center of your main display onto the fan."
    @Published var projectionFramesSent = 0
    @Published var projectionFPS = 0.0
    @Published var projectionSourceKind: ProjectionSourceKind = .area
    @Published var projectionDisplays: [ProjectionSources.Display] = []
    @Published var projectionWindows: [ProjectionSources.Window] = []
    @Published var projectionDisplayID: CGDirectDisplayID?
    @Published var projectionAreaRect: CGRect?
    @Published var projectionWindowID: CGWindowID?
    @Published var projectionCrop = MediaConverter.Crop()
    @Published var showCaptureFrame = true
    @Published var projectionPreview: CGImage?
    /// The capture frame is shown only while the Projection tab is open or a projection is running.
    var projectionPageVisible = false {
        didSet { updateCaptureOverlay() }
    }
    private var projector: ScreenProjector?
    private var captureOverlay: CaptureOverlay?
    private var sourceUpdateInFlight = false
    private var sourceUpdatePending = false

    enum ProjectionSourceKind: String, CaseIterable, Identifiable {
        case area
        case window
        var id: String { rawValue }
    }
    private var projectionCounterTimer: Timer?
    private let projectionCounter = FrameCounter()

    /// Frames sent from the capture queue, read once per second on the main actor.
    final class FrameCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.withLock { count += 1 } }
        func take() -> Int { lock.withLock { defer { count = 0 }; return count } }
    }
    @Published var pendingExperimentalAction: ExperimentalAction?
    @Published var isRemoteMatching = false

    /// Export targets, following the original Export window (generic, device types 25 and 26).
    enum ExportFormat: String, CaseIterable, Identifiable {
        case fan
        case generic
        case type25
        case type26
        var id: String { rawValue }
    }

    /// The export choices available now: "This fan" only when the fan uses an FTLV-compatible format.
    var availableExportFormats: [ExportFormat] {
        var formats: [ExportFormat] = [.generic, .type25, .type26]
        if case .mold = fanEncoding { formats.insert(.fan, at: 0) }
        return formats
    }

    func exportFormatLabel(_ format: ExportFormat) -> String {
        switch format {
        case .fan: return "This fan (type \(connectedDevice?.deviceType ?? 0))"
        case .generic: return "Generic"
        case .type25: return "Device type 25"
        case .type26: return "Device type 26"
        }
    }

    private func exportTarget(_ format: ExportFormat) -> MediaConverter.Target {
        let base = conversionTarget
        switch format {
        case .fan:
            return base
        case .generic:
            return MediaConverter.Target(imageSize: base.imageSize, maxFPS: base.maxFPS)
        case .type25, .type26:
            let deviceType: UInt8 = format == .type25 ? 25 : 26
            // The original Export window uses 672-pixel frames and fixed mold presets for these types.
            let mold = MoldTranscoder.exportPreset(deviceType: deviceType, imageWidth: 672)!
            return MediaConverter.Target(imageSize: 672, maxFPS: base.maxFPS, encoding: .mold(mold, deviceType: deviceType))
        }
    }

    enum ExperimentalAction: String, Identifiable {
        case factoryReset
        case remotePairing
        case routerDisconnect
        var id: String { rawValue }
    }

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
        var crop = MediaConverter.Crop()
        var previewSource: CGImage?
        var includeAudio = true
        var startSecond = 0
        var endSecond: Int?
        var holdLastFrame = true
        var exportFormat: ExportFormat = .fan
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

    private var terminationObserver: NSObjectProtocol?

    init() {
        // On quit, end projection on the fan (0x37 0) and close the control connection cleanly.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stopProjection()
                self?.disconnect()
            }
        }
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
        rotationSpeedRPM = nil
        isMeasuringSpeed = false
        transcoding = nil
        binConfiguration = nil
        fanEncoding = .standard
        isLampTestActive = false
        fileEditor = nil
        hasLoadedSettings = false
        isRemoteMatching = false
        pendingExperimentalAction = nil
        tearDownProjection()
    }

    // MARK: - Screen projection

    var projectionUnsupportedReason: String? {
        if deviceInfo?.restrictions.contains(.projection) == true {
            return "The device does not support the screen projection function."
        }
        // Content-type-3 fans project mold JPEGs, which need their transcoding parameters; the original
        // projects plain JPEGs to every other content type.
        if deviceInfo?.contentType == 3, transcoding == nil {
            return "Waiting for this fan's LED transcoding parameters (content type 3)…"
        }
        return nil
    }

    /// Lists displays and windows (this also triggers the Screen Recording prompt the first time).
    func loadProjectionSources() {
        Task {
            do {
                let sources = try await ProjectionSources.load()
                projectionDisplays = sources.displays
                projectionWindows = sources.windows
                if projectionDisplayID == nil || !sources.displays.contains(where: { $0.id == projectionDisplayID }) {
                    let main = sources.displays.first { $0.id == CGMainDisplayID() } ?? sources.displays.first
                    projectionDisplayID = main?.id
                    projectionAreaRect = nil
                }
                if let windowID = projectionWindowID, !sources.windows.contains(where: { $0.id == windowID }) {
                    projectionWindowID = nil
                }
                if projectionWindowID == nil { projectionWindowID = sources.windows.first?.id }
                if projectionAreaRect == nil { resetProjectionArea() } else { projectionSourceChanged() }
            } catch {
                projectionMessage = error.localizedDescription
            }
        }
    }

    private var selectedDisplay: ProjectionSources.Display? {
        projectionDisplays.first { $0.id == projectionDisplayID }
    }

    var currentProjectionSource: ProjectionSource? {
        switch projectionSourceKind {
        case .area:
            guard let id = projectionDisplayID, let rect = projectionAreaRect else { return nil }
            return .displayArea(displayID: id, rect: rect)
        case .window:
            guard let id = projectionWindowID else { return nil }
            return .window(windowID: id, crop: projectionCrop)
        }
    }

    /// The original's default: a centered square of the display's shorter side, at most 1024 points.
    func resetProjectionArea() {
        guard let display = selectedDisplay else { return }
        projectionAreaRect = ScreenProjector.captureRect(screenWidth: display.size.width, screenHeight: display.size.height)
        projectionSourceChanged()
    }

    /// Resizes the capture square around its center, keeping it on the display.
    func setProjectionAreaSize(_ side: CGFloat) {
        guard let display = selectedDisplay, let rect = projectionAreaRect else { return }
        let clamped = min(max(side, 120), min(display.size.width, display.size.height))
        var resized = CGRect(x: rect.midX - clamped / 2, y: rect.midY - clamped / 2, width: clamped, height: clamped)
        resized.origin.x = min(max(resized.minX, 0), display.size.width - clamped)
        resized.origin.y = min(max(resized.minY, 0), display.size.height - clamped)
        projectionAreaRect = resized
        projectionSourceChanged()
    }

    func setProjectionCrop(_ crop: MediaConverter.Crop) {
        var adjusted = crop
        adjusted.zoom = min(max(adjusted.zoom, MediaConverter.Crop.zoomRange.lowerBound), MediaConverter.Crop.zoomRange.upperBound)
        adjusted.centerX = min(max(adjusted.centerX, 0), 1)
        adjusted.centerY = min(max(adjusted.centerY, 0), 1)
        projectionCrop = adjusted
        projectionSourceChanged()
    }

    /// Updates the on-screen frame and, while projecting, the running capture.
    func projectionSourceChanged() {
        updateCaptureOverlay()
        pushProjectionSource()
    }

    private func updateCaptureOverlay() {
        guard showCaptureFrame, projectionSourceKind == .area, projectionPageVisible || isProjecting,
              let id = projectionDisplayID, let rect = projectionAreaRect,
              let screen = NSScreenLookup.screen(for: id) else {
            captureOverlay?.close()
            captureOverlay = nil
            return
        }
        if let captureOverlay {
            captureOverlay.update(screen: screen, rect: rect)
        } else {
            let overlay = CaptureOverlay(screen: screen, rect: rect)
            overlay.onChange = { [weak self] rect in
                guard let self else { return }
                self.projectionAreaRect = rect
                self.pushProjectionSource()
            }
            captureOverlay = overlay
            // The overlay must be excluded from a capture that is already running.
            pushProjectionSource(force: true)
        }
    }

    private var excludedWindowIDs: [CGWindowID] {
        captureOverlay.map { [$0.windowID] } ?? []
    }

    /// Applies the current source to the running capture, coalescing rapid changes such as drags.
    private func pushProjectionSource(force: Bool = false) {
        guard isProjecting, let projector, let source = currentProjectionSource else { return }
        if sourceUpdateInFlight {
            sourceUpdatePending = true
            return
        }
        sourceUpdateInFlight = true
        let excluded = excludedWindowIDs
        Task {
            do {
                if force { try await projector.update(source: source, excludingWindowIDs: excluded, forceFilter: true) }
                else { try await projector.update(source: source, excludingWindowIDs: excluded) }
            } catch {
                projectionMessage = error.localizedDescription
            }
            sourceUpdateInFlight = false
            if sourceUpdatePending {
                sourceUpdatePending = false
                pushProjectionSource()
            }
        }
    }

    func startProjection() {
        guard isConnected, let connection else {
            projectionMessage = "Connect to the fan before projecting."
            return
        }
        if let reason = projectionUnsupportedReason {
            projectionMessage = reason
            return
        }
        guard !isUploadingFTLV else {
            projectionMessage = "Wait for the current upload to finish."
            return
        }
        guard !isProjecting, !isStartingProjection else { return }
        guard currentProjectionSource != nil else {
            projectionMessage = projectionSourceKind == .window
                ? "Choose a window to project (press Refresh to list windows)."
                : "Choose a display to project (press Refresh to list displays)."
            loadProjectionSources()
            return
        }
        isStartingProjection = true
        projectionMessage = "Asking the fan to start projection (retrying every 2 s for up to 30 s)…"
        let connectionID = connection.id
        let target = conversionTarget
        connection.startProjection { [weak self] result in
            Task { @MainActor in
                guard let self, self.connection?.id == connectionID else { return }
                switch result {
                case .failure(let error):
                    self.isStartingProjection = false
                    self.projectionMessage = error.localizedDescription
                case .success:
                    await self.beginCapture(connection: connection, target: target)
                }
            }
        }
    }

    private func beginCapture(connection: DeviceConnection, target: MediaConverter.Target) async {
        var mold: MoldTranscoder?
        if case .mold(let transcoder, _) = target.encoding { mold = transcoder }
        let projector = ScreenProjector(imageSize: target.imageSize, maxFPS: target.maxFPS, mold: mold)
        let counter = projectionCounter
        _ = counter.take()
        projector.onFrame = { jpeg in
            if connection.sendProjectionFrame(jpeg) { counter.increment() }
        }
        projector.onStopped = { [weak self] message in
            Task { @MainActor in self?.stopProjection(message: message) }
        }
        projector.onPreview = { [weak self] image in
            Task { @MainActor in self?.projectionPreview = image }
        }
        do {
            guard let source = currentProjectionSource else { throw ScreenProjector.ProjectionError.noDisplay }
            try await projector.start(source: source, excludingWindowIDs: excludedWindowIDs)
        } catch {
            connection.stopProjection()
            isStartingProjection = false
            projectionMessage = error.localizedDescription
            return
        }
        self.projector = projector
        isStartingProjection = false
        isProjecting = true
        updateCaptureOverlay()
        projectionFramesSent = 0
        projectionFPS = 0
        projectionMessage = projectionSourceKind == .area
            ? "Projecting the framed area. Drag the orange frame to move it, scroll over it to resize."
            : "Projecting the selected window. It is followed if you move it."
        projectionCounterTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let frames = self.projectionCounter.take()
                self.projectionFramesSent += frames
                self.projectionFPS = Double(frames)
            }
        }
    }

    func stopProjection(message: String = "Projection stopped.") {
        guard isProjecting || isStartingProjection else { return }
        tearDownProjection()
        connection?.stopProjection()
        projectionMessage = message
    }

    private func tearDownProjection() {
        projector?.stop()
        projector = nil
        projectionCounterTimer?.invalidate()
        projectionCounterTimer = nil
        isProjecting = false
        isStartingProjection = false
        projectionFPS = 0
        projectionPreview = nil
        sourceUpdatePending = false
        updateCaptureOverlay()
    }

    /// Fills the editable settings from the fan once per connection so periodic refreshes don't overwrite edits.
    private func applyDeviceInfo(_ info: FanDeviceInfo) {
        let imageSizeChanged = deviceInfo?.imageSize != info.imageSize
        deviceInfo = info
        if imageSizeChanged { rebuildFanEncoding() }
        guard !hasLoadedSettings else { return }
        hasLoadedSettings = true
        // The original queries transcoding at connect for content type 3 and bin parameters for type 1.
        if info.contentType == 3 { try? connection?.requestTranscoding() }
        if info.contentType == 1 { try? connection?.requestBinConfiguration() }
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
        syncGroup = Int(info.groupNumber)
        isSyncHost = info.syncFlag == 1
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
        case SpinDisplayProtocol.syncGroupCommand:
            return accepted ? "Sync group saved." : "The fan rejected the sync group (status \(status))."
        case SpinDisplayProtocol.setCoordinateCommand:
            return accepted ? "Splicing position saved." : "The fan rejected the splicing position (status \(status))."
        case SpinDisplayProtocol.jointModeCommand:
            return accepted ? "Splicing mode changed." : "The fan rejected the splicing mode (status \(status))."
        case SpinDisplayProtocol.resetCommand:
            return accepted ? "Factory settings restored successfully." : "The fan rejected the factory reset (status \(status))."
        case SpinDisplayProtocol.remoteMatchCommand:
            if status == 2 {
                isRemoteMatching = false
                return "Remote control matched."
            }
            return accepted ? "Remote pairing started: press any key on the remote." : "Remote pairing response: status \(status)."
        default:
            return "Response 0x\(String(format: "%02X", command)) status \(status)."
        }
    }

    /// Original Settings "Sync Group": group 0–20 and "Set as host (a sync group can only have one host)".
    func applySyncGroup() {
        guard isConnected, let connection else {
            connectionMessage = "Connect to the fan before changing its sync group."
            return
        }
        do {
            try connection.setSyncGroup(syncGroup, isHost: isSyncHost)
            connectionMessage = "Sync group command sent."
        } catch {
            connectionMessage = error.localizedDescription
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

    /// Runs an experimental command after its confirmation; each is locked behind `experimentalUnlocked`.
    func performExperimentalAction(_ action: ExperimentalAction) {
        guard experimentalUnlocked else {
            connectionMessage = "Unlock experimental features first."
            return
        }
        guard isConnected, let connection else {
            connectionMessage = "Connect to the fan first."
            return
        }
        do {
            switch action {
            case .factoryReset:
                try connection.factoryReset()
                hasLoadedSettings = false
                connectionMessage = "Factory reset command sent."
            case .remotePairing:
                try connection.setRemoteMatching(true)
                isRemoteMatching = true
                connectionMessage = "Remote pairing requested. Press any key on the remote."
            case .routerDisconnect:
                try connection.disconnectFromRouter(currentSSID: deviceInfo?.routerName ?? "")
                connectionMessage = "Router disconnect sent. The fan may drop off this network and return to its own hotspot."
            }
        } catch {
            connectionMessage = error.localizedDescription
        }
    }

    func cancelRemotePairing() {
        guard isConnected, let connection else { return }
        do {
            try connection.setRemoteMatching(false)
            isRemoteMatching = false
            connectionMessage = "Remote pairing cancelled."
        } catch {
            connectionMessage = error.localizedDescription
        }
    }

    // MARK: - Factory test tools (original TestWindow)

    func toggleLampTest() {
        guard experimentalUnlocked, isConnected, let connection else { return }
        let turnOn = !isLampTestActive
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try connection.setLampTest(turnOn) }
            Task { @MainActor in
                switch result {
                case .success:
                    self.isLampTestActive = turnOn
                    self.connectionMessage = "Lamp test \(turnOn ? "started" : "ended") (the fan was powered off first, as the original does)."
                case .failure(let error):
                    self.connectionMessage = error.localizedDescription
                }
            }
        }
    }

    /// Original Test Picture: four solid frames (red, green, blue, white), 2 seconds each.
    func uploadTestPicture() {
        guard experimentalUnlocked else { return }
        let size = conversionTarget.imageSize
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpinDisplayTestPicture-\(UUID().uuidString)", isDirectory: true)
        let output = directory.appendingPathComponent(uploadName(for: URL(fileURLWithPath: "Test picture.ftlv")))
            .appendingPathExtension("ftlv")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let writer = try FTLVWriter(url: output, magic: .standard, frameDuration: 2_000_000)
            for color: [UInt8] in [[255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 255, 255]] {
                var pixels = [UInt8](repeating: 255, count: size * size * 4)
                for pixel in 0..<(size * size) {
                    pixels[pixel * 4] = color[0]
                    pixels[pixel * 4 + 1] = color[1]
                    pixels[pixel * 4 + 2] = color[2]
                }
                try writer.appendVideoFrame(BaselineJPEGEncoder.encode(rgba: pixels, width: size, height: size), duration: 2_000_000)
            }
            try writer.finish()
        } catch {
            try? FileManager.default.removeItem(at: directory)
            connectionMessage = error.localizedDescription
            return
        }
        startUpload(of: output, validatingMessage: "Uploading the test picture…") {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: - Firmware update from a local .POVC package

    static func firmwareVersionText(_ version: Int) -> String {
        String(format: "%.2f", Double(version) / 100)
    }

    func chooseFirmwarePackage() {
        guard experimentalUnlocked else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a firmware package (.POVC)"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let header = [UInt8](try handle.read(upToCount: FirmwarePackageInfo.headerLength) ?? Data())
            let length = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            guard let package = FirmwarePackageInfo.parse(header: header, fileLength: length) else {
                firmwareMessage = "\(url.lastPathComponent) is not a firmware package (.POVC files start with byte FF)."
                return
            }
            allowFirmwareModelMismatch = false
            firmwareCandidate = FirmwareCandidate(url: url, package: package)
        } catch {
            firmwareMessage = error.localizedDescription
        }
    }

    /// Why the candidate cannot be flashed as-is, following the original's automatic-update rule.
    var firmwareBlockReason: String? {
        guard let candidate = firmwareCandidate else { return nil }
        guard isConnected, connectedDevice != nil else { return "Connect to a discovered fan first." }
        guard let version = versionInfo else { return "The fan's version has not been read yet." }
        if candidate.package.model != Int(version.model), !allowFirmwareModelMismatch {
            return "This package is for model \(candidate.package.model), but the fan reports model \(version.model)."
        }
        if isUploadingFTLV || isProjecting { return "Wait for the current upload or projection to finish." }
        return nil
    }

    func startFirmwareUpdate() {
        guard experimentalUnlocked, let candidate = firmwareCandidate, firmwareBlockReason == nil,
              let connection, !isUpdatingFirmware else { return }
        firmwareCandidate = nil
        isUpdatingFirmware = true
        firmwareProgress = 0
        firmwareMessage = "Starting the firmware update…"
        let connectionID = connection.id
        connection.updateFirmware(
            at: candidate.url,
            progress: { [weak self] progress, message in
                Task { @MainActor in
                    guard let self, self.connection?.id == connectionID else { return }
                    self.firmwareProgress = progress
                    self.firmwareMessage = message
                }
            },
            completion: { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    self.isUpdatingFirmware = false
                    switch result {
                    case .success:
                        self.firmwareProgress = 1
                        self.firmwareMessage = "Upgrade successful. The fan may restart; reconnect to confirm the new version."
                    case .failure(let error):
                        self.firmwareMessage = error.localizedDescription
                    }
                }
            }
        )
    }

    func sendRawCommand() {
        guard experimentalUnlocked, isConnected, let connection else { return }
        guard let packet = SpinDisplayProtocol.rawPacket(hex: rawCommandText) else {
            appendConsole("! Enter hex bytes starting with 68, command, and 2-byte length (the CRC is added).")
            return
        }
        do {
            try connection.sendRawPacket(packet)
            appendConsole("→ " + Self.hex(packet))
        } catch {
            appendConsole("! " + error.localizedDescription)
        }
    }

    func appendConsole(_ line: String) {
        consoleLines.append(line)
        if consoleLines.count > 200 { consoleLines.removeFirst(consoleLines.count - 200) }
    }

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// Read-only query from the original factory Test window's Speed button.
    func measureRotationSpeed() {
        guard isConnected, let connection else {
            connectionMessage = "Connect to the fan before measuring its speed."
            return
        }
        do {
            try connection.requestRotationSpeed()
            isMeasuringSpeed = true
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if isMeasuringSpeed {
                    isMeasuringSpeed = false
                    connectionMessage = "The fan did not answer the speed query."
                }
            }
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
        guard isBinFan else {
            startUpload(of: url, validatingMessage: "Validating FTLV file…") {
                if hasSecurityScope { url.stopAccessingSecurityScopedResource() }
            }
            return
        }
        // Like the original SendFTLVBinWork, re-encode the FTLV's frames as bin frames first.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpinDisplayBin-\(UUID().uuidString)", isDirectory: true)
        let output = directory.appendingPathComponent(url.deletingPathExtension().lastPathComponent).appendingPathExtension("ftlv")
        let target = conversionTarget
        ftlvUploadMessage = "Converting the FTLV frames for this fan…"
        Task {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try await Task.detached { try MediaConverter.rebinFTLV(url, target: target, output: output) }.value
                if hasSecurityScope { url.stopAccessingSecurityScopedResource() }
                startUpload(of: output, validatingMessage: "Uploading…") {
                    try? FileManager.default.removeItem(at: directory)
                }
            } catch {
                if hasSecurityScope { url.stopAccessingSecurityScopedResource() }
                try? FileManager.default.removeItem(at: directory)
                ftlvUploadMessage = error.localizedDescription
            }
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
        let progress: (Double, String) -> Void = { [weak self] progress, message in
            Task { @MainActor in
                guard let self, self.connection?.id == connectionID else { return }
                self.ftlvUploadProgress = progress
                self.ftlvUploadMessage = message
            }
        }
        let completion: (Result<Void, Error>) -> Void = { [weak self] result in
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
        if isBinFan {
            // Content-type-1 fans take bin frames over the 0x38 protocol instead of an FTLV file.
            connection.uploadBin(
                container: url,
                name: url.deletingPathExtension().lastPathComponent,
                voiceDisabled: deviceInfo?.restrictions.contains(.voice) == true,
                progress: progress,
                completion: completion
            )
        } else {
            connection.uploadFTLV(at: url, deviceType: device.deviceType, progress: progress, completion: completion)
        }
        return true
    }

    // MARK: - Media conversion

    var conversionTarget: MediaConverter.Target {
        guard let info = deviceInfo else { return .generic }
        return MediaConverter.Target(imageSize: info.imageSize, maxFPS: info.maxFPS, encoding: fanEncoding)
    }

    var conversionUnsupportedReason: String? {
        MediaConverter.unsupportedReason(
            contentType: deviceInfo?.contentType,
            hasTranscoding: transcoding != nil,
            hasBinConfiguration: binConfiguration != nil
        )
    }

    var isBinFan: Bool {
        if case .bin = fanEncoding { return true }
        return false
    }

    /// Builds the encoder for the fan's content type: mold JPEG (3), bin bit planes (1), or plain JPEG.
    private func rebuildFanEncoding() {
        let imageSize = deviceInfo?.imageSize ?? MediaConverter.Target.generic.imageSize
        switch deviceInfo?.contentType {
        case 3?:
            if let transcoding, let device = connectedDevice {
                fanEncoding = .mold(MoldTranscoder(transcoding: transcoding, imageWidth: imageSize), deviceType: device.deviceType)
            } else {
                fanEncoding = .standard
            }
        case 1?:
            fanEncoding = binConfiguration.map { .bin(BinTranscoder(configuration: $0, imageWidth: imageSize)) } ?? .standard
        default:
            fanEncoding = .standard
        }
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
                var state = MediaConversionState(sourceURL: url, hasSecurityScope: hasSecurityScope, kind: kind)
                state.exportFormat = availableExportFormats.first ?? .generic
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

    /// Loads the source frame shown in the preview (the frame at the start second for video).
    func refreshMediaPreview() {
        guard let state = mediaConversion else { return }
        Task {
            do {
                let source = try await MediaConverter.sourceFrame(state.sourceURL, kind: state.kind, startSecond: state.startSecond)
                guard mediaConversion?.id == state.id else { return }
                mediaConversion?.previewSource = source
                renderMediaPreview()
            } catch {
                mediaConversion?.message = error.localizedDescription
            }
        }
    }

    /// Re-renders the preview locally with the same circle rendering as conversion, at half resolution.
    func renderMediaPreview() {
        guard let state = mediaConversion, let source = state.previewSource else { return }
        let size = max(64, conversionTarget.imageSize / 2)
        mediaConversion?.preview = try? MediaConverter.render(source, size: size, crop: state.crop)
    }

    func setMediaCrop(_ crop: MediaConverter.Crop) {
        guard mediaConversion != nil else { return }
        var adjusted = crop
        adjusted.zoom = min(max(adjusted.zoom, MediaConverter.Crop.zoomRange.lowerBound), MediaConverter.Crop.zoomRange.upperBound)
        adjusted.centerX = min(max(adjusted.centerX, 0), 1)
        adjusted.centerY = min(max(adjusted.centerY, 0), 1)
        mediaConversion?.crop = adjusted
        renderMediaPreview()
    }

    /// Converts the selected media, then either uploads it or saves it to `exportURL`.
    func runMediaConversion(exportTo exportURL: URL? = nil) {
        guard var state = mediaConversion, !state.isWorking else { return }
        if !availableExportFormats.contains(state.exportFormat) { state.exportFormat = .generic }
        if exportURL == nil || state.exportFormat == .fan, let reason = conversionUnsupportedReason {
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
            crop: state.crop,
            includeAudio: state.includeAudio,
            startSecond: state.startSecond,
            endSecond: state.endSecond,
            holdLastFrame: state.holdLastFrame
        )
        let target = exportURL == nil ? conversionTarget : exportTarget(state.exportFormat)
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
                    connection.onRawFrame = { [weak self] frame in
                        Task { @MainActor in
                            guard let self, self.connection?.id == connectionID else { return }
                            // Heartbeat, playback status, and parameter refreshes arrive every few seconds.
                            if self.consoleHidesRoutine, [0x14, 0x35, 0x12].contains(frame[1]) { return }
                            self.appendConsole("← " + Self.hex(frame))
                        }
                    }
                    connection.onTranscoding = { [weak self] transcoding in
                        Task { @MainActor in
                            guard let self, self.connection?.id == connectionID else { return }
                            self.transcoding = transcoding
                            self.rebuildFanEncoding()
                        }
                    }
                    connection.onBinConfiguration = { [weak self] configuration in
                        Task { @MainActor in
                            guard let self, self.connection?.id == connectionID else { return }
                            self.binConfiguration = configuration
                            self.rebuildFanEncoding()
                        }
                    }
                    connection.onRotationSpeed = { [weak self] value in
                        Task { @MainActor in
                            guard let self, self.connection?.id == connectionID else { return }
                            self.rotationSpeedRPM = value
                            self.isMeasuringSpeed = false
                        }
                    }
                    connection.onProjectionEnded = { [weak self] message in
                        Task { @MainActor in
                            guard let self, self.connection?.id == connectionID else { return }
                            self.stopProjection(message: message)
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
                projectionPage
                    .tabItem { Label("Projection", systemImage: "rectangle.on.rectangle") }
                FleetView(fleet: model.fleet, model: model)
                    .tabItem { Label("Group", systemImage: "square.grid.2x2") }
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
        .sheet(item: $model.firmwareCandidate) { candidate in
            FirmwareConfirmationSheet(model: model, candidate: candidate)
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

    private var projectionPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !model.isConnected {
                    disconnectedNotice
                }
                GroupBox("Screen projection") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Streams part of your screen to the fan as \(model.conversionTarget.imageSize)×\(model.conversionTarget.imageSize) JPEGs at quality 30, up to \(model.conversionTarget.maxFPS) fps, like the original app. macOS asks for Screen Recording permission the first time; after allowing it you may need to reopen the app.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let reason = model.projectionUnsupportedReason {
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        HStack(alignment: .top, spacing: 18) {
                            projectionPreview
                            projectionSourceControls
                        }
                        HStack {
                            if model.isProjecting {
                                Label("\(Int(model.projectionFPS)) fps  •  \(model.projectionFramesSent) frames", systemImage: "dot.radiowaves.left.and.right")
                                    .monospacedDigit()
                            } else if model.isStartingProjection {
                                ProgressView().controlSize(.small)
                            }
                            Spacer()
                            if model.isProjecting || model.isStartingProjection {
                                Button("Stop projection", role: .destructive) { model.stopProjection() }
                            } else {
                                Button("Start projection") { model.startProjection() }
                                    .disabled(!model.isConnected || model.isUploadingFTLV || model.projectionUnsupportedReason != nil)
                            }
                        }
                        Text(model.projectionMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(.vertical, 8)
        }
        .onAppear {
            model.projectionPageVisible = true
            if model.projectionDisplays.isEmpty { model.loadProjectionSources() }
        }
        .onDisappear { model.projectionPageVisible = false }
    }

    private var projectionPreview: some View {
        ZStack {
            Circle().fill(Color.black)
            if let image = model.projectionPreview {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .clipShape(Circle())
            } else {
                Text(model.isProjecting ? "Waiting for frames…" : "Preview appears while projecting")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(24)
            }
        }
        .frame(width: 200, height: 200)
    }

    private var projectionSourceControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Source", selection: Binding(
                    get: { model.projectionSourceKind },
                    set: { model.projectionSourceKind = $0; model.projectionSourceChanged() }
                )) {
                    Text("Screen area").tag(DeviceViewModel.ProjectionSourceKind.area)
                    Text("Window").tag(DeviceViewModel.ProjectionSourceKind.window)
                }
                .pickerStyle(.segmented)
                Button("Refresh") { model.loadProjectionSources() }
                    .help("Reload the list of displays and windows")
            }
            switch model.projectionSourceKind {
            case .area:
                Picker("Display", selection: Binding(
                    get: { model.projectionDisplayID ?? 0 },
                    set: { model.projectionDisplayID = $0; model.resetProjectionArea() }
                )) {
                    ForEach(model.projectionDisplays) { display in
                        Text(display.name).tag(display.id)
                    }
                }
                if let rect = model.projectionAreaRect,
                   let display = model.projectionDisplays.first(where: { $0.id == model.projectionDisplayID }) {
                    let maximum = max(121, min(display.size.width, display.size.height))
                    HStack {
                        Text("Size")
                        Slider(value: Binding(
                            get: { Double(rect.width) },
                            set: { model.setProjectionAreaSize(CGFloat($0)) }
                        ), in: 120...Double(maximum))
                        Text("\(Int(rect.width)) pt")
                            .monospacedDigit()
                            .frame(width: 56, alignment: .trailing)
                    }
                }
                HStack {
                    Toggle("Show capture frame", isOn: Binding(
                        get: { model.showCaptureFrame },
                        set: { model.showCaptureFrame = $0; model.projectionSourceChanged() }
                    ))
                    Spacer()
                    Button("Center") { model.resetProjectionArea() }
                        .help("Restore the original app's area: a centered square, at most 1024 points")
                }
                Text("Drag the orange frame on screen to move the area; scroll over it to resize.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .window:
                Picker("Window", selection: Binding(
                    get: { model.projectionWindowID ?? 0 },
                    set: { model.projectionWindowID = $0; model.projectionSourceChanged() }
                )) {
                    ForEach(model.projectionWindows) { window in
                        Text(window.title).lineLimit(1).tag(window.id)
                    }
                }
                Picker("Framing", selection: Binding(
                    get: { model.projectionCrop.framing },
                    set: { model.setProjectionCrop(MediaConverter.Crop(framing: $0)) }
                )) {
                    Text("Fill circle").tag(MediaConverter.Framing.fill)
                    Text("Fit whole window").tag(MediaConverter.Framing.fit)
                }
                .pickerStyle(.segmented)
                HStack {
                    Text("Zoom")
                    Slider(value: Binding(
                        get: { model.projectionCrop.zoom },
                        set: { zoom in
                            var crop = model.projectionCrop
                            crop.zoom = zoom
                            model.setProjectionCrop(crop)
                        }
                    ), in: MediaConverter.Crop.zoomRange)
                    Text(String(format: "%.1f×", model.projectionCrop.zoom))
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                }
                HStack {
                    Text("Horizontal")
                    Slider(value: Binding(
                        get: { model.projectionCrop.centerX },
                        set: { x in
                            var crop = model.projectionCrop
                            crop.centerX = x
                            model.setProjectionCrop(crop)
                        }
                    ), in: 0...1)
                }
                HStack {
                    Text("Vertical")
                    Slider(value: Binding(
                        get: { model.projectionCrop.centerY },
                        set: { y in
                            var crop = model.projectionCrop
                            crop.centerY = y
                            model.setProjectionCrop(crop)
                        }
                    ), in: 0...1)
                    Button("Reset") { model.setProjectionCrop(MediaConverter.Crop(framing: model.projectionCrop.framing)) }
                        .controlSize(.small)
                }
                Text("The window is followed if you move it, and captured even when partly covered.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

                GroupBox("Sync group") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Picker("Group", selection: $model.syncGroup) {
                                Text("Ungrouped").tag(0)
                                ForEach(1...20, id: \.self) { Text("Sync group \($0)").tag($0) }
                            }
                            .frame(maxWidth: 240)
                            Toggle("Set as host", isOn: $model.isSyncHost)
                                .disabled(model.syncGroup == 0)
                            Spacer()
                            Button("Apply group") { model.applySyncGroup() }
                                .disabled(!model.isConnected || model.deviceInfo?.restrictions.contains(.sync) == true)
                        }
                        Text("Fans in the same group play in sync; a group can only have one host. Bluetooth audio is only available on the host of a group.")
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

                experimentalSection

                Text("Firmware updates are not available: the original downloads firmware from the manufacturer's server, and a failed update could leave the fan unusable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
        }
    }

    private var experimentalSection: some View {
        GroupBox("Experimental — not tested on hardware") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("I understand these commands are experimental and untested", isOn: $model.experimentalUnlocked)
                Text("Decoded from the original app but never run on a fan. Each one asks for confirmation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Restore factory settings…", role: .destructive) {
                        model.pendingExperimentalAction = .factoryReset
                    }
                    Button("Disconnect from router…", role: .destructive) {
                        model.pendingExperimentalAction = .routerDisconnect
                    }
                }
                .disabled(!model.experimentalUnlocked)
                Divider()
                Text("Factory tests (the original's Test window)")
                    .font(.subheadline.weight(.semibold))
                HStack {
                    Button(model.isLampTestActive ? "End lamp test" : "Start lamp test") { model.toggleLampTest() }
                        .help("Powers the fan off, then toggles the LED test pattern (0xE1).")
                    Button("Upload test picture") { model.uploadTestPicture() }
                        .disabled(model.isUploadingFTLV || model.isProjecting)
                        .help("Four solid frames, red, green, blue, and white, 2 seconds each.")
                }
                .disabled(!model.experimentalUnlocked)
                Text("Raw command (hex, CRC added automatically)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("68 11 00 00", text: $model.rawCommandText)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .onSubmit { model.sendRawCommand() }
                    Button("Send") { model.sendRawCommand() }
                }
                .disabled(!model.experimentalUnlocked)
                HStack {
                    Toggle("Hide heartbeat and status traffic", isOn: $model.consoleHidesRoutine)
                        .font(.caption)
                    Spacer()
                    Button("Clear") { model.consoleLines.removeAll() }
                        .controlSize(.small)
                }
                ScrollView {
                    Text(model.consoleLines.suffix(60).joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 110)
                .background(Color(nsColor: .textBackgroundColor))
                Divider()
                Text("Firmware update from a local package")
                    .font(.subheadline.weight(.semibold))
                Text("Uses a .POVC file already on this Mac, such as the one bundled with the original app (356256A/package/1.POVC). Downloading firmware needs the manufacturer's server and is not supported. A failed or mismatched update could leave the fan unusable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Choose firmware package…") { model.chooseFirmwarePackage() }
                        .disabled(model.isUpdatingFirmware)
                    if model.isUpdatingFirmware {
                        ProgressView(value: model.firmwareProgress)
                            .frame(maxWidth: 160)
                    }
                }
                .disabled(!model.experimentalUnlocked)
                if !model.firmwareMessage.isEmpty {
                    Text(model.firmwareMessage)
                        .font(.caption)
                        .textSelection(.enabled)
                }
                Divider()
                HStack {
                    Button("Pair remote control…") { model.pendingExperimentalAction = .remotePairing }
                        .disabled(model.isRemoteMatching)
                    Button("Cancel pairing") { model.cancelRemotePairing() }
                        .disabled(!model.isRemoteMatching)
                    if model.isRemoteMatching {
                        ProgressView().controlSize(.small)
                        Text("Press any key on the remote…").font(.caption)
                    }
                }
                .disabled(!model.experimentalUnlocked)
            }
            .disabled(!model.isConnected)
            .padding(.vertical, 4)
        }
        .confirmationDialog(
            experimentalTitle,
            isPresented: Binding(
                get: { model.pendingExperimentalAction != nil },
                set: { if !$0 { model.pendingExperimentalAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Continue", role: .destructive) {
                if let action = model.pendingExperimentalAction { model.performExperimentalAction(action) }
                model.pendingExperimentalAction = nil
            }
            Button("Cancel", role: .cancel) { model.pendingExperimentalAction = nil }
        } message: {
            Text(experimentalMessage)
        }
    }

    private var experimentalTitle: String {
        switch model.pendingExperimentalAction {
        case .factoryReset: return "Restore factory settings?"
        case .remotePairing: return "Pair a remote control?"
        case .routerDisconnect: return "Disconnect the fan from its router?"
        case nil: return ""
        }
    }

    /// Warnings are the original app's own text where it has one.
    private var experimentalMessage: String {
        switch model.pendingExperimentalAction {
        case .factoryReset:
            return "The original app says this restores the device parameters but does not empty the contents. It may also reset Wi-Fi, which would take the fan off this network."
        case .remotePairing:
            return "Press any button on the remote after starting. The original app warns that after a successful match the device can only be controlled through the remote controller."
        case .routerDisconnect:
            return "The fan leaves its router and returns to its own hotspot. This Mac will lose the connection until you join the fan's hotspot or configure Wi-Fi again."
        case nil:
            return ""
        }
    }

    /// `rotationSpeedRPM` holds the fan's raw speed value. On the user's fan it read 680 while running and
    /// fell to 0 after power-off, so it behaves like RPM (a period would rise as the blades slow).
    static func speedDescription(_ value: Int) -> String {
        guard value > 0 else { return "Not spinning (0)" }
        return "≈\(value.formatted()) RPM (raw value; the original showed \((60_000_000 / value).formatted()))"
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
                    infoRow("Firmware", model.versionInfo.map { String(format: "%.2f (model %d, protocol %d)", Double($0.firmware) / 100, $0.model, $0.agreement) } ?? "—")
                    infoRow("Serial", info.serialNumber)
                    infoRow(
                        "Factory date",
                        String(format: "%04d-%02d-%02d", info.factoryDate.year ?? 0, info.factoryDate.month ?? 0, info.factoryDate.day ?? 0)
                    )
                    infoRow("Display", "\(info.imageWidth)×\(info.imageSize) px, diameter \(info.diameter), up to \(info.maxFPS) fps")
                    HStack(alignment: .firstTextBaseline) {
                        Text("Rotation speed")
                            .foregroundStyle(.secondary)
                            .frame(width: 100, alignment: .leading)
                        Text(model.rotationSpeedRPM.map(Self.speedDescription) ?? "—")
                            .monospacedDigit()
                            .help("The fan's value drops to 0 when the blades stop, so it reads as RPM. The original Test window showed 60,000,000 ÷ value, which gives impossible speeds.")
                        Spacer(minLength: 0)
                        if model.isMeasuringSpeed { ProgressView().controlSize(.small) }
                        Button("Measure") { model.measureRotationSpeed() }
                            .controlSize(.small)
                            .disabled(model.isMeasuringSpeed)
                    }
                    .font(.callout)
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
                        Picker("Framing", selection: Binding(
                            get: { state.crop.framing },
                            set: { model.setMediaCrop(MediaConverter.Crop(framing: $0)) }
                        )) {
                            Text("Fill circle").tag(MediaConverter.Framing.fill)
                            Text("Fit whole image").tag(MediaConverter.Framing.fit)
                        }
                        .pickerStyle(.segmented)
                        HStack {
                            Text("Zoom")
                            Slider(
                                value: Binding(
                                    get: { state.crop.zoom },
                                    set: { zoom in
                                        var crop = model.mediaConversion?.crop ?? state.crop
                                        crop.zoom = zoom
                                        model.setMediaCrop(crop)
                                    }
                                ),
                                in: MediaConverter.Crop.zoomRange
                            )
                            Text(String(format: "%.1f×", state.crop.zoom))
                                .monospacedDigit()
                                .frame(width: 36, alignment: .trailing)
                        }
                        HStack {
                            Text("Drag the preview to move the circle.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Reset") { model.setMediaCrop(MediaConverter.Crop(framing: state.crop.framing)) }
                                .controlSize(.small)
                        }
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
                    Picker("Export for", selection: binding(\.exportFormat)) {
                        ForEach(model.availableExportFormats) { format in
                            Text(model.exportFormatLabel(format)).tag(format)
                        }
                    }
                    .frame(width: 220)
                    .help("Like the original Export window: generic FTLV, or mold-encoded files for device types 25 and 26.")
                    Button("Export .ftlv…") { model.exportMediaConversion() }
                        .disabled(state.isWorking || (state.exportFormat == .fan && model.conversionUnsupportedReason != nil))
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

    private static let previewSize: CGFloat = 220

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
        .frame(width: Self.previewSize, height: Self.previewSize)
        .contentShape(Circle())
        .gesture(
            DragGesture()
                .onChanged { value in
                    let start = model.mediaDragStartCrop ?? state.crop
                    if model.mediaDragStartCrop == nil { model.mediaDragStartCrop = start }
                    guard let source = state.previewSource else { return }
                    // Dragging moves the image under the circle, so the crop center moves the other way.
                    let side = MediaConverter.cropRect(width: source.width, height: source.height, crop: start).width
                    let pointsToPixels = side / Self.previewSize
                    var crop = start
                    crop.centerX = start.centerX - Double(value.translation.width * pointsToPixels) / Double(source.width)
                    crop.centerY = start.centerY - Double(value.translation.height * pointsToPixels) / Double(source.height)
                    model.setMediaCrop(crop)
                }
                .onEnded { _ in model.mediaDragStartCrop = nil }
        )
        .help("Drag to position the circle over the image.")
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

/// Final check before flashing: package versus fan, with the original's model and version rules.
private struct FirmwareConfirmationSheet: View {
    @ObservedObject var model: DeviceViewModel
    let candidate: DeviceViewModel.FirmwareCandidate

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Update fan firmware?").font(.title2.bold())
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Package").foregroundStyle(.secondary)
                    Text("\(candidate.url.lastPathComponent): model \(candidate.package.model), version \(DeviceViewModel.firmwareVersionText(candidate.package.version))")
                }
                GridRow {
                    Text("Fan").foregroundStyle(.secondary)
                    Text(model.versionInfo.map { "model \($0.model), version \(DeviceViewModel.firmwareVersionText($0.firmware))" } ?? "version not read yet")
                }
            }
            if let version = model.versionInfo {
                if candidate.package.model != Int(version.model) {
                    Text("Model mismatch. The original app only installs packages for the fan's own model; flashing another model's firmware is very likely to break the fan.")
                        .foregroundStyle(.red)
                    Toggle("Override the model check (the original factory Test window's behavior)", isOn: $model.allowFirmwareModelMismatch)
                } else if !candidate.package.isAutomaticUpdate(forModel: Int(version.model), firmware: version.firmware) {
                    Text("This package is not newer than the fan's firmware. The original app would not offer it automatically.")
                        .foregroundStyle(.orange)
                }
            }
            Text("Keep the fan powered and on this network until the update finishes. The fan may restart afterwards.")
                .font(.callout)
            if let reason = model.firmwareBlockReason {
                Text(reason).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.firmwareCandidate = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Update firmware", role: .destructive) { model.startFirmwareUpdate() }
                    .disabled(model.firmwareBlockReason != nil)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
