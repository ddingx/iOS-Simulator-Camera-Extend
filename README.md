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

<div align="center">
<img src="docs/assets/architecture.png" alt="Architecture" width="900" />
</div>

帧线协议（48 字节 v2 头 + `cameraSlot`）见 [SimCamHook.h](Sources/SimCamHook/SimCamHook.h)。

<details>
<summary>ASCII 版（fallback）</summary>

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

</details>

---

## 现在能做什么

两条链路都打通了，可以**同时**用：

| 你想要的效果 | 走哪条链路 | 服务对象 |
|---|---|---|
| 在 **iOS Simulator 里**跑你的 iOS app，让它的相机预览/扫码/视频通话拿到自定义画面 | **Simulator hook 链路**（DYLD inject） | 任何 simulator 内的 iOS app（你的 demo、你公司业务 app、第三方 app） |
| 在 **macOS 上**用 QuickTime / FaceTime / Zoom / 飞书 / 腾讯会议 / OBS 录屏，把摄像头切成自定义画面 | **CMIO sysext 链路** | 任何 macOS AVFoundation 客户端 |

**两条链路共享同一个画面源**：你在 SimCam menubar 里把 back/front 切到 *FaceTime HD / Image / Video / QR / Simulator passthrough / 任意窗口或 Display*，QuickTime 看到的画面、simulator 内 iOS app 看到的画面**完全同源、同步切换**。

> ⚠️ **iOS Simulator 内 iOS app 不可能直接走 CMIO** —— iOS SDK 里根本没有 CMIO 接口，这是 Apple 平台的硬限制（不是本项目能解决的，SimCam 商业版同样如此）。所以"让 simulator 里 iOS app 看到 SimCam 画面"必须走 hook 链路。这跟 SimCam 官网"without changing anything in your app"承诺并不矛盾——指的是**你 iOS app 代码不改 / 不引 SDK / 不换 bundle id**，并不是不需要在 Mac 一侧做注入步骤。

---

## 环境准备

### 必须

| | 说明 |
|---|---|
| **macOS** | 13+（开发机用 macOS 14/15/26 都验过） |
| **Xcode** | 15+，命令行工具齐全（`xcodebuild` / `xcrun simctl` / `codesign` / `security`）|
| **OpenSSL** | macOS 自带 LibreSSL 的 `security` 工具够用；`bootstrap-cert.sh` 会用 OpenSSL 3.x（Homebrew 装的或 macOS 14+ 自带） |
| **booted iOS Simulator** | 要测哪台机型自己 boot；一台就够 |

### 仅 CMIO sysext 链路需要

| | 说明 |
|---|---|
| **SIP developer mode** | `sudo systemextensionsctl developer on`（重启失效，每次开机要重开一次） |
| **sudo 权限** | 装 sysext 必须把 host bundle 拷到 `/Applications/` 并 `chown root:wheel`（sysextd 的硬约束） |
| **本地自签名证书 SimCam Local Dev** | 一次性，`make bootstrap-cert` 生成并导入 keychain；私钥不入仓 |

### **不需要**

- ❌ 付费 Apple Developer Program（$99/年）—— 用本地自签名证书替代
- ❌ Personal Team —— 已验证 Personal Team 不支持 System Extension capability
- ❌ 关 SIP / 越狱
- ❌ 改 iOS app 代码、装 SDK、换 bundle id

---

## Quick start

### 一次性 setup（每台开发机做一次）

```bash
# 1. 生成本地代码签名证书 SimCam Local Dev，导入 login keychain
make bootstrap-cert

# 2. 打开 macOS 系统扩展开发者模式（重启失效）
sudo systemextensionsctl developer on
```

### 跑通 CMIO 链路（macOS 上的虚拟摄像头）

```bash
# 3. build + 重签 + 拷到 /Applications/（需要 sudo）
make install

# 4. 启动 SimCam menubar app
make run

# 5. 第一次激活：菜单栏点 SimCam 图标 → Activate Virtual Camera
#    系统会弹一次 "允许 SimCam Local Dev 签发的 system extension"
#    去 System Settings → Privacy & Security 点 Allow
#    之后任何 rebuild / 重装都不会再弹（DR 锁证书根，TCC 不失忆）

# 6. 验证
systemextensionsctl list | grep simcam
# 应该看到：dev.simcam.app.extension  [activated enabled]

# 然后打开 QuickTime → New Movie Recording → 摄像头下拉选 "SimCam Virtual Camera"
```

### 跑通 Simulator hook 链路（让 iOS app 看到画面）

```bash
# 7. 启动一台 simulator + 装 demo app
open -a Simulator
xcrun simctl boot "iPhone 17 Pro" 2>/dev/null || true

xcodebuild -project SimCam.xcodeproj -scheme SimCamDemo \
    -configuration Debug \
    -destination 'generic/platform=iOS Simulator' build

xcrun simctl install booted \
    ~/Library/Developer/Xcode/DerivedData/SimCam-*/Build/Products/Debug-iphonesimulator/SimCamDemoApp.app

# 8. 注入 hook 并启动 demo（host SimCamApp 必须在跑）
./scripts/inject-simulator.sh dev.simcam.demo

# 期望：simulator 里 SimCamDemoApp 的 back / front 摄像头预览
# 实时显示 SimCam menubar 选中的画面源
```

把它用在**你自己**的 iOS app 上，bundle id 换掉即可：

```bash
xcrun simctl install booted /path/to/YourApp.app
./scripts/inject-simulator.sh com.yourcompany.YourApp
```

**你的 app 一行代码都不用改，不重编、不重签、不换 bundle id。**

---

## Make targets 一览

| target | 作用 |
|---|---|
| `make bootstrap-cert` | **一次性**：生成 self-signed `SimCam Local Dev` 证书并导入 login keychain |
| `make build` | xcodebuild Debug 配置 build host + extension |
| `make test` | xcodebuild test |
| `make install` | build + 重签（注入完整 entitlements）+ 拷到 `/Applications/` + `chown root:wheel`（需 sudo）|
| `make run` | install + `open /Applications/SimCamApp.app` |
| `make doctor` | 一键诊断：SIP / 开发者模式 / 签名 / sysextd 日志 / extension 状态 |
| `make reset-tcc` | 切换签名身份后才需要：清掉旧 TCC 记录 |
| `make open` | 打开 Xcode 工程 |
| `make clean` | 清掉 `build/` 和 `DerivedData/` |

签名机制详见 [docs/signing-and-tcc.md](docs/signing-and-tcc.md)。

---

## 完全不行的场景

- **真机**虚拟相机：不可能。iOS 真机相机 API 在沙箱外，需要内核级 hook 或越狱，本仓库不涉及。
- 想发布到 App Store 的 app 用它：本仓库的 dylib 注入只在 *Simulator* 进程内有效，不进 ipa，对 App Store 审核没影响 —— 但它也不是给生产用的"假相机源"。
- 不想 inject、想让 simulator 内 iOS app 走 CMIO 那条管子：见上面方框里的解释，物理上不可能。

---

## 故障排查速查

| 现象 | 检查 |
|---|---|
| `make install` 报 `'SimCam Local Dev' not found` | 跑 `make bootstrap-cert`；确认 `security find-identity -v -p codesigning` 列表里有 SimCam Local Dev |
| `systemextensionsctl list` 看不到 extension | 跑 `make doctor`；常见根因：没开 `sudo systemextensionsctl developer on`、host 没在 `/Applications/`、host owner 不是 root:wheel |
| sysext 状态是 `[activated waiting for user]` | 去 System Settings → Privacy & Security → 最下面点 Allow |
| QuickTime 摄像头列表里没有 *SimCam Virtual Camera* | sysext 没 activated（看上一行）；或 sysext activated 了但 host 没启动 → `make run` |
| 注入 simulator 后看不到画面 / `xcrun simctl spawn booted log stream` 没有 `[SimCamHook]` 行 | dylib 路径错（必须是 `Build/Products/Debug-iphonesimulator/libSimCamHook.dylib`，未签名 intermediate 那份会被 dyld 静默拒绝），或 host SimCamApp 没在跑（`/tmp/com.simcam.frames.sock` 不存在）|
| iOS app 报 `Camera permission denied` | 不是注入的问题，是被测 app 自己 Info.plist 缺 `NSCameraUsageDescription` |
| 改了 hook 代码、注入没生效 | 必须 build `SimCamDemo` scheme，不是 `SimCam` scheme（hook dylib 只在 SimCamDemo scheme 里 build） |

更长的排查清单见 [docs/permissions-and-flow.md](docs/permissions-and-flow.md) §3 和 [RUN_NOTES.md](RUN_NOTES.md)。

---

## 文档

| 文档 | 内容 |
|---|---|
| [README.en.md](README.en.md) | English version |
| [docs/signing-and-tcc.md](docs/signing-and-tcc.md) | self-signed `SimCam Local Dev` 证书的设计动机；为什么不用 ad-hoc / Personal Team / Developer Program |
| [docs/permissions-and-flow.md](docs/permissions-and-flow.md) | 屏幕录制 / 摄像头 / 系统扩展三类权限矩阵、Hardened Runtime entitlement、host → simulator 完整帧流、故障排查 |
| [docs/no-developer-account.md](docs/no-developer-account.md) | 长版 runbook：双链路端到端步骤、TCC、SIP、`developer on`、踩坑恢复 |
| [RUN_NOTES.md](RUN_NOTES.md) | 复刻过程踩到的非显然坑 + 根因 |
| [Sources/SimCamHook/SimCamHook.h](Sources/SimCamHook/SimCamHook.h) | 帧线协议 v2（48 字节头 + `cameraSlot`） |

---

## About

iOS Simulator 没有相机这件事，我和大多数 iOS 开发者一样吃过苦头：每次写涉及拍照、扫码、人脸、AR 的功能，都得来回插拔真机，或者写一坨假数据兜底。Software Mansion 的 SimCam 把这个问题解得很优雅 —— 但它要 $99/年开发者账号 + 商业 license，对很多个人开发者、自学者、教学课堂、内部工具团队来说门槛偏高。

这个仓库是**一次纯粹的工程练习**：仅依据 [simcam.swmansion.com](https://simcam.swmansion.com/) 公开记录的架构（menubar host + `DYLD_INSERT_LIBRARIES` swizzle + 可选 CMIO 系统扩展），用 Apple 公开 API（`ScreenCaptureKit` / `AVFoundation` / `CoreMediaIO` / `OSSystemExtensionRequest`）从零复刻。**没有任何 SimCam 代码被使用、查看或复制。**

目标只有两条：让没有付费 Apple 账号的开发者也能在 Simulator 里调相机功能；把整个实现过程的踩坑（TCC、Hardened Runtime entitlement、CMIO 系统扩展激活流程）原汁原味记录在文档里，方便后人少绕路。

如果你最终的需求是**生产级**、**长期支持**、**已公证**的虚拟相机：请买 SimCam 商业版，原团队做了所有难的设计工作，值得这笔钱。如果你只是想本机调试 / 教学 / 做内部工具，欢迎用、改、fork。

---

## License

[MIT](LICENSE) — fork、改、ship。本项目**不**附属于、也未被 Software Mansion 背书。
