# Reolink on Mac

A native, Apple-Silicon-first macOS client for Reolink cameras, built with
SwiftUI. It connects to cameras over the local network for live viewing,
snapshots, PTZ control, and basic events/playback where the model supports it.

> Not affiliated with Reolink. Uses the camera's documented local HTTP (CGI)
> API and standard RTSP streams.

## Status

This is the **first milestone** scaffold. It includes a complete, buildable
SwiftUI app with:

- ✅ Camera model + secure credential storage (Keychain)
- ✅ Add Camera flow with **Test Connection**
- ✅ Reolink HTTP API client (login, device info, capabilities, snapshot, PTZ, events)
- ✅ RTSP URL builder (modern `Preview_*` + legacy `h264Preview_*` forms)
- ✅ Single-camera live view and 1×1 / 2×2 / 3×3 / 4×4 grids
- ✅ Snapshots saved to `~/Pictures/Reolink Snapshots`
- ✅ PTZ pad + zoom (hidden when unsupported)
- ✅ Events list by date with playback-capability fallback
- ✅ ONVIF WS-Discovery (best effort)
- ✅ **Mock camera mode** so you can run the app with no hardware

- ✅ **Live RTSP playback** via VLCKit (SPM), main/sub streams, in-place quality
  switching, start/stop/refresh, loading + error states, auto-reconnect
- ✅ Multiple simultaneous streams (one player per tile)

VLCKit is integrated through Swift Package Manager and resolves automatically —
see "Live RTSP video" below. Without it, mock cameras still render an animated
placeholder so the whole UI remains usable.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 15.3+ / Swift 5.10+
- Apple Silicon or Intel Mac

## Project layout

```
ReolinkClient/
├── ReolinkClientApp.swift        # @main App + Settings scene
├── ContentView.swift             # Grid + toolbar + sheets
├── Models/
│   ├── Camera.swift              # Camera, capabilities, StreamQuality
│   ├── CameraStream.swift        # RTSP stream + StreamState
│   └── CameraEvent.swift         # Detection events
├── Services/
│   ├── ReolinkAPIClient.swift    # async actor over /cgi-bin/api.cgi
│   ├── RTSPURLBuilder.swift      # main/sub RTSP URLs (+ legacy fallback)
│   ├── CameraDiscoveryService.swift  # ONVIF WS-Discovery
│   ├── KeychainService.swift     # secure password storage
│   ├── SnapshotStore.swift       # snapshot file naming + saving
│   └── MockMedia.swift           # synthetic frames/events for dev
├── ViewModels/
│   ├── CameraStore.swift         # app-wide camera list (MVVM)
│   └── CameraViewModel.swift     # per-camera state, reconnect, snapshot, PTZ
├── Views/
│   ├── CameraGridView.swift      # grid layouts
│   ├── CameraTileView.swift      # one tile
│   ├── CameraDetailView.swift    # large view + PTZ + events
│   ├── AddCameraView.swift       # add/edit + Test Connection
│   ├── PTZControlView.swift      # directional + zoom pad
│   ├── EventListView.swift       # events by date
│   └── SettingsView.swift        # manage cameras + discovery
└── Video/
    ├── RTSPPlayerView.swift      # NSViewRepresentable host
    └── VLCPlayerWrapper.swift    # engine (real when VLCKit linked, else stub)
```

## Getting started

1. **Open the project**

   ```sh
   open ReolinkClient.xcodeproj
   ```

2. **Select the `ReolinkClient` scheme** and choose **My Mac** as the run
   destination, then ⌘R.

3. **Try it with no hardware:** click **Add Mock Camera** (or press
   ⌘⇧M). A mock tile appears and "plays" an animated placeholder. Snapshots,
   PTZ, and events are all exercised in mock mode.

4. **Add a real camera:** click **＋ Add Camera**, enter the IP, port
   (usually `80`), username, and password, then **Test Connection**. On
   success, save — capabilities (PTZ/playback) are auto-detected.

### Live RTSP video (VLCKit via Swift Package Manager)

Live playback is powered by **VLCKit**, integrated through the
[`tylerjonesio/vlckit-spm`](https://github.com/tylerjonesio/vlckit-spm) Swift
package (product/module **`VLCKitSPM`**, pinned to `3.5.1`). The dependency is
**already declared in the Xcode project** — Xcode resolves and downloads it
automatically on first open/build. No manual steps are required.

On first build, expect a one-time download of the VLCKit binary framework
(~hundreds of MB). To resolve it from the command line:

```sh
xcodebuild -project ReolinkClient.xcodeproj -scheme ReolinkClient \
  -resolvePackageDependencies
```

On Apple Silicon, VLCKit decodes H.264/H.265 through **VideoToolbox**
(hardware), so several tiles can stream at once with low CPU use. RTSP is
forced over **TCP** with a small network cache for stability + low latency.

#### Building without the package

`VLCPlayerWrapper.swift` gates the real implementation behind
`#if canImport(VLCKitSPM)`. If the package is removed, the app still compiles
and runs — live tiles show a "engine not linked" message, and **mock cameras
keep working** (they render a synthesized frame loop, no engine needed).

> Prefer FFmpegKit? Implement the `RTSPPlayerEngine` protocol with an FFmpeg
> backend and swap it in `RTSPPlayerView.Coordinator.installEngineIfNeeded`.

### Smoke-testing live RTSP against a real camera

CI compiles and links VLCKit but cannot exercise a real stream (no camera on the
runner), so verify playback locally:

1. Build & run on **My Mac**, then **＋ Add Camera** with your camera's IP,
   username, and password; **Test Connection** should report the model.
2. The tile should go **Connecting… → Live** within a few seconds (sub stream).
3. Open the large view (double-click). Toggle **Main/Sub** — video should switch
   **in place** without the window reopening.
4. Click **Refresh** — it should reload even though the URL is unchanged.
5. **Failure paths:**
   - Wrong password → after retries, the tile shows
     "Authentication failed — check the username and password." with **Retry**.
   - Unplug the camera / block its IP while Live → status goes
     **Retrying (n)…** with exponential backoff, then recovers when restored.
   - A camera that only serves the legacy URL scheme should still connect via the
     automatic `h264Preview_*` fallback.
6. Open a 2×2 grid with multiple cameras to confirm several simultaneous streams
   render with reasonable CPU use (hardware decode via VideoToolbox).

What to watch for: exactly one VLC instance per tile (reconnects reuse it), clean
teardown when closing the detail view or stopping a tile, and no runaway CPU.

## How it works

### RTSP URLs

`RTSPURLBuilder` produces, for channel 1:

```
rtsp://<user>:<pass>@<host>:554/Preview_01_main   # main / HD
rtsp://<user>:<pass>@<host>:554/Preview_01_sub    # sub  / SD
```

Older firmware uses `h264Preview_01_main` / `_sub`; both are returned by
`candidateURLs(...)` so the player can fall back.

### HTTP API

`ReolinkAPIClient` is an `actor` that POSTs JSON commands to
`/cgi-bin/api.cgi?cmd=…`, authenticating with a `Login` token. Implemented
commands: `Login`, `GetDevInfo`, `GetAbility`, `Snap`, `PtzCtrl`, `Search`.

### Security

- Passwords live in the **Keychain** (`KeychainService`), keyed by camera UUID.
  They are never written to `UserDefaults`, JSON, or logs.
- `CameraStream.redactedDescription` strips credentials for any logging.
- App Sandbox is enabled with only the entitlements needed: outgoing network,
  UDP (for discovery), and read/write to `~/Pictures`.

### Reconnect

`CameraViewModel` retries dropped streams with exponential backoff
(1, 2, 4, 8 … s, capped at 30s, up to 6 attempts) and surfaces live status in
each tile.

## Known limitations / next steps

- **ONVIF discovery** uses UDP multicast (`239.255.255.250:3702`). Under App
  Sandbox, multicast may require Apple's `com.apple.developer.networking.multicast`
  entitlement (request access from Apple), or run with the sandbox disabled
  during development. Manual add always works.
- **HTTPS with self-signed certs:** the default `URLSession` will reject
  untrusted certs. Most Reolink cameras serve the API over HTTP on the LAN; add
  a `URLSessionDelegate` trust handler if you use HTTPS.
- **Event playback** wiring is stubbed where models lack a documented playback
  API — the UI shows "Playback not supported for this model".

## Regenerating the Xcode project

The `.xcodeproj` is generated deterministically from the source tree:

```sh
python3 generate_xcodeproj.py
```

Run this after adding/removing Swift files to keep the project in sync.
