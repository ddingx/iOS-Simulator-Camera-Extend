# 在没有 Apple Developer Program（年费 $99）账号的情况下，如何让 SimCam 跑起来

> **适用场景**：你只有免费 Apple ID，没有付费 $99，没有团队 Provisioning Profile。
> 但你想在自己的 Mac 上跑通 SimCam 的两条核心链路：
>
> 1. **macOS 端**：CMIO Camera System Extension（虚拟摄像头出现在所有 macOS 相机 app 里：QuickTime、FaceTime、Zoom……）
> 2. **iOS Simulator 端**：被测 app 的 **标准 AVFoundation API 零代码改动**，就能拿到 host 推过来的画面 / QR / 视频。这条链路是 SimCam 商业版的主打能力。
>
> **结论**：两条链路在免账号状态下**都能跑通**。代价：
> - 链路 1 需要降级 SIP（仅在开发机上一次）+ ad-hoc 签 + `/Applications/` 安装。
> - 链路 2 完全不需要降级 SIP、不需要任何系统授权——只要 build 出 dylib 就能注入。
>
> **当前已验证范围（macOS 26.2 Tahoe / Xcode 26.2 / iOS Simulator 26.2）**：
> - ✅ macOS：System Extension 通过 sysextd 校验、`activated enabled`、被 lazy launch
> - ✅ macOS：host `AVCaptureDevice` 看到 `SimCam Virtual Camera`，`AVCaptureSession` 8 秒收 241 帧 @ 1920×1080 / 30fps
> - ✅ Simulator：被测 demo app（`AVCaptureDevice.DiscoverySession` 标准 API）枚举到 `SimCam Back Camera (back)` + `SimCam Front Camera (front)`
> - ✅ Simulator：`AVCaptureVideoPreviewLayer` 接管，host 的 demo 帧（绿色弧 + 橙点）显示在被测 app 里，进程不崩

---

## 0. 一张图看清两条链路

```
┌────────────────────────── host macOS ──────────────────────────┐
│                                                                │
│  ┌────────────┐   1. demo source / image / video / camera     │
│  │ SimCamCore │──┐                                            │
│  └────────────┘  │                                            │
│                  │     ┌─────────────────────────┐            │
│                  ├────▶│ CMIO sink               │── extension─┐
│                  │     │ (FrameRelay → ext)      │             │
│                  │     └─────────────────────────┘             │
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

- **链路 1 (macOS)**：`SimCamCore` → `FrameRelayServer` → `SimCamCameraExtension` → cmiod/AVF。给 macOS 上所有相机 app 用。
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

- `Build/Intermediates.noindex/.../SimCamHook.build/Objects-normal/<arch>/Binary/libSimCamHook.dylib`：**未签名**，⚠️ 不能用
- `Build/Products/Debug-iphonesimulator/libSimCamHook.dylib`：universal + ad-hoc 签 ✅ 用这个

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

### 2.1 苹果给 system extension 设的三条门

| 路径 | 要求 |
|---|---|
| 正经发行 | $99 开发者账号 + Notarization + 用户在系统设置里允许 |
| 团队内测 | $99 + Provisioning Profile 含 `com.apple.developer.system-extension.install` entitlement |
| 本机调试（本文要解决的） | **ad-hoc 签 + `systemextensionsctl developer on` 绕过 Profile 校验** |

第三条 Apple 没在文档里大书特书，但确实存在。代价是你必须放宽一部分 SIP。

### 2.2 必须的前置环境

#### 2.2.1 关闭 SIP 的"调试和签名校验"两块（其余保留）

不需要 `csrutil disable` 裸奔。用：

```bash
# Recovery 终端：
csrutil enable --without debug --without kext
```

只关闭：
- Debugging Restrictions（允许调试别人的进程、加 entitlement 调试）
- Kext Signing（允许加载未经 Apple 签名的 kext / system extension）

保留：FS Protections / Apple Internal / Runtime Protections。

#### 2.2.2 进 Recovery

Apple Silicon：关机 → 长按电源键 → "Loading startup options" → Options → Continue → 顶部菜单 Utilities → Terminal → 执行上面那条 → 重启。

Intel：开机即按住 ⌘R，进入后同样开 Terminal。

#### 2.2.3 启用"system extension developer mode"

```bash
sudo systemextensionsctl developer on
```

这是 SimCam 这种**未托管**应用能 `OSSystemExtensionRequest activationRequest` 成功的关键。重启后会失效，每次重启都要再开。

### 2.3 安装路径必须是 `/Applications/`

`SimCamApp.app` 必须从 `/Applications/SimCamApp.app` 启动；DerivedData 路径下的 app 跑 `OSSystemExtensionManager` 时会被 sysextd 拒绝（理由：路径不在受信任位置）。

```bash
# 把 DerivedData 里 build 出来的 host app 复制 / symlink 到 /Applications
sudo cp -R ~/Library/Developer/Xcode/DerivedData/SimCam-*/Build/Products/Debug/SimCamApp.app /Applications/
```

每次改 host 代码 / extension 代码后都要重新 cp。

### 2.4 端到端步骤

```bash
# 1. build host + extension
xcodebuild -scheme SimCam build

# 2. cp 到 /Applications
sudo rm -rf /Applications/SimCamApp.app
sudo cp -R ~/Library/Developer/Xcode/DerivedData/SimCam-*/Build/Products/Debug/SimCamApp.app /Applications/

# 3. 启动 host（menubar app）
open /Applications/SimCamApp.app

# 4. 在 menubar popover 里点 "Activate Extension"
#    系统会弹"系统设置 → Privacy & Security → 允许 ..." 的提示
#    在那里点 Allow，extension 进入 [activated enabled]

# 5. 验证
systemextensionsctl list | grep simcam
# 应该有 enabled active 行
system_profiler SPCameraDataType | grep -i simcam
# 应该看到 "SimCam Virtual Camera"

# 6. 在 host 任意相机 app（QuickTime → New Movie Recording → Camera 下拉）
#    选 SimCam Virtual Camera，应该看到 host 推送的 demo 帧
```

### 2.5 macOS 链路常见坑

| 现象 | 原因 | 修法 |
|---|---|---|
| `Activation Request: error 1` (`extensionMissingIdentifier`) | extension bundle 没在 host app 的 `Contents/Library/SystemExtensions/` 下 | 检查 `SimCamCameraExtension.systemextension` 是否被 Xcode 拷进 host app |
| `error 4` (`forbiddenBySystemPolicy`) | 没开 `systemextensionsctl developer on`，或者 host app 不在 `/Applications/` | 见 §2.2.3 / §2.3 |
| activate 后系统**没弹**任何允许提示 | sysextd 已经记住该 extension 被拒过一次 | `sudo systemextensionsctl reset` + 重启 + 重新 activate |
| `cmiod` 看不到 device | extension 进程没被 launch / `startService` 失败 | `log stream --predicate 'process == "SimCamCameraExtension"'` |

---

## 3. 两条链路同时跑

它们没有冲突，host SimCamCore 同一份 `setSource(...)` 出来的帧会**同时**送到：

- 链路 1：`FrameRelayServer` → CMIO sink → extension → cmiod
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
