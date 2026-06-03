import Foundation
import AVFoundation
import CoreMedia
import CoreMediaIO
import os.log

/// CMIOSinkClient
///
/// Host (SimCamApp) 端把帧推给 CMIO Camera Extension 的官方推荐通道
/// （WWDC22 "Create camera extensions with Core Media IO" Session 10022）：
///
///     Host process                            Extension process
///     ┌──────────────────────┐                ┌────────────────────────────┐
///     │ CMSimpleQueueEnqueue │ ─── shmem ──▶  │ consumeSampleBuffer(from:) │
///     └──────────────────────┘                └────────────────────────────┘
///
/// 整套流程：
///   1) `CMIOObjectGetPropertyData(kCMIOHardwarePropertyDevices)` 枚举所有 CMIO 设备
///   2) 按 `kCMIOObjectPropertyName` 匹配 `CameraDiscovery.virtualCameraName`
///      （= "SimCam Virtual Camera"）找到我们的虚拟相机
///   3) 取 `kCMIODevicePropertyStreams`，遍历每条 stream，找 `kCMIOStreamPropertyDirection`
///      为 sink 的那条（direction 含义见 CMIOHardware.h —— 1 = output/sink）
///   4) `CMIOStreamCopyBufferQueue(streamID, queueAlteredProc, refCon, &queue)` 拿
///      到 sink 的 `CMSimpleQueueRef`
///   5) `CMIODeviceStartStream(deviceID, streamID)` 让 extension 端 startStream
///   6) `push(_:)` 时 `CMSimpleQueueEnqueue(queue, sample)` —— extension 的
///      `consumeSampleBuffer(from:)` 回调会拿到这个 sample
///
/// 找设备失败（extension 还没安装 / 还没激活）就每秒重试，直到找到为止。
public final class CMIOSinkClient {

    private let log = OSLog(subsystem: "dev.simcam", category: "cmio.sink")
    private let queue = DispatchQueue(label: "dev.simcam.cmio.sink", qos: .userInteractive)

    private var deviceID: CMIOObjectID = 0
    private var streamID: CMIOObjectID = 0
    private var sinkQueue: CMSimpleQueue?

    private let stateLock = NSLock()
    private var running = false
    private var connected = false
    /// 上次 lazy connect 失败时间 —— 避免 push() 每帧都跑一遍 device enum。
    private var lastConnectAttempt: TimeInterval = 0

    public init() {}

    public var isConnected: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return connected
    }

    public func start() {
        stateLock.lock()
        guard !running else { stateLock.unlock(); return }
        running = true
        stateLock.unlock()
        os_log("CMIOSinkClient.start() —— lazy mode, will attempt to connect on first push", log: log, type: .info)
    }

    public func stop() {
        stateLock.lock()
        running = false
        let dID = deviceID
        let sID = streamID
        deviceID = 0
        streamID = 0
        sinkQueue = nil
        connected = false
        stateLock.unlock()

        if dID != 0 && sID != 0 {
            CMIODeviceStopStream(dID, sID)
        }
    }

    /// 把 sample buffer enqueue 到 sink stream 的 CMSimpleQueue。
    ///
    /// **Lazy connect**：host engine 一开始就在不断 push 帧（哪怕没人在看）；
    /// 我们不做"无脑每秒重连"那种刷屏 log 的事，而是：
    ///   - 第一次有帧到来时尝试一次连接
    ///   - 失败的话最少间隔 5s 再尝试，避免反复枚举 CMIO 设备
    /// 真正的"用户开了 QuickTime / Simulator" 触发顺序是：
    ///   AVFoundation client → CMIO source stream startStream → extension 端
    ///   有了 source 消费者，sink 才有意义被启动。所以 lazy 是合理的。
    public func push(_ s: CMSampleBuffer) {
        stateLock.lock()
        let liveQ = sinkQueue
        let live = connected
        let isRunning = running
        stateLock.unlock()
        guard isRunning else { return }

        if !live {
            attemptLazyConnect()
            // attempt 之后再读一次状态
            stateLock.lock()
            let q2 = sinkQueue
            let live2 = connected
            stateLock.unlock()
            guard live2, let q2 = q2 else { return }
            enqueue(s, into: q2)
            return
        }
        guard let q = liveQ else { return }
        enqueue(s, into: q)
    }

    private func enqueue(_ s: CMSampleBuffer, into q: CMSimpleQueue) {
        // CMSimpleQueueEnqueue 接管一份 retain，所以传入前先 retain。
        // CMSampleBuffer 是 ARC，直接 Unmanaged.passRetained。
        if CMSimpleQueueGetCount(q) >= CMSimpleQueueGetCapacity(q) {
            // 满了就丢最旧的，避免延迟堆积
            if let oldest = CMSimpleQueueDequeue(q) {
                Unmanaged<CMSampleBuffer>.fromOpaque(oldest).release()
            }
        }
        let unmanaged = Unmanaged.passRetained(s)
        let status = CMSimpleQueueEnqueue(q, element: unmanaged.toOpaque())
        if status != noErr {
            unmanaged.release()
            os_log("CMSimpleQueueEnqueue failed: %{public}d", log: log, status)
        }
    }

    // MARK: - private

    private func attemptLazyConnect() {
        let now = Date().timeIntervalSince1970
        stateLock.lock()
        let cooldownLeft = (lastConnectAttempt + 5.0) - now
        if cooldownLeft > 0 {
            stateLock.unlock(); return
        }
        lastConnectAttempt = now
        stateLock.unlock()

        // 同步在 push 调用线程里跑（push 来自 SimCamEngine 后台 queue，不阻塞 UI）。
        if locateDevice() {
            os_log("connected to SimCam Virtual Camera CMIO sink (lazy)", log: log, type: .info)
        }
    }

    /// 在系统所有 CMIO 设备里找 SimCam Virtual Camera + 它的 sink stream + 关联 queue。
    /// 找到任意一步失败都返回 false（让外层 5s 后再尝试）。
    private func locateDevice() -> Bool {
        guard let dev = findDeviceID(byName: CameraDiscovery.virtualCameraName) else {
            os_log("locateDevice: SimCam Virtual Camera device not found yet (extension not loaded?)", log: log, type: .info)
            return false
        }
        os_log("locateDevice: found device id=%{public}u, looking for sink stream", log: log, type: .info, dev)
        guard let sink = findSinkStream(for: dev) else {
            os_log("locateDevice: device %{public}u has no sink (direction=1) stream", log: log, type: .error, dev)
            return false
        }
        os_log("locateDevice: found sink stream id=%{public}u on device %{public}u", log: log, type: .info, sink, dev)
        // 拿 sink 的 CMSimpleQueue
        var q: Unmanaged<CMSimpleQueue>?
        let res = CMIOStreamCopyBufferQueue(sink, { _, _, _ in /* alter cb: 不需要 */ }, nil, &q)
        guard res == noErr, let queueRef = q?.takeRetainedValue() else {
            os_log("CMIOStreamCopyBufferQueue failed: %{public}d", log: log, res)
            return false
        }
        // 启动 stream（让 extension 端 startStream 触发）
        let startRes = CMIODeviceStartStream(dev, sink)
        if startRes != noErr {
            os_log("CMIODeviceStartStream failed: %{public}d", log: log, startRes)
            return false
        }
        stateLock.lock()
        deviceID = dev
        streamID = sink
        sinkQueue = queueRef
        connected = true
        stateLock.unlock()
        return true
    }

    private func findDeviceID(byName target: String) -> CMIOObjectID? {
        // **关键**：CMIO Camera Extension publish 的虚拟相机，**默认不会出现**
        // 在 host 进程的 `kCMIOHardwarePropertyDevices` 列表里。必须先用
        // AVFoundation 的 DiscoverySession 列一次设备 —— AVFoundation 内部
        // 会触发 CMIO assistant 把 extension device "暴露"给当前进程。
        //
        // 参考 Apple Developer Forums Thread 718128（mansourmoufid 的回答）+
        // codejam.info "USB iPhone screen recording in Swift" 的"warmup
        // side-effect"章节：没有这一步，AVCaptureDeviceWasConnected 通知不会
        // 到达，CMIO 列表里也看不到 extension device。
        // CMIO Camera Extension 在 macOS 14+ 是 `.external`，13 是 `.externalUnknown`。
        let extType: AVCaptureDevice.DeviceType
        if #available(macOS 14.0, *) {
            extType = .external
        } else {
            extType = .externalUnknown
        }
        let warmup = AVCaptureDevice.DiscoverySession(
            deviceTypes: [extType, .builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified)
        var avUniqueID: String? = nil
        for d in warmup.devices where d.localizedName == target {
            avUniqueID = d.uniqueID
            break
        }

        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var dataSize: UInt32 = 0
        var res = CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject),
                                                &addr, 0, nil, &dataSize)
        guard res == noErr, dataSize > 0 else { return nil }
        let count = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
        var ids = [CMIOObjectID](repeating: 0, count: count)
        var dataUsed: UInt32 = 0
        res = ids.withUnsafeMutableBufferPointer { buf in
            CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject),
                                      &addr, 0, nil, dataSize, &dataUsed, buf.baseAddress!)
        }
        guard res == noErr else { return nil }
        var seen: [String] = []
        // 优先用 AVFoundation 拿到的 uniqueID 反查 CMIO device（更可靠 —— name 可能被本地化）。
        if let uid = avUniqueID {
            for id in ids {
                if let cmioUID = stringProperty(id, kCMIODevicePropertyDeviceUID), cmioUID == uid {
                    return id
                }
                if let name = stringProperty(id, kCMIOObjectPropertyName) { seen.append(name) }
            }
        } else {
            for id in ids {
                if let name = stringProperty(id, kCMIOObjectPropertyName) {
                    seen.append(name)
                    if name == target {
                        return id
                    }
                }
            }
        }
        os_log("findDeviceID: target=%{public}s not found (avFound=%{public}@), saw %{public}u CMIO devices: %{public}s",
               log: log, type: .info, target,
               avUniqueID == nil ? "no" : "yes",
               UInt32(seen.count), seen.joined(separator: " | "))
        return nil
    }

    private func findSinkStream(for device: CMIOObjectID) -> CMIOObjectID? {
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyStreams),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var dataSize: UInt32 = 0
        var res = CMIOObjectGetPropertyDataSize(device, &addr, 0, nil, &dataSize)
        guard res == noErr, dataSize > 0 else { return nil }
        let count = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
        var streams = [CMIOObjectID](repeating: 0, count: count)
        var dataUsed: UInt32 = 0
        res = streams.withUnsafeMutableBufferPointer { buf in
            CMIOObjectGetPropertyData(device, &addr, 0, nil, dataSize, &dataUsed, buf.baseAddress!)
        }
        guard res == noErr else { return nil }
        for s in streams {
            // direction: 0 = output (source/from device to host), 1 = input (sink/from host to device)
            if let dir = uint32Property(s, kCMIOStreamPropertyDirection), dir == 1 {
                return s
            }
        }
        return nil
    }

    private func stringProperty(_ obj: CMIOObjectID, _ selector: Int) -> String? {
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(selector),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        let size: UInt32 = UInt32(MemoryLayout<CFString?>.size)
        var cf: CFString?
        var used: UInt32 = 0
        let res = withUnsafeMutablePointer(to: &cf) { ptr -> OSStatus in
            CMIOObjectGetPropertyData(obj, &addr, 0, nil, size, &used, ptr)
        }
        guard res == noErr, let s = cf else { return nil }
        return s as String
    }

    private func uint32Property(_ obj: CMIOObjectID, _ selector: Int) -> UInt32? {
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(selector),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var v: UInt32 = 0
        let size: UInt32 = UInt32(MemoryLayout<UInt32>.size)
        var used: UInt32 = 0
        let res = CMIOObjectGetPropertyData(obj, &addr, 0, nil, size, &used, &v)
        guard res == noErr else { return nil }
        return v
    }
}
