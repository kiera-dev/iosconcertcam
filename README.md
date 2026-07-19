# ConcertCam 🎸

A minimal iOS camera app for recording concerts **without Apple's audio processing** — no auto-gain pumping, no limiter squash, no "muffled the second the band starts" audio. Built for iOS 26 / iPhone 17e, targeting iOS 18+.

## Why

The stock Camera app runs mic input through a processing chain (automatic gain control, limiting, EQ, audio zoom beamforming) that crushes loud music. Third-party apps can opt out. ConcertCam gives you three audio modes, from "stock minus the worst of it" to "completely unprocessed."

## Audio modes

| Mode | What it is | When to use |
|------|-----------|-------------|
| **Stereo** | Stereo capture with audio zoom OFF and wind removal OFF (💨 button can re-enable wind removal) | Default; keeps stereo width with minimal processing |
| **Raw** | Mono through an `AVAudioSession` in `.measurement` mode — bypasses AGC/limiter/EQ entirely. Pick the physical mic (Bottom / Front / Back); a cardioid pickup pattern is requested automatically when the hardware supports it | Very loud shows; maximum dynamic range and fidelity |
| **AudioZoom** | Stereo with audio zoom + wind removal deliberately ON — the pickup beam narrows with your video zoom | Emergency suppression of loudly singing neighbors |

Raw + Back mic + cardioid = pickup aimed at the stage with the phone body shadowing the crowd, and zero DSP on the music.

## Camera features

- **Night mode** (🌙) — low-light auto frame rate (30 → 24 fps for longer exposure), the same mechanism the stock camera uses for low-light video. Available on 30 fps formats
- **Tap to focus/expose** with stock-style indicator box
- **Zoom presets** built from the device's real lens switch-over points, plus pinch-to-zoom (works mid-recording)
- **Resolution/fps picker** — 1080p/4K at 30/60, filtered to device support; persisted
- **Stabilization picker** — Off / Standard / Cinematic / Extended (stronger = steadier but more crop; pick mode before framing)
- **Pause/resume** during recording — stitches into a single file
- **Live mic level meter** — computed from the actual recording sample buffers; doubles as a covered-mic-port and clipping indicator
- **Horizon level** — CoreMotion line that snaps yellow when level, in portrait and landscape grips
- **"Rotate for YouTube" reminder** — turns red if you're actually recording in portrait
- Portrait-locked UI with controls that rotate in place (no preview snap on rotation); recordings still orient correctly via `RotationCoordinator`
- Recordings save straight to Photos

## Building

```sh
brew install xcodegen
xcodegen generate
open ConcertCam.xcodeproj
```

In Xcode: select the ConcertCam target → Signing & Capabilities → choose your team, then run on a device (camera apps are useless in the Simulator). With a free Apple ID the install expires after 7 days — re-run from Xcode the day before the show.

## Notable API facts (verified against the iOS 26.5 SDK)

- `AVCaptureDeviceInput.isAudioZoomEnabled` is iOS 26.4+, and audio zoom only applies when `multichannelAudioMode != .none` — third-party apps sidestep it by default
- Stock camera users can disable audio zoom at Settings → Camera → Record Sound → Audio Zoom (iOS 26.4+; grayed out in Mono format)
- `AVCaptureAudioChannel.averagePowerLevel` never updates on iOS — meter from an `AVCaptureAudioDataOutput` instead
- Wind-noise removal (`isWindNoiseRemovalEnabled`) also requires the multichannel path, so it's unavailable in Raw mode by design
