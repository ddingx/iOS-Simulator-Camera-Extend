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

<div align="center">
<img src="docs/assets/architecture.png" alt="Architecture" width="900" />
</div>

The wire protocol (48-byte v2 header with `cameraSlot`) is in [SimCamHook.h](Sources/SimCamHook/SimCamHook.h).

<details>
<summary>ASCII fallback</summary>

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

</details>

---

## What works today

Both pipelines are wired up and can run **at the same time**:

| What you want | Which pipeline | Who it serves |
|---|---|---|
| Run your iOS app **inside iOS Simulator** and have its camera preview / QR scanner / video-call code see custom frames | **Simulator hook pipeline** (DYLD inject) | Any iOS app inside the simulator (the bundled demo, your business app, third-party apps) |
| On **macOS**, swap the camera feed for QuickTime / FaceTime / Zoom / Discord / OBS | **CMIO sysext pipeline** | Any macOS AVFoundation client |

**Both pipelines share the same source**: pick *FaceTime HD / Image / Video / QR / Simulator passthrough / any window or display* in the SimCam menubar, and what QuickTime sees and what your iOS app inside the simulator sees are **identical, switched in sync**.

> ⚠️ **An iOS app inside the Simulator cannot reach the CMIO sysext directly** — the iOS SDK has no CMIO surface area. This is an Apple platform limitation, not something this project can solve, and it is the same for the commercial SimCam. So "iOS apps inside the simulator see the SimCam feed" must go through the hook pipeline. This does **not** contradict the SimCam tagline "without changing anything in your app" — that means **you don't change your iOS app's code / SDKs / bundle id**, not that no Mac-side injection is required.

---

## Requirements

### Required

| | Notes |
|---|---|
| **macOS** | 13+ (verified on 14 / 15 / 26) |
| **Xcode** | 15+, with `xcodebuild` / `xcrun simctl` / `codesign` / `security` available |
| **OpenSSL** | macOS LibreSSL `security` is enough; `bootstrap-cert.sh` uses OpenSSL 3.x (Homebrew or built-in on macOS 14+) |
| **A booted iOS Simulator** | Any model you want to test |

### Required only for the CMIO sysext pipeline

| | Notes |
|---|---|
| **System-extension developer mode** | `sudo systemextensionsctl developer on` (resets on reboot, re-run after every restart) |
| **sudo access** | Installing a sysext requires copying the host bundle to `/Applications/` and `chown root:wheel` (sysextd's hard rule) |
| **Local self-signed cert: SimCam Local Dev** | One-shot `make bootstrap-cert`, generated and imported into login keychain; the private key is **never** committed |

### **Not** required

- ❌ Paid Apple Developer Program ($99/yr) — replaced with a local self-signed cert
- ❌ Personal Team — verified that Personal Teams don't support the System Extension capability
- ❌ Disabling SIP, jailbreaking
- ❌ Changing your iOS app's source / SDK / bundle id

---

## Quick start

### One-time setup (do this once per machine)

```bash
# 1. Generate the local SimCam Local Dev code-signing cert and import it
make bootstrap-cert

# 2. Enable system-extension developer mode (resets on reboot)
sudo systemextensionsctl developer on
```

### Bring up the CMIO pipeline (macOS virtual camera)

```bash
# 3. Build + re-sign + copy to /Applications/ (needs sudo)
make install

# 4. Launch the SimCam menubar app
make run

# 5. First activation: click the SimCam menubar icon → Activate Virtual Camera
#    macOS will prompt once: "allow system extension signed by SimCam Local Dev"
#    Approve it under System Settings → Privacy & Security
#    Subsequent rebuilds / reinstalls will *not* prompt again
#    (DR pinned to certificate root → TCC entries stay valid).

# 6. Verify
systemextensionsctl list | grep simcam
# Expected: dev.simcam.app.extension  [activated enabled]

# Then in QuickTime → New Movie Recording → camera dropdown → "SimCam Virtual Camera"
```

### Bring up the Simulator hook pipeline (let your iOS app see the feed)

```bash
# 7. Boot a simulator and install the demo app
open -a Simulator
xcrun simctl boot "iPhone 17 Pro" 2>/dev/null || true

xcodebuild -project SimCam.xcodeproj -scheme SimCamDemo \
    -configuration Debug \
    -destination 'generic/platform=iOS Simulator' build

xcrun simctl install booted \
    ~/Library/Developer/Xcode/DerivedData/SimCam-*/Build/Products/Debug-iphonesimulator/SimCamDemoApp.app

# 8. Inject the hook and launch the demo (the host SimCamApp must be running)
./scripts/inject-simulator.sh dev.simcam.demo

# Expected: the demo app's back / front camera previews inside the simulator
# render whatever you picked in the SimCam menubar.
```

To use this with **your own** iOS app, just point the script at your bundle id:

```bash
xcrun simctl install booted /path/to/YourApp.app
./scripts/inject-simulator.sh com.yourcompany.YourApp
```

**Your app is not modified, recompiled, or re-signed; the bundle id stays the same.**

---

## Make targets at a glance

| target | what it does |
|---|---|
| `make bootstrap-cert` | **One-time**: generate the self-signed `SimCam Local Dev` cert and import it into login keychain |
| `make build` | xcodebuild Debug for host + extension |
| `make test` | xcodebuild test |
| `make install` | build + re-sign with full entitlements + copy to `/Applications/` + `chown root:wheel` (needs sudo) |
| `make run` | install + `open /Applications/SimCamApp.app` |
| `make doctor` | one-shot diagnostics: SIP / dev mode / signing / sysextd log / extension state |
| `make reset-tcc` | only after switching signing identity: wipe stale TCC entries |
| `make open` | open the Xcode project |
| `make clean` | wipe `build/` and `DerivedData/` |

The signing rationale lives in [docs/signing-and-tcc.md](docs/signing-and-tcc.md).

---

## Things this repo cannot do

- **Real-device** virtual camera: not possible. iOS device camera APIs live outside the sandbox; you'd need kernel-level hooks or a jailbreak. Out of scope here.
- A camera source for App Store apps: the dylib is injected only inside the *Simulator* process, never ends up in your `.ipa`, has no impact on App Store review — but it is also not a production "fake camera source".
- Skip injection and have the iOS app inside the simulator go through CMIO: see the boxed note above. Apple's SDK boundary makes this physically impossible.

---

## Troubleshooting cheat sheet

| Symptom | Check |
|---|---|
| `make install` fails with `'SimCam Local Dev' not found` | Run `make bootstrap-cert`; verify `security find-identity -v -p codesigning` lists SimCam Local Dev |
| `systemextensionsctl list` shows nothing | Run `make doctor`; common culprits: `sudo systemextensionsctl developer on` not run, host not in `/Applications/`, host owner ≠ root:wheel |
| sysext stuck at `[activated waiting for user]` | Approve in System Settings → Privacy & Security |
| *SimCam Virtual Camera* missing from QuickTime's camera list | sysext not activated (see above); or activated but host process not running → `make run` |
| Injected the simulator but no frames / `xcrun simctl spawn booted log stream` shows no `[SimCamHook]` lines | Wrong dylib path (must be `Build/Products/Debug-iphonesimulator/libSimCamHook.dylib`; the unsigned intermediate is silently rejected by dyld); or the host SimCamApp isn't running (`/tmp/com.simcam.frames.sock` missing) |
| iOS app reports `Camera permission denied` | Not an injection issue — the app under test is missing `NSCameraUsageDescription` in its own Info.plist |
| Changed hook code and the change didn't take effect | You must build the `SimCamDemo` scheme, not the `SimCam` scheme (the hook dylib is only built by SimCamDemo) |

A longer checklist lives in [docs/permissions-and-flow.md](docs/permissions-and-flow.md) §3 and [RUN_NOTES.md](RUN_NOTES.md).

---

## Documentation

| Doc | Topic |
|---|---|
| [README.md](README.md) | Chinese version |
| [docs/signing-and-tcc.md](docs/signing-and-tcc.md) | Why this repo uses a self-signed `SimCam Local Dev` cert and not ad-hoc / Personal Team / Developer Program |
| [docs/permissions-and-flow.md](docs/permissions-and-flow.md) | Permission matrix (screen recording / camera / system extensions), Hardened Runtime entitlements, full host → simulator frame flow, troubleshooting |
| [docs/no-developer-account.md](docs/no-developer-account.md) | Long-form runbook: end-to-end for both pipelines, TCC, SIP, `developer on`, recovery |
| [RUN_NOTES.md](RUN_NOTES.md) | Field notes from the clean-room re-implementation |
| [Sources/SimCamHook/SimCamHook.h](Sources/SimCamHook/SimCamHook.h) | Wire protocol v2 (48-byte header, `cameraSlot`) |

---

## About

Most iOS engineers know the pain: every time you build a feature touching cameras — capture, QR, face detection, AR — you end up plugging a real device in and out, or sprinkling fake-data stubs through your code. Software Mansion's SimCam fixes this elegantly, but at $99/year for an Apple Developer account plus a paid license, the bar is high for indie developers, students, classrooms, and internal-tooling teams.

This repo is **a pure engineering exercise**: a from-scratch re-implementation guided only by the architecture publicly documented at [simcam.swmansion.com](https://simcam.swmansion.com/) (menubar host + `DYLD_INSERT_LIBRARIES` swizzle + an optional CMIO system extension), built on public Apple APIs (`ScreenCaptureKit` / `AVFoundation` / `CoreMediaIO` / `OSSystemExtensionRequest`). **No SimCam source code was used, viewed, or copied.**

Two goals: let developers without a paid Apple account exercise camera code paths inside the Simulator; and document every non-obvious gotcha (TCC, Hardened Runtime entitlements, system-extension activation flow) so the next person doesn't have to relearn it.

If you need a **production-grade**, supported, notarized virtual-camera product, please buy SimCam — the original team did the hard design work and deserves your money. If you just want local debugging, teaching, or internal tooling, you're welcome to use, modify, and fork this.

---

## License

[MIT](LICENSE) — fork, modify, ship. This project is **not** affiliated with or endorsed by Software Mansion.
