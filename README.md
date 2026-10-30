# SpinDisplay for macOS

This is a native SwiftUI macOS app based on static analysis of the supplied Windows application. It has no CrossOver or Wine runtime dependency.

## Build and run

```sh
swift run SpinDisplayMacProtocolTests
swift run SpinDisplayStatusCLI 192.168.2.205 --duration 30
./build-app.sh
open dist/SpinDisplay.app
```

The status CLI opens its own TCP connection and only sends the handshake, heartbeat, playback-status query, and device-parameter query. It binds to the matching local subnet interface like the GUI and runs for 30 seconds by default; `--duration` changes that. The GUI and CLI each retry transient connection/handshake failures—including temporary no-route-to-host errors—up to five times, with a 0.25-second delay between attempts. Do not run the CLI while the GUI app is connected, because the fan may only accept one control connection at a time.

The app scans IPv4 broadcast interfaces for devices using the recovered UDP discovery protocol, supports the recovered password challenge, and performs the TCP control-channel handshake on port 50110. It sends the original protocol's two-second heartbeat to keep the control connection alive and reports a peer-closed connection as disconnected. Broadcast discovery is limited to the local subnet; for a fan on a routed VLAN or IoT network, enter its IPv4 address manually. Connections use the matching local interface when the fan is on-link and otherwise use macOS routing.

The interface is organized into four pages:

- **Connection** discovers devices, accepts a manual IPv4 address, and shows the active connection.
- **Playlist & Control** reads the playlist, controls power and brightness, and provides play-from-start, repeat-item, back, next, reorder, delete, and media-upload actions. Back/next stop at the ends of the list. Repeat sends the original client's control `(2, slot)` followed by `(1, slot)` sequence; this has not yet been hardware-verified. Reorder requests use one-based positions as in the original app; the UI updates locally and leaves refresh manual so it does not immediately replace the order with a stale playlist response. Refresh to confirm the fan saved a move.
- **Wi-Fi** sends a network name and password using the recovered configuration command. Applying settings may disconnect the fan from its current network.
- **Configuration** shows the fan's reported device information (model, firmware, serial, factory date, display geometry, storage, router state, unsupported-feature flags) and exposes the recovered commands for device name, fan angle, automatic power schedule, clock synchronization, Bluetooth audio/volume, display mode (Highlight/True color), login verification password, third-party control, and delete-all-files. Editable settings are filled from the fan's parameter response once per connection. Fan angle control has been confirmed on hardware; the remaining settings have not all been verified.
- **File editing** (pencil button on a playlist row) mirrors the original File Edit window: rename, repetition count, All day / Hidden / Set-time playback, and eight weekly time windows. It is sent with the recovered `0x34` command and has not been hardware-verified.

The original desktop client's play command starts the selected item from its beginning; it is not a resume command. The recovered two-command stop sequence restarts playback on the tested fan, so it has been removed from the controls. No reliable stop or standalone pause command has been identified. The handheld remote's single button toggles play/pause, but its command is not yet known, so the app does not send a status query as if it were a pause. Device parameters are refreshed every five seconds. Playback status responses are not elapsed time: command `0x35` is decoded as `responseField * 1000 + playlistSlot`, and the app displays those raw fields rather than a misleading clock; the first field's meaning is still unknown. Brightness uses the original app's 0–5 scale, displayed as 50–100%.

To test Bluetooth audio, connect to the fan, enable **Fan Bluetooth audio**, and then pair/select the fan in macOS **System Settings > Bluetooth**. Choose it under **System Settings > Sound > Output**, play a short audio clip, and adjust both the fan volume (0–31, then **Set speaker volume**) and Mac output volume. Start with a low fan volume such as 8. The app does not receive Bluetooth state readback, so command submission is not confirmation that the speaker connected.

The media uploader accepts existing `.ftlv` files only; it validates the `FTL` header and declared file lengths, and reproduces the original client's compatibility check (device types 25 and 26 only accept exact type matches). It opens the recovered data channel on TCP port 50115, retries the control-channel readiness request while ignoring the original busy status, reports transfer progress, and refreshes the playlist only after a completion response. Upload has not yet been tested on physical fan hardware. Upload rejections use the original client's messages for statuses 1–5 (no space, duplicate name, SD card failure, write error, file limit). Image/video conversion to FTLV is not implemented.

Not yet exposed, although their packets are recovered: factory reset (`0x19`, payload `0x55`; the original says it restores parameters but keeps content, but its effect on network settings is unverified), remote-control pairing (`0x22`; the original warns the fan can then only be controlled by the remote), and router disconnect (`0x07` with flag `0`). Larger original features that still need building: image/video-to-FTLV conversion and export, live screen projection (`0x37`), multi-fan splicing/joint layouts (`0x50`/`0x52`/`0x53`), sync groups and multi-device batch commands (`0x51`), firmware OTA (`0x15`), audio/bin transfer (`0x38`–`0x3A`), and the cloud/login and app-update services. The factory test window (lamp test `0xE1`, speed `0xE0`) is intentionally out of scope. A successful UI launch does not by itself prove a connection to physical fan hardware.
