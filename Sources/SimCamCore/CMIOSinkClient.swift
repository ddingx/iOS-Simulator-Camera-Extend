import Foundation
import AVFoundation
import CoreMedia
import CoreMediaIO
import CoreVideo
import os.log

/// CMIOSinkClient
///
/// host (SimCamApp) → CMIO Camera Extension 的帧通道 = **Apple 官方 sink stream**。
///
/// 工作流程（参考 fuziki/CameraEX + Apple DTS Quinn forums/706184）：
///
/// 1. discover：用 `AVCaptureDevice.DiscoverySession(deviceTypes:[.externalUnknown])`
///    拿到 SimCam Virtual Camera 的 `AVCaptureDevice`，再用 uniqueID 反查
///    出对应的 `CMIODeviceID`。
/// 2. locate sink stream：device 上枚举 streams，优先按 stream name 选择
///    `SimCam.Sink`。不要只靠 direction 猜；不同层暴露出来的 direction
///    语义很容易把 source/sink 搞反。
/// 3. 拿 sink stream 的 `CMSimpleQueue`：
///    `CMIOStreamCopyBufferQueue(streamID, …) -> CMSimpleQueueRef`，
///    （在 host 端 enqueue，sysext 端的 `consumeSampleBuffer` 闭包会被
///    cmiod 自动调到。）
/// 4. push：每帧 `CMSimpleQueueEnqueue(queue, buffer)`。
///
/// **历史**：之前曾断言 cmiod 对自家 host 隐藏自家 sysext device，写了
/// 一条 IOSurface + Darwin notify 桥的 plan B；但 sysext sandbox 实测
/// EPERM `/tmp` + ENOENT App Group container（`/private/var/db/cmiodalassistants/`
/// 与 `~/Library/Group Containers/` 跨进程隔离），plan B 是死路。
/// fuziki/CameraEX 项目证明同 app bundle 既 publish 又消费**完全可行**，
/// 关键是 enumerate 时**必须**用 `.externalUnknown`（macOS 13）/`.external`
/// （macOS 14+），而不是直接 `kCMIOHardwarePropertyDevices`。
public final class CMIOSinkClient {

    private let log = OSLog(subsystem: "dev.simcam", category: "cmio.sink")
    private let lock = NSLock()
    private var running = false

    /// 已经 enqueue 过帧（用于 isLive）。
    private var enqueuedCount: UInt64 = 0
    private var lastPublishWallClock: TimeInterval = 0
    private let enqueueAckTimeout: TimeInterval = 2.0

    /// 找到 sink stream 后的句柄。三个一组缓存避免每帧都 enumerate。
    private var deviceID: CMIODeviceID = 0
    private var sinkStreamID: CMIOStreamID = 0
    private var sinkQueue: CMSimpleQueue?

    /// CMIO sink stream 流控：host 必须在 cmiod 回调 `queueAlteredProc` 后
    /// 才能再 enqueue 下一帧（双握手）。否则 cmiod 默认认为 host 没准备好，
    /// 直接不把 buffer 派发给 sysext consumeSampleBuffer，结果 sysext 永远
    /// 拿不到帧（queue depth 一直顶满）。这是 fuziki/CameraEX 实战项目里
    /// `shouldEnqueue` 闸门的精髓。
    private var shouldEnqueue: Bool = false

    /// 后台 retry 定时器：第一次启动时 sysext 可能还没起来，间隔重试。
    private var discoverTimer: DispatchSourceTimer?

    public init() {}

    /// host 是否最近一秒在推帧（diagnose() 用）。
    public var isLive: Bool {
        lock.lock(); defer { lock.unlock() }
        guard running else { return false }
        return (Date().timeIntervalSince1970 - lastPublishWallClock) < 1.0
    }

    /// host 端启动：尝试 discover sink stream。如果失败（sysext 还没注册），
    /// 后台周期性重试，直到 sysext 上线或 stop()。
    public func start() {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        discoverTickCount = 0
        lastPublishWallClock = 0
        lock.unlock()

        os_log("CMIOSinkClient.start() — looking up SimCam Virtual Camera sink stream",
               log: log, type: .default)
        // 关键：先 opt-in `kCMIOHardwarePropertyAllowScreenCaptureDevices`，
        // 否则 cmiod 默认不把 screen-capture / virtual 类 device 暴露给当前
        // 进程的 HAL enumerate（这是 ldenoue/cameraextension 实战项目里
        // 关键的 makeDevicesVisible() 开关，长期被忽视）。
        Self.allowVirtualDeviceVisibility(log: log)
        scheduleDiscovery()
    }

    public func stop() {
        lock.lock()
        let oldDeviceID = deviceID
        let oldSinkStreamID = sinkStreamID
        running = false
        sinkQueue = nil
        deviceID = 0
        sinkStreamID = 0
        shouldEnqueue = false
        lastPublishWallClock = 0
        lock.unlock()
        discoverTimer?.cancel()
        discoverTimer = nil
        if oldDeviceID != 0 && oldSinkStreamID != 0 {
            CMIODeviceStopStream(oldDeviceID, oldSinkStreamID)
        }
        os_log("CMIOSinkClient.stop()", log: log, type: .default)
    }

    /// producer 回调进来一帧 sample buffer 就 enqueue 给 sink stream。
    /// 调用线程：producer 后台 queue。
    public func push(_ sample: CMSampleBuffer) {
        let now = Date().timeIntervalSince1970
        lock.lock()
        if running,
           sinkQueue != nil,
           !shouldEnqueue,
           lastPublishWallClock > 0,
           now - lastPublishWallClock > enqueueAckTimeout {
            lock.unlock()
            resetSinkConnection(reason: "no alteredProc ack after enqueue; rediscovering sink stream")
            return
        }
        let isRunning = running
        let q = sinkQueue
        let canEnqueue = shouldEnqueue
        let currentStreamID = sinkStreamID
        lock.unlock()
        guard isRunning else { return }
        guard let queue = q else {
            // sink 还没找到（sysext 没起来 / device 还没出现）—— 跳过这一帧
            return
        }
        // 双握手：等 cmiod alteredProc 回来再推下一帧。否则 cmiod 不会把
        // queue 里的 buffer 派发给 sysext consumeSampleBuffer，导致表面看
        // queue depth=cap 顶满，但 sysext 那边一帧都收不到。
        guard canEnqueue else { return }

        let depthBefore = CMSimpleQueueGetCount(queue)
        let capacity = CMSimpleQueueGetCapacity(queue)
        guard capacity > 0, depthBefore < capacity else {
            resetSinkConnection(
                reason: "sink queue full before enqueue; stream=\(currentStreamID) depth=\(depthBefore) cap=\(capacity)"
            )
            return
        }

        let unmanaged = Unmanaged.passRetained(sample)
        let status = CMSimpleQueueEnqueue(queue, element: unmanaged.toOpaque())
        if status != noErr {
            unmanaged.release()
            let depthAfterFailure = CMSimpleQueueGetCount(queue)
            os_log("CMSimpleQueueEnqueue failed status=%{public}d stream=%{public}u depth=%{public}d cap=%{public}d",
                   log: log, type: .error,
                   Int(status), currentStreamID, Int(depthAfterFailure), Int(capacity))
            if status == kCMSimpleQueueError_QueueIsFull {
                resetSinkConnection(
                    reason: "sink queue full on enqueue; stream=\(currentStreamID) depth=\(depthAfterFailure) cap=\(capacity)"
                )
            }
            return
        }

        lock.lock()
        // 关闸：等 alteredProc 重新打开
        shouldEnqueue = false
        enqueuedCount &+= 1
        let n = enqueuedCount
        lastPublishWallClock = now
        lock.unlock()

        if n == 1 || n % 30 == 0 {
            os_log("cmio sink push #%{public}llu (queue depth=%{public}d, gate closed waiting alteredProc)",
                   log: log, type: .default, n, Int(CMSimpleQueueGetCount(queue)))
        }
    }

    // MARK: - private discovery

    /// 用来限频打 retry log，避免 1Hz 刷屏。每 5 次（≈5s）打一次进度。
    private var discoverTickCount: UInt64 = 0

    private func scheduleDiscovery() {
        discoverTimer?.cancel()
        let q = DispatchQueue(label: "dev.simcam.cmio.sink.discover", qos: .userInitiated)
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now(), repeating: .seconds(1))
        t.setEventHandler { [weak self] in self?.tryDiscover() }
        discoverTimer = t
        t.resume()
    }

    private func tryDiscover() {
        lock.lock()
        let isRunning = running
        let alreadyFound = (sinkQueue != nil)
        discoverTickCount &+= 1
        let tick = discoverTickCount
        lock.unlock()
        guard isRunning else { return }
        if alreadyFound { return }

        let logProgress = (tick == 1 || tick % 5 == 0)

        // ---- 重 opt-in 时机（保守）----
        // macOS 26 实测：`kCMIOHardwarePropertyAllowScreenCaptureDevices=1` 是
        // 一次性 set 时刻 cmiod 才把"当前已注册的 virtual / sysext device"加入
        // visible 列表。如果 sysext 在 set 之后才 addDevice 完成，cmiod 不会
        // 自动重新计算 visibility，host HAL 永远只看到内置 device。
        //
        // 但是**每秒重 set** 会把 sysext 的 stream 实例打成"每秒重 init 一次"
        // 的不稳定状态（log 实测：sysext 每 1s 都在 _initWithLocalizedName/
        // streamID/direction）—— sysext 永远没法跑完 addDevice/addStream succeeded。
        //
        // 折中：每 10 个 tick（≈10s）重 set 一次，给 sysext 时间稳定下来。
        if tick > 1 && tick % 10 == 0 {
            Self.allowVirtualDeviceVisibility(log: log, silent: true)
        }

        // ---- 双路 discover：AVFoundation 优先（Apple DTS 推荐），HAL 兜底 ----
        // Apple DevForum thread/718128 DTS 工程师明确建议：
        //   "Get a list of cameras with AVCaptureDeviceDiscoverySession, find
        //    the one with the localizedName that you want, then get its ID
        //    using kCMIODevicePropertyDeviceUID."
        //
        // 之前完全跳过 AVFoundation 直接走 HAL by hardcoded UID 是个误判：
        // `system_profiler SPCameraDataType` 已实测看到 SimCam Virtual Camera，
        // 说明系统级别 device 是公开的，AVFoundation 应该也能看到。HAL by UID
        // 失败可能是 cmiod 在 host 进程身份这一侧对 HAL 全量 list 做了过滤
        // （但 AVFoundation enumerate 走另一条 path 不受影响）。
        var cmioDeviceID: CMIODeviceID = 0
        if let avDevice = findVirtualCameraAVDevice() {
            os_log("tick=%{public}llu: AVFoundation discovered name=%{public}@ uid=%{public}@",
                   log: log, type: .default,
                   tick, avDevice.localizedName, avDevice.uniqueID)
            // 用 AVFoundation 报上来的 uniqueID 反查 CMIODeviceID（HAL 这一步
            // 通常能成功，因为我们已经知道 device 真实存在）。
            if let id = lookupCMIODeviceIDByUID(avDevice.uniqueID, tick: tick, logProgress: false) {
                cmioDeviceID = id
            }
        }

        // HAL fallback：用预编固定 UID 直接查（兼容老路径，AVFoundation 真挂时兜底）。
        if cmioDeviceID == 0 {
            guard let id = lookupCMIODeviceIDByUID(
                CameraDiscovery.virtualCameraDeviceUID,
                tick: tick, logProgress: logProgress) else {
                return
            }
            cmioDeviceID = id
        }
        os_log("tick=%{public}llu: HAL CMIODeviceID=0x%{public}x for SimCam Virtual Camera",
               log: log, type: .default, tick, cmioDeviceID)
        guard let sinkStreamID = findSinkStream(deviceID: cmioDeviceID) else {
            os_log("device 0x%{public}x has no sink stream yet (tick=%{public}llu)",
                   log: log, type: .default, cmioDeviceID, tick)
            return
        }
        guard let queue = copySinkQueue(streamID: sinkStreamID) else {
            os_log("CMIOStreamCopyBufferQueue for sink %{public}u returned nil",
                   log: log, type: .error, sinkStreamID)
            return
        }
        // 必须告诉 cmiod 我们要"开始"这条 sink stream，否则 enqueue 不会
        // 触发 sysext 端 consumeSampleBuffer。
        let startStatus = CMIODeviceStartStream(cmioDeviceID, sinkStreamID)
        if startStatus != noErr {
            os_log("CMIODeviceStartStream(sink) failed status=%{public}d",
                   log: log, type: .error, Int(startStatus))
            return
        }

        lock.lock()
        self.deviceID = cmioDeviceID
        self.sinkStreamID = sinkStreamID
        self.sinkQueue = queue
        // 初始放行：让第一帧能入队，之后由 alteredProc 回调严格双握手。
        // 这是 fuziki/CameraEX `startStream` 末尾 `shouldEnqueue = true` 的等价。
        self.shouldEnqueue = true
        self.lastPublishWallClock = 0
        lock.unlock()
        os_log("cmio sink discover succeeded: device=0x%{public}x sink stream=%{public}u queue depth=%{public}d cap=%{public}d (gate open for 1st frame)",
               log: log, type: .default,
               cmioDeviceID, sinkStreamID,
               Int(CMSimpleQueueGetCount(queue)), Int(CMSimpleQueueGetCapacity(queue)))

        // 找到了就停掉 retry timer
        discoverTimer?.cancel()
        discoverTimer = nil
    }

    /// step 1: AVFoundation 层 enumerate 找自家 SimCam Virtual Camera。
    ///
    /// 关键坑：macOS 14+ Apple 把 `.externalUnknown` deprecate 后，**仅传一种
    /// type 是不够的** —— 不同 macOS 版本对自家 sysext 注册的 device 归类不
    /// 一致（13 是 `.externalUnknown`、14+ 是 `.external`、26 实测有时归
    /// 到 `.continuityCamera` 桶）。所以这里**多 type 全打开**，最后再用
    /// `system_profiler SPCameraDataType` 已确认存在的 fallback：直接走
    /// 老式的 `AVCaptureDevice.default(for:)` + `devices(for:)` 兜底。
    private func findVirtualCameraAVDevice() -> AVCaptureDevice? {
        var types: [AVCaptureDevice.DeviceType] = []
        if #available(macOS 14.0, *) {
            types.append(.external)
            types.append(.continuityCamera)
            types.append(.deskViewCamera)
        }
        // .externalUnknown 在 macOS 13 还有用；在 14+ 是 deprecated 但仍可填，
        // 作为多版本兜底统一写。
        types.append(.externalUnknown)
        types.append(.builtInWideAngleCamera)

        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: .unspecified)
        let needle = CameraDiscovery.virtualCameraName.lowercased()
        let allDevices = session.devices

        if let hit = allDevices.first(where: { $0.localizedName.lowercased().hasPrefix(needle) }) {
            return hit
        }

        // 兜底：AVCaptureDevice.devices(for: .video) 在 macOS 26 仍然返回所有
        // 已注册的 video device（包括我们自家 sysext）—— `system_profiler`
        // 已经确认设备在系统里，AVFoundation 必然也能看到，只是不在 DiscoverySession
        // 的某个 deviceTypes 桶里。
        let legacy = AVCaptureDevice.devices(for: .video)
        if let hit = legacy.first(where: { $0.localizedName.lowercased().hasPrefix(needle) }) {
            os_log("findVirtualCameraAVDevice: hit via legacy devices(for:.video) — DiscoverySession bucket missing for this macOS",
                   log: log, type: .default)
            return hit
        }

        // 还是没找到 —— 把 enumerate 到的所有 video device 一次性列出来，
        // 方便看 SimCam 实际被归到了什么 bucket / 名字 / uid。
        if !allDevices.isEmpty || !legacy.isEmpty {
            for d in allDevices {
                os_log("session enum: type=%{public}@ name=%{public}@ uid=%{public}@",
                       log: log, type: .default,
                       d.deviceType.rawValue, d.localizedName, d.uniqueID)
            }
            for d in legacy where !allDevices.contains(d) {
                os_log("legacy enum: type=%{public}@ name=%{public}@ uid=%{public}@",
                       log: log, type: .default,
                       d.deviceType.rawValue, d.localizedName, d.uniqueID)
            }
        }
        return nil
    }

    /// step 2: 用 AVCaptureDevice.uniqueID 反查 CMIODeviceID。
    /// 走 `kCMIOHardwarePropertyDevices` 拿 device list，再用
    /// `kCMIODevicePropertyDeviceUID` 比对——这是 fuziki 项目的关键步骤。
    private func lookupCMIODeviceID(uniqueID: String) -> CMIODeviceID? {
        return lookupCMIODeviceIDByUID(uniqueID, tick: 0, logProgress: false)
    }

    /// HAL 层直接扫所有 CMIODeviceID，把 deviceUID 字符串与 needle 对比。
    /// 跟 AVFoundation `DiscoverySession` 完全无关 —— cmiod 在 HAL 层
    /// 不对自家 host 屏蔽自家 sysext device（已用 system_profiler 旁证）。
    /// 找不到时（在 logProgress=true 的 tick）把 HAL 全量 device 的 UID
    /// dump 出来，便于看 UID 字符串实际长什么样。
    private func lookupCMIODeviceIDByUID(
        _ needleUID: String,
        tick: UInt64,
        logProgress: Bool
    ) -> CMIODeviceID? {
        let object = CMIOObjectID(kCMIOObjectSystemObject)
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var dataSize: UInt32 = 0
        var dataUsed: UInt32 = 0
        var status = CMIOObjectGetPropertyDataSize(object, &addr, 0, nil, &dataSize)
        if status != noErr || dataSize == 0 {
            if logProgress {
                os_log("tick=%{public}llu: HAL kCMIOHardwarePropertyDevices size=0 (status=%{public}d)",
                       log: log, type: .default, tick, Int(status))
            }
            return nil
        }
        let count = Int(dataSize) / MemoryLayout<CMIODeviceID>.size
        let buf = UnsafeMutablePointer<CMIODeviceID>.allocate(capacity: count)
        defer { buf.deallocate() }
        status = CMIOObjectGetPropertyData(object, &addr, 0, nil, dataSize, &dataUsed, buf)
        if status != noErr { return nil }
        let devices = UnsafeBufferPointer(start: buf, count: count)
        let needleLower = needleUID.lowercased()
        var foundUIDs: [(CMIODeviceID, String)] = []
        for did in devices {
            let uid = stringProperty(object: did,
                                     selector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID)) ?? "<nil>"
            foundUIDs.append((did, uid))
            if uid.lowercased() == needleLower || uid.lowercased().contains(needleLower) {
                return did
            }
        }
        // needle 没命中。若到了 progress 节奏，把 HAL 看到的所有 device UID 列出。
        if logProgress {
            os_log("tick=%{public}llu: HAL has %{public}d device(s), none match UID needle=%{public}@",
                   log: log, type: .default,
                   tick, foundUIDs.count, needleUID)
            for (did, uid) in foundUIDs {
                let name = stringProperty(object: did,
                                          selector: CMIOObjectPropertySelector(kCMIOObjectPropertyName)) ?? "<noname>"
                os_log("  HAL device=0x%{public}x name=%{public}@ uid=%{public}@",
                       log: log, type: .default, did, name, uid)
            }
        }
        return nil
    }

    /// step 3: 在 device 下枚举 streams，挑真正的 sink stream。
    ///
    /// 这里不能只按 `kCMIOStreamPropertyDirection == 1` 判断。实测 QuickTime
    /// 已经能启动 source stream，而 host 端第一帧 enqueue 就得到
    /// `kCMSimpleQueueError_QueueIsFull`；这非常像拿到了 source/output 侧的
    /// buffer queue。扩展发布时 sink stream 的 localizedName 固定为
    /// `SimCam.Sink`，所以 host 端优先按名字选它，再退回到"第二条 stream"
    /// （addStream 顺序为 source, sink），最后才保留 direction 兜底。
    private func findSinkStream(deviceID: CMIODeviceID) -> CMIOStreamID? {
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyStreams),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var dataSize: UInt32 = 0
        var dataUsed: UInt32 = 0
        var status = CMIOObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &dataSize)
        if status != noErr || dataSize == 0 { return nil }
        let count = Int(dataSize) / MemoryLayout<CMIOStreamID>.size
        let buf = UnsafeMutablePointer<CMIOStreamID>.allocate(capacity: count)
        defer { buf.deallocate() }
        status = CMIOObjectGetPropertyData(deviceID, &addr, 0, nil, dataSize, &dataUsed, buf)
        if status != noErr { return nil }
        let streams = Array(UnsafeBufferPointer(start: buf, count: count))
        var namedSink: CMIOStreamID?
        var secondStream: CMIOStreamID?
        var directionFallback: CMIOStreamID?

        for (index, sid) in streams.enumerated() {
            let name = stringProperty(
                object: sid,
                selector: CMIOObjectPropertySelector(kCMIOObjectPropertyName)
            ) ?? "<noname>"
            let direction = uint32Property(
                object: sid,
                selector: CMIOObjectPropertySelector(kCMIOStreamPropertyDirection)
            )
            let directionText = direction.map(String.init) ?? "<nil>"
            os_log("stream candidate index=%{public}d id=%{public}u name=%{public}@ direction=%{public}@",
                   log: log, type: .default,
                   index, sid, name, directionText)

            if namedSink == nil,
               name.range(of: "sink", options: [.caseInsensitive]) != nil {
                namedSink = sid
            }
            if index == 1, secondStream == nil {
                secondStream = sid
            }
            if let direction, direction == 1, directionFallback == nil {
                directionFallback = sid
            }
        }

        if let namedSink {
            os_log("selected sink stream by name: %{public}u",
                   log: log, type: .default, namedSink)
            return namedSink
        }
        if let secondStream {
            os_log("selected sink stream by source/sink add order fallback: %{public}u",
                   log: log, type: .default, secondStream)
            return secondStream
        }
        if let directionFallback {
            os_log("selected sink stream by direction fallback: %{public}u",
                   log: log, type: .default, directionFallback)
            return directionFallback
        }
        return nil
    }

    /// step 4: 拿 sink stream 的 input queue —— `CMIOStreamCopyBufferQueue`
    /// 的 callback (`CMIODeviceStreamQueueAlteredProc`) 是 cmiod 在 sysext
    /// 那边消费完一帧后回调过来的"放行信号"。fuziki/CameraEX 实战项目
    /// 把这个回调当作"双握手 ack"：每收到一次 ack 就把 `shouldEnqueue`
    /// 重新置 true，host 才能推下一帧。**没有这个握手，cmiod 不会把 host
    /// enqueue 的 buffer 派发给 sysext**——这就是 queue depth 顶满 + sysext
    /// 一帧都收不到的真根因。
    private func copySinkQueue(streamID: CMIOStreamID) -> CMSimpleQueue? {
        var queue: Unmanaged<CMSimpleQueue>?
        let refCon = Unmanaged.passUnretained(self).toOpaque()
        let proc: CMIODeviceStreamQueueAlteredProc = { _, _, refCon in
            guard let refCon else { return }
            let client = Unmanaged<CMIOSinkClient>.fromOpaque(refCon).takeUnretainedValue()
            client.onQueueAltered()
        }
        let status = CMIOStreamCopyBufferQueue(streamID, proc, refCon, &queue)
        if status != noErr { return nil }
        return queue?.takeRetainedValue()
    }

    /// cmiod 在 sysext 消费完一帧后回调进来 —— 打开 enqueue 闸门。
    private func onQueueAltered() {
        lock.lock()
        let firstAck = (enqueuedCount > 0) && !shouldEnqueue
        shouldEnqueue = true
        let n = enqueuedCount
        lock.unlock()
        if firstAck && (n == 1 || n % 30 == 0) {
            os_log("cmio sink alteredProc ack — gate reopened (after enqueue #%{public}llu)",
                   log: log, type: .default, n)
        }
    }

    private func resetSinkConnection(reason: String) {
        lock.lock()
        let shouldRestart = running
        let oldDeviceID = deviceID
        let oldSinkStreamID = sinkStreamID
        sinkQueue = nil
        deviceID = 0
        sinkStreamID = 0
        shouldEnqueue = false
        lastPublishWallClock = 0
        discoverTickCount = 0
        lock.unlock()

        if oldDeviceID != 0 && oldSinkStreamID != 0 {
            let status = CMIODeviceStopStream(oldDeviceID, oldSinkStreamID)
            if status != noErr {
                os_log("CMIODeviceStopStream during reset failed status=%{public}d",
                       log: log, type: .error, Int(status))
            }
        }
        os_log("cmio sink reset: %{public}@",
               log: log, type: .default, reason)
        if shouldRestart {
            scheduleDiscovery()
        }
    }

    private func stringProperty(object: CMIOObjectID, selector: CMIOObjectPropertySelector) -> String? {
        var addr = CMIOObjectPropertyAddress(
            mSelector: selector,
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var dataSize: UInt32 = 0
        var status = CMIOObjectGetPropertyDataSize(object, &addr, 0, nil, &dataSize)
        if status != noErr || dataSize == 0 { return nil }
        var cfStr: CFString?
        var used: UInt32 = 0
        status = withUnsafeMutablePointer(to: &cfStr) { ptr -> OSStatus in
            CMIOObjectGetPropertyData(object, &addr, 0, nil, dataSize, &used, ptr)
        }
        if status != noErr { return nil }
        return cfStr as String?
    }

    private func uint32Property(object: CMIOObjectID, selector: CMIOObjectPropertySelector) -> UInt32? {
        var addr = CMIOObjectPropertyAddress(
            mSelector: selector,
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var value: UInt32 = 0
        var used: UInt32 = 0
        let status = CMIOObjectGetPropertyData(
            object, &addr, 0, nil,
            UInt32(MemoryLayout<UInt32>.size), &used, &value)
        guard status == noErr else { return nil }
        return value
    }

    /// 必须在 enumerate device 之前调一次。把
    /// `kCMIOHardwarePropertyAllowScreenCaptureDevices` 设为 `1`，cmiod
    /// 才会把 screen-capture / virtual / sysext 类 device 列入当前进程的
    /// HAL enumerate 结果——这就是 ldenoue 范例里 `makeDevicesVisible()`
    /// 的作用。**没这一步**，host 看 HAL 全量 device 永远看不到自家 sysext。
    static func allowVirtualDeviceVisibility(log: OSLog, silent: Bool = false) {
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var allow: UInt32 = 1
        let status = CMIOObjectSetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil,
            UInt32(MemoryLayout<UInt32>.size), &allow)
        if status != noErr {
            os_log("kCMIOHardwarePropertyAllowScreenCaptureDevices=1 set failed status=%{public}d",
                   log: log, type: .error, Int(status))
        } else if !silent {
            os_log("kCMIOHardwarePropertyAllowScreenCaptureDevices=1 set OK — virtual / sysext devices visible to HAL enumerate",
                   log: log, type: .default)
        }
    }
}
