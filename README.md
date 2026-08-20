# Hikvision iVMS for macOS

An ultra-thin native macOS client for Hikvision cameras and NVRs. The release
app is about **2 MB**, ad-hoc signed, and built only with Apple frameworks.
No Electron, no VLC, no ffmpeg bundle, no SDK runtime.

[中文 README](README.zh-CN.md)

<table>
  <tr>
    <td><img src="Assets/Screenshots/live.jpg" alt="Live view screenshot" /></td>
    <td><img src="Assets/Screenshots/playback.jpg" alt="Playback timeline screenshot" /></td>
  </tr>
  <tr>
    <td align="center">Live view with stream selection and PTZ controls</td>
    <td align="center">Playback with day timeline, zoom, speed, and downloads</td>
  </tr>
</table>

The screenshots above use synthetic camera frames, not private or real home
footage.

## Features

- Live view for Hikvision cameras and NVR channels.
- Playback by day with a consumer-camera-style recording timeline.
- Blue timeline ranges for recorded segments and grey gaps for missing video.
- Timeline zoom, fullscreen playback, and video zoom tools.
- Playback speed control through RTSP `Scale`.
- Recording search and direct streaming download to disk.
- PTZ tap-to-step and hold-to-move controls.
- G.711 audio playback when the device exposes PCMU or PCMA audio tracks.
- Device discovery through SADP multicast.
- Passwords stored in the macOS Keychain.

## Design goals

- **Ultra thin:** about 2 MB for the app binary in Release builds.
- **Native:** SwiftUI, Network.framework, VideoToolbox, AVFoundation, and
  AudioToolbox/AVAudioEngine style system capabilities.
- **Small distribution:** no vendor SDK installer, browser plugin, VLC, ffmpeg,
  or bundled media runtime.
- **Direct protocols:** RTSP over TCP interleaved RTP plus Hikvision ISAPI.

## Compatibility

The app targets macOS 14 or newer and focuses on Hikvision RTSP/ISAPI devices.
It currently supports H.264/H.265 video and G.711 PCMU/PCMA audio.

Hikvision playback URLs use the device's local timestamp convention. Some
devices treat the trailing `z` in `yyyyMMddtHHmmssz` as a literal local-time
marker instead of UTC.

## Build

Open in Xcode:

```sh
open MyIVMS.xcodeproj
```

Build from Terminal:

```sh
xcodebuild \
  -project MyIVMS.xcodeproj \
  -scheme MyIVMS \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData \
  build
```

Create a zip:

```sh
ditto -c -k --sequesterRsrc --keepParent \
  build/DerivedData/Build/Products/Release/MyIVMS.app \
  MyIVMS.app.zip
```

The project uses Xcode file-system-synchronized groups, so source files under
`MyIVMS/` are picked up by the project automatically.

## Opening the app

GitHub Actions builds are ad-hoc signed and not notarized.

On first launch:

1. Right-click `MyIVMS.app`.
2. Choose **Open**.
3. Click **Open** again in the macOS warning dialog.

If macOS still blocks it:

1. Open **System Settings**.
2. Go to **Privacy & Security**.
3. Scroll to the security warning for `MyIVMS`.
4. Click **Open Anyway**.

macOS may also ask for **Local Network** permission. Allow it if you want SADP
device discovery to work.

## Repository layout

```text
MyIVMS/
  Discovery/   SADP multicast discovery
  ISAPI/       Hikvision ISAPI search and download
  Models/      Device and app state
  PTZ/         PTZ command models
  RTSP/        RTSP, SDP, Digest auth, RTP, audio, video decode
  Security/    Keychain password storage
  Video/       Stream session and URL helpers
  Views/       SwiftUI interface
```

## Security notes

- Passwords are stored in the macOS Keychain.
- Device credentials are not embedded in RTSP URLs by the app.
- Recording downloads stream directly to disk instead of buffering whole files
  in memory.
- The app does not include a SOCKS or HTTP proxy feature.

## Limitations

- Two-way talk is not implemented.
- Playback speed depends on the NVR accepting RTSP `Scale`.
- Native AAC audio support is not wired yet; G.711 PCMU/PCMA is supported.
- Devices outside the local multicast domain may not appear in SADP discovery.

## License

MIT
