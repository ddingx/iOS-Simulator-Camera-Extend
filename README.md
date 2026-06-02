# iOS-Simulator-Camera-Extend

> **A free, open-source, zero-Apple-Developer-account replica of [SimCam](https://simcam.swmansion.com/) — give your iOS Simulator a real camera, with zero changes to the app under test.**
>
> macOS menubar app. Pipes Mac camera / desktop / image / video / QR frames into the iOS Simulator through a `DYLD_INSERT_LIBRARIES`-injected dylib that swizzles `AVFoundation`. Your app keeps calling stock `AVCaptureDevice` / `AVCaptureSession` / `AVCaptureVideoPreviewLayer` / `AVCaptureMetadataOutput` and just sees a working back / front camera.

---

## Why this project exists

[SimCam by Software Mansion](https://simcam.swmansion.com/) is a fantastic commercial macOS app that finally fixes the "iOS Simulator doesn't have a real camera" pain point. The catch:

- it's a paid product;
- **and** to ship the macOS-side virtual-camera path it needs a $99/year Apple Developer account + a system-extension entitlement that Apple only grants on a paid Team.

This repo is a **clean-room re-implementation of the same architecture** for hobbyists / OSS contributors who:

1. **Don't have $99** to pay Apple every year;
2. Are fine running the app on their own development machine (where SIP can be relaxed for local debugging);
3. Want to read & hack the source.

Everything here is built from public APIs — `ScreenCaptureKit`, `AVFoundation`, `CoreMediaIO`, `OSSystemExtensionRequest`, plus old-school `dyld` interposition for the simulator side. **No private SPI, no jailbreak, no SIP-disable required for the Simulator path.**

---

## Highlights

- 🎥 **Two independent slots** for `back` + `front` simulator cameras, each with its own source pipeline (Mac camera / desktop / window / image / video / QR / demo card).
- 🪟 **Simulator passthrough mode (default `back`)** — the simulator camera "sees through" the Simulator window onto the desktop behind it, and follows the window as you drag it. This is the SimCam-flagship effect.
- 📷 **All standard AVFoundation paths** are intercepted: `AVCaptureDevice.DiscoverySession`, `AVCaptureSession.add/removeInput`, `AVCaptureVideoDataOutput`, `AVCaptureMetadataOutput` (QR codes!), and `AVCaptureVideoPreviewLayer`.
- 🛡️ **Zero changes to the app under test.** No SDK, no `import`, no entitlement edits, no bundle-id constraint. If your app uses `AVFoundation` correctly it Just Works.
- 🖥️ **macOS-side virtual camera** (CMIO Camera System Extension) is also implemented — usable from QuickTime / FaceTime / Zoom / OBS — for users willing to relax SIP locally on a dev machine.
- 🧰 **No paid account required** for the Simulator path. Ad-hoc signing is enough.

---

## Architecture (one picture)

```
┌──────────────────────── macOS host ─────────────────────────────┐
│                                                                  │
│   SimCamApp.app  (menubar)                                       │
│   ┌────────────────────────────────────────────────────────┐    │
│   │  SimCamEngine                                            │    │
│   │   ├─ FrameProducer (per slot: back / front)              │    │
│   │   │   • CameraDeviceFrameProducer  (AVF capture)         │    │
│   │   │   • ScreenFrameProducer         (ScreenCaptureKit)   │    │
│   │   │     ├─ raw display / window                          │    │
│   │   │     └─ followSimulator: locks sourceRect onto         │    │
│   │   │       Simulator.app's window, excludes it from       │    │
│   │   │       capture (no recursion)                         │    │
│   │   │   • Image / Video / QR / DemoCard                    │    │
│   │   ├─→ CMIO sink stream  ──►  SimCamExtension.systemext   │    │
│   │   └─→ LocalSocketFrameServer  ──►  /tmp/com.simcam.…sock │    │
│   └────────────────────────────────────────────────────────┘    │
│                                                                  │
│   ┌────────────── iOS Simulator ──────────────────────────┐     │
│   │  YourApp  (stock AVFoundation, untouched)              │     │
│   │   ▲                                                    │     │
│   │   │ swizzle (DYLD_INSERT_LIBRARIES)                    │     │
│   │   │                                                    │     │
│   │  libSimCamHook.dylib                                   │     │
│   │   • fakeBack / fakeFront AVCaptureDevice               │     │
│   │   • frame puller @ unix sock — back/front slots        │     │
│   │   • fans frames out to all sample-buffer delegates,    │     │
│   │     QR metadata delegates, preview-layer .contents     │     │
│   └────────────────────────────────────────────────────────┘     │
└──────────────────────────────────────────────────────────────────┘
```

For the wire protocol (48-byte v2 header with `cameraSlot`), see [SimCamHook.h](Sources/SimCamHook/SimCamHook.h).
For the full theory of operation, including how we work around the macOS-Sonoma-14+ TCC degraded path, ad-hoc cdhash churn invalidating screen-recording grants, and how `setBounds:` / `setFrame:` is rerouted to `CALayer` to avoid hitting `AVCaptureVideoPreviewLayer`'s private ivars on `init`, see [docs/no-developer-account.md](docs/no-developer-account.md).

---

## Quick start (Simulator path — recommended first run)

You only need a free Apple ID, Xcode 15+, and `xcodegen` (or you can hand-author the Xcode project).

```bash
# 1. Generate the Xcode project
brew install xcodegen
make open                          # = xcodegen + open SimCam.xcodeproj

# 2. Build the host menubar app
xcodebuild -scheme SimCam -configuration Debug \
  -derivedDataPath build/SimCamDD build

# 3. Build the demo + the injected dylib
#    (must be the SimCamDemo scheme — SimCam scheme does NOT build the dylib)
xcodebuild -project SimCam.xcodeproj -scheme SimCamDemo \
  -sdk iphonesimulator -arch arm64 -configuration Debug build

# 4. Boot a simulator and install the demo app
xcrun simctl boot "iPhone 17 Pro" 2>/dev/null || true
open -a Simulator
xcrun simctl install booted \
  ~/Library/Developer/Xcode/DerivedData/SimCam-*/Build/Products/Debug-iphonesimulator/SimCamDemoApp.app

# 5. Launch the host menubar app
open build/SimCamDD/Build/Products/Debug/SimCamApp.app

# 6. Inject the hook into the demo app
./scripts/inject-simulator.sh dev.simcam.demo
```

You should now see the demo app inside the Simulator with a `Switch to Front` button and live frames coming from the host. The default `back` source is **Simulator passthrough** — drag the Simulator window around and the camera content follows the desktop behind it.

If you want to use this with **your own** app instead of the demo, just point the script at your app's bundle id:

```bash
xcrun simctl install booted /path/to/YourApp.app
./scripts/inject-simulator.sh com.yourcompany.YourApp
```

Your app does not need to be modified, recompiled, or re-signed. **Zero integration code.**

---

## macOS path (CMIO virtual camera — optional, advanced)

If you also want `SimCam Virtual Camera` to show up in QuickTime / FaceTime / Zoom on the host Mac, you must:

1. Boot into Recovery and run `csrutil enable --without debug --without kext` (this is a partial SIP relaxation, not a full disable);
2. `sudo systemextensionsctl developer on`;
3. Install `SimCamApp.app` into `/Applications/` (sysextd refuses to load extensions from DerivedData paths);
4. Launch it and accept the system-extension prompt in System Settings → Privacy & Security.

Step-by-step instructions and recovery commands for "I bricked my install" live in [docs/no-developer-account.md](docs/no-developer-account.md). **You can skip this section entirely if you only care about the Simulator.**

---

## Targets / Schemes

| Target | Kind | Role |
|---|---|---|
| **SimCamApp** | macOS app | menubar UI + `SimCamEngine` + unix-sock frame server + extension activator |
| **SimCamExtension** | system extension (embedded in SimCamApp) | CMIO virtual camera implementation |
| **SimCamHook** | iOS-Simulator dylib (Obj-C) | `DYLD_INSERT_LIBRARIES` payload — swizzles AVFoundation |
| **SimCamDemoApp** | iOS app (runs in simulator) | Sample app proving the "stock AVFoundation" claim — no SimCam dependency |
| **SimCamCoreTests** | XCTest bundle | engine, QR, license, frame producer unit tests |

| Scheme | Builds |
|---|---|
| `SimCam` | SimCamApp + SimCamExtension + SimCamCoreTests |
| `SimCamDemo` | **SimCamHook** + SimCamDemoApp |

⚠️ Always rebuild `SimCamDemo` after touching `SimCamHook.m`. The `SimCam` scheme does not depend on the dylib target, so a `-scheme SimCam` build will leave you running the previous hook binary.

---

## Repository layout

```
project.yml                     # xcodegen recipe
Makefile                        # generate / build / test / run shortcuts
Generated/                      # Info.plist + entitlements (gitignored, regenerated)
SimCam.xcodeproj/               # gitignored, regenerated
Sources/
  SimCamCore/                   # engine, frame producers, unix-sock server, QR
    SimCamEngine.swift
    FrameProducers.swift          # CameraDevice / ScreenFrame (with followSimulator) / Image / Video / QR / DemoCard
    LocalSocketFrameServer.swift  # /tmp/com.simcam.frames.sock
    CameraSource.swift / SimCamState.swift / QRCodeGenerator.swift
    SystemExtensionProbe.swift
  SimCamExtension/              # CMIO Camera System Extension
    SimCamExtensionMain.swift / SimCamCMIODevice.swift
  SimCamApp/                    # menubar host
    AppDelegate.swift / ExtensionActivator.swift
    MenubarView.swift / MenubarViewModel.swift
  SimCamHook/                   # ⭐ Obj-C dylib injected into the simulator process
    SimCamHook.h / SimCamHook.m
  SimCamDemoApp/                # iOS demo (stock AVFoundation, no SimCam imports)
    AppDelegate.swift / ContentView.swift
Tests/SimCamCoreTests/
scripts/
  bootstrap-xcode.sh            # brew install xcodegen
  inject-simulator.sh           # SIMCTL_CHILD_DYLD_INSERT_LIBRARIES launcher
  install-systemext.sh          # cp to /Applications + entitlement bypass
  diagnose-sysext.sh            # one-shot sysextd log dump
docs/
  no-developer-account.md       # the long-form runbook
RUN_NOTES.md                    # field notes & gotchas
```

---

## Known gotchas (the short list)

The full version with reproductions and root-cause analyses lives in [RUN_NOTES.md](RUN_NOTES.md) and [docs/no-developer-account.md](docs/no-developer-account.md). Highlights:

- **`SimCam` scheme does not build `SimCamHook`.** Always rebuild `SimCamDemo` after editing the hook.
- **Unsigned dylibs are silently ignored** by the iOS-17+ simulator's dyld. Inject only from `Build/Products/Debug-iphonesimulator/` (already ad-hoc signed by Xcode); the `Intermediates.noindex/.../Binary/` copy is unsigned and won't load.
- **TCC screen-recording grants vanish on rebuild** because ad-hoc signing changes the cdhash that TCC keys on. The menubar UI now always shows a "Grant Screen Recording" button which calls `SCStream.startCapture()` to force the system prompt — use it instead of toggling System Settings by hand.
- **macOS 14+ `SCShareableContent` does NOT throw on missing permission.** It silently returns `displays = []` and windows with `owningApplication == nil`. We detect that and surface a "denied" state, rather than pretending there are no displays.
- **Don't share an `AVCaptureSession` between SwiftUI `updateUIView` calls without a stable `inputs` array.** A `removeInput → addInput` cycle leaves the hook's shadow array empty for one frame, which used to cause a flash of the wrong slot's content. Fixed by caching the last resolved slot per session and skipping frames during the gap.

---

## Documentation

- [README.md](README.md) — what this project is, how to build & run it (you are here).
- [docs/no-developer-account.md](docs/no-developer-account.md) — long-form runbook: TCC, ad-hoc signing, system-extension activation, and recovery steps.
- [RUN_NOTES.md](RUN_NOTES.md) — field notes and gotchas accumulated while building this clone (Chinese).
- [Sources/SimCamHook/SimCamHook.h](Sources/SimCamHook/SimCamHook.h) — wire protocol v2 (48-byte header, `cameraSlot`).

---

## Roadmap

- [ ] Multi-simulator support (currently picks the largest Simulator window)
- [ ] CLI for headless CI usage (no menubar, source picked via flags)
- [ ] Per-slot resolution / FPS controls in the UI
- [ ] Continuity Camera as a first-class source (already works via the generic camera path)
- [ ] Optional H.264 wire encoding to lower CPU on busy hosts
- [ ] Notarization-signed release for users with a paid account

PRs welcome.

---

## License

[MIT](LICENSE) — feel free to fork, extend, ship.

This project is **not** affiliated with or endorsed by Software Mansion. It re-implements the publicly documented architecture of [simcam.swmansion.com](https://simcam.swmansion.com/) using only public Apple APIs. No SimCam source code was used, viewed, or copied. If you need a polished, supported, notarized product — please buy a SimCam license, the original team did the hard design work and deserves your money.

## Acknowledgements

- [Software Mansion / SimCam](https://simcam.swmansion.com/) — for proving the architecture is feasible and for the excellent UX that inspired this clone.
- Apple's `ScreenCaptureKit`, `AVFoundation`, and `CoreMediaIO` framework engineers for the public APIs that make this possible.
