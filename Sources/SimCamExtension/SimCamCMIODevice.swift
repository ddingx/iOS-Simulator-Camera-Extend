import Foundation
import CoreMedia
import CoreMediaIO
import CoreVideo
import OSLog
import os

/// 真正接入 CoreMediaIO 的 device / stream / provider。
/// 这个文件只属于 SimCamExtension target —— 所以不需要任何条件编译。
///
/// **host ↔ extension 帧通道 = Apple 官方 CMIO sink stream**：
///
///     SimCamApp 进程                      SimCamExtension 进程
///     ┌──────────────────┐  CMSampleBuf  ┌──────────────────────────┐
///     │ CMIOSinkClient   │ ─ Mach IPC  ▶ │ SimCamCMIOSinkSource     │
///     │ CMSimpleQueue    │             ▶ │ stream.consumeSample…    │
///     │   Enqueue        │             ▶ │ → handleRealSampleBuffer │
///     │                  │             ▶ │ → source stream.send     │
///     └──────────────────┘             ▶ │ → cmiod → AVFoundation   │
///                                          └──────────────────────────┘
///
/// 这是 WWDC22 Session 10022 + Apple DTS Quinn 在 forums/706184 推荐
/// 的标准路径："If you need to pass a video stream into your CMIO
/// extension, have the CMIO extension publish an output device."
/// 实战参考：https://github.com/fuziki/CameraEX
///
/// **历史**：之前一度怀疑 cmiod 对自家 host 隐藏自家 device 而走过
/// IOSurface + Darwin notify 桥，但实测 sysext sandbox 直接 EPERM
/// `/tmp` 又跨进程隔离 App Group container（`/private/var/db/cmiodalassistants/`
/// vs `~/Library/Group Containers/`），那条路是死的。回到官方 sink stream。

@available(macOS 13.0, *)
public final class SimCamCMIODevice: NSObject {

    public static let shared = SimCamCMIODevice()

    private let log = Logger(subsystem: "dev.simcam.extension", category: "cmio")
    private let providerSource: SimCamCMIOProviderSource

    private override init() {
        self.providerSource = SimCamCMIOProviderSource()
        super.init()
    }

    public func provider() -> SimCamCMIOProviderSource { providerSource }
}

@available(macOS 13.0, *)
public final class SimCamCMIOProviderSource: NSObject, CMIOExtensionProviderSource {

    // CMIOExtensionDevice / CMIOExtensionStream 对它们的 source 是 weak
    // reference —— 必须由 provider source 自己 strong-hold 住，否则一旦
    // init 返回，deviceSource / streamSource 就被 ARC 释放，cmio framework
    // 在 query availableProperties 时拿到 null，host 收到的 device 列表
    // 看似存在但属性全空，从而被过滤掉，AVCaptureDevice 里就看不到。
    private var deviceSource: SimCamCMIODeviceSource!
    fileprivate(set) var streamSource: SimCamCMIOStreamSource?
    fileprivate(set) var sinkSource: SimCamCMIOSinkSource?
    private var device: CMIOExtensionDevice!
    public private(set) var provider: CMIOExtensionProvider!

    public override init() {
        super.init()
        let deviceID = UUID(uuidString: "5C8F9A6E-2D11-4A5D-8E6E-3F1C4B1E0001")!
        self.deviceSource = SimCamCMIODeviceSource()
        self.device = CMIOExtensionDevice(
            localizedName: CameraDiscovery.virtualCameraName,
            deviceID: deviceID,
            // 关键：必须填 legacyDeviceID（=UUID 字符串）。它就是 HAL 看到的
            // `kCMIODevicePropertyDeviceUID` 字段值；填 nil 时 macOS 26 cmiod
            // 可能拒绝把 device 暴露给 HAL/AVFoundation enumerate。ldenoue
            // (cameraextension) 和 fuziki (CameraEX) 都把它设为 UUID 字符串。
            legacyDeviceID: deviceID.uuidString,
            source: deviceSource)
        deviceSource.device = self.device
        self.provider = CMIOExtensionProvider(source: self, clientQueue: nil)

        let source = SimCamCMIOStreamSource(device: device)
        self.streamSource = source
        // sink stream 拿 host 推过来的帧；它把帧回灌给 source.handleRealSampleBuffer。
        let sink = SimCamCMIOSinkSource(device: device, sourceStream: source)
        self.sinkSource = sink

        do {
            // 关键顺序：必须先 device.addStream(...)，最后才 provider.addDevice(...)。
            //
            // cmiod 在 provider.addDevice() 那一刻冻结 device 的 streams 列表
            // 用来填 HAL 的 kCMIODevicePropertyStreams。如果 addDevice 之后才
            // addStream，cmiod 看到的是"零 stream device"——HAL/AVFoundation
            // enumerate 路径会把这种残废 device 过滤掉，但直接按 localizedName
            // 打开（QuickTime 这条 path）反而能用。这就是我们之前 SimCamApp
            // 看不到、QuickTime 看得到的根因。
            //
            // ldenoue/cameraextension 把 addStream 写在 deviceSource.init 内部
            // (在 provider.addDevice 之前)，fuziki/CameraEX 也是同顺序。
            try device.addStream(source.stream)
            try device.addStream(sink.stream)
            try provider.addDevice(device)
            os_log("SimCam CMIO addStream(source+sink) → addDevice succeeded — host frames arrive via CMIO sink",
                   log: SimCamCMIOStreamSource.streamLog, type: .default)
        } catch {
            os_log("SimCam CMIO add device/stream FAILED: %{public}s",
                   log: SimCamCMIOStreamSource.streamLog, type: .error,
                   error.localizedDescription)
        }
    }

    public func connect(to client: CMIOExtensionClient) throws {}
    public func disconnect(from client: CMIOExtensionClient) {}

    public var availableProperties: Set<CMIOExtensionProperty> {
        [.providerManufacturer, .providerName]
    }
    public func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let p = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { p.manufacturer = "Software Mansion" }
        if properties.contains(.providerName)         { p.name         = "SimCam" }
        return p
    }
    public func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}

@available(macOS 13.0, *)
final class SimCamCMIODeviceSource: NSObject, CMIOExtensionDeviceSource {
    fileprivate weak var device: CMIOExtensionDevice?

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel]
    }
    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let p = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceModel) {
            p.model = "SimCam Virtual Camera"
        }
        return p
    }
    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}
}

@available(macOS 13.0, *)
final class SimCamCMIOStreamSource: NSObject, CMIOExtensionStreamSource {

    static let streamLog = OSLog(subsystem: "dev.simcam.extension", category: "stream")

    // 必须是 var：用 ldenoue / fuziki 项目验证有效的 init 顺序——先 super.init()
    // 再 self.stream = CMIOExtensionStream(..., source: self)。这样 cmiod 在
    // stream 注册时立刻 query 到的是真 self 的 formats / availableProperties，
    // 而不是 placeholder shim 的空值。后者会让 cmiod 把这个 stream 当作
    // "format-less"，进而拒绝把整个 device 暴露给 HAL/AVFoundation enumerate。
    var stream: CMIOExtensionStream!
    private let streamFormats: [CMIOExtensionStreamFormat]
    private weak var device: CMIOExtensionDevice?
    private var formatDescription: CMFormatDescription?
    private var sequenceNumber: UInt64 = 0
    private var width: Int32 = 1920
    private var height: Int32 = 1080

    init(device: CMIOExtensionDevice) {
        self.device = device
        let streamID = UUID(uuidString: "5C8F9A6E-2D11-4A5D-8E6E-3F1C4B1E0002")!
        let format = Self.makeFormat(width: 1920, height: 1080)
        self.formatDescription = format
        let cfg = CMIOExtensionStreamFormat(formatDescription: format,
                                            maxFrameDuration: CMTime(value: 1, timescale: 30),
                                            minFrameDuration: CMTime(value: 1, timescale: 60),
                                            validFrameDurations: nil)
        self.streamFormats = [cfg]
        super.init()
        // 现在 self 已经是有效 NSObject，直接传 self 给 stream init。
        self.stream = CMIOExtensionStream(localizedName: "SimCam.Stream",
                                          streamID: streamID,
                                          direction: .source,
                                          clockType: .hostTime,
                                          source: self)
    }

    fileprivate static func makeFormat(width: Int32, height: Int32) -> CMFormatDescription {
        var fmt: CMFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                       codecType: kCVPixelFormatType_32BGRA,
                                       width: width, height: height,
                                       extensions: nil, formatDescriptionOut: &fmt)
        return fmt!
    }

    // MARK: CMIOExtensionStreamSource
    var formats: [CMIOExtensionStreamFormat] { streamFormats }
    var availableProperties: Set<CMIOExtensionProperty> { [.streamActiveFormatIndex, .streamFrameDuration] }
    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let p = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { p.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration)     { p.frameDuration = CMTime(value: 1, timescale: 30) }
        return p
    }
    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}
    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    // 自带的 60fps 测试图样：白色横线从上到下扫描，用来在没有
    // host→ext 数据通道时验证 source stream 整条 cmio 链路是通的。
    // 一旦 sink 送来真实帧，就停掉这个 demoTimer，从此走真实帧。
    private var demoTimer: DispatchSourceTimer?
    private var demoY: Int = 0
    private let realFrameLock = NSLock()
    private var receivedRealFrame = false

    func startStream() throws {
        os_log("SimCam stream startStream() entered",
               log: Self.streamLog, type: .default)
        let q = DispatchQueue(label: "dev.simcam.extension.demo", qos: .userInteractive)
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now(), repeating: .milliseconds(33))
        t.setEventHandler { [weak self] in self?.tickDemoIfNoRealFrame() }
        demoTimer = t
        t.resume()
        os_log("SimCam stream START — demo armed, waiting for sink frames",
               log: Self.streamLog, type: .default)
    }
    func stopStream() throws {
        demoTimer?.cancel(); demoTimer = nil
        realFrameLock.lock()
        receivedRealFrame = false
        realFrameLock.unlock()
        os_log("SimCam stream STOP", log: Self.streamLog, type: .default)
    }

    /// host 端通过 sink stream 直接 enqueue 的 CMSampleBuffer —— 已经是
    /// sample buffer 形态。这里熄 demo + 直接 send 到 source stream，给
    /// 系统的 AVFoundation 客户端（QuickTime/FaceTime/Photo Booth）。
    func handleRealSampleBuffer(_ sample: CMSampleBuffer, hostTimeNs: UInt64) {
        realFrameLock.lock()
        let firstReal = !receivedRealFrame
        receivedRealFrame = true
        realFrameLock.unlock()
        if firstReal {
            demoTimer?.cancel(); demoTimer = nil
            os_log("SimCam stream: switched from demo to host frames (sink)",
                   log: Self.streamLog, type: .default)
        }

        if let pb = CMSampleBufferGetImageBuffer(sample) {
            let w = Int32(CVPixelBufferGetWidth(pb))
            let h = Int32(CVPixelBufferGetHeight(pb))
            if w != width || h != height || formatDescription == nil {
                width = w; height = h
                formatDescription = Self.makeFormat(width: w, height: h)
            }
        }
        sequenceNumber &+= 1
        stream.send(sample, discontinuity: [],
                    hostTimeInNanoseconds: hostTimeNs)
    }

    /// 只在还没收到任何真实帧时画 demo —— 一旦 host 接通，demoTimer 会被
    /// handleRealSampleBuffer 立刻 cancel，所以这个判断只是个保险。
    private func tickDemoIfNoRealFrame() {
        realFrameLock.lock()
        let real = receivedRealFrame
        realFrameLock.unlock()
        if real { return }
        tickDemo()
    }

    private func tickDemo() {
        let w = Int(self.width), h = Int(self.height)
        var pbOut: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                            kCVPixelFormatType_32BGRA,
                            attrs as CFDictionary, &pbOut)
        guard let pb = pbOut else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        if let base = CVPixelBufferGetBaseAddress(pb) {
            let bpr = CVPixelBufferGetBytesPerRow(pb)
            memset(base, 0x22, bpr * h)
            demoY = (demoY + 4) % h
            let row = base.advanced(by: demoY * bpr)
            memset(row, 0xFF, bpr)
        }
        CVPixelBufferUnlockBaseAddress(pb, [])

        guard let fmt = formatDescription else { return }
        let host = CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: host,
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                           imageBuffer: pb,
                                           dataReady: true,
                                           makeDataReadyCallback: nil,
                                           refcon: nil,
                                           formatDescription: fmt,
                                           sampleTiming: &timing,
                                           sampleBufferOut: &sample)
        guard let sample else { return }
        sequenceNumber &+= 1
        stream.send(sample, discontinuity: [],
                    hostTimeInNanoseconds: UInt64(host.value))
    }
}

// MARK: - sink stream（host → extension 推帧）

/// CMIOExtensionStream(direction: .sink) —— Apple 官方推荐的 host→ext
/// 帧通道入口。host 端把它当作"output device"打开，调
/// `CMSimpleQueueEnqueue` 推 CMSampleBuffer，cmiod 把每个 buffer
/// 投递到 `consumeSampleBuffer(from:)` callback；我们在 callback 里
/// 把 sample buffer 转给 source stream 的 `handleRealSampleBuffer`。
@available(macOS 13.0, *)
final class SimCamCMIOSinkSource: NSObject, CMIOExtensionStreamSource {

    // var + 后赋值：见 SimCamCMIOStreamSource 的注释，避免 placeholder shim
    // 在 stream 注册时把空 properties 暴露给 cmiod。
    var stream: CMIOExtensionStream!
    private let streamFormats: [CMIOExtensionStreamFormat]
    private weak var device: CMIOExtensionDevice?
    private weak var sourceStream: SimCamCMIOStreamSource?
    private var subscribed = false
    private var client: CMIOExtensionClient?

    init(device: CMIOExtensionDevice, sourceStream: SimCamCMIOStreamSource) {
        self.device = device
        self.sourceStream = sourceStream
        let streamID = UUID(uuidString: "5C8F9A6E-2D11-4A5D-8E6E-3F1C4B1E0003")!
        let format = SimCamCMIOStreamSource.makeFormat(width: 1920, height: 1080)
        let cfg = CMIOExtensionStreamFormat(formatDescription: format,
                                            maxFrameDuration: CMTime(value: 1, timescale: 30),
                                            minFrameDuration: CMTime(value: 1, timescale: 60),
                                            validFrameDurations: nil)
        self.streamFormats = [cfg]
        super.init()
        self.stream = CMIOExtensionStream(localizedName: "SimCam.Sink",
                                          streamID: streamID,
                                          direction: .sink,
                                          clockType: .hostTime,
                                          source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { streamFormats }
    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex,
         .streamFrameDuration,
         .streamSinkBufferQueueSize,
         .streamSinkBuffersRequiredForStartup]
    }
    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let p = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { p.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) {
            p.frameDuration = CMTime(value: 1, timescale: 30)
        }
        if properties.contains(.streamSinkBufferQueueSize) {
            p.sinkBufferQueueSize = 1
        }
        if properties.contains(.streamSinkBuffersRequiredForStartup) {
            p.sinkBuffersRequiredForStartup = 1
        }
        return p
    }
    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}
    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        self.client = client
        return true
    }

    /// 当 host 进程"打开"这个 sink stream 时被 cmiod 调到。这里订阅
    /// `consumeSampleBuffer` callback —— host 每 enqueue 一帧就回调一次。
    func startStream() throws {
        os_log("SimCam sink startStream entered (will subscribe to host frames)",
               log: SimCamCMIOStreamSource.streamLog, type: .default)
        subscribed = true
        subscribeNext()
    }
    func stopStream() throws {
        subscribed = false
        os_log("SimCam sink stopStream", log: SimCamCMIOStreamSource.streamLog, type: .default)
    }

    /// recursive subscribe —— 每次 callback 完都重新订阅下一帧，
    /// 这是 fuziki 项目和 Apple sample 都用的 pattern。
    private func subscribeNext() {
        guard subscribed, let client = self.client else { return }
        stream.consumeSampleBuffer(from: client) { [weak self] sample, seq, _, _, error in
            guard let self else { return }
            if let error = error {
                os_log("sink consumeSampleBuffer error: %{public}s",
                       log: SimCamCMIOStreamSource.streamLog, type: .error,
                       error.localizedDescription)
                // 即使出错也继续订阅，下一帧再尝试
                self.subscribeNext()
                return
            }
            defer { self.subscribeNext() }
            guard let sample else { return }
            let nanoSec = UInt64(sample.presentationTimeStamp.seconds * Double(NSEC_PER_SEC))
            // 把 host 推过来的帧回灌给 source stream
            self.sourceStream?.handleRealSampleBuffer(sample, hostTimeNs: nanoSec)
            // 通知 host: scheduled output 已消费（让 enqueue 流量统计闭环）
            let output = CMIOExtensionScheduledOutput(sequenceNumber: seq,
                                                      hostTimeInNanoseconds: nanoSec)
            self.stream.notifyScheduledOutputChanged(output)
        }
    }
}
