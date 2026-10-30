import SwiftUI
import SpinDisplayCore
import SpinDisplayMedia
import UniformTypeIdentifiers

/// The Group tab: several fans at once (batch settings, sync groups, file checks, splicing).
struct FleetView: View {
    @ObservedObject var fleet: FleetModel
    @ObservedObject var model: DeviceViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Built from the original app's multi-device features; not yet tested with more than one fan. Connecting here closes the single-fan connection, because a fan accepts one control connection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                fansSection
                if !fleet.connectedMembers.isEmpty {
                    batchSection
                    filesSection
                    SplicingSection(fleet: fleet)
                }
                HStack {
                    if fleet.isBusy { ProgressView(value: fleet.progress).frame(maxWidth: 160) }
                    Text(fleet.message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(.vertical, 8)
        }
        .onAppear { fleet.sync(with: model.devices) }
        .onChange(of: model.devices) { fleet.sync(with: $0) }
    }

    private var fansSection: some View {
        GroupBox("Fans") {
            VStack(alignment: .leading, spacing: 6) {
                if fleet.members.isEmpty {
                    Text("No fans discovered yet. Scan from the Connection page.")
                        .foregroundStyle(.secondary)
                }
                ForEach(fleet.members) { member in
                    HStack {
                        Toggle(isOn: Binding(
                            get: { fleet.selectedIDs.contains(member.id) },
                            set: { if $0 { fleet.selectedIDs.insert(member.id) } else { fleet.selectedIDs.remove(member.id) } }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(member.device.name)
                                Text("\(member.device.address)  •  \(member.status)\(groupText(member))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if member.isConnected {
                            Button(fleet.hostID == member.id ? "Host" : "Make host") { fleet.hostID = member.id }
                                .controlSize(.small)
                                .disabled(fleet.hostID == member.id)
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("Disconnect all") { fleet.disconnectAll() }
                        .disabled(fleet.connectedMembers.isEmpty)
                    Button("Connect selected") { fleet.connectSelected { model.disconnect() } }
                        .disabled(fleet.selectedIDs.isEmpty)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func groupText(_ member: FleetModel.Member) -> String {
        guard let info = member.info else { return "" }
        if info.groupNumber == 0 { return "  •  ungrouped" }
        return "  •  group \(info.groupNumber)\(info.syncFlag == 1 ? " (host)" : "")"
    }

    private var batchSection: some View {
        GroupBox("All connected fans") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button("Power on") { fleet.setPower(true) }
                    Button("Power off") { fleet.setPower(false) }
                    Button("Sync clocks") { fleet.syncClocks() }
                    Button("Refresh playlists") { fleet.refreshPlaylists() }
                }
                HStack {
                    Text("Brightness")
                    ForEach(0...5, id: \.self) { level in
                        Button("\(50 + level * 10)%") { fleet.setBrightness(level) }.controlSize(.small)
                    }
                }
                HStack {
                    Button("Highlight") { fleet.setDisplayMode(.highlight) }
                    Button("True color") { fleet.setDisplayMode(.trueColor) }
                    Divider().frame(height: 16)
                    Button("Bluetooth on") { fleet.setBluetooth(true) }
                    Button("Bluetooth off") { fleet.setBluetooth(false) }
                }
                HStack {
                    Button("Start when powered on") { fleet.setAutoOn(true) }
                    Button("Stop when powered on") { fleet.setAutoOn(false) }
                }
                HStack {
                    Text("Sync group")
                    Menu("Assign…") {
                        Button("Ungroup") { fleet.assignGroup(0) }
                        ForEach(1...20, id: \.self) { group in
                            Button("Sync group \(group)") { fleet.assignGroup(group) }
                        }
                    }
                    .frame(maxWidth: 140)
                    Text(fleet.hostID == nil ? "Choose a host with “Make host” first." : "The chosen host gets the host flag; a group can only have one host.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Play item")
                    ForEach(1...6, id: \.self) { slot in
                        Button("\(slot)") { fleet.play(slot: slot) }.controlSize(.small)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var filesSection: some View {
        GroupBox("Files") {
            VStack(alignment: .leading, spacing: 8) {
                let inconsistent = fleet.inconsistentFiles
                if inconsistent.isEmpty {
                    Text("All connected fans have the same files.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("These files are not on every fan, which can break synchronized playback:")
                        .font(.caption)
                    ForEach(inconsistent, id: \.name) { item in
                        Text("• \(item.name) — missing on \(item.missingOn.joined(separator: ", "))")
                            .font(.caption)
                    }
                    Button("Delete files the \(fleet.hostID == nil ? "first fan" : "host") does not have", role: .destructive) {
                        fleet.deleteRedundantFiles()
                    }
                }
                HStack {
                    Spacer()
                    Button("Upload .ftlv to all…") { pickFile(types: [UTType(filenameExtension: "ftlv") ?? .data]) { fleet.uploadFTLV($0) } }
                    Button("Convert & upload to all…") {
                        pickFile(types: [.image, .movie, .gif]) { fleet.convertAndUpload($0, options: MediaConverter.Options()) }
                    }
                }
                .disabled(fleet.isBusy)
            }
            .padding(.vertical, 4)
        }
    }
}

/// Picks one file with an open panel (used by the Group tab, where a second fileImporter would conflict).
@MainActor
func pickFile(types: [UTType], then action: (URL) -> Void) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = types
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    action(url)
}

/// Splicing layout: drag circles to arrange fans, then save positions or upload one image spread across them.
private struct SplicingSection: View {
    @ObservedObject var fleet: FleetModel
    private static let canvasSize: CGFloat = 360

    var body: some View {
        GroupBox("Splicing") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Arrange the fans as they are mounted. Pointing at a circle makes that fan identify itself. Save sends each fan its position; “Splice & upload” gives each fan its part of one picture or video.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Toggle("Adjustment mode on the fans", isOn: Binding(get: { fleet.jointModeActive }, set: fleet.setJointMode))
                    Spacer()
                    Menu("Arrange in grid") {
                        ForEach(1...6, id: \.self) { columns in
                            Button("\(columns) per row") { fleet.arrangeGrid(columns: columns) }
                        }
                    }
                    .frame(maxWidth: 160)
                }
                canvas
                ForEach(fleet.connectedMembers) { member in
                    HStack {
                        Text(member.device.name).frame(width: 140, alignment: .leading).lineLimit(1)
                        Text("x \(Int(member.position.x))  y \(Int(member.position.y))")
                            .monospacedDigit()
                            .font(.caption)
                        Spacer()
                        Stepper("Tier \(member.tier)", value: Binding(get: { member.tier }, set: { fleet.setTier(member.id, $0) }), in: 1...3)
                            .frame(width: 120)
                    }
                }
                HStack {
                    Spacer()
                    Button("Save layout to fans") { fleet.saveLayout() }
                    Button("Splice & upload…") {
                        pickFile(types: [.image, .movie, .gif]) { fleet.spliceUpload($0, options: MediaConverter.Options()) }
                    }
                    .disabled(fleet.isBusy)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var canvas: some View {
        let bounds = fleet.layoutBounds
        let world = bounds.isNull ? CGRect(x: 0, y: 0, width: 1000, height: 1000) : bounds.insetBy(dx: -bounds.width * 0.15 - 50, dy: -bounds.height * 0.15 - 50)
        let scale = Self.canvasSize / max(world.width, world.height)
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.black.opacity(0.85))
            ForEach(fleet.connectedMembers) { member in
                let diameter = member.diameter * scale
                Circle()
                    .strokeBorder(member.id == fleet.hostID ? Color.orange : Color.accentColor, lineWidth: 2)
                    .background(Circle().fill(Color.accentColor.opacity(0.15 * Double(member.tier))))
                    .overlay(Text(member.device.name).font(.caption2).foregroundStyle(.white).lineLimit(1).padding(4))
                    .frame(width: diameter, height: diameter)
                    .position(x: (member.position.x - world.minX) * scale, y: (member.position.y - world.minY) * scale)
                    .onHover { fleet.identify(member.id, $0) }
                    .gesture(DragGesture().onChanged { value in
                        fleet.movePosition(member.id, to: CGPoint(x: value.location.x / scale + world.minX,
                                                                  y: value.location.y / scale + world.minY))
                    })
            }
        }
        .frame(width: Self.canvasSize, height: Self.canvasSize)
        .clipped()
    }
}
