# VALHost

A native macOS audio plug-in host built with **JUCE** and **SwiftUI**. VALHost
loads Audio Unit (AU), VST3, and LV2 instruments and effects, runs them through a
mixer-style channel strip, and routes the result to any Core Audio device — paired
with its companion virtual loopback driver, [VALDriver](https://github.com/betzburger/VALDriver),
it can stream that audio straight into other applications.

> Built from the ground up for Apple Silicon (universal arm64 + x86_64), with a
> hardened-runtime, Developer-ID-signed, notarizable build pipeline.

---

## Features

- **Plug-in hosting** — AU, VST3, and LV2 instruments and effects. VST2 is
  intentionally disabled (deprecated). Crash-safe plug-in editors with a
  self-learning generic-editor fallback for plug-ins whose native views misbehave.
- **Channel strip mixer** — horizontal volume fader with a smooth piecewise dB
  taper (down to a true −∞ floor), atomic gain/mute, and professional dBFS output
  metering with peak-hold.
- **Menu-bar presence** — a live mini level meter rendered into an `NSStatusItem`;
  click it for an `NSPopover` control panel without bringing the main window
  forward.
- **Computer keyboard as a piano** — play hosted instruments directly from the Mac
  keyboard, with octave shifting.
- **System volume-key integration** — the hardware volume/mute keys drive the
  output level via VALDriver's volume/mute control.
- **Robust audio I/O** — explicit microphone-permission handling so real and
  virtual inputs actually deliver signal under the hardened runtime; resilient
  audio-device initialization.
- **Session persistence** — restores your last session on launch.

## Architecture

VALHost is a hybrid app: SwiftUI drives the UI, while the real-time audio work
lives in a C++/JUCE engine, bridged through Objective-C++.

| Path | Role |
|------|------|
| `Source/VALHostApp.swift`        | App entry point, `NSStatusItem` menu-bar item, computer-keyboard piano, window lifecycle, microphone-permission flow |
| `Source/ContentView.swift`       | SwiftUI control panel: channel strip, faders, meters, plug-in selection and editors |
| `Source/AudioEngine.{h,cpp}`     | JUCE-based audio engine — device management, plug-in graph, metering |
| `Source/VALHostEngineBridge.{h,mm}` | Objective-C++ bridge exposing the C++ engine to Swift |
| `Source/SystemVolumeLink.{h,mm}` | Isolates the Core Audio calls that link the hardware volume keys to the output |
| `Source/JuceInitializer.{h,cpp}` | JUCE GUI/message-loop initialization |
| `Source/Info.plist`              | Bundle metadata + `NSMicrophoneUsageDescription` |
| `CMakeLists.txt`                 | Build definition (targets, plug-in-host flags, entitlements, signing) |

## Requirements

- macOS 11 or later (Apple Silicon or Intel)
- [JUCE](https://juce.com) framework
- CMake 3.22+ and Xcode (with command-line tools)

The JUCE location is configured in `CMakeLists.txt` via the `JUCE_DIR` variable —
point it at your local JUCE checkout before building.

## Building

VALHost uses CMake to generate an Xcode project, which is then built with
`xcodebuild` (or opened in Xcode).

```bash
# 1. Generate the Xcode project from CMakeLists.txt
cmake -G Xcode -B build_xcode

# 2. Build the Debug configuration
xcodebuild -project build_xcode/VALHost.xcodeproj -scheme VALHost -configuration Debug build
```

The build enables AU, VST3, and LV2 plug-in hosting and the macOS hardened
runtime. Two entitlements are required and configured in `CMakeLists.txt`:

- `com.apple.security.cs.disable-library-validation` — lets the hardened runtime
  load third-party plug-ins signed by other developers.
- `com.apple.security.device.audio-input` — **mandatory** to read any audio input;
  without it Core Audio silently delivers nothing but silence.

## Packaging & Distribution

`package.sh` produces a signed, **notarized** `.dmg` for distribution to other
Macs — a simple drag-to-Applications install with no Gatekeeper warnings.

One-time prerequisites:

1. A *Developer ID Application* certificate in your keychain.
2. Notarization credentials stored as a `notarytool` keychain profile.

```bash
APP_SIGN_ID="Developer ID Application: Your Name (TEAMID)" \
TEAM_ID="TEAMID" \
NOTARY_PROFILE="VALNotary" \
./package.sh
```

## Companion: VALDriver

[VALDriver](https://github.com/betzburger/VALDriver) is a self-written virtual
audio loopback driver that exposes a **“VALHost 2ch”** device. Selecting it as
VALHost's output and as another app's input (Zoom, OBS, a recorder…) streams
VALHost's audio into that application with no extra latency.

## License

Released under the [MIT License](LICENSE).
