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
- **Playlist & Control** reads the playlist, controls power and brightness, and provides play-from-start, repeat-item, back, next, reorder, delete, and media-upload actions. Back/next stop at the ends of the list. Repeat sends the original client's Cycleplay sequence, play `(1, slot)` then loop `(2, slot)`. Delete uses one-based slots, as the original does. Reorder requests use one-based positions as in the original app; the UI updates locally and leaves refresh manual so it does not immediately replace the order with a stale playlist response. Refresh to confirm the fan saved a move.
- **Wi-Fi** sends a network name and password using the recovered configuration command. Applying settings may disconnect the fan from its current network.
- **Configuration** shows the fan's reported device information (model, firmware, serial, factory date, display geometry, storage, router state, unsupported-feature flags) and exposes the recovered commands for device name, fan angle, automatic power schedule, clock synchronization, Bluetooth audio/volume, display mode (Highlight/True color), login verification password, third-party control, and delete-all-files. Editable settings are filled from the fan's parameter response once per connection. Fan angle control has been confirmed on hardware; the remaining settings have not all been verified.
- **File editing** (pencil button on a playlist row) mirrors the original File Edit window: rename, repetition count, All day / Hidden / Set-time playback, and eight weekly time windows. It is sent with the recovered `0x34` command and has not been hardware-verified.

The original desktop client's play command starts the selected item from its beginning; it is not a resume command. The recovered two-command stop sequence restarts playback on the tested fan, so it has been removed from the controls. No reliable stop or standalone pause command has been identified. The handheld remote's single button toggles play/pause, but its command is not yet known, so the app does not send a status query as if it were a pause. Device parameters are refreshed every five seconds. Playback status responses are not elapsed time: command `0x35` is decoded as `responseField * 1000 + playlistSlot`, and the app displays those raw fields rather than a misleading clock; the first field's meaning is still unknown. Brightness uses the original app's 0–5 scale, displayed as 50–100%.

Bluetooth audio works in the opposite direction from a Bluetooth speaker: the fan is the audio source and pairs itself with an external Bluetooth speaker. It never appears in the Mac's Bluetooth list. To test it:
1. Turn on **fan Bluetooth** on the Configuration page.
2. Put a Bluetooth speaker in pairing mode near the fan and press **Search and connect speaker**. This sends control `(2, 0)`, the original app's "Search and connect" button.
3. Set a low fan volume, such as 8 out of 31.
4. Play a video that was converted with audio.

The app receives no confirmation that pairing succeeded. Like the original, it refuses Bluetooth changes on a fan that is in a sync group but is not that group's host.

The media uploader accepts existing `.ftlv` files only; it validates the `FTL` header and declared file lengths, and reproduces the original client's compatibility check (device types 25 and 26 only accept exact type matches). It opens the recovered data channel on TCP port 50115, retries the control-channel readiness request while ignoring the original busy status, reports transfer progress, and refreshes the playlist only after a completion response. Upload has not yet been tested on physical fan hardware. Upload rejections use the original client's messages for statuses 1–5 (no space, duplicate name, SD card failure, write error, file limit). **Media conversion.** **Convert image or video…** accepts still images, animated GIFs, and videos. It shows a circular preview, offers Fill/Fit framing with zoom and drag-to-position (the original's movable circle) (and, for video: start/end seconds, an audio toggle, and **Hold last frame**, on by default. Hold rounds the length up to whole seconds and repeats the final frame; turned off, the converter drops the final partial second as the original does), then either uploads the result or exports a `.ftlv` file. The conversion follows the original's non-transcoding path:
- **Frames:** the selected square drawn on black, clipped to a circle, saved as baseline 4:4:4 quality-80 JPEGs (built-in encoder matching the original's libjpeg-turbo output: JFIF only, no restart markers) at the fan's reported image size (default 672).
- **Still images:** one 10-second frame.
- **Video and GIFs:** fps = min(source, fan maximum), defaulting to 20.
- **Audio:** 44.1 kHz mono unsigned 8-bit PCM.
- **Container:** the original's exact layout.

Fans reporting content type 3, or device types 25/26, need the original's LED "mold" transcoding, which is not implemented, so conversion is disabled for them. `swift run SpinDisplayConvertCLI convert <input> <out.ftlv>` and `… inspect <file.ftlv> [--extract-frames DIR]` convert and verify files offline without contacting a fan. Converted uploads have not yet been tested on fan hardware.

**Screen projection** (Projection tab) follows the original's `ProjectionWindow`:
1. The app opens the data channel on port 50115 and repeats `0x37 (1)` every 2 s until the fan accepts with status 0.
2. It streams a centered square of the main display (its shorter side, at most 1024 points), scaled to the fan's image size.
3. Each frame is a 4:2:0 quality-30 JPEG prefixed with `FA` and a 3-byte little-endian length.
4. Stopping sends `0x37 (0)` and closes the data channel.

The Mac adds several controls the original lacked; changes apply live while projecting:
- **Source:** a screen area on any display, or a single window. The window is followed when it moves and is captured even when partly covered.
- **Screen area:** a Size slider, plus an orange on-screen capture frame. The frame is shown while the Projection tab is open or projecting; drag it to move the area and scroll over it to resize. It is excluded from the capture.
- **Window framing:** Fill/Fit with zoom and position sliders.
- **Preview:** a live circle in the app shows what is being sent.
- **Center:** restores the original's centered area.

Capture uses ScreenCaptureKit, so macOS asks for Screen Recording permission. Because the app bundle is ad-hoc signed, macOS may ask again after each rebuild. Uploads and projection exclude each other. Projection has not been tested on hardware.

**Experimental (locked behind a checkbox, untested):** factory reset (`0x19 0x55`), remote-control pairing (`0x22`, start 0 / cancel 1; the fan answers 2 when matched), and router disconnect (`0x07` with flag 0). Firmware updates are not available: the original downloads packages from the manufacturer's server, and a failed update could leave the fan unusable.

Still not built: multi-fan splicing, sync groups, and batch commands (`0x50`–`0x53`, UDP group play); LED transcoding for content-type-3 and type-25/26 fans (needed by both conversion and projection on those models); and the cloud/login service.