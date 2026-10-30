import Foundation
import SpinDisplayCore
import SpinDisplayMedia

/// Several fans at once, following the original's multi-device features: the device tree with batch
/// commands (MainWindow and GroupSettingWindow), sync groups (`0x51`), missing/redundant file checks
/// (FileTipsWindow), and splicing layouts (NewJointWindow: `0x50` SetCoord, `0x52` JointModel,
/// `0x53` SelectDevice). Built from the IL; the user has one fan, so none of it is hardware-verified.
@MainActor
final class FleetModel: ObservableObject {
    struct Member: Identifiable {
        let device: FanDevice
        var id: String { device.id }
        var isConnected = false
        var status = "Not connected"
        var info: FanDeviceInfo?
        var playlist: [FanFile] = []
        var transcoding: FanTranscoding?
        var binConfiguration: FanBinConfiguration?
        /// Splicing position: circle centre in the fan's diameter units (the original's `RealPosition`).
        var position = CGPoint.zero
        /// Splicing layer, 1-based in the UI (`SetCoord` sends tier − 1).
        var tier = 1

        /// The original defaults the circle diameter to 556 when the fan reports none.
        var diameter: Double { Double(info?.diameter ?? 0) > 0 ? Double(info!.diameter) : 556 }
    }

    @Published var members: [Member] = []
    @Published var selectedIDs: Set<String> = []
    @Published var message = "Select fans and connect them as a group."
    @Published var isBusy = false
    @Published var progress = 0.0
    @Published var jointModeActive = false
    @Published var hostID: String?

    private var connections: [String: DeviceConnection] = [:]

    var connectedMembers: [Member] { members.filter(\.isConnected) }

    /// Keeps the member list in step with discovery, preserving state for fans already listed.
    func sync(with devices: [FanDevice]) {
        for device in devices where !members.contains(where: { $0.id == device.id }) {
            members.append(Member(device: device))
        }
    }

    // MARK: - Connections

    func connectSelected(closingPrimary: () -> Void) {
        let targets = members.filter { selectedIDs.contains($0.id) && !$0.isConnected }
        guard !targets.isEmpty else {
            message = "Select at least one fan that is not connected yet."
            return
        }
        closingPrimary()
        for member in targets {
            if member.device.passwordProtected {
                update(member.id) { $0.status = "Password-protected: verify it once on the Connection page first." }
                continue
            }
            update(member.id) { $0.status = "Connecting…" }
            DeviceConnection.connect(to: member.device.address) { [weak self] result in
                Task { @MainActor in self?.attach(result, to: member.id) }
            }
        }
    }

    func disconnectAll() {
        if jointModeActive { setJointMode(false) }
        for (id, connection) in connections {
            connection.disconnect()
            update(id) { $0.isConnected = false; $0.status = "Disconnected" }
        }
        connections.removeAll()
    }

    private func attach(_ result: Result<DeviceConnection, Error>, to id: String) {
        switch result {
        case .failure(let error):
            update(id) { $0.status = error.localizedDescription }
        case .success(let connection):
            connections[id]?.disconnect()
            connections[id] = connection
            let connectionID = connection.id
            func current() -> Bool { self.connections[id]?.id == connectionID }
            connection.onDeviceInfoChanged = { [weak self] info in
                Task { @MainActor in
                    guard let self, current() else { return }
                    let isFirst = self.members.first { $0.id == id }?.info == nil
                    self.update(id) {
                        $0.info = info
                        if isFirst {
                            $0.position = CGPoint(x: Double(info.coordinateX), y: Double(info.coordinateY))
                            $0.tier = Int(info.coordinateLevel) + 1
                        }
                    }
                    if isFirst {
                        if info.groupNumber != 0, info.syncFlag == 1 { self.hostID = id }
                        if info.contentType == 3 { try? connection.requestTranscoding() }
                        if info.contentType == 1 { try? connection.requestBinConfiguration() }
                    }
                }
            }
            connection.onPlaylistChanged = { [weak self] files in
                Task { @MainActor in
                    guard let self, current() else { return }
                    self.update(id) { $0.playlist = files }
                }
            }
            connection.onTranscoding = { [weak self] transcoding in
                Task { @MainActor in
                    guard let self, current() else { return }
                    self.update(id) { $0.transcoding = transcoding }
                }
            }
            connection.onBinConfiguration = { [weak self] configuration in
                Task { @MainActor in
                    guard let self, current() else { return }
                    self.update(id) { $0.binConfiguration = configuration }
                }
            }
            connection.onDisconnected = { [weak self] reason in
                Task { @MainActor in
                    guard let self, current() else { return }
                    self.connections[id] = nil
                    self.update(id) { $0.isConnected = false; $0.status = reason }
                }
            }
            connection.startReceiving()
            update(id) { $0.isConnected = true; $0.status = "Connected" }
        }
    }

    private func update(_ id: String, _ change: (inout Member) -> Void) {
        guard let index = members.firstIndex(where: { $0.id == id }) else { return }
        change(&members[index])
    }

    // MARK: - Batch commands (GroupSettingWindow)

    /// Sends a packet built per fan to every connected fan.
    func broadcast(_ description: String, _ packet: (Member) -> [UInt8]?) {
        var sent = 0
        for member in connectedMembers {
            guard let connection = connections[member.id], let bytes = packet(member) else { continue }
            if (try? connection.sendCommand(bytes)) != nil { sent += 1 }
        }
        message = sent == 0 ? "No connected fans to send to." : "\(description) sent to \(sent) fan(s)."
    }

    func setPower(_ isOn: Bool) {
        broadcast("Power \(isOn ? "on" : "off")") { _ in SpinDisplayProtocol.powerRequest(isOn: isOn) }
    }

    func setBrightness(_ level: Int) {
        broadcast("Brightness \(level)") { _ in SpinDisplayProtocol.brightnessRequest(level: UInt8(max(0, min(5, level)))) }
    }

    func setDisplayMode(_ mode: FanDisplayMode) {
        broadcast("Display mode") { _ in SpinDisplayProtocol.displayModeRequest(mode) }
    }

    func setBluetooth(_ isOn: Bool) {
        broadcast("Bluetooth \(isOn ? "on" : "off")") { _ in SpinDisplayProtocol.bleVolumeRequest(control: isOn ? 1 : 0) }
    }

    /// GroupSettingWindow "Start/Stop when powered on": keeps each fan's own timed power settings.
    func setAutoOn(_ isOn: Bool) {
        broadcast("Start when powered on \(isOn ? "on" : "off")") { member in
            let info = member.info
            return SpinDisplayProtocol.scheduleRequest(
                autoOn: isOn,
                shutdownEnabled: info?.isShutdownScheduled ?? false,
                bootEnabled: info?.isBootScheduled ?? false,
                shutdownHour: info?.shutdownHour ?? 0,
                shutdownMinute: info?.shutdownMinute ?? 0,
                bootHour: info?.bootHour ?? 0,
                bootMinute: info?.bootMinute ?? 0
            )
        }
    }

    func syncClocks() {
        broadcast("Clock sync") { _ in SpinDisplayProtocol.clockSyncRequest() }
    }

    func play(slot: Int) {
        broadcast("Play item \(slot)") { _ in SpinDisplayProtocol.playControlRequest(control: 1, index: UInt8(max(1, min(255, slot)))) }
    }

    /// Puts every connected fan in `group`; only the chosen host gets the host flag (one host per group).
    func assignGroup(_ group: Int) {
        broadcast(group == 0 ? "Ungroup" : "Sync group \(group)") { member in
            SpinDisplayProtocol.syncGroupRequest(group: group, isHost: member.id == self.hostID)
        }
    }

    func refreshPlaylists() {
        for member in connectedMembers { try? connections[member.id]?.refreshPlaylist() }
        message = "Playlist refresh requested."
    }

    // MARK: - File consistency (FileTipsWindow)

    /// File names present on some connected fans but not on all of them.
    var inconsistentFiles: [(name: String, missingOn: [String])] {
        let fans = connectedMembers
        let names = Set(fans.flatMap { $0.playlist.map(\.name) })
        return names.sorted().compactMap { name in
            let missing = fans.filter { !$0.playlist.contains { $0.name == name } }.map { $0.device.name }
            return missing.isEmpty ? nil : (name, missing)
        }
    }

    /// FileTips "Delete redundant files": removes files that the host (or, without a host, the first
    /// connected fan) does not have. Deletes from the end so earlier slots keep their positions.
    func deleteRedundantFiles() {
        guard let reference = connectedMembers.first(where: { $0.id == hostID }) ?? connectedMembers.first else { return }
        let keep = Set(reference.playlist.map(\.name))
        var deleted = 0
        for member in connectedMembers where member.id != reference.id {
            guard let connection = connections[member.id] else { continue }
            for (index, file) in member.playlist.enumerated().reversed() where !keep.contains(file.name) {
                if (try? connection.deleteFile(at: index)) != nil { deleted += 1 }
            }
            try? connection.refreshPlaylist()
        }
        message = "Requested deletion of \(deleted) redundant file(s); playlists will refresh."
    }

    // MARK: - Uploads to every fan

    func target(for member: Member) -> MediaConverter.Target {
        let size = member.info?.imageSize ?? 672
        let fps = member.info?.maxFPS ?? 20
        switch member.info?.contentType {
        case 3?:
            if let transcoding = member.transcoding {
                return .init(imageSize: size, maxFPS: fps,
                             encoding: .mold(MoldTranscoder(transcoding: transcoding, imageWidth: size), deviceType: member.device.deviceType))
            }
        case 1?:
            if let configuration = member.binConfiguration {
                return .init(imageSize: size, maxFPS: fps, encoding: .bin(BinTranscoder(configuration: configuration, imageWidth: size)))
            }
        default:
            break
        }
        return .init(imageSize: size, maxFPS: fps)
    }

    private func isBin(_ member: Member) -> Bool {
        if case .bin = target(for: member).encoding { return true }
        return false
    }

    /// Converts `source` separately for each fan (its own size, fps, and content path), optionally with a
    /// per-fan crop, then uploads to each fan in turn.
    func convertAndUpload(_ source: URL, options: MediaConverter.Options, crops: [String: MediaConverter.Crop] = [:]) {
        guard !isBusy else { return }
        let fans = connectedMembers
        guard !fans.isEmpty else {
            message = "Connect fans first."
            return
        }
        isBusy = true
        progress = 0
        let hasScope = source.startAccessingSecurityScopedResource()
        Task {
            defer {
                if hasScope { source.stopAccessingSecurityScopedResource() }
                isBusy = false
            }
            do {
                let kind = try await MediaConverter.inspect(source)
                for (number, member) in fans.enumerated() {
                    guard let connection = connections[member.id] else { continue }
                    message = "Converting for \(member.device.name) (\(number + 1) of \(fans.count))…"
                    var memberOptions = options
                    if let crop = crops[member.id] { memberOptions.crop = crop }
                    let directory = FileManager.default.temporaryDirectory
                        .appendingPathComponent("SpinDisplayFleet-\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    defer { try? FileManager.default.removeItem(at: directory) }
                    let output = directory.appendingPathComponent(source.deletingPathExtension().lastPathComponent).appendingPathExtension("ftlv")
                    let target = target(for: member)
                    _ = try await Task.detached {
                        try await MediaConverter.convert(source, kind: kind, target: target, options: memberOptions, output: output,
                                                         isCancelled: { false }, progress: { _, _ in })
                    }.value
                    message = "Uploading to \(member.device.name) (\(number + 1) of \(fans.count))…"
                    try await upload(output, to: member, connection: connection)
                    progress = Double(number + 1) / Double(fans.count)
                }
                message = "Uploaded to \(fans.count) fan(s)."
            } catch {
                message = error.localizedDescription
            }
        }
    }

    /// Uploads an existing `.ftlv` to every connected fan (re-encoding for bin fans, as the original does).
    func uploadFTLV(_ source: URL) {
        guard !isBusy else { return }
        let fans = connectedMembers
        isBusy = true
        progress = 0
        let hasScope = source.startAccessingSecurityScopedResource()
        Task {
            defer {
                if hasScope { source.stopAccessingSecurityScopedResource() }
                isBusy = false
            }
            do {
                for (number, member) in fans.enumerated() {
                    guard let connection = connections[member.id] else { continue }
                    message = "Uploading to \(member.device.name) (\(number + 1) of \(fans.count))…"
                    if isBin(member) {
                        let directory = FileManager.default.temporaryDirectory
                            .appendingPathComponent("SpinDisplayFleet-\(UUID().uuidString)", isDirectory: true)
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        defer { try? FileManager.default.removeItem(at: directory) }
                        let output = directory.appendingPathComponent(source.deletingPathExtension().lastPathComponent).appendingPathExtension("ftlv")
                        let target = target(for: member)
                        try await Task.detached { try MediaConverter.rebinFTLV(source, target: target, output: output) }.value
                        try await upload(output, to: member, connection: connection)
                    } else {
                        try await upload(source, to: member, connection: connection)
                    }
                    progress = Double(number + 1) / Double(fans.count)
                }
                message = "Uploaded to \(fans.count) fan(s)."
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func upload(_ url: URL, to member: Member, connection: DeviceConnection) async throws {
        let bin = isBin(member)
        let voiceDisabled = member.info?.restrictions.contains(.voice) == true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if bin {
                connection.uploadBin(container: url, name: url.deletingPathExtension().lastPathComponent,
                                     voiceDisabled: voiceDisabled, progress: { _, _ in }) { continuation.resume(with: $0) }
            } else {
                connection.uploadFTLV(at: url, deviceType: member.device.deviceType, progress: { _, _ in }) { continuation.resume(with: $0) }
            }
        }
    }

    // MARK: - Splicing (NewJointWindow)

    /// Joint mode 1 while arranging (the original sends it when the splicing window opens), 0 to leave it.
    func setJointMode(_ isOn: Bool) {
        broadcast(isOn ? "Splicing adjustment mode" : "Normal mode") { _ in SpinDisplayProtocol.jointModeRequest(isOn ? 1 : 0) }
        jointModeActive = isOn
    }

    /// The original highlights a fan while the pointer is over its circle.
    func identify(_ id: String, _ isOn: Bool) {
        try? connections[id]?.sendCommand(SpinDisplayProtocol.selectDeviceRequest(isSelected: isOn))
    }

    func movePosition(_ id: String, to point: CGPoint) {
        update(id) { $0.position = point }
    }

    func setTier(_ id: String, _ tier: Int) {
        update(id) { $0.tier = max(1, min(3, tier)) }
    }

    /// Places the connected fans in a grid, `columns` wide, touching edge to edge.
    func arrangeGrid(columns: Int) {
        let fans = connectedMembers
        guard !fans.isEmpty else { return }
        let columns = max(1, columns)
        for (index, member) in fans.enumerated() {
            let diameter = member.diameter
            let row = index / columns, column = index % columns
            update(member.id) {
                $0.position = CGPoint(x: diameter / 2 + Double(column) * diameter, y: diameter / 2 + Double(row) * diameter)
                $0.tier = 1
            }
        }
    }

    /// Original save: `SetCoord(x, y, tier − 1, 1)` to every fan, then joint mode 0.
    func saveLayout() {
        broadcast("Splicing positions") { member in
            SpinDisplayProtocol.setCoordinateRequest(
                x: Int(member.position.x.rounded()), y: Int(member.position.y.rounded()), level: member.tier - 1, model: 1
            )
        }
        setJointMode(false)
        message = "Splicing positions saved to \(connectedMembers.count) fan(s)."
    }

    /// The layout's bounding box in diameter units.
    var layoutBounds: CGRect {
        connectedMembers.reduce(CGRect.null) { bounds, member in
            let radius = member.diameter / 2
            return bounds.union(CGRect(x: member.position.x - radius, y: member.position.y - radius,
                                       width: member.diameter, height: member.diameter))
        }
    }

    /// Per-fan crops that spread one source across the whole layout, like the original's splicing clip.
    func spliceCrops(sourceWidth: Int, sourceHeight: Int) -> [String: MediaConverter.Crop] {
        MediaConverter.spliceCrops(
            circles: connectedMembers.map { (id: $0.id, center: $0.position, diameter: $0.diameter) },
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight
        )
    }

    func spliceUpload(_ source: URL, options: MediaConverter.Options) {
        Task {
            let hasScope = source.startAccessingSecurityScopedResource()
            defer { if hasScope { source.stopAccessingSecurityScopedResource() } }
            do {
                let kind = try await MediaConverter.inspect(source)
                let frame = try await MediaConverter.sourceFrame(source, kind: kind, startSecond: options.startSecond)
                convertAndUpload(source, options: options, crops: spliceCrops(sourceWidth: frame.width, sourceHeight: frame.height))
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
