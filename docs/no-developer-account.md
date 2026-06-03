# 在没有 Apple Developer Program（年费 $99）账号的情况下，如何让 SimCam 跑起来

> **适用场景**：你只有免费 Apple ID，没有付费 $99，没有团队 Provisioning Profile。
> 但你想在自己的 Mac 上跑通 SimCam 的两条核心链路：
>
> 1. **macOS 端**：CMIO Camera System Extension（虚拟摄像头出现在所有 macOS 相机 app 里：QuickTime、FaceTime、Zoom……）
> 2. **iOS Simulator 端**：被测 app 的 **标准 AVFoundation API 零代码改动**，就能拿到 host 推过来的画面 / QR / 视频。这条链路是 SimCam 商业版的主打能力。
>
> **结论**：两条链路在免账号状态下**都能跑通**。代价：
> - 链路 1（macOS CMIO）：一次性 `make bootstrap-cert` 生成本地 self-signed CA + `sudo systemextensionsctl developer on`（重启失效，每次开机要再开一次）+ host app 必须装在 `/Applications/`（`make install` 会代办）。**不需要降级 SIP。**
> - 链路 2（iOS Simulator hook）：完全不需要降级 SIP、不需要任何系统授权——只要 build 出 dylib 就能注入。
>
> **当前已验证范围（macOS 26.2 Tahoe / Xcode 26.2 / iOS Simulator 26.2）**：
> - macOS：System Extension 通过 sysextd 校验、`activated enabled`、被 lazy launch
> - macOS：host `AVCaptureDevice` 看到 `SimCam Virtual Camera`，`AVCaptureSession` 8 秒收 241 帧 @ 1920×1080 / 30fps
> - Simulator：被测 demo app（`AVCaptureDevice.DiscoverySession` 标准 API）枚举到 `SimCam Back Camera (back)` + `SimCam Front Camera (front)`
> - Simulator：`AVCaptureVideoPreviewLayer` 接管，host 的 demo 帧（绿色弧 + 橙点）显示在被测 app 里，进程不崩

---

## 0. 一张图看清两条链路

```
┌────────────────────────── host macOS ──────────────────────────┐
│                                                                │
│  ┌────────────┐   1. demo source / image / video / camera     │
│  │ SimCamCore │──┐                                            │
│  └────────────┘  │                                            │
│                  │     ┌─────────────────────────┐            │
│                  ├────▶│ CMIOSinkClient          │── sysext───┐
│                  │     │ (CMSimpleQueueEnqueue   │            │
│                  │     │  → consumeSampleBuffer) │            │
│                  │     └─────────────────────────┘            │
│                  │                                              │
│                  │     ┌─────────────────────────┐             │
│                  └────▶│ LocalSocketFrameServer  │             │
│                        │ /tmp/com.simcam.frames..│             │
│                        └─────────────────────────┘             │
│                                  ▲                              │
│  ┌─────────────────────────┐     │                              │
│  │ SimCamCameraExtension   │     │                              │
│  │ (CMIO System Extension) │     │      ┌────────────────────┐  │
│  └─────────────────────────┘     │      │  iOS Simulator     │  │
│           │                      │      │ ┌────────────────┐ │  │
│           ▼                      └──────┼─┤ libSimCamHook  │ │  │
│  ┌─────────────────────────┐     unix   │ │  .dylib (DYLD_ │ │  │
│  │  cmiod / FaceTime /     │     sock   │ │  INSERT_LIBS_) │ │  │
│  │  Zoom / QuickTime       │            │ └────────────────┘ │  │
│  └─────────────────────────┘            │ ┌────────────────┐ │  │
│                                         │ │ Demo / 被测 app│ │  │
│                                         │ │ AVFoundation   │ │  │
│                                         │ └────────────────┘ │  │
│                                         └────────────────────┘  │
└────────────────────────────────────────────────────────────────┘
```

- **链路 1 (macOS)**：`SimCamCore` → `CMIOSinkClient`（host 端把 CMSampleBuffer push 进 sysext 的 sink stream）→ `SimCamCameraExtension`（CMIO System Extension）→ cmiod/AVFoundation。给 macOS 上所有相机 app（QuickTime、FaceTime、Zoom、Teams、Meet、OBS、Chrome WebRTC …）用。**和 iOS Simulator 无关，可以独立跑。**
- **链路 2 (iOS Simulator)**：`SimCamCore` → `LocalSocketFrameServer (/tmp/com.simcam.frames.sock)` → `libSimCamHook.dylib`（DYLD_INSERT_LIBRARIES 注入）→ swizzle AVFoundation → 被测 app 看到的就是 host 推过来的画面。**被测 app 0 行业务代码改动。**

---

## 1. 链路 2：iOS Simulator（最简单，强烈推荐先跑这个）

### 1.1 为什么 Simulator 链路这么"轻"

iOS Simulator 上的进程跑在 macOS 用户态，**没有 SIP/AMFI 限制**，dyld 默许 `DYLD_INSERT_LIBRARIES`。这就是 SimCam 商业版的真做法——和 ECM 静默注入、调试器无关，纯 dyld 加载，启动期跑 `__attribute__((constructor))` 就能 swizzle AVFoundation。

`xcrun simctl launch` 自身不接受 `--setenv DYLD_INSERT_LIBRARIES=...`（路径校验），但它**会把宿主环境里所有以 `SIMCTL_CHILD_` 开头的变量去前缀后注入到子进程**。所以正确做法是：

```bash
SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=/path/to/libSimCamHook.dylib \
  xcrun simctl launch --terminate-running-process booted dev.simcam.demo
```

我们的 [scripts/inject-simulator.sh](file:///Users/guoshuyu/workspace/swmansion-copy/scripts/inject-simulator.sh) 就是把这条命令包了一下。

### 1.2 端到端步骤

```bash
# A. 确认 simulator 已启动
xcrun simctl list devices booted | grep -v "^--"
# 没有的话开一个：
open -a Simulator
xcrun simctl boot "iPhone 17 Pro"

# B. build SimCamHook + SimCamDemoApp（两个都在 SimCamDemo scheme 里）
xcodebuild -scheme SimCamDemo -destination 'generic/platform=iOS Simulator' build

# C. 把 demo app 装到 simulator
xcrun simctl install booted \
  ~/Library/Developer/Xcode/DerivedData/SimCam-*/Build/Products/Debug-iphonesimulator/SimCamDemoApp.app

# D. 启动 host SimCamApp（menubar app）—— 它会 listen unix sock
#    并按默认进入 demo 帧源（绿色圆弧 + 橙色圆点的测试画面）
open ~/Library/Developer/Xcode/DerivedData/SimCam-*/Build/Products/Debug/SimCamApp.app

# E. 注入 SimCamHook 到 simulator 里的 demo app
./scripts/inject-simulator.sh dev.simcam.demo

# F. 截图验证
xcrun simctl io booted screenshot /tmp/sim.png
open /tmp/sim.png
```

成功的画面会显示：

```
AVCaptureDevice list (2):
  • SimCam Back Camera (back)
  • SimCam Front Camera (front)
```

并把 host 推送的 demo 帧渲染到全屏 preview。

### 1.3 dylib 必须用 *codesigned* 那份

**最常见踩坑**：iOS Simulator 17+（含 26.x）的 dyld 拒绝加载 *未签名* 的 dylib，注入会被静默忽略（没有错误也没有 `[SimCamHook] installed` 日志）。

Xcode build 后实际产物有两份：

- `Build/Intermediates.noindex/.../SimCamHook.build/Objects-normal/<arch>/Binary/libSimCamHook.dylib`：**未签名**，不能用
- `Build/Products/Debug-iphonesimulator/libSimCamHook.dylib`：universal + ad-hoc 签，**用这个**

`scripts/inject-simulator.sh` 已经写死只搜 `Build/Products/Debug-iphonesimulator/` 路径，如果你手动注入，记得也用这个路径。

```bash
codesign -dvv Build/Products/Debug-iphonesimulator/libSimCamHook.dylib
# 期望：Identifier=libSimCamHook, Signature=adhoc
```

### 1.4 Back / Front 双路 + 桌面捕获（对齐 SimCam 商业版）

从 v1.0.0 起 host 的 wire protocol 升级到 v2（48 字节 header，新增 `cameraSlot`），目的是让被测 app 在调用 `AVCaptureDevicePosition.back` 与 `.front` 时分别拿到**两路独立的 host source**——和 [https://simcam.swmansion.com/](https://simcam.swmansion.com/) 商业版的菜单栏一致。同步加上 ScreenCaptureKit 桌面 / 窗口源。

```
┌──── host SimCamApp ───────────────────────┐
│                                            │
│   menubar 两栏并列 picker                  │
│   ┌──────────────┐  ┌──────────────┐      │
│   │ Back camera  │  │ Front camera │      │
│   │  • Demo      │  │  • Demo      │      │
│   │  • FaceTime  │  │  • iPhone    │      │
│   │  • Display 1 │  │  • Window …  │      │
│   │  • Image / Q │  │  • Image / Q │      │
│   └──────┬───────┘  └──────┬───────┘      │
│          │                 │              │
│   ┌──────▼───────┐  ┌──────▼───────┐      │
│   │ FrameProducer│  │ FrameProducer│      │
│   │   slot=0     │  │   slot=1     │      │
│   └──────┬───────┘  └──────┬───────┘      │
│          └────────┬────────┘              │
│   ┌───────────────▼──────────────────┐    │
│   │ LocalSocketFrameServer            │    │
│   │ writes 48-byte v2 header w/ slot  │    │
│   └───────────────┬──────────────────┘    │
└───────────────────┼──────────────────────┘
                    │
                /tmp/com.simcam.frames.sock
                    │
┌───────────────────▼──────────────────────┐
│  iOS Simulator (libSimCamHook.dylib)      │
│  gLatestPixelBuffer[2]   ← per-slot       │
│  gLatestQRPayload[2]     ← per-slot       │
│                                            │
│  AVCaptureSession.inputs[0].device.position│
│      .back  → slot 0                       │
│      .front → slot 1                       │
│                                            │
│  dispatch_sample / render_preview /        │
│  dispatch_metadata 仅 fan-out 到匹配 slot   │
│  的 delegate / preview-layer               │
└────────────────────────────────────────────┘
```

#### v2 wire protocol（48 字节 header）

```c
// SimCamHook.h
#define SIMCAM_FRAME_VERSION 2u   // v1 (40B) 已被破坏；老 hook 装上后会
                                  // 在 [SimCamHook] bad header 日志后自动重连
#define SIMCAM_SLOT_BACK     0u
#define SIMCAM_SLOT_FRONT    1u
#define SIMCAM_SLOT_COUNT    2

#pragma pack(push, 1)
typedef struct {
    uint32_t magic, version, width, height, bytesPerRow, pixelFormat;
    uint64_t hostTimeNs;
    uint32_t payloadLen, qrPayloadLen;
    uint8_t  cameraSlot;     // 0=back, 1=front
    uint8_t  reserved[7];    // future use
} SimCamFrameHeader;
#pragma pack(pop)
_Static_assert(sizeof(SimCamFrameHeader) == 48, "v2 header must be 48 bytes");
```

#### host 侧关键 API（per-slot）

```swift
// 设置 back 槽位为 demo，front 槽位为主屏幕：
SimCamEngine.shared.setSource(.demo, slot: .back)
SimCamEngine.shared.setSource(.screen(displayID: 1, windowID: 0,
                                      includeMouse: true),
                              slot: .front)

// 单路停止
SimCamEngine.shared.stop(slot: .front)
```

#### 桌面捕获

源类型 [`.screen(displayID:windowID:includeMouse:)`](file:///Users/guoshuyu/workspace/swmansion-copy/Sources/SimCamCore/CameraSource.swift#L21) 走 [ScreenFrameProducer](file:///Users/guoshuyu/workspace/swmansion-copy/Sources/SimCamCore/FrameProducers.swift#L364)：

- 用 `SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)` 列举可选；
- `windowID != 0` 时构造 `SCContentFilter(desktopIndependentWindow:)`，否则锁定 display；
- `SCStreamConfiguration` 取 host 当前 `FrameFormat`（`width/height/fps`）；
- `SCStreamOutput` 校验 `SCStreamFrameInfo.status == .complete` 才转发；
- **首次 `start()` 会触发系统的「屏幕录制权限」弹窗**——授权后第二次启动即可正常出帧。SimCamApp 自身（自指）窗口在 [ScreenSourceDiscovery.list()](file:///Users/guoshuyu/workspace/swmansion-copy/Sources/SimCamCore/FrameProducers.swift#L327) 里被 `processIdentifier` 过滤掉，避免 cycle。

#### hook 侧 slot 路由

[SimCamHook.m](file:///Users/guoshuyu/workspace/swmansion-copy/Sources/SimCamHook/SimCamHook.m) 在收到 v2 header 后：

1. `gLatestPixelBuffer[slot]` / `gLatestQRPayload[slot]` 分桶缓存；
2. `simcam_session_slot(AVCaptureSession*)` 通过 `session.inputs[0].device.position` 反查归属 slot（`addInput:` 时也把 session 关联到 input/output 上）；
3. `simcam_dispatch_sample` 只 fan-out 到 `simcam_session_slot(out.session) == slot` 的 sample-buffer delegate；
4. `simcam_render_preview` 用 `gPreviewLayerSessions` (NSMapTable，weak↔weak) 反查 layer 所属 session 后按 slot 过滤；
5. `simcam_dispatch_metadata` 同样按 slot 过滤 QR delegate。

被测 app 的常见切换代码因此**自然生效**：

```swift
// 任意被测 app 的标准 AVFoundation 写法：
let device = AVCaptureDevice.DiscoverySession(
    deviceTypes: [.builtInWideAngleCamera],
    mediaType: .video,
    position: .front       // ← .back / .front 一切照旧
).devices.first!
let input = try AVCaptureDeviceInput(device: device)
session.addInput(input)
```

切到 `.front` 时，hook 自动只把 slot=1 的帧喂给这个 session 的 sample-buffer delegate / preview layer，**进程零代码改动**。

#### menubar UI

[MenubarView.swift](file:///Users/guoshuyu/workspace/swmansion-copy/Sources/SimCamApp/MenubarView.swift) 现在是两栏并列 picker（`BACK CAMERA SOURCE` / `FRONT CAMERA SOURCE`），分别独立选择 None / Demo / 任意真实摄像头 / Image / Video / QR / 任意 display 或 window。每栏右侧绿点指示该路是否在 streaming，且各自有独立的 `Stop back` / `Stop front` 按钮。

真实摄像头按 `CameraDescriptor.kind`（[CameraKind](file:///Users/guoshuyu/workspace/swmansion-copy/Sources/SimCamCore/SimCamState.swift#L66) = builtIn / external / continuity / deskView / front / simcamVirtual）显示真实标签——不再像 v1 那样把所有 mac 摄像头统一打成 `back`（macOS 上 `device.position` 永远是 unspecified，所以旧 UI 完全没意义）。SimCam 自家虚拟相机默认从列表里过滤掉（避免被自己挑成源造成 cycle），这是 [CameraDiscovery.list(includeSimCamVirtual:)](file:///Users/guoshuyu/workspace/swmansion-copy/Sources/SimCamCore/FrameProducers.swift) 的 `false` 默认值控制的。

### 1.5 hook 内部做了什么（只要你想自己拓展功能就要看）

`Sources/SimCamHook/SimCamHook.m` 里 swizzle 了下面这些 AVFoundation 类方法 / 实例方法：

| API | 做了什么 |
|---|---|
| `+[AVCaptureDevice devicesWithMediaType:]` | 返回 `[fakeBack, fakeFront]` |
| `+[AVCaptureDevice defaultDeviceWithMediaType:]` | 返回 `fakeBack` |
| `+[AVCaptureDevice deviceWithUniqueID:]` | 按 UID 返回 `fakeBack`/`fakeFront` |
| `+[AVCaptureDevice authorizationStatusForMediaType:]` | 直接返回 `Authorized` |
| `+[AVCaptureDevice requestAccessForMediaType:completionHandler:]` | 直接 callback `YES` |
| `+[AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:mediaType:position:]` | `class_createInstance(...)` 创建空 session 再 associate `devices` |
| `-[AVCaptureDeviceDiscoverySession devices]` | 返回 fake 设备列表（按 position 过滤） |
| `+[AVCaptureDeviceInput deviceInputWithDevice:error:]` | 接收 fake device 时合成空 input + associate |
| `-[AVCaptureSession addInput:]` / `canAddInput:` / `canAddOutput:` | no-op + always YES |
| `-[AVCaptureSession startRunning]` / `stopRunning` / `isRunning` | 切 hook 内部状态机，不动真硬件 |
| `-[AVCaptureVideoDataOutput setSampleBufferDelegate:queue:]` | 注册到 hook 的 delegate 表，后台 puller 喂 BGRA `CMSampleBuffer` |
| `-[AVCaptureMetadataOutput setMetadataObjectsDelegate:queue:]` | 同上，喂 fake `AVMetadataMachineReadableCodeObject` |
| `-[AVCaptureMetadataOutput setMetadataObjectTypes:]` / `availableMetadataObjectTypes` | 收下 `[.qr, .ean13, …]`，绕过真硬件能力校验 |
| `-[AVCaptureVideoPreviewLayer initWithSession:]` | 创建一个 `[CALayer alloc] init` + `object_setClass` 成 AVCaptureVideoPreviewLayer 的 instance（绕过私有 init），并把 `setBounds:`/`setFrame:`/`layoutSublayers`/`display` 重定向到 CALayer 的实现 |
| `-[AVCaptureVideoPreviewLayer setVideoGravity:]` | 翻译成 `CALayer.contentsGravity` |

后台 `simcam_pull_loop` 从 `/tmp/com.simcam.frames.sock` 按 48 字节 v2 header 读帧（含 `cameraSlot`），`CVPixelBufferCreateWithBytes` 包出 BGRA pixel buffer，再 `CMSampleBufferCreate...` 包出 sample buffer，**按 slot fan-out** 到所有注册过的 sample-buffer delegate / preview layer 上 (`layer.contents = (__bridge id)CGImageRef`)。

### 1.6 troubleshooting

| 现象 | 原因 | 修法 |
|---|---|---|
| `xcrun simctl launch ... --setenv DYLD_INSERT_LIBRARIES=...` 报 `Invalid device: --setenv` | simctl 不接受这个 flag | 用 `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=... xcrun simctl launch --terminate-running-process booted <bundle>` |
| 注入命令"成功"但日志里没 `[SimCamHook] installed` | dylib 未签名 / 路径不对 | 确认走 `Build/Products/Debug-iphonesimulator/libSimCamHook.dylib`（见 §1.3），`codesign -dvv` 不应说 `not signed` |
| Demo app 启动后立即 SIGSEGV，crash 在 `-[AVCaptureVideoPreviewLayer setBounds:]` | hook 装上但 preview layer init 没绕过私有 ivar | 确认你 build 的是最新的 `SimCamHook.m`（含 `setBounds`/`setFrame` 重定向到 CALayer） |
| Demo app crash 抛 `NSInvalidArgumentException Unsupported type found (org.iso.QRCode)` | hook 没 swizzle `setMetadataObjectTypes:` | 同上，确认是最新版本 |
| Demo app 看 device list 是空的 | hook 没装上（DYLD_INSERT 没传进去）/ swizzle 安装顺序 race | 看 `xcrun simctl spawn booted log show --last 30s --predicate 'eventMessage CONTAINS "SimCamHook"'`，应该有 `installed` + `connected to host frame socket` 两行 |
| dylib 装上但画面黑 | host SimCamApp 没启动 / `/tmp/com.simcam.frames.sock` 不存在 | `lsof -U \| grep simcam.frames.sock` 应该有 SimCamApp 在 listen；没有就 `open SimCamApp.app` |
| 多个 simulator booted，注入到错的那个 | `simctl ... booted` 的解析行为 | 显式指定 udid：`./scripts/inject-simulator.sh <bundle> <udid>` |

### 1.7 给真实被测 app（不是 demo）用

完全一样，三步：

```bash
# 假设你的被测 app bundle id 是 com.example.MyScanner
xcrun simctl install booted /path/to/MyScanner.app
open SimCamApp.app                     # host menubar 起 unix sock
./scripts/inject-simulator.sh com.example.MyScanner
```

被测 app 不需要 `import` 任何 SimCam framework，不需要 link 任何东西，不需要改 entitlements，不需要改 bundle id。**这就是 SimCam 商业版承诺的 "0 lines of integration code"**。

---

## 2. 链路 1：macOS CMIO Camera System Extension

如果你只关心 simulator，**这一节可以全部跳过**。链路 1 是给"想让 macOS 上 QuickTime/FaceTime/Zoom 也看到 SimCam 虚拟摄像头"的场景用的，需要 system extension 进系统。

> 也是 [https://simcam.swmansion.com/](https://simcam.swmansion.com/) 商业版「macOS 上 Mac 端任何相机 app 都能选 SimCam Virtual Camera」那条链路的开源复刻。

### 2.1 苹果给 system extension 设的三条门

| 路径 | 要求 |
|---|---|
| 正经发行 | $99 开发者账号 + Notarization + 用户在系统设置里允许 |
| 团队内测 | $99 + Provisioning Profile 含 `com.apple.developer.system-extension.install` entitlement |
| 本机调试（本文要解决的） | **self-signed CA `SimCam Local Dev` 签 + `systemextensionsctl developer on`** |

ad-hoc（`codesign -s -`）和 Apple Development（Personal Team 免费签）都**不能**走第三条：

- **ad-hoc**：能装上 system extension，但 TCC 用 cdhash 锁 designated requirement，每次 rebuild cdhash 一变，Camera / Screen Recording / Microphone 授权全部失效；
- **Personal Team 免费签**：Apple 不给 Personal Team 颁 System Extension capability，profile 申请直接报 *"Personal development teams ... do not support the System Extension capability"*。

所以本仓库选了第三条：本地 self-signed CA + `systemextensionsctl developer on`。原理 / 取舍 / 替代方案对比见 [docs/signing-and-tcc.md](file:///Users/guoshuyu/workspace/swmansion-copy/docs/signing-and-tcc.md)。

### 2.2 必须的前置环境

#### 2.2.1 SIP 现状（**不需要降级**）

self-signed CA + `systemextensionsctl developer on` 路线**不需要**碰 SIP。保持默认即可。

```bash
csrutil status
# 期望：System Integrity Protection status: enabled.
```

> 历史版本的笔记曾要求 `csrutil enable --without debug --without kext`，那是基于"用 ad-hoc 签 system extension"的旧路线。现在签名升级到 self-signed CA 后这一步**不需要**做。

##### （可选）SIP 最小化降级：`csrutil enable --without kext --without debug`

下面这条**只**在两种场景下需要做，**当前推荐路线（self-signed CA + `systemextensionsctl developer on`）完全用不上**：

- 场景 A：你不想 / 不能用 self-signed CA（比如团队脚本固定走 ad-hoc 签 sysext 的老路）。
- 场景 B：你想用 Xcode / lldb **attach 调试**正在运行的 system extension（默认 SIP 会拒绝 `task_for_pid` 到非 Apple 签的进程）。

操作（**只关 kext 校验 + 调试器限制，其它 SIP 保护全部保留**）：

```bash
# 1. 关机
# 2. 长按电源键，直到看到：
#    Loading startup options
# 3. 选择：Options / 选项
#    进入 Recovery。
# 4. 菜单里打开：Utilities / 实用工具 → Terminal / 终端
# 5. 执行：
csrutil enable --without kext --without debug
# 6. 然后：
reboot
```

回到普通系统验证：

```bash
csrutil status
# 期望：
# System Integrity Protection status: enabled (Custom Configuration).
#   Apple Internal: disabled
#   Kext Signing: disabled
#   Filesystem Protections: enabled
#   Debugging Restrictions: disabled
#   DTrace Restrictions: enabled
#   NVRAM Protections: enabled
#   BaseSystem Verification: enabled
#   Boot-arg Restrictions: enabled
#   Kernel Integrity Protections: enabled
#   Authenticated Root Requirement: enabled
```

各开关含义（用 Apple 官方术语）：

| 关掉的开关 | 影响 |
|---|---|
| `--without kext` | 允许加载未由 Apple 公证的 kext / 给 sysextd 放行未由 Apple anchor 签的 system extension |
| `--without debug` | 允许 lldb / Xcode `task_for_pid` attach 到非 Apple 签名进程（用于断点调试 sysext / host） |

恢复完整 SIP（强烈建议平时保持 enabled 状态，仅调试时降级）：

```bash
# Recovery Terminal
csrutil clear
reboot
# 或者
csrutil enable
reboot
```

> 警告：**只在自己的开发机做这个**。SimCam 默认推荐路线是「**SIP 完整启用** + self-signed CA + `systemextensionsctl developer on`」，正常运行 / 安装 / 卸载 / 重签都不需要降级 SIP。本节只为「真的不想用 self-signed CA」或「真的要 attach 调试 sysext」的人保留作为最小化降级方案，避免你看到外网帖子去 `csrutil disable`（那是过度操作）。

#### 2.2.2 启用 system-extension developer mode

```bash
sudo systemextensionsctl developer on
```

这是让 SimCam 这种**非 Apple-signed** host 能成功 `OSSystemExtensionRequest activationRequest` 的关键。**重启后会失效**，每次重启都要再开。`make doctor` 会检查这一项。

#### 2.2.3 一次性生成本地 self-signed code-signing 证书

第一次 clone 仓库后**必须**先做这一步，否则 build 会报 *"No identity found"*：

```bash
make bootstrap-cert
```

这条命令（[scripts/bootstrap-cert.sh](file:///Users/guoshuyu/workspace/swmansion-copy/scripts/bootstrap-cert.sh)）会：

1. 在你的 `login.keychain-db` 里生成一对 ECC P-256 key；
2. 自签一张证书，CN = `SimCam Local Dev`，EKU = codeSigning；
3. 把这张证书标成"始终信任 (codeSigning)"。

私钥**只**留在你机器的 keychain，**不**入仓——所以仓库里没有任何证书材料，每个开发者各签各的。

验证：

```bash
security find-identity -v -p codesigning | grep "SimCam Local Dev"
# 期望：1 valid identities found
```

### 2.3 安装路径必须是 `/Applications/`

`SimCamApp.app` 必须从 `/Applications/SimCamApp.app` 启动；DerivedData 路径下的 app 跑 `OSSystemExtensionManager` 时会被 sysextd 拒绝（理由：路径不在受信任位置）。host app 还必须 `chown root:wheel`。

仓库提供的 [scripts/install-systemext.sh](file:///Users/guoshuyu/workspace/swmansion-copy/scripts/install-systemext.sh) 把这套约束都封装好了：build 完之后**重签**一遍（确保 host + extension + 内部 dylib 全部用 `SimCam Local Dev` 签且 designated requirement 锁到 CN）→ 拷到 `/Applications/` → `chown root:wheel`。直接 `make install` 调它即可。

### 2.4 端到端步骤

```bash
# 0. 一次性：生成本地证书（仅第一次 clone 后）
make bootstrap-cert
sudo systemextensionsctl developer on    # 重启后需要重新执行

# 1. build + 重签 + 拷到 /Applications/（需要 sudo 写入）
make install                              # 等价于 make build + scripts/install-systemext.sh

# 2. 启动 host menubar app
make run                                  # = make install + open /Applications/SimCamApp.app
#    或者：open /Applications/SimCamApp.app

# 3. 在 menubar popover 里点 "Activate Extension"
#    第一次会触发 系统设置 → Privacy & Security → 允许扩展 的对话框
#    点 Allow，extension 会进入 [activated enabled]

# 4. 验证
systemextensionsctl list | grep simcam
# 期望：dev.simcam.app.extension  [activated enabled]
system_profiler SPCameraDataType | grep -i simcam
# 期望看到 "SimCam Virtual Camera"

# 5. 在 host 任意相机 app（QuickTime → New Movie Recording → Camera 下拉）
#    选 SimCam Virtual Camera，应该看到 host 推送的 demo 帧
```

诊断脚本：

```bash
make doctor      # = scripts/diagnose-sysext.sh
# 一把检查 SIP / sysext developer mode / 证书 / host 安装位置 / sysextd 日志
```

### 2.5 macOS 链路常见坑

| 现象 | 原因 | 修法 |
|---|---|---|
| `Activation Request: error 1` (`extensionMissingIdentifier`) | extension bundle 没在 host app 的 `Contents/Library/SystemExtensions/` 下 | 检查 `SimCamCameraExtension.systemextension` 是否被 Xcode 拷进 host app |
| `error 4` (`forbiddenBySystemPolicy`) | 没开 `systemextensionsctl developer on`，或者 host app 不在 `/Applications/` | 见 §2.2.2 / §2.3，或直接 `make run` |
| `error 8` (`codeValidationFailed`) | 签名身份不对（多半是没跑 `make bootstrap-cert`，host fallback 到 ad-hoc） | `security find-identity -v -p codesigning \| grep 'SimCam Local Dev'` 应该有；没有就 `make bootstrap-cert`，然后 `make install` 重签 |
| activate 后系统**没弹**任何允许提示 | sysextd 已经记住该 extension 被拒过一次 | `sudo systemextensionsctl reset` + 重启 + `make run` |
| 重 build 后 TCC 授权失效（系统设置里 ON 但实际 deny） | 你绕过了 `make install` 直接 `xcodebuild build` 跑了 ad-hoc 拷贝 | `make reset-tcc` + `sudo rm -rf /Applications/SimCamApp.app` + `make run` |
| `cmiod` 看不到 device | extension 进程没被 launch / `startService` 失败 | `log stream --predicate 'process == "SimCamCameraExtension"'` |
| QuickTime 选了 SimCam Virtual Camera 但只看到 sysext 内置的 demo timer（深灰底 + 移动白线），没看到 host 选的真画面 | host 端 `CMIOSinkClient` 把 source stream 误当 sink stream 在 enqueue（一晚上踩过的坑） | 见 [docs/CMIO-LESSONS-LEARNED.md](file:///Users/guoshuyu/workspace/swmansion-copy/docs/CMIO-LESSONS-LEARNED.md) §2 反转#8。修法已在 main：按 stream `name == "SimCam.Sink"` 选 |
| sysext 日志反复 `enqueue failed: -12773 (kCMSimpleQueueError_QueueIsFull)` | sink stream 的 CMSimpleQueue 被 host 在 cmiod 还没 consume 的时候打满 | `CMIOSinkClient` push 前先 `CMSimpleQueueGetCount`/`GetCapacity` 判一下，遇到队列满就 `resetSinkConnection`（已实现）|

> 改任何 CMIO 相关代码或排查 CMIO 链路前，**先扫一眼** [docs/CMIO-LESSONS-LEARNED.md](file:///Users/guoshuyu/workspace/swmansion-copy/docs/CMIO-LESSONS-LEARNED.md)（9 次反转 / 5 个关键证据 / 7 条长期红线）。

---

## 3. 两条链路同时跑

它们没有冲突，host SimCamCore 同一份 `setSource(...)` 出来的帧会**同时**送到：

- 链路 1：`CMIOSinkClient.push(sample)` → CMIO sink stream → sysext `consumeSampleBuffer` → cmiod → AVFoundation 客户端
- 链路 2：`LocalSocketFrameServer` → unix sock → simulator dylib

实测同时打开 QuickTime（选 SimCam Virtual Camera）和 simulator 里的 demo app，两边看到的是同一帧、同一速率。

Menubar popover 里 [MenubarView.swift](file:///Users/guoshuyu/workspace/swmansion-copy/Sources/SimCamApp/MenubarView.swift) 显示两条 banner：

```
CMIO ext: registered           1920×1080 / 30fps
Sim hook: 1 connected           dev.simcam.demo @ /tmp/com.simcam.frames.sock
```

`SimCamEngine.diagnose()` 也会输出 `cmio extension` + `simulator hooks` 两个键，方便测试断言。

---

## 4. 法律/合规小字

苹果对 SIP 降级和 `systemextensionsctl developer on` 都有明确文档说明，**这些操作只能用在你自己的开发机**。把 SimCam 拿去给最终用户分发，仍然需要付费开发者账号 + Notarization。

链路 2（DYLD_INSERT_LIBRARIES）只对 iOS Simulator 内部进程有效。**在真机 iOS 上 dyld 会拒绝加载未签的注入库**，所以不构成生产侧的安全问题。SimCam 商业版自身也只支持 simulator。
