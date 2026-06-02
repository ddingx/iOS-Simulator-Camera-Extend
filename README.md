<div align="center">

<img src="docs/assets/logo.png" alt="SimCam Clone Logo" width="180" />

# iOS-Simulator-Camera-Extend

**给 iOS Simulator 一台真正能用的相机 ——
零代码改动、零开发者账号、零月费。**

[English](README.en.md) ｜ 中文

<img src="docs/assets/demo.gif" alt="SimCam demo" width="640" />

</div>

---

## 是什么

[SimCam (Software Mansion)](https://simcam.swmansion.com/) 是一款很优秀的 macOS 商业 app，用一种很巧妙的方式解决了"iOS Simulator 没有真相机"这个老大难。代价：
**$99/年 Apple Developer 账号 + 商业 license**。

**本仓库**是这套架构的**clean-room 复刻**，目标只有一个 ——

> 让没有 Apple 付费账号、只想本机调试的开发者也能用上同样的能力。

被测 iOS app 完全使用**标准 AVFoundation**（`AVCaptureDevice` / `AVCaptureSession` / `AVCaptureMetadataOutput` / `AVCaptureVideoPreviewLayer`），**一行业务代码都不改**，就能在 Simulator 里看到 Mac 的摄像头、桌面、视频文件、二维码……

整个项目仅使用公开 Apple API（`ScreenCaptureKit` / `AVFoundation` / `CoreMediaIO` / `OSSystemExtensionRequest`）+ iOS Simulator 上的 `DYLD_INSERT_LIBRARIES`。**无私有 API、无越狱、无关闭 SIP**（对 Simulator 路径而言）。

---

## 能做什么

| 能力 | 说明 |
|---|---|
| 🎥 **Back / Front 双槽位** | 后置 + 前置两个独立 producer，各自挑帧源 |
| 🪟 **Simulator passthrough**（默认 `back`） | 相机"穿透" Simulator 这扇窗，拍背后桌面，跟随窗口拖动 |
| 📷 **拦截全部标准 AVFoundation 路径** | DiscoverySession / addInput / VideoDataOutput / MetadataOutput（QR）/ VideoPreviewLayer |
| 🛡️ **被测 app 零侵入** | 不需要 SDK、不需要 import、不改 bundle id，AVF 用得对就 Just Works |
| 🖥️ **macOS 端虚拟摄像头** | CMIO Camera System Extension，QuickTime / FaceTime / Zoom / OBS 都能选用（需要本机降级 SIP） |
| 🧰 **免付费 Apple Developer** | Personal Team 免费签名即可（Simulator 路径甚至 ad-hoc 就行） |

---

## 架构一图流

```
┌─────────────────────── macOS host ───────────────────────────┐
│                                                              │
│   SimCamApp.app  (menubar)                                   │
│   ┌─────────────────────────────────────────────────────┐    │
│   │  SimCamEngine                                        │    │
│   │   ├─ FrameProducer (per slot: back / front)          │    │
│   │   │   • CameraDeviceFrameProducer  (AVFoundation)    │    │
│   │   │   • ScreenFrameProducer         (ScreenCaptureKit)    │
│   │   │     ├─ raw display / window                      │    │
│   │   │     └─ followSimulator: 锁定 Simulator 窗口取景    │    │
│   │   │   • Image / Video / QR / DemoCard                │    │
│   │   ├─→ CMIO sink stream  ──►  SimCamExtension.systemext   │
│   │   └─→ LocalSocketFrameServer  ──►  /tmp/com.simcam.…sock │
│   └─────────────────────────────────────────────────────┘    │
│                                                              │
│   ┌──────────── iOS Simulator ────────────────────────┐      │
│   │  YourApp  (stock AVFoundation, untouched)         │      │
│   │   ▲                                               │      │
│   │   │  swizzle (DYLD_INSERT_LIBRARIES)              │      │
│   │   │                                               │      │
│   │  libSimCamHook.dylib                              │      │
│   │   • fakeBack / fakeFront AVCaptureDevice          │      │
│   │   • frame puller @ unix sock — back/front slots   │      │
│   │   • fan out 帧到 sample-buffer / metadata / preview│      │
│   └───────────────────────────────────────────────────┘      │
└──────────────────────────────────────────────────────────────┘
```

帧线协议（48 字节 v2 头 + `cameraSlot` 字段）见 [SimCamHook.h](Sources/SimCamHook/SimCamHook.h)。
完整运行流程 + 三类系统权限触发点见 [docs/permissions-and-flow.md](docs/permissions-and-flow.md)。

---

## 快速开始（Simulator 路径，强烈推荐先跑这条）

环境：免费 Apple ID + Xcode 15+ + `xcodegen`。

```bash
# 1. 生成 Xcode 工程
brew install xcodegen
make open                          # = xcodegen generate + open SimCam.xcodeproj

# 2. build host menubar app
xcodebuild -scheme SimCam -configuration Debug \
  -derivedDataPath build/SimCamDD build

# 3. build demo + 注入用 dylib（必须用 SimCamDemo scheme，SimCam scheme 不会带 dylib）
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

跑通的样子：simulator 里的 demo app 出现 *Switch to Front* 按钮，画面是 host 推过来的。
默认 back 源是 **Simulator passthrough** —— 拖动 Simulator 窗口，相机画面就跟着背后桌面走。

想测**自己的 app**？把 bundle id 换成自己的：

```bash
xcrun simctl install booted /path/to/YourApp.app
./scripts/inject-simulator.sh com.yourcompany.YourApp
```

被测 app 一行代码不用改，一次重 build 都不需要。**Zero integration code.**

---

## macOS 路径（CMIO 虚拟摄像头，可选 / 进阶）

如果你还想让 *SimCam Virtual Camera* 出现在 QuickTime / FaceTime / Zoom 里：

1. 进 Recovery 跑 `csrutil enable --without debug --without kext`（**部分**降级 SIP，不是全关）；
2. `sudo systemextensionsctl developer on`；
3. 把 `SimCamApp.app` 安装到 `/Applications/`（sysextd 拒绝从 DerivedData 路径加载扩展）；
4. 启动它，去 *系统设置 ▸ 隐私与安全性* 点允许。

完整步骤、故障恢复指令在 [docs/no-developer-account.md](docs/no-developer-account.md)。
**只想用 Simulator 路径的话整段可以跳过。**

---

## Targets / Schemes

| Target | 类型 | 作用 |
|---|---|---|
| **SimCamApp** | macOS app | menubar UI + `SimCamEngine` + unix-sock frame server + extension activator |
| **SimCamExtension** | system extension（嵌在 SimCamApp 里） | CMIO 虚拟摄像头 |
| **SimCamHook** | iOS Simulator dylib (Obj-C) | `DYLD_INSERT_LIBRARIES` 注入物，swizzle AVFoundation |
| **SimCamDemoApp** | iOS app（跑在 simulator） | 证明"标准 AVFoundation"那条 claim，**不依赖任何 SimCam 代码** |
| **SimCamCoreTests** | XCTest | engine / QR / license / frame producer 单测 |

| Scheme | builds |
|---|---|
| `SimCam` | SimCamApp + SimCamExtension + SimCamCoreTests |
| `SimCamDemo` | **SimCamHook** + SimCamDemoApp |

⚠️ 改了 `SimCamHook.m` 之后**必须**重 build `SimCamDemo` scheme。`SimCam` scheme 不依赖 dylib，单跑 `-scheme SimCam` 你跑的是上一次的 hook。

---

## 仓库目录

```
project.yml                     # xcodegen 配方
Makefile                        # generate / build / test / run 快捷
Generated/                      # Info.plist + entitlements (gitignored, 自动生成)
SimCam.xcodeproj/               # gitignored, 自动生成
Sources/
  SimCamCore/                   # engine / frame producers / unix-sock server / QR
  SimCamExtension/              # CMIO Camera System Extension
  SimCamApp/                    # menubar host (AppDelegate / MenubarView)
  SimCamHook/                   # ⭐ 注入到 simulator 的 Obj-C dylib
  SimCamDemoApp/                # iOS demo（标准 AVFoundation，无 SimCam 依赖）
Tests/SimCamCoreTests/
scripts/
  bootstrap-xcode.sh            # brew install xcodegen
  inject-simulator.sh           # SIMCTL_CHILD_DYLD_INSERT_LIBRARIES 包装
  install-systemext.sh          # cp 到 /Applications + entitlement bypass
  diagnose-sysext.sh            # 一键 sysextd 日志
  reset-tcc.sh                  # 一键清掉旧 ad-hoc 残留的 TCC 状态
docs/
  assets/                       # README 用素材（logo / demo gif）
  permissions-and-flow.md       # 三类权限 + 端到端流程 + 故障排查（中文）
  no-developer-account.md       # 长版 runbook（中文）
RUN_NOTES.md                    # 调试笔记（中文）
README.md / README.en.md
```

---

## 文档导航

| 文档 | 内容 |
|---|---|
| [README.md](README.md) | 你正在看的（中文主版） |
| [README.en.md](README.en.md) | English version |
| [docs/permissions-and-flow.md](docs/permissions-and-flow.md) | 屏幕录制 / 摄像头 / 系统扩展三类权限的触发点、Hardened Runtime entitlement 矩阵、完整 host → simulator 帧流、故障排查 |
| [docs/no-developer-account.md](docs/no-developer-account.md) | 详尽 runbook：TCC、ad-hoc 签名、系统扩展激活、踩坑恢复 |
| [RUN_NOTES.md](RUN_NOTES.md) | 复刻过程踩到的非显然坑 + 根因 |
| [Sources/SimCamHook/SimCamHook.h](Sources/SimCamHook/SimCamHook.h) | 帧线协议 v2（48 字节头 + `cameraSlot`） |

---

## 已知坑 (短列表)

完整版本在 [RUN_NOTES.md](RUN_NOTES.md) 与 [docs/no-developer-account.md](docs/no-developer-account.md)，这里挑最高频的：

- **`SimCam` scheme 不 build `SimCamHook`** —— 改 hook 后必须 build `SimCamDemo`，否则你跑的是上一版。
- **未签名 dylib 被 simulator 的 dyld 静默忽略**（iOS 17+）。注入只能用 `Build/Products/Debug-iphonesimulator/`，不要用 `Intermediates.noindex/.../Binary/`。
- **TCC 屏幕录制权限 ad-hoc 签会随每次 rebuild 失效** —— 项目已经切成 Personal Team 自动签来根治。详见 [RUN_NOTES.md §4](RUN_NOTES.md)。
- **macOS 14+ `SCShareableContent` 在权限缺失时不抛错**，会静默返回空 displays / 无 owner 的 windows。我们用 "displays.isEmpty 且 windows 全空" 作为未授权信号。
- **Hardened Runtime ON 时 camera entitlement 缺失会让 `AVCaptureDevice.requestAccess` 静默返回 NO**，且**永远不弹框、设置里也不出现条目**。`project.yml` 里已经显式声明了 `device.camera`、`audio-input`、`disable-library-validation`。

---

## Roadmap

- [ ] 多 simulator 同时支持（目前抓最大那个 Simulator 窗口）
- [ ] 无头 CLI（不挂 menubar，源用 flags 指定，给 CI 用）
- [ ] 每槽位独立的分辨率 / FPS 控制
- [ ] Continuity Camera 升为一等公民（目前已经能用，但走的是通用 camera 路径）
- [ ] 可选 H.264 帧线编码，降低高负载机器的 CPU 占用
- [ ] 公证签名的发行版（给有付费账号的用户）

PR 欢迎。

---

## License

[MIT](LICENSE) — fork 它、扩展它、ship 它。

本项目**不**附属于、也未被 Software Mansion 背书。它仅依据 [simcam.swmansion.com](https://simcam.swmansion.com/) 公开记录的架构、用 Apple 公开 API 重新实现，**没有**使用、查看、复制 SimCam 任何源码。如果你需要一份打磨过、有支持、已公证的产品 —— 请购买 SimCam 商业版，原团队做了所有难的设计工作，他们值得你的钱。

## 致谢

- [Software Mansion / SimCam](https://simcam.swmansion.com/) — 为我们证明了这套架构可行，也提供了启发本项目的优秀 UX。
- Apple 的 `ScreenCaptureKit` / `AVFoundation` / `CoreMediaIO` 工程师 —— 是这些公开 API 让一切成为可能。
