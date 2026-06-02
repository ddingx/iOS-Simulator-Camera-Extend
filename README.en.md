<div align="center">

<img src="docs/assets/logo.png" alt="iOS-Simulator-Camera-Extend" width="160" />

# iOS-Simulator-Camera-Extend

**Give your iOS Simulator a real, working camera. Zero code changes, zero Apple Developer account, zero subscription.**

English ｜ [中文](README.md)

<img src="docs/assets/demo.gif" alt="Demo" width="640" />

</div>

---

## The problem this solves

The iOS Simulator has no camera. The moment your app touches `AVCaptureSession`, QR scanning, face detection, AR, ID OCR, or video calling, you're forced onto a real device — or you sprinkle `#if targetEnvironment(simulator)` stubs everywhere.

[SimCam by Software Mansion](https://simcam.swmansion.com/) solves this elegantly, but requires a **$99/year Apple Developer account plus a paid license**.

This project is a **clean-room re-implementation** of that architecture, built for one audience:

> developers without a paid Apple account who just want to debug locally.

The app under test stays on **stock AVFoundation** — `AVCaptureDevice` / `AVCaptureSession` / `AVCaptureMetadataOutput` / `AVCaptureVideoPreviewLayer`. **Not a single line of business code changes, no re-signing, no bundle-id constraint.** Inside the Simulator it sees Mac-side cameras, the desktop, video files, and QR codes.

The whole thing is built on public Apple APIs (`ScreenCaptureKit` / `AVFoundation` / `CoreMediaIO` / `OSSystemExtensionRequest`) plus `DYLD_INSERT_LIBRARIES` on the Simulator side. **No private SPI, no jailbreak, no SIP-disable** for the Simulator path.

---

## What it does

- **Zero changes to the app under test**: no SDK, no `import`, no re-signing. Use AVFoundation correctly and it Just Works.
- **All standard AVFoundation paths intercepted**: `AVCaptureDevice.DiscoverySession`, `AVCaptureSession.addInput`, `AVCaptureVideoDataOutput`, `AVCaptureMetadataOutput` (QR included), `AVCaptureVideoPreviewLayer`.
- **Independent back / front slots**, each with its own source.
- **Simulator-window passthrough (default back)**: the camera "looks through" the Simulator window onto the desktop behind it, follows the window as you drag.
- **Many sources**: Mac camera, full screen / single window / Simulator passthrough, local image / video file, QR generator, demo card.
- **Optional macOS virtual camera**: a CMIO Camera System Extension so QuickTime / FaceTime / Zoom / OBS can also pick *SimCam Virtual Camera*.

---

## Architecture

```
┌────────────────────── macOS host ─────────────────────────┐
│  SimCamApp.app  (menubar)                                 │
│   ┌──────────────────────────────────────────────────┐    │
│   │  SimCamEngine                                    │    │
│   │   ├─ FrameProducer (per slot: back / front)      │    │
│   │   │   • CameraDeviceFrameProducer (AVFoundation) │    │
│   │   │   • ScreenFrameProducer (ScreenCaptureKit)   │    │
│   │   │       ├─ display / window                    │    │
│   │   │       └─ followSimulator (locks onto window) │    │
│   │   │   • Image / Video / QR / DemoCard            │    │
│   │   ├─→ CMIO sink ──► SimCamExtension.systemextension   │
│   │   └─→ LocalSocketFrameServer ──► /tmp/com.simcam.…sock │
│   └──────────────────────────────────────────────────┘    │
│                                                           │
│   ┌─────────── iOS Simulator ────────────────────────┐    │
│   │  YourApp  (stock AVFoundation, untouched)        │    │
│   │   ▲                                              │    │
│   │   │  swizzle  (DYLD_INSERT_LIBRARIES)            │    │
│   │   │                                              │    │
│   │  libSimCamHook.dylib                             │    │
│   │   • fakeBack / fakeFront AVCaptureDevice         │    │
│   │   • frame puller @ unix socket                   │    │
│   │   • fan out to sample buffer / metadata / preview│    │
│   └──────────────────────────────────────────────────┘    │
└───────────────────────────────────────────────────────────┘
```

The wire protocol (48-byte v2 header with `cameraSlot`) is in [SimCamHook.h](Sources/SimCamHook/SimCamHook.h).

---

## Quick start (Simulator path)

Requirements: a free Apple ID, Xcode 15+, and `xcodegen`.

```bash
# 1. Generate the Xcode project
brew install xcodegen
make open

# 2. Build the host menubar app
xcodebuild -scheme SimCam -configuration Debug \
  -derivedDataPath build/SimCamDD build

# 3. Build the demo + injected dylib
#    (must be the SimCamDemo scheme — SimCam scheme does NOT build the dylib)
xcodebuild -project SimCam.xcodeproj -scheme SimCamDemo \
  -sdk iphonesimulator -arch arm64 -configuration Debug build

# 4. Boot a simulator and install the demo
xcrun simctl boot "iPhone 17 Pro" 2>/dev/null || true
open -a Simulator
xcrun simctl install booted \
  ~/Library/Developer/Xcode/DerivedData/SimCam-*/Build/Products/Debug-iphonesimulator/SimCamDemoApp.app

# 5. Launch the host menubar app
open build/SimCamDD/Build/Products/Debug/SimCamApp.app

# 6. Inject the hook into the demo
./scripts/inject-simulator.sh dev.simcam.demo
```

You should now see the demo app inside the Simulator with a *Switch to Front* button and live frames coming from the host. The default back source is **Simulator passthrough** — drag the Simulator window around and the camera content follows the desktop behind it.

To use this with **your own** app, just point the script at your bundle id:

```bash
xcrun simctl install booted /path/to/YourApp.app
./scripts/inject-simulator.sh com.yourcompany.YourApp
```

Your app is not modified, recompiled, or re-signed.

---

## macOS path (CMIO virtual camera, optional)

If you also want *SimCam Virtual Camera* to show up in QuickTime / FaceTime / Zoom on the Mac itself:

1. Boot into Recovery and run `csrutil enable --without debug --without kext` (this is a **partial** SIP relaxation, not a full disable).
2. `sudo systemextensionsctl developer on`.
3. Install `SimCamApp.app` into `/Applications/` (sysextd refuses to load extensions from DerivedData paths).
4. Launch it and accept the system-extension prompt in *System Settings → Privacy & Security*.

Step-by-step instructions and recovery commands live in [docs/no-developer-account.md](docs/no-developer-account.md). **Skip this section entirely if you only care about the Simulator path.**

---

## Documentation

| Doc | Topic |
|---|---|
| [README.md](README.md) | Chinese (primary) |
| [docs/permissions-and-flow.md](docs/permissions-and-flow.md) | Triggers for screen-recording / camera / system-extension permissions, Hardened Runtime entitlement matrix, full host → simulator frame flow, troubleshooting |
| [docs/no-developer-account.md](docs/no-developer-account.md) | Long-form runbook: TCC, ad-hoc signing, system-extension activation, recovery |
| [RUN_NOTES.md](RUN_NOTES.md) | Field notes from the clean-room re-implementation |
| [Sources/SimCamHook/SimCamHook.h](Sources/SimCamHook/SimCamHook.h) | Wire protocol v2 (48-byte header, `cameraSlot`) |

---

## License

[MIT](LICENSE) — fork, extend, ship.

This project is **not** affiliated with or endorsed by Software Mansion. It re-implements the publicly documented architecture of [simcam.swmansion.com](https://simcam.swmansion.com/) using only public Apple APIs. **No** SimCam source code was used, viewed, or copied. If you need a polished, supported, notarized product, please buy a SimCam license — the original team did the hard design work and deserves your money.
