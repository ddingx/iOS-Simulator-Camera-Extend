<div align="center">

<img src="docs/assets/logo.png" alt="iOS-Simulator-Camera-Extend" width="160" />

# iOS-Simulator-Camera-Extend

**给 iOS Simulator 一台真正能用的相机。零代码改动，零开发者账号，零订阅费。**

[English](README.en.md) ｜ 中文

<img src="docs/assets/demo.gif" alt="Demo" width="640" />

</div>

---

## 它解决什么问题

iOS Simulator 没有相机。一旦你的 app 涉及 `AVCaptureSession`、扫码、人脸、AR、ID OCR、视频通话——你只能跑真机，或者写一堆 `#if targetEnvironment(simulator)` 假数据兜底。

[SimCam (Software Mansion)](https://simcam.swmansion.com/) 用一种很巧妙的架构解决了这件事，但它需要 **$99/年 Apple Developer 账号 + 商业 license**。

本项目是这套架构的**clean-room 复刻**，目标只有一个：

> 让没有付费 Apple 账号、只想本机调试的开发者也能用上同样的能力。

被测 app 完全使用 **标准 AVFoundation** —— `AVCaptureDevice` / `AVCaptureSession` / `AVCaptureMetadataOutput` / `AVCaptureVideoPreviewLayer` ——**一行业务代码不改，不重新签名，不换 bundle id**。在 Simulator 里就能拿到 Mac 的摄像头、桌面、视频文件、二维码画面。

整套实现仅依赖 Apple 公开 API（`ScreenCaptureKit` / `AVFoundation` / `CoreMediaIO` / `OSSystemExtensionRequest`）+ iOS Simulator 上的 `DYLD_INSERT_LIBRARIES`。**没有私有 SPI，不越狱，不关 SIP**（Simulator 路径而言）。

---

## 能做什么

- **被测 app 零侵入**：不需要 SDK、不需要 `import`、不需要重新签名。AVFoundation 用得对，开箱即用。
- **拦截全部标准 AVFoundation 路径**：`AVCaptureDevice.DiscoverySession`、`AVCaptureSession.addInput`、`AVCaptureVideoDataOutput`、`AVCaptureMetadataOutput`（含二维码）、`AVCaptureVideoPreviewLayer`。
- **后置 / 前置双槽位独立**：每个槽位独立挑选帧源。
- **Simulator 窗口穿透（默认后置）**：相机"看穿" Simulator 这扇窗，呈现它背后的桌面，跟随窗口移动。
- **多种帧源**：Mac 摄像头、整屏 / 单窗口 / Simulator passthrough、本地图片 / 视频、二维码生成器、demo 卡片。
- **macOS 端虚拟摄像头（可选）**：CMIO Camera System Extension，让 QuickTime / FaceTime / Zoom / OBS 也能选用 *SimCam Virtual Camera*。

---

## 架构

```
┌────────────────────── macOS host ─────────────────────────┐
│  SimCamApp.app  (menubar)                                 │
│   ┌──────────────────────────────────────────────────┐    │
│   │  SimCamEngine                                    │    │
│   │   ├─ FrameProducer (per slot: back / front)      │    │
│   │   │   • CameraDeviceFrameProducer (AVFoundation) │    │
│   │   │   • ScreenFrameProducer (ScreenCaptureKit)   │    │
│   │   │       ├─ display / window                    │    │
│   │   │       └─ followSimulator (跟随 Simulator 窗口) │    │
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

帧线协议（48 字节 v2 头 + `cameraSlot`）见 [SimCamHook.h](Sources/SimCamHook/SimCamHook.h)。

---

## 快速开始（Simulator 路径）

只需要：免费 Apple ID + Xcode 15+ + `xcodegen`。

```bash
# 1. 生成 Xcode 工程
brew install xcodegen
make open

# 2. build host menubar app
xcodebuild -scheme SimCam -configuration Debug \
  -derivedDataPath build/SimCamDD build

# 3. build demo + 注入用 dylib（必须 SimCamDemo scheme，SimCam scheme 不带 dylib）
xcodebuild -project SimCam.xcodeproj -scheme SimCamDemo \
  -sdk iphonesimulator -arch arm64 -configuration Debug build

# 4. 启动 simulator + 安装 demo
xcrun simctl boot "iPhone 17 Pro" 2>/dev/null || true
open -a Simulator
xcrun simctl install booted \
  ~/Library/Developer/Xcode/DerivedData/SimCam-*/Build/Products/Debug-iphonesimulator/SimCamDemoApp.app

# 5. 启动 host menubar app
open build/SimCamDD/Build/Products/Debug/SimCamApp.app

# 6. 把 hook 注入到 demo
./scripts/inject-simulator.sh dev.simcam.demo
```

跑通的样子：simulator 里的 demo app 出现 *Switch to Front* 按钮，画面是 host 推过来的。默认后置源是 **Simulator passthrough** —— 拖动 Simulator 窗口，相机画面就跟着背后桌面走。

把它接到**自己的 app**上，把 bundle id 换成自己的即可：

```bash
xcrun simctl install booted /path/to/YourApp.app
./scripts/inject-simulator.sh com.yourcompany.YourApp
```

被测 app 不改一行代码，不重新编译，不重新签名。

---

## macOS 路径（CMIO 虚拟摄像头，可选）

如果你还想让 *SimCam Virtual Camera* 出现在 QuickTime / FaceTime / Zoom：

1. 进 Recovery 跑 `csrutil enable --without debug --without kext`（**部分**降级 SIP，不是全关）。
2. `sudo systemextensionsctl developer on`。
3. 把 `SimCamApp.app` 安装到 `/Applications/`（sysextd 不接受 DerivedData 路径）。
4. 启动它，去 *系统设置 → 隐私与安全性* 点允许。

完整步骤、踩坑恢复见 [docs/no-developer-account.md](docs/no-developer-account.md)。**只用 Simulator 路径可以跳过整段。**

---

## 文档

| 文档 | 内容 |
|---|---|
| [README.en.md](README.en.md) | English version |
| [docs/permissions-and-flow.md](docs/permissions-and-flow.md) | 屏幕录制 / 摄像头 / 系统扩展三类权限的触发点、Hardened Runtime entitlement 矩阵、host → simulator 完整帧流、故障排查 |
| [docs/no-developer-account.md](docs/no-developer-account.md) | 长版 runbook：TCC、ad-hoc 签名、系统扩展激活、踩坑恢复 |
| [RUN_NOTES.md](RUN_NOTES.md) | 复刻过程踩到的非显然坑 + 根因 |
| [Sources/SimCamHook/SimCamHook.h](Sources/SimCamHook/SimCamHook.h) | 帧线协议 v2（48 字节头 + `cameraSlot`） |

---

## License

[MIT](LICENSE) — fork 它、扩展它、ship 它。

本项目**不**附属于、也未被 Software Mansion 背书。它仅依据 [simcam.swmansion.com](https://simcam.swmansion.com/) 公开记录的架构、用 Apple 公开 API 重新实现，**没有**使用、查看或复制 SimCam 任何源码。如果你需要一份打磨过、有支持、已公证的产品 —— 请购买 SimCam 商业版，原团队做了所有难的设计工作，他们值得你的钱。
