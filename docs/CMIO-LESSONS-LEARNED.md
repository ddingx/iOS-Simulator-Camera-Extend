# SimCam CMIO 实现踩坑历史（事后复盘）

> 本文档把 CMIO 链路调通过程中的现场快照、最终修复和长期教训合并到一处——尤其是早期实现*反复猜错*的几次反转、当时拿到了什么证据没用上、之后该怎么避免。
>
> 写这份文档的目的：避免后续 reviewer / 我自己重蹈覆辙——不要再删 entitlements、不要再猜 mach service name、不要再回到 IOSurface / framesock。

---

## 0. 一句话总结

**真正的 root cause**：
host 端 [CMIOSinkClient.findSinkStream()](Sources/SimCamCore/CMIOSinkClient.swift) 用 `kCMIOStreamPropertyDirection == 1` 来判断 sink stream，结果选错了 stream → 第一帧 `CMSimpleQueueEnqueue` 立刻返回 `-12773 / kCMSimpleQueueError_QueueIsFull` → host 把 demo 帧塞进错误 queue，sysext 端 `SimCamCMIOSinkSource.startStream()` 永远不触发，QuickTime 看到的是 source stream 自带的 demo 扫描线。

**正确的修法**：
按 stream **name** 优先匹配 `SimCam.Sink`，按 `addStream(source) → addStream(sink)` 的顺序作为兜底，`direction == 1` 降级为最后 fallback；同时在 `push()` 前先 `CMSimpleQueueGetCount`/`GetCapacity` 防止往满 queue 里塞，遇满立即 `resetSinkConnection` + rediscover。

**早期实现反复猜错的原因**（也就是这份文档的主题）：
没有先把 device 的 streams 整个枚举出来打日志（`index/id/name/direction`），就直接相信 `direction==1` 是 sink。在底层 API 没核对的前提下去猜更上层的 entitlements / signing / activation policy，导致一晚上在错的层级反复打补丁。

---

## 1. 反转表（按时间顺序）

> 结论列含义：**保留** = 留下了正面贡献的修改；**撤回** = 没有证据 / 已回滚；**半对** = 部分对部分错。

| # | 假设 | 结论 | 撤回 / 保留理由 |
|---|---|---|---|
| 1 | "macOS 26 cmiod 故意不让自家 host 看自家 sysext"（"loopback shielding"） | 撤回 | 一段无 entitlement 的独立 swift 脚本在同机器同时段 enumerate 看到 SimCam Virtual Camera，反证之 |
| 2 | "sysext Info.plist `CMIOExtensionMachServiceName` 缺 TeamID 前缀是根因" | 撤回 | 当时 QuickTime 已能选到 device 看到扫描线，证明 sysext 已经被 cmiod 接受；删 TeamID 前缀也没影响这条路径 |
| 3 | "sysext 端要先 `addStream` 再 `provider.addDevice`，否则 cmiod 把 device 视作零流" | 保留 | 改完跟 ldenoue/fuziki 对齐，没有打破任何东西，保留 |
| 4 | "`legacyDeviceID` 必须填 `deviceID.uuidString` 而不是 `nil`" | 保留 | 跟参考项目一致，保留 |
| 5 | "`var stream = nil` + `super.init()` 之后再 `self.stream = CMIOExtensionStream(..., source: self)` 比 placeholder shim 干净" | 保留 | 跟参考项目一致，保留 |
| 6 | "`com.apple.security.application-groups` 让 cmiod 把 host 当 sysext 自家父 app 做'回环屏蔽'，必须删掉" | 撤回（**直接造成 `extension category returned error` / 起不来**） | 删除后 sysextd 立刻拒绝激活；恢复后 `OSSystemExtensionRequest` 变正常的 _await user approval_ → _activated_。已强制回滚并在 [SimCamApp.entitlements](Sources/SimCamApp/Resources/SimCamApp.entitlements) 注释里禁止后人再删 |
| 7 | "25 个僵尸 `[terminated waiting to uninstall on reboot]` 阻塞激活，必须重启" | 撤回 | 没有任何 sysextd reject log 支持；同时拿 ldenoue 项目对照，僵尸只是视觉上难看，实际不阻塞激活。已撤回 [scripts/install-systemext.sh L50-L62](scripts/install-systemext.sh#L50-L62) 阈值 `exit 1` |
| 8 | "`kCMIOStreamPropertyDirection == 1` 一定就是 sink stream" | 撤回（**真正的 root cause**） | host 第一帧 `CMSimpleQueueEnqueue` 返回 `-12773 / QueueIsFull`，sysext 端没有任何 sink `startStream()` 触发；说明根本没在向真正的 `SimCam.Sink` 塞帧。修复方案改成按 stream **name** 优先匹配。修复后 QuickTime 实时画面正常 |
| 9 | "QuickTime 看到扫描线 = source stream 没发布" | 撤回 | 扫描线恰好是 [SimCamCMIOStreamSource.tickDemo()](Sources/SimCamExtension/SimCamCMIODevice.swift) 的 demo fallback。出现扫描线证明 **source stream 已经在跑**，问题在 sink 链路 |

---

## 2. 各阶段拿到了哪些"用得上但没用上"的证据

后视镜里看，每一个错误反转都有一条本来该用、却没用上的反证：

### 2.1 反转 #1（"cmiod 屏蔽自家 host"）的反证

> 写一段最小 swift 脚本（无 entitlement、无 sandbox、无 group），在同机器同时段跑——它能看到 `SimCam Virtual Camera`。

应该立刻得出结论：**sysext 已经在 cmiod 里正确发布**，host 看不到是 host 进程一侧的事。但当时被 "host 看不到 = sysext 没注册" 这个先入为主的假设带偏了，去查签名、entitlements。

### 2.2 反转 #2（"mach service name 缺 TeamID 前缀"）的反证

> QuickTime 当时已经能在 picker 里选到 SimCam Virtual Camera，并打开看到扫描线。

QuickTime 是系统级 camera picker，走的就是同一个 cmiod。如果 mach service name 真有问题，picker 不会显示该 device，更不会成功打开 source stream。这条已经证伪了 "service name 是根因"。

### 2.3 反转 #6（删 application-groups）的反证

> 项目从一开始 host + sysext 两边就有同名 `application-groups`，过去无数次激活都成功。删掉的当下没有任何 cmiod / sysextd log 指向 application-groups 是问题。

这是纯粹的 _猜测驱动改动_：为了配合反转 #1 的假设，瞎调一个变量。代价是 sysextd 直接拒激活，浪费一整轮 install。

### 2.4 反转 #7（"僵尸阻塞激活"）的反证

> sysextd 给的 error 字符串是 `extension category returned error`（[ExtensionActivator.swift L69-L73](Sources/SimCamApp/ExtensionActivator.swift#L69-L73) 的 `didFailWithError`）。这是 entitlement / category 配置错的标准错误，跟 zombie 数量无关。

这条错误信息本身就是答案，但当时已经被反转 #6 的 "我刚动过 entitlements" 吓到不愿意承认是 #6 引起的，转去挑了一个看起来更安全的解释（zombie 太多）。

### 2.5 反转 #8（`direction==1` 当 sink）的反证

> host 端日志：`CMSimpleQueueEnqueue failed status=-12773`，并且**第一帧**就 -12773。同时 sysext 端**完全没有** `SimCam sink startStream entered`、没有 `consumeSampleBuffer`。

`-12773 = kCMSimpleQueueError_QueueIsFull`。如果一开始 queue 就是满的，意味着这个 queue **不是** sysext 在等的那个 queue（sysext 那边没人在消费它，所以 cap=10 立刻满）。同时 sink 端从来没 `startStream`，证明 host 根本没启动 `SimCam.Sink` 这个 stream。

这两条 log 摆在那里，但当时没去做最简单的事：**枚举 device 的所有 streams，把每条的 `name / id / direction` 全打出来**。直到后续修复轮才补上。

---

## 3. 最关键的方法论教训

### 3.1 在 CMIO 这种 C API 层，**先枚举、先打日志**，不要相信单一标志

```swift
var streamIDs = [CMIOObjectID](repeating: 0, count: 16)
var dataSize: UInt32 = 0
var addr = CMIOObjectPropertyAddress(
    mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyStreams),
    mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
    mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
// ... 拿到 streamIDs
for sid in streamIDs {
    let name = copyStringProperty(sid, kCMIOObjectPropertyName)
    let direction = copyUInt32Property(sid, kCMIOStreamPropertyDirection)
    log("stream candidate id=\(sid) name=\(name ?? "?") direction=\(direction)")
}
```

这种 5 行 boilerplate 哪怕只在 dev 模式打一次，就能避免反转 #8。教训：**调 C API 永远先把它返回的所有字段打出来核对**，不要只读自己关心的那个字段就过。

### 3.2 错误码必须查表，不能靠猜

`-12773` 在 CoreMedia framework header `CMSimpleQueue.h` 里有明确的命名常量 `kCMSimpleQueueError_QueueIsFull`。一旦看到 OSStatus，**第一时间** `grep -r "12773" /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs` 或 `xcrun --sdk macosx --show-sdk-path` 下找命名常量。靠 "可能是权限错误吧" 之类的语义猜会无限发散。

### 3.3 错误信息字符串本身往往就是答案

`extension category returned error` 这一句对应的就是 `OSSystemExtensionRequest` 在 entitlement / category 校验阶段拒绝。看到它**第一反应**应该是 "我刚动过的 entitlements 有问题"，而不是去想 "也许是 zombie / 也许是 macOS 26 怪行为"。

### 3.4 改一个变量之前先证明它跟症状有因果

反转 #6 的删除完全没有"如果它有锅，应该有 X 现象"的预测。改完之后 sysextd 立刻给负反馈（reject 激活），但当时甚至没把这个 reject 跟自己刚动的 entitlements 联系起来。**所有改动都要带"如果改对了应该看到 A，改错了应该看到 B"的可证伪预测**。

### 3.5 不要跨层乱跳

栈是这样的：

```
QuickTime
  ↓ (CMIO API)
cmiod (system daemon)
  ↓ (XPC)
SimCamExtension (sysext)
  ↑ (CMSimpleQueue / sink)
SimCamApp (host)
```

正确顺序：**先确定下层 OK，再往上走**。

- sysext 注册 → 看 `systemextensionsctl list` + 独立 swift script enumerate
- sysext source stream → 看 QuickTime 能否选到 + 看扫描线（出现扫描线就 OK）
- sink stream 选择 → 枚举 streams 看 name/direction
- sink push → 看 `CMSimpleQueueEnqueue` 状态码、count、cap
- alteredProc ack → 看 `CMIODeviceStreamQueueAlteredProc` 触发频率

早期实现一晚上做的：sysext 还没确认完就跳到签名，签名没核对完就跳到 entitlements，entitlements 没核对完就跳到 mach service name，最后被一个上层 daemon 反馈带回来，把同一层再走一遍。**至少多耗了 5 个 install 循环**。

---

## 4. 哪些"长期不要回退的方向"

这部分是给后人的红线，请保留：

1. **不要把 `application-groups` 从 [SimCamApp.entitlements](Sources/SimCamApp/Resources/SimCamApp.entitlements) 或 [scripts/install-systemext.sh L101-L132](scripts/install-systemext.sh#L101-L132) 删除**。删除会破坏 OSSystemExtensions host↔sysext ownership 契约，sysextd 直接拒激活。
2. **不要把扫描线当成 source stream 没发布**。扫描线 = [SimCamCMIOStreamSource.tickDemo()](Sources/SimCamExtension/SimCamCMIODevice.swift) 的 demo fallback，出现它恰好证明 source stream 已经在跑。
3. **不要回到 IOSurface + Darwin notify 桥方案**。sandbox EPERM `/tmp` + Group Container 跨进程隔离，已证伪。
4. **不要回到 framesock IPC 替代 CMIO**。这是用户红线："我们就是做 CMIO，你放弃 CMIO 那还做什么"。framesock 留着只给 iOS Simulator dylib 注入用。
5. **不要把 `kCMIOStreamPropertyDirection == 1` 当成识别 sink stream 的可靠判据**。优先按 name (`SimCam.Sink`)，再按 `addStream` 顺序，`direction` 只能做最后 fallback。
6. **不要遇到 `kCMSimpleQueueError_QueueIsFull` 还继续 enqueue**。它是"队列健康度"的信号，遇到就要 `resetSinkConnection` + rediscover，否则会无限堆错帧。
7. **不要"重启 = 万能修复"**。zombie sysext 条目只在视觉上烦，不阻塞激活。

---

## 5. 这次能跑通的链路全图（备查）

```text
SimCamApp (host process)
  │
  ├─ ExtensionActivator.activate()
  │     ├─ OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: "dev.simcam.app.extension")
  │     ├─ requestNeedsUserApproval → System Settings 弹"允许扩展"
  │     └─ didFinishWithResult = .completed
  │           sysextd 把 sysext 拉起来，cmiod 接管 device 注册
  │
  ├─ CMIOSinkClient.start()
  │     ├─ kCMIOHardwarePropertyAllowScreenCaptureDevices = 1
  │     ├─ AVCaptureDevice.DiscoverySession → SimCam Virtual Camera (uniqueID)
  │     ├─ HAL kCMIOHardwarePropertyDevices → CMIODeviceID
  │     ├─ enumerate device streams
  │     │     - stream candidate name="SimCam.Stream" direction=0
  │     │     - stream candidate name="SimCam.Sink"   direction=1
  │     │     → selected sink stream by name "SimCam.Sink"
  │     ├─ CMIOStreamCopyBufferQueue(sinkStreamID, alteredProc, ...) → CMSimpleQueueRef
  │     ├─ CMIODeviceStartStream(deviceID, sinkStreamID)
  │     └─ push loop:
  │           if CMSimpleQueueGetCount < GetCapacity:
  │               CMSimpleQueueEnqueue(sample) → 0
  │           else:
  │               wait alteredProc ack OR resetSinkConnection
  │
SimCamExtension (sysext process)
  │
  ├─ SimCamCMIOSinkSource (CMIOExtensionStream direction=.sink)
  │     ├─ shouldEnqueue = true → cmiod 推 sample 进来
  │     ├─ startStream() entered ← host 端 CMIODeviceStartStream 触发
  │     └─ consumeSampleBuffer(from:) ← 真画面
  │
  ├─ SimCamCMIOStreamSource (CMIOExtensionStream direction=.source)
  │     ├─ startStream() entered ← QuickTime 选中并打开 device 时触发
  │     ├─ if 有 host 帧 → handleRealSampleBuffer() → stream.send(realSample)
  │     └─ else → tickDemo() 发扫描线 fallback
  │
QuickTime
  └─ AVCaptureSession with SimCam Virtual Camera
        → 看到真实 camera 画面
```

---

## 6. 反思：能不能更早发现真问题

**能**。其实这一晚上有三个明确的"如果当时停下来枚举一下就解决了"的时点：

1. 第一次看到 `CMSimpleQueueEnqueue failed status=-12773` 的时候，应该立刻 grep header 找命名常量、立刻枚举 device.streams 打 name。
2. 第一次看到 sysext 端没有 `SimCam sink startStream entered` 的时候，应该立刻怀疑 host 没在向 `SimCam.Sink` 塞帧（而不是怀疑 sysext 没注册）。
3. 第一次未经验证就删 `application-groups` 之前，应该问自己一句"我有任何证据这个 key 跟症状有因果吗？" —— 答：没有。

但事实上，早期实现把这三次机会都浪费了，每一次都跳到更上层的 entitlements / signing / activation policy 去乱猜。修复轮顶替之后，做的第一件事就是补回最朴素的枚举日志，然后顺着 `-12773` 这条线一次锁定根因。

---

## 7. 参考实现

- [ldenoue/cameraextension](https://github.com/ldenoue/cameraextension) — paid TeamID `388X9C8CWR`
- [fuziki/CameraEX](https://github.com/fuziki/CameraEX) — 用 `$(TeamIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)` 模板

下次再有 sink stream 类问题，**第一步**应该是去这两个仓库 grep `findSinkStream` / `kCMIOStreamPropertyDirection` / `CMIOStreamCopyBufferQueue` 看人家怎么选 stream，而不是去看人家的 entitlements。

---

## 8. 关联文档

- [docs/signing-and-tcc.md](docs/signing-and-tcc.md) — 自签 cert / Personal Team / 重签流程
- [docs/no-developer-account.md](docs/no-developer-account.md) — 没有 paid Apple Developer Program 时的限制
- [docs/permissions-and-flow.md](docs/permissions-and-flow.md) — TCC、Camera、Screen Capture 的权限链
