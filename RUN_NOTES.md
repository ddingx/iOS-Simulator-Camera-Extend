# Field Notes（踩坑笔记 / 中文）

> 这是从 0 复刻 [SimCam](https://simcam.swmansion.com/) 过程中积累的实战笔记。
> README 已经覆盖「项目是什么 / 怎么跑」，这里只记录**调试过程踩到的非显然坑**和对应根因。
>
> 最后更新：2026-06-02

如果你只是想跑通项目，请看 [README.md](README.md) 与 [docs/no-developer-account.md](docs/no-developer-account.md)。

---

## 1. SimCamHook 不在 SimCam scheme 里 —— 改了 hook 没生效

**现象**：改 `SimCamHook.m`，跑 `xcodebuild -scheme SimCam`，注入到 Simulator 后行为没变化。

**根因**：`SimCamHook` 是个独立的 dylib target，**没有**被加到 `SimCam` scheme 的 build 阶段。`SimCam` scheme 编译出来的只有 host 端 + extension + 单测，dylib 仍是上次的旧产物。

**修法**：改 hook 之后必须 build `SimCamDemo` scheme：

```bash
xcodebuild -project SimCam.xcodeproj -scheme SimCamDemo \
  -sdk iphonesimulator -arch arm64 -configuration Debug build
```

或者把 `SimCamHook` 加到 `SimCam` scheme 的 Targets 里（项目里没这么做是因为想保持 macOS scheme 与 iOS Simulator scheme 物理隔离，避免错配 SDK）。

---

## 2. 未签名的 dylib 被 dyld 静默忽略

**现象**：`./scripts/inject-simulator.sh` 跑完没报错，进程也起来了，但 hook 完全没装上（`xcrun simctl spawn booted log show --predicate 'eventMessage CONTAINS "SimCamHook"'` 一行都没有）。

**根因**：iOS 17+ Simulator 的 dyld 拒绝加载未签名 dylib，但**不会**给任何错误日志。

Xcode 编出来的产物有两份：

- `Build/Intermediates.noindex/.../SimCamHook.build/Objects-normal/<arch>/Binary/libSimCamHook.dylib` —— **未签名**，不能用
- `Build/Products/Debug-iphonesimulator/libSimCamHook.dylib` —— universal + ad-hoc 签 ✅

**修法**：注入脚本只走 `Build/Products/Debug-iphonesimulator/` 路径（`scripts/inject-simulator.sh` 已写死）。手动注入时记得：

```bash
codesign -dvv Build/Products/Debug-iphonesimulator/libSimCamHook.dylib
# 期望：Identifier=libSimCamHook, Signature=adhoc
```

---

## 3. macOS 14+ `SCShareableContent` 在 TCC 拒绝时**不抛错**

**现象**：用户没给屏幕录制权限，`SCShareableContent.excludingDesktopWindows(...)` 仍然成功 await 返回，但 `displays` 数组永远空、`windows` 数组里所有 entry 的 `owningApplication == nil`。整段 UI 渲染成「无屏可选」，用户无法触发授权。

**根因**：macOS 14（Sonoma）开始 ScreenCaptureKit 在缺权限时进入「TCC 退化路径」——API 调用本身成功（return），但实际数据被掏空。

**修法**：用「`displays.isEmpty` 且 windows 全空 / 全无 owner」作为「未授权」的判定信号；UI 总是显示「Screen capture」分组，未授权时显示 `Grant Screen Recording` 按钮，点了显式调 `SCStream(filter:configuration:delegate:).startCapture()` 触发系统对话框。详见 [`ScreenSourceDiscovery.listWithAuth`](Sources/SimCamCore/FrameProducers.swift) 与 [`requestAuthorizationByProbingCapture`](Sources/SimCamCore/FrameProducers.swift)。

---

## 4. ad-hoc 签名导致 TCC 授权反复失效 —— 用 self-signed CA `SimCam Local Dev` 修

**现象**：每次重 build 后，「系统设置 → 隐私与安全性 → 屏幕录制 / 摄像头」里 SimCamApp 的勾仍然在，但实际授权早已失效。必须先到设置里**把 app 移除**、再重新打开 app 让它重弹一次对话框，才能恢复。每次 build 都要重来一遍，奇葩到怀疑人生。

**根因**：

TCC 的索引键不是 `(bundle-id, cdhash)`，而是 `(bundle-id, code signing requirement)`（俗称 DR / csreq）。这个 DR 的形态取决于签名方式：

| 签名方式 | DR 内容 | rebuild 后是否稳定 |
| --- | --- | --- |
| `codesign -s -` (ad-hoc) | `... certificate leaf = H"<cdhash>"` | ❌ 每次 build cdhash 变就废 |
| Apple Development（Personal Team 免费签） | `anchor apple generic and certificate leaf[subject.CN] = "Apple Development: <Apple ID>"` | ✅ 但**不能用**：Personal Team 不支持 System Extension capability，profile 直接报错 *"Personal development teams ... do not support the System Extension capability"* |
| Apple Developer Program ($99/年) | `... certificate leaf[subject.OU] = "<TeamID>"` | ✅ 但开源项目无法把团队私钥入仓共享 |
| **self-signed CA `SimCam Local Dev`** | `identifier "..." and certificate leaf[subject.CN] = "SimCam Local Dev"` | ✅ 锁 CN，cdhash 怎么变都不影响 |

Apple DTS Quinn 在 [forums/thread/819406](https://developer.apple.com/forums/thread/819406) / [forums/thread/678816](https://developer.apple.com/forums/thread/678816) 直接确认了"TCC needs a stable signing identity"。完整原理见 [docs/signing-and-tcc.md](docs/signing-and-tcc.md)。

**修法**（项目里已经做好了）：

1. **一次性生成本地 self-signed CA + 叶子证书** —— 私钥**不入仓**，每个开发者各自生成一份：
   ```bash
   make bootstrap-cert
   ```
   这条命令做的事：在 login.keychain-db 里生成一对 ECC P-256 key，CN = `SimCam Local Dev`，EKU = codeSigning，并把它标成"始终信任"。
2. **macOS 端**（host + system extension）签名走这张 CN：[SimCam.xcodeproj](SimCam.xcodeproj) 里 `SimCamApp` 和 `SimCamCameraExtension` 两个 target 的 `CODE_SIGN_IDENTITY = "SimCam Local Dev"`，配 Hardened Runtime + 必需的 entitlements（`system-extension.install` / `device.camera` / `device.audio-input` / `cs.disable-library-validation` / `application-groups`）。
3. **iOS 端**（hook dylib + demo app）继续 ad-hoc。原因：iOS Simulator 的 dyld 在被测进程是 ad-hoc 时不会接受签了非 ad-hoc cert 的注入 dylib；硬塞反而废掉注入路径。这两个 target 在 .pbxproj 里强制 `CODE_SIGN_IDENTITY = "-"`，**不要**改。
4. **一次性清掉旧 ad-hoc 残留**（很重要，否则旧 cdhash 条目还卡着）：
   ```bash
   make reset-tcc      # = scripts/reset-tcc.sh
   ```
   它会 `tccutil reset` Camera / Microphone / ScreenCapture / SystemPolicyAllFiles 这几条针对 `dev.simcam.app` 的记录，并提示你手动 `sudo rm -rf /Applications/SimCamApp.app` 清掉旧拷贝。
5. **重新装一遍** —— `make install` 会重签 + 拷到 `/Applications/`（sysextd 硬约束），`make run` 是 install + open 一条龙：
   ```bash
   make install        # 需要 sudo（写 /Applications/）
   make run
   ```
6. 重 build 后启动一次，**只**会再弹一次授权对话框；之后任意次重 build、重启都不再失效。

验证：

```bash
codesign -dvv /Applications/SimCamApp.app 2>&1 | grep -E 'Authority|Identifier'
# 期望：Authority=SimCam Local Dev
#       Identifier=dev.simcam.app

codesign -d --requirements - /Applications/SimCamApp.app 2>&1
# 期望含：identifier "dev.simcam.app"
#         and certificate leaf[subject.CN] = "SimCam Local Dev"

codesign -dvv build/Build/Products/Debug-iphonesimulator/libSimCamHook.dylib 2>&1 | grep -E 'Signature|TeamIdentifier'
# 期望：Signature=adhoc, TeamIdentifier=not set
```

---

## 5. `AVCaptureVideoPreviewLayer` 私有 ivar 崩溃

**现象**：被测 demo 启动后立刻 SIGSEGV，crash trace 在 `-[AVCaptureVideoPreviewLayer setBounds:]` 里。

**根因**：hook 里我们用 `class_createInstance(NSClassFromString(@"AVCaptureVideoPreviewLayer"), 0)` 绕过了 AVF 的私有 init，但这个类的 `setBounds:` / `setFrame:` / `layoutSublayers` / `display` 都依赖 init 时设置的私有 ivars，导致 deref 0x0。

**修法**：把这些方法 swizzle 成转发到 `CALayer` 的实现：

```objc
// SimCamHook.m
class_replaceMethod(cls, @selector(setBounds:),
    class_getMethodImplementation([CALayer class], @selector(setBounds:)),
    "v@:{CGRect={CGPoint=dd}{CGSize=dd}}");
// 同理 setFrame:, layoutSublayers, display
```

详见 [`SimCamHook.m`](Sources/SimCamHook/SimCamHook.m) 的 `simcam_install_preview_layer_overrides`。

---

## 6. `removeInput → addInput` 间隙的「闪一帧另一路」

**现象**：在 back 摄像头运行时，**偶尔**会闪一下 front 的画面（不是切换的时候，是稳定运行中）。

**根因**：被测 demo（譬如 SwiftUI 的 `updateUIView`）有时会先 `session.removeInput(cur)` 再 `session.addInput(new)`。在两者之间的极短窗口里，hook 的 `simcam.inputs` shadow 数组**短暂为空**，`simcam_session_slot()` 默认 fallback 到 BACK，把 front host 帧错路由到 back layer。

**修法**：

1. `simcam_session_slot()` 空 inputs 不再默认返回 BACK，而是读 `simcam.lastSlot` 缓存或返回 `-1`；
2. `simcam_dispatch_sample` / `simcam_dispatch_metadata` / `simcam_render_preview` 看到 `slot < 0` 直接跳帧；
3. `addInput:` 时 eager 把成功解析的 slot 写入 `simcam.lastSlot`，之后 `removeInput:` 不清这个缓存；
4. `addInput:`/`addOutput:`/`removeInput:`/`removeOutput:` 全部加 `@synchronized(self)` 锁。

详见 [`simcam_session_slot`](Sources/SimCamHook/SimCamHook.m)。

---

## 7. SwiftUI Picker 闪烁 / 误触 menubar 关闭

**现象**：在 menubar popover 里点一个 `Picker`，popover 自动关闭。

**根因**：NSPopover.behavior = `.transient`，任何 keyWindow 切换都会关。SwiftUI 的 menu picker 实现在某些 macOS 版本上 internal 切了 keyWindow。

**修法**：

- 把 popover.behavior 改成 `.semitransient`；
- 或者把 picker 替换成自定义 `Menu { Button } label:` 形式（SwiftUI 原生菜单不切 keyWindow）。

---

## 8. `xcodebuild -scheme SimCam` 不 build `SimCamHook`，多次组合命令时容易踩

**现象**：CI 脚本 `xcodebuild -scheme SimCam build && open SimCamApp.app && ./inject-simulator.sh` 跑通了但行为是上一次的。

**根因**：参见 §1。

**修法**：始终两条命令都跑：

```bash
xcodebuild -scheme SimCam     -derivedDataPath build/SimCamDD     build
xcodebuild -scheme SimCamDemo -derivedDataPath build/SimCamDemoDD \
  -sdk iphonesimulator -arch arm64 build
```

---

## 9. 「Simulator passthrough」default 看到的是整张 mac 桌面，不是 simulator 窗口背后

**现象**：默认 back source = `screen(displayID: 0, ...)` 时，iPhone preview 显示的是**整张 mac 桌面**等比缩进 9:16 buffer，上下大黑边。

**根因 + 修法**：

- ScreenCaptureKit 把横向 mac 桌面 letterbox 进 9:16 buffer 时主动加黑边——单纯改 layer.contentsGravity 救不回来；
- 真正想要的是 SimCam 商业版「相机透过 simulator 这个窗户看背后」效果：用 `SCStreamConfiguration.sourceRect` 把捕获区裁到 Simulator.app 窗口位置，并把 Simulator 窗口本身放进 `excludingWindows` 防止套娃；
- 用 timer 周期 `updateConfiguration` / `updateContentFilter` 跟随窗口移动；
- buffer 大小按 simulator 窗口 aspect 算，避免黑边。

详见 [`ScreenFrameProducer` followSimulator 路径](Sources/SimCamCore/FrameProducers.swift)。

---

## 10. 排查 checklist

遇到问题时按这个顺序过一遍：

1. SimCamApp 在「屏幕录制」权限里是否真的有效（不是只看开关）？
   - `tccutil reset ScreenCapture dev.simcam.app` 后从 menubar 的 `Grant Screen Recording` 按钮重新申请
2. 改了 hook 之后是否 build 了 **SimCamDemo** scheme？
3. `scripts/inject-simulator.sh` 用的 dylib 路径是否是 `Build/Products/Debug-iphonesimulator/`？
4. `xcrun simctl spawn booted log show --last 30s --predicate 'eventMessage CONTAINS "SimCamHook"'` 应至少有 `installed` + `connected to host frame socket` 两行
5. `lsof -U | grep simcam.frames.sock` 应有 SimCamApp 在 listen
6. 多 simulator 时 `inject-simulator.sh` 第二个参数显式传 udid

---

## 11. 常用命令汇总

```bash
# 全量重 build
xcodebuild -scheme SimCam     -configuration Debug -derivedDataPath build/SimCamDD build
xcodebuild -scheme SimCamDemo -configuration Debug -derivedDataPath build/SimCamDemoDD \
  -sdk iphonesimulator -arch arm64 build

# 启动宿主
open build/SimCamDD/Build/Products/Debug/SimCamApp.app

# 注入
bash scripts/inject-simulator.sh dev.simcam.demo

# 重置屏幕录制权限
tccutil reset ScreenCapture dev.simcam.app

# 看 simulator 里 hook 日志
xcrun simctl spawn booted log stream --level debug \
  --predicate 'eventMessage CONTAINS "SimCamHook"'

# 看 sysextd 日志（macOS path）
sudo log stream --predicate 'process == "sysextd"' --level info
```
