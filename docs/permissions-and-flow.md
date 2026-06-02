# SimCam — 权限矩阵与运行流程

本文档汇总：

1. SimCam 涉及的三类系统权限（屏幕录制 / 摄像头 / 系统扩展）
2. 完整的端到端运行流程（host → simulator）
3. 一份可对照的故障排查清单

读完之后你应该能：

- 知道每个权限**为什么**需要、**何时**触发、**怎么**授予；
- 看懂 [SimCamApp](file:///Users/guoshuyu/workspace/swmansion-copy/Sources/SimCamApp) 启动时各个组件的初始化次序；
- 在出问题时，从 `log show --predicate 'subsystem == "dev.simcam"'` 直接定位到组件。

---

## 0. 角色与组件总览

| 角色 | 进程 / Bundle | 来源 | 入口 |
|---|---|---|---|
| **menubar host** | `SimCamApp.app` (`dev.simcam.app`) | macOS app | [SimCamApp/AppDelegate.swift](file:///Users/guoshuyu/workspace/swmansion-copy/Sources/SimCamApp/AppDelegate.swift) |
| **engine** | host 内 in-proc | Swift framework | [SimCamCore/SimCamEngine.swift](file:///Users/guoshuyu/workspace/swmansion-copy/Sources/SimCamCore/SimCamEngine.swift) |
| **frame producers** | host 内 | Swift | [SimCamCore/FrameProducers.swift](file:///Users/guoshuyu/workspace/swmansion-copy/Sources/SimCamCore/FrameProducers.swift) |
| **frame socket server** | host 内 | Swift | [SimCamCore/LocalSocketFrameServer.swift](file:///Users/guoshuyu/workspace/swmansion-copy/Sources/SimCamCore/LocalSocketFrameServer.swift) |
| **CMIO 系统扩展** | `dev.simcam.app.extension.systemextension` | macOS sysext | [Sources/SimCamExtension](file:///Users/guoshuyu/workspace/swmansion-copy/Sources/SimCamExtension) |
| **iOS hook dylib** | `libSimCamHook.dylib` (注入到被测 app) | C/Obj-C | [SimCamHook/SimCamHook.m](file:///Users/guoshuyu/workspace/swmansion-copy/Sources/SimCamHook/SimCamHook.m) |
| **demo app** | `SimCamDemoApp.app` (`dev.simcam.demo`) | iOS app | [Sources/SimCamDemoApp](file:///Users/guoshuyu/workspace/swmansion-copy/Sources/SimCamDemoApp) |

宏观图：

```
┌──────────────────────────  macOS host  ──────────────────────────┐
│                                                                  │
│  [Mac Camera] ─┐                                                 │
│  [Screen]     ─┼─► FrameProducer ─► SimCamEngine ─► Encoder ──┐  │
│  [Demo built-in]─┘                                            │  │
│                                                               ▼  │
│                                       LocalSocketFrameServer     │
│                                       (/tmp/com.simcam.frames.sock)
│                                       │                          │
│                                       ├──► CMIO sysext ──► AVFoundation 宿主
│                                       │     "SimCam Virtual Camera"
│                                       │     (Mac 上任何 AV client 看见)
│                                       │                          │
│                                       └──► Unix socket ──► iOS Sim
│                                                              │   │
│                                                              ▼   │
│                                       libSimCamHook.dylib (DYLD_INSERT_LIBRARIES)
│                                       │                          │
│                                       │ swizzle AVCaptureDevice  │
│                                       │ / AVCaptureSession       │
│                                       │ / AVPreviewLayer         │
│                                       ▼                          │
│                                       被测 iOS app 的 AVFoundation
└──────────────────────────────────────────────────────────────────┘
```

---

## 1. 权限矩阵

| 权限 | 触发组件 | 触发时机 | TCC 服务 ID | 失败表现 |
|---|---|---|---|---|
| 屏幕录制 (Screen Recording) | [ScreenFrameProducer](file:///Users/guoshuyu/workspace/swmansion-copy/Sources/SimCamCore/FrameProducers.swift) | menubar 选 "Display N" / "Simulator passthrough" | `kTCCServiceScreenCapture` | SC stream 起不来，错误 `-3801` |
| 摄像头 (Camera) | [CameraDeviceFrameProducer.start](file:///Users/guoshuyu/workspace/swmansion-copy/Sources/SimCamCore/FrameProducers.swift#L117-L140) | menubar 选某台 mac 摄像头 | `kTCCServiceCamera` | engine log `FAIL setSource camera://... — Camera permission denied`，画面留 .none |
| 系统扩展 (System Extension) | [ExtensionActivator.activate](file:///Users/guoshuyu/workspace/swmansion-copy/Sources/SimCamApp/ExtensionActivator.swift) | host 启动时 | 不走 TCC，走 `OSSystemExtensions` 框架 | "SimCam Virtual Camera" 不出现在 `system_profiler SPCameraDataType` |

> 备注：本机调用 mac 摄像头**不需要**屏幕录制权限；屏幕录制只在你想"截屏 / 抓 simulator 窗口"时需要。

### 1.1 屏幕录制 (Screen Recording)

**用途**：[ScreenFrameProducer](file:///Users/guoshuyu/workspace/swmansion-copy/Sources/SimCamCore/FrameProducers.swift) 通过 [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) 抓取 display / 应用窗口。Simulator passthrough 模式下专门追踪 `Simulator.app` 的窗口矩形，把它的可见区域作为虚拟相机的"取景"。

**触发**：menubar 中点击一个 *Screen capture* 行（任一显示器、Simulator、或某个具体 app 窗口）。

**授予方式**：
1. 第一次调用 SCStream 时系统弹"想要录制此电脑的屏幕"；点 *Open System Settings* / *Allow*。
2. 系统设置 → *隐私与安全性* → *屏幕录制* → 找到 **SimCamApp** → 打开开关。
3. 系统会要求你**重启 SimCamApp** 才能生效。

**失败现象**：[ScreenFrameProducer.startAsync](file:///Users/guoshuyu/workspace/swmansion-copy/Sources/SimCamCore/FrameProducers.swift) 会打 `startAsync failed: <Error>`，常见错误码 `-3801` 表示用户没给权限。

### 1.2 摄像头 (Camera)

**用途**：让 mac 上的物理摄像头（FaceTime HD / Cat Camera / Continuity Camera / DeskView…）作为帧源进入 SimCam，再通过 hook 喂给 simulator 内的 iOS app。

**触发**：menubar 中点击某个 mac camera 行（"FaceTime HD Camera"、"Cat Camera"、…）。

**关键 entitlement**（这是踩过最大的坑）：

[project.yml](file:///Users/guoshuyu/workspace/swmansion-copy/project.yml#L66-L74) 必须包含：

```yaml
entitlements:
  path: Generated/SimCamApp.entitlements
  properties:
    com.apple.security.app-sandbox: false
    com.apple.security.application-groups:
      - dev.simcam.app
    com.apple.security.device.camera: true        # ← 必需
    com.apple.security.device.audio-input: true   # 后续 mic passthrough
    com.apple.security.cs.disable-library-validation: true
```

为什么必需：SimCamApp 是 **Hardened Runtime ON** 的（codesign flag `0x10000(runtime)`，由 Personal Team / DEVELOPMENT cert 签出来都会自动启用）。Hardened Runtime 强制要求**任何使用 camera / mic / location 等隐私 API 的进程**必须在 entitlement 里**显式声明**。少一行 `com.apple.security.device.camera`，则：

- `AVCaptureDevice.requestAccess(for: .video)` **静默返回 NO，不弹任何对话框**；
- 系统设置的 *Camera* 列表里**永远不出现 SimCamApp**（用户连"开关"都看不到）；
- `tccutil reset Camera dev.simcam.app` 也不能恢复，因为根本不是 TCC 表里有 deny 条目，而是这个进程被 Hardened Runtime 直接判违规。

**授予方式**（entitlement 已配好的前提下）：
1. 第一次进 mac camera 时 [CameraDeviceFrameProducer.start](file:///Users/guoshuyu/workspace/swmansion-copy/Sources/SimCamCore/FrameProducers.swift#L117-L140) 调 `requestAccess(for: .video)` → 系统弹对话框；
2. 点 *Allow* → SimCamApp 出现在系统设置 Camera 列表，开关 ON；
3. 再次进入 mac camera 直接走，不再弹框。

**失败现象**：

| log 里出现 | 含义 | 修法 |
|---|---|---|
| `FAIL setSource camera://... — Camera permission denied. Enable in System Settings ...` | 用户在弹框里拒绝了，或者 entitlement 缺失静默拒绝 | 先确认 [project.yml](file:///Users/guoshuyu/workspace/swmansion-copy/project.yml#L66-L74) 有 `device.camera`；再 `tccutil reset Camera dev.simcam.app` + 重启 app |
| menubar 点击 mac camera 后立刻跳回 None | 同上 |  |

### 1.3 系统扩展 (System Extension / CMIO)

**用途**：把 SimCam 端的画面"注册"成一台真实虚拟摄像头 *SimCam Virtual Camera*，让 Mac 上**任何** AVFoundation 客户端（iOS Simulator、QuickTime、Zoom、Discord…）都能像选普通摄像头一样选它。

**触发**：[AppDelegate.applicationDidFinishLaunching](file:///Users/guoshuyu/workspace/swmansion-copy/Sources/SimCamApp/AppDelegate.swift#L19-L28) 启动时调 `ExtensionActivator.shared.activate()`。

**激活流程**：
1. host 调 [OSSystemExtensionRequest.activationRequest](file:///Users/guoshuyu/workspace/swmansion-copy/Sources/SimCamApp/ExtensionActivator.swift#L33-L40)，bundle id `dev.simcam.app.extension`；
2. 第一次安装会弹 *"系统扩展被阻止"* → 跳到 *系统设置 ▸ 隐私与安全性 ▸ 安全性*，最下面有一行 *"已阻止：开发者 'XXX' 的系统软件"* → 点 *允许*；
3. 系统再让你输入管理员密码或 Touch ID；
4. 系统会重启 `cmiod`（CMIO daemon），完成后 SimCam Virtual Camera 出现在 `system_profiler SPCameraDataType` 列表。

**前置硬件 / 系统条件**：

- **必须用真实 Apple Developer Team ID 签名**（即使是免费 Personal Team 也行）。ad-hoc 签名 (`-` identity) 系统**直接拒绝**，错误为 `OSSystemExtensionErrorDomain.codeValidationFailed`。
- macOS 13+。

**Apple 的"developer mode"开关**（仅当你想用 ad-hoc 签名跑系统扩展，**正常路径不需要**）：

```sh
sudo systemextensionsctl developer on
```

详见 [scripts/install-systemext.sh](file:///Users/guoshuyu/workspace/swmansion-copy/scripts/install-systemext.sh) 与 [scripts/diagnose-sysext.sh](file:///Users/guoshuyu/workspace/swmansion-copy/scripts/diagnose-sysext.sh)。

**验证**：

```sh
systemextensionsctl list | grep simcam
# 期望看到：
#   dev.simcam.app.extension  [activated enabled]
system_profiler SPCameraDataType | grep -A2 SimCam
# 期望看到一台 "SimCam Virtual Camera"
```

---

## 2. 端到端运行流程

下面按 **第一次安装** 的次序展开。

### 2.1 启动 host

```sh
make run                       # = build + open SimCamApp.app
# 或者 xcodebuild ... && open
```

[AppDelegate.applicationDidFinishLaunching](file:///Users/guoshuyu/workspace/swmansion-copy/Sources/SimCamApp/AppDelegate.swift#L19-L28) 执行：

1. `configureStatusItem()`：在 menubar 上挂 `NSStatusItem` 图标；
2. `configurePopover()`：构造 [MenubarView](file:///Users/guoshuyu/workspace/swmansion-copy/Sources/SimCamApp/MenubarView.swift) UI；
3. `SimCamEngine.shared.start()`：
   - 启动 [LocalSocketFrameServer](file:///Users/guoshuyu/workspace/swmansion-copy/Sources/SimCamCore/LocalSocketFrameServer.swift)，监听 `/tmp/com.simcam.frames.sock`；
   - 默认两个 slot（Back / Front）的 source 都是 `.demo`，这样不需要任何外部输入也能立刻看见画面；
   - 把帧序列推给 socket server，等 simulator 的 hook 来连。
4. `ExtensionActivator.shared.activate()`：尝试激活 CMIO 系统扩展（详见 [§1.3](#13-系统扩展-system-extension--cmio)）。

### 2.2 启动 simulator + 安装 demo

```sh
make demo-build                # build SimCamDemoApp.app for iOS Simulator
xcrun simctl boot <udid>       # 或者 Xcode 里直接打开 simulator
xcrun simctl install booted build/.../SimCamDemoApp.app
```

### 2.3 注入 hook 到被测 app

```sh
./scripts/inject-simulator.sh dev.simcam.demo
```

[inject-simulator.sh](file:///Users/guoshuyu/workspace/swmansion-copy/scripts/inject-simulator.sh) 做了三件事：

1. 找到最新的 `libSimCamHook.dylib`（排除 `Index.noindex` 空壳）；
2. 通过 `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=<dylib path>` 把它注入；
3. `xcrun simctl launch --terminate-running-process` 启动被测 app。

[SimCamHook.m](file:///Users/guoshuyu/workspace/swmansion-copy/Sources/SimCamHook/SimCamHook.m) 的 `__attribute__((constructor))` 在被测 app 进入 `main()` 之前就跑：

- 连 `/tmp/com.simcam.frames.sock`；
- swizzle `AVCaptureDevice.DiscoverySession` → 暴露 2 台假设备 `SIMCAM-BACK-CAMERA` / `SIMCAM-FRONT-CAMERA`；
- swizzle `AVCaptureSession.startRunning` → 启动后台帧拉取；
- swizzle `AVCaptureVideoDataOutput` 的 sample-buffer delegate 注册 → 把 socket 帧 fan out；
- swizzle `AVCaptureMetadataOutput` → 给被测 app 喂 host 端检测到的 QR string；
- swizzle `AVCaptureVideoPreviewLayer` → 替换为我们渲染的 fake CALayer。

被测 app **不用改一行代码**，它看到的就是普通 AVFoundation。

### 2.4 在 menubar 选源

打开 menubar popover（[MenubarView](file:///Users/guoshuyu/workspace/swmansion-copy/Sources/SimCamApp/MenubarView.swift)），有 *Back camera* / *Front camera* 两列，每列可选：

| 选项 | 走的 producer | 备注 |
|---|---|---|
| None | nil | 关流，hook 端会喂占位帧 |
| Demo (built-in) | [DemoFrameProducer](file:///Users/guoshuyu/workspace/swmansion-copy/Sources/SimCamCore/FrameProducers.swift) | 内置图案，零权限，开箱即用 |
| Simulator passthrough | [ScreenFrameProducer](file:///Users/guoshuyu/workspace/swmansion-copy/Sources/SimCamCore/FrameProducers.swift) | 抓 Simulator 窗口；**注意不要选成 simulator 自己显示的画面，会无限套娃** |
| FaceTime / Cat / DeskView … | [CameraDeviceFrameProducer](file:///Users/guoshuyu/workspace/swmansion-copy/Sources/SimCamCore/FrameProducers.swift#L117-L140) | mac 物理摄像头；首次需 Camera 权限 |
| Display N / app window | [ScreenFrameProducer](file:///Users/guoshuyu/workspace/swmansion-copy/Sources/SimCamCore/FrameProducers.swift) | 屏幕录制；首次需 Screen Recording 权限 |

[MenubarViewModel.setSource](file:///Users/guoshuyu/workspace/swmansion-copy/Sources/SimCamApp/MenubarViewModel.swift) 把选择转发给 [SimCamEngine.setSource(_:slot:)](file:///Users/guoshuyu/workspace/swmansion-copy/Sources/SimCamCore/SimCamEngine.swift#L51-L100)：

1. 如果是 Pro-only 源 + 当前 license 不够 → 立刻 return `.licenseRequired`；
2. 否则 stop 旧 producer（如果有）；
3. new producer + `start(onFrame:)`；
4. 把 frame callback 挂到 [LocalSocketFrameServer](file:///Users/guoshuyu/workspace/swmansion-copy/Sources/SimCamCore/LocalSocketFrameServer.swift)；
5. 成功 → 打 `[engine] [Slot] source -> ...`；失败 → 打 `[engine] [Slot] FAIL setSource ... — <error>` + 把 slot 回滚到 `.none`。

### 2.5 帧从 host 流到 simulator

[LocalSocketFrameServer](file:///Users/guoshuyu/workspace/swmansion-copy/Sources/SimCamCore/LocalSocketFrameServer.swift) 把每个 `CMSampleBuffer` 序列化成 v2 帧（48 字节 header + BGRA payload + 可选 QR payload，见 [SimCamHook.m#L31-L46](file:///Users/guoshuyu/workspace/swmansion-copy/Sources/SimCamHook/SimCamHook.m#L31-L46)）：

```c
struct SimCamFrameHeader {
    uint32_t magic;
    uint32_t version;
    uint32_t width;
    uint32_t height;
    uint32_t bytesPerRow;
    uint32_t pixelFormat;
    uint64_t hostTimeNs;
    uint32_t payloadLen;
    uint32_t qrPayloadLen;
    uint8_t  cameraSlot;     // 0=back, 1=front
    uint8_t  reserved[7];
};
```

被测 app 内 [SimCamHook.m](file:///Users/guoshuyu/workspace/swmansion-copy/Sources/SimCamHook/SimCamHook.m) 拉取后：

- 解出 `cameraSlot`，路由到 back / front 槽位；
- 用 BGRA payload 构造 `CVPixelBufferRef` → `CMSampleBuffer`；
- fan out 给所有注册过的 `AVCaptureVideoDataOutputSampleBufferDelegate`；
- 如果有 QR payload 且被测 app 注册过 `AVCaptureMetadataOutputObjectsDelegate`，也把它发出去；
- 同步把帧渲染到所有 fake `AVCaptureVideoPreviewLayer`。

### 2.6 同时，CMIO 系统扩展把帧暴露给 Mac 端 AV 客户端

CMIO sysext (`dev.simcam.app.extension`) 也连同一个 socket，把 host 推过来的帧渲染成一台**真实的 AVCapture 设备**。这样：

- iOS 17+ Simulator 系统级别的 *Camera Bridge* 能直接看到 SimCam Virtual Camera（不需要 dylib hook 也行）；
- QuickTime / Zoom / OBS 等 mac 端 app 也能选 "SimCam Virtual Camera"。

### 2.7 关闭

- 退 menubar app → engine stop → socket server close → 所有 producer stop；
- demo 留在 simulator 里，下次 inject 重启即可。

---

## 3. 故障排查

### 3.1 看日志

所有自家日志统一打到 `subsystem=dev.simcam`。Console.app 或命令行：

```sh
log show --last 5m --style compact --predicate 'subsystem == "dev.simcam"'
log stream --style compact --predicate 'subsystem == "dev.simcam"'
```

类目（category）：

| category | 文件 |
|---|---|
| `engine` | [SimCamEngine.swift](file:///Users/guoshuyu/workspace/swmansion-copy/Sources/SimCamCore/SimCamEngine.swift) |
| `producer` | [FrameProducers.swift](file:///Users/guoshuyu/workspace/swmansion-copy/Sources/SimCamCore/FrameProducers.swift) |
| `framesock` | [LocalSocketFrameServer.swift](file:///Users/guoshuyu/workspace/swmansion-copy/Sources/SimCamCore/LocalSocketFrameServer.swift) |
| `extension-activator` | [ExtensionActivator.swift](file:///Users/guoshuyu/workspace/swmansion-copy/Sources/SimCamApp/ExtensionActivator.swift) |

注入到 simulator 的 hook 用 `os_log(OS_LOG_DEFAULT, "[SimCamHook] ...")`，可以这样看：

```sh
xcrun simctl spawn booted log stream --level debug \
  --predicate 'eventMessage CONTAINS "SimCamHook"'
```

### 3.2 常见问题

#### 「点 mac camera 没反应，跳回 None」

看 engine log：
```
[Back] FAIL setSource camera://FaceTime HD Camera — Camera permission denied. ...
```

按下面顺序排查：

1. `codesign -d --entitlements - $(...)/SimCamApp.app | grep camera` 必须能看到 `com.apple.security.device.camera`；
2. 系统设置 → *隐私与安全性* → *相机* 列表里有没有 SimCamApp？
   - **没有** → entitlement 缺失，回到 step 1；
   - **有，开关 OFF** → 打开开关，重启 SimCamApp；
   - **有，开关 ON** → `tccutil reset Camera dev.simcam.app` + 重启 SimCamApp，让系统重弹一次；
3. 看 [CameraDeviceFrameProducer.start](file:///Users/guoshuyu/workspace/swmansion-copy/Sources/SimCamCore/FrameProducers.swift#L117-L140) 的 throw 路径有没有进入。

#### 「Simulator passthrough 选了之后画面是全黑/出 -3801」

屏幕录制权限问题。按 [§1.1](#11-屏幕录制-screen-recording) 给权限，**重启 SimCamApp**（屏幕录制权限对已运行进程不生效）。

#### 「SimCam Virtual Camera 不出现」

```sh
systemextensionsctl list | grep simcam
```

- 没有任何条目 → [ExtensionActivator.activate](file:///Users/guoshuyu/workspace/swmansion-copy/Sources/SimCamApp/ExtensionActivator.swift) 没跑通，看 `subsystem=dev.simcam.app, category=extension-activator` 日志；
- `[activated waiting for user]` → 你没去 *系统设置 ▸ 安全性* 点允许；
- `[terminated waiting for user]` → 同上，但你之前点过否决；用 `systemextensionsctl reset` 然后再启动 host；
- `OSSystemExtensionErrorDomain code 8 (codeValidationFailed)` → 签名问题，签名身份必须是真实 Team ID，**不能是 ad-hoc**。

#### 「demo 启动了但摄像头画面全是占位帧」

说明 hook 注入失败 / socket 没连上。

- `ls /tmp/com.simcam.frames.sock` 必须存在；
- `xcrun simctl spawn booted log stream --predicate 'eventMessage CONTAINS "SimCamHook"'` 看 hook 是否报错；
- 如果 hook 显示 `connect() failed` —— 多半是 host 没启动，先 `make run`。

#### 「menubar 点击不响应」

确认进程是 [project.yml](file:///Users/guoshuyu/workspace/swmansion-copy/project.yml) 里的 `dev.simcam.app`：

```sh
pgrep -lf SimCamApp
```

如果存在多个 SimCamApp 进程（dev build + 安装版），先全杀掉：`pkill -9 -x SimCamApp`，然后只启动你想测的那一份。

---

## 4. 一份可复制的"重置 + 重启"序列

如果你彻底想要从零开始（清掉所有 TCC + 重装 sysext）：

```sh
# 1. 关掉一切相关进程
pkill -9 -x SimCamApp 2>/dev/null
xcrun simctl terminate booted dev.simcam.demo 2>/dev/null

# 2. 清 TCC（屏幕录制 + 摄像头）
tccutil reset Camera dev.simcam.app
tccutil reset ScreenCapture dev.simcam.app

# 3. 卸 sysext（注意：需要 SIP off 或 dev mode on 才能真删）
systemextensionsctl uninstall <TeamID> dev.simcam.app.extension

# 4. 重新 build + 跑
make run
./scripts/inject-simulator.sh dev.simcam.demo
```

---

## 5. 关于「为什么这次能用，上次不能」（已修）

历史 commit 关系：

| commit | 内容 | mac camera 是否能用 |
|---|---|---|
| `e03403d` | 初始 commit。ad-hoc 签名 + 没开 Hardened Runtime | ✅ |
| `3bd7833` | 切到 Personal Team 签名 → 开了 Hardened Runtime；为持久化 TCC csreq | ❌（entitlement 漏配，silent denied） |
| `cc501de` | 加 [com.apple.security.device.camera + audio-input + disable-library-validation](file:///Users/guoshuyu/workspace/swmansion-copy/project.yml#L66-L74) | ✅ |

**教训**：Hardened Runtime 一旦 ON，所有隐私 API（camera / mic / location / Apple Events / file access）的 entitlement 必须**显式**配齐，否则 macOS 直接静默拒绝且**不进 TCC 流程**——这是最难调试的状态，因为 `tccutil`、`requestAccess`、系统设置都看不出问题。

---

## 6. 现象记录：屏幕录制对话框间歇性弹出（**未根治**）

> 这一节是给后续维护者看的"现场报告"，不是已修问题。

**现象**：SimCamApp 在「系统设置 → 屏幕录制」里开关已 ON，但**偶尔**仍会弹出 macOS 的复授权对话框：

> "SimCamApp" would like to record this computer's screen and audio.
> Grant access to this application in Privacy & Security settings ...
> [ Open System Settings ]   [ Deny ]

注意是文案 **"would like to record this computer's screen"** 这一种（macOS 13/14 的 alert 形态），不是 macOS 15 的 *"bypass the private window picker / Allow For One Month"*。

**已查清的事实**：

抓 `tccd` + `replayd` log（`log show --predicate 'process == "tccd" OR process == "replayd"'`）显示，SimCamApp 跑 [ScreenFrameProducer](file:///Users/guoshuyu/workspace/swmansion-copy/Sources/SimCamCore/FrameProducers.swift) 时：

```
14:56:58.858  tccd: Handling access request to kTCCServiceScreenCapture
              from dev.simcam.app  pid=...
              ReqResult(Auth Right: Allowed (System Set), promptType: 1, DB Action: None)
14:56:58.868  replayd: hasScreenCaptureAccess... TCC Allow
```

- 每秒约 4 次（≈ 250ms 一次），频率正好对应 [ScreenFrameProducer.startFollowTimer](file:///Users/guoshuyu/workspace/swmansion-copy/Sources/SimCamCore/FrameProducers.swift#L691-L700) 的 `repeating: .milliseconds(250)`；
- `Auth Right: Allowed (System Set)` —— 权限是真的有；
- `DB Action: None` —— TCC 没动数据库；
- `promptType: 1` —— 但 access 评估带的 promptType 是 1（`kTCCPromptTypeAlert`，会触发模态对话框的那一档）。

**初步结论**（**尚未通过对照实验完全确认**）：

- 这**不是**首次授权框（那种叫 *"Policy disallows prompt"* 或 *"AUTHREQ_PROMPT"*）。
- 这**不是** macOS 15 Sequoia 的"月度复授权提醒"（那种文案带 *"Allow For One Month"*）。
- 高频的 `kTCCServiceScreenCapture` access 评估 + `promptType=1` 是嫌疑触发条件 —— 但**单独**重启 SimCamApp 时不一定每次都弹（稳定性低）。
- 弹与不弹之间的差异变量目前不明（怀疑跟 distance-from-last-Allow / 显示器拓扑变化 / SC 调用参数差异有关）。

**为什么 followTimer 是 250ms**：[ScreenFrameProducer](file:///Users/guoshuyu/workspace/swmansion-copy/Sources/SimCamCore/FrameProducers.swift#L702-L753) 在 followSimulator 模式下需要跟随 Simulator 窗口移动 —— 每 250ms 调一次 `SCShareableContent.excludingDesktopWindows(...)` 拿到最新的 `Simulator.app` 窗口矩形，然后 `updateContentFilter` 把 `sourceRect` 锁定上去。这是 SimCam 商业版的招牌效果，**不能简单删掉**。

**目前的应对**：

- 弹框出现时点 *Open System Settings* 或 *Deny* 都可以 —— 现在跑着的 SCStream **不会**断（log 显示 `TCC Allow` 一直在打）；这个对话框是 replayd 的"提醒"，不是"撤销"。
- 关掉 popover、不选 Simulator passthrough（用 *Display N* / *Demo*）会让 `followTimer` 不启动，TCC 评估频率降到几乎 0，从而（经验上）减少弹出。

**潜在优化方向**（待评估，**不要无许可改动**）：

1. **拉长 followTimer 周期**：250ms → 1000ms 或 2000ms，跟随延迟换 TCC 请求量。
2. **缓存 + 阈值**：仅当 Simulator 矩形 dx/dy ≥ 16pt 时才调 `updateContentFilter`；窗口列表 / display 列表只在第一次 producer 启动时取，之后用便宜的 `CGWindowListCopyWindowInfo`（不需要屏幕录制权限）。
3. **不重 stop+start SCStream**：[SimCamEngine.setSource](file:///Users/guoshuyu/workspace/swmansion-copy/Sources/SimCamCore/SimCamEngine.swift) 切源时如果新旧都是 `ScreenFrameProducer`，复用现有 stream，只 `updateContentFilter`。

> **注意**：方向 1/2/3 都**会**减少 TCC 请求量，但**并不能保证**根治弹框。要确认根因还需要在弹框出现的瞬间同步抓 `log stream` 现场。在没有可重现 reproducer 之前，不建议盲改 followSimulator 这条核心代码路径。

**抓现场的命令模板**：

```bash
# 1. 准备：清一下旧 log，开 stream
log stream \
  --predicate 'process == "tccd" OR process == "replayd" OR process == "SimCamApp"' \
  --info --debug --style compact > /tmp/simcam-trace.log &

# 2. 复现：quit + 重启 SimCamApp，等弹框出现
pkill -x SimCamApp
sleep 1
open <path-to-SimCamApp.app>

# 3. 弹框出现的那一刻，立即停 stream（kill %1）

# 4. 找出弹框前 1 秒内 replayd / tccd 在做什么
grep -nE 'prompt|present|alert|hasScreenCaptureAccess|promptType' /tmp/simcam-trace.log | tail -100
```

