import Foundation
import CoreMedia
import CoreMediaIO
import CoreVideo
import IOSurface
import OSLog
import os

/// 真正接入 CoreMediaIO 的 device / stream / provider。
/// 这个文件只属于 SimCamExtension target —— 所以不需要任何条件编译。
///
/// host ↔ extension 的帧通道走 **CMIO sink stream**（WWDC22 Session 10022
/// "Create camera extensions with Core Media IO" 的官方推荐路径）。
/// extension 端在同一个 device 上额外开一条 direction=.sink 的
/// CMIOExtensionStream；host 端用 CMIO C API 找到这条 stream 关联的
/// CMSimpleQueue，把 CMSampleBuffer enqueue 进去。框架会调到这个文件里
/// SimCamCMIOSinkSource.consumeSampleBuffer(from client:) 的实现。

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
            legacyDeviceID: nil,
            source: deviceSource)
        deviceSource.device = self.device
        self.provider = CMIOExtensionProvider(source: self, clientQueue: nil)

        let source = SimCamCMIOStreamSource(device: device)
        self.streamSource = source
        // 同一个 device 上的 sink stream —— host 端 enqueue 帧到它的
        // CMSimpleQueue，extension 端 consumeSampleBuffer 把帧转发给上面
        // source stream 的 send 逻辑（共用 handleRealFrame）。
        let sink = SimCamCMIOSinkSource(device: device, sourceStream: source)
        self.sinkSource = sink

        do {
            try provider.addDevice(device)
            try device.addStream(source.stream)
            try device.addStream(sink.stream)
            os_log("SimCam CMIO addDevice/addStream(source+sink) succeeded",
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

    let stream: CMIOExtensionStream
    private let streamFormats: [CMIOExtensionStreamFormat]
    private weak var device: CMIOExtensionDevice?
    private var formatDescription: CMFormatDescription?
    private var sequenceNumber: UInt64 = 0
    private var width: Int32 = 1920
    private var height: Int32 = 1080
    // CMIOExtensionStream 对 source 是 weak ref —— 必须 strong-hold 这个
    // shim 否则 init 一返回它就被 ARC 释放，cmio query 拿到 null 属性。
    private var sourceShim: StreamSourceShim?

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
        // 先用占位 source 创建 stream，super.init 之后再把 self 接进去。
        let placeholder = StreamSourceShim()
        let s = CMIOExtensionStream(localizedName: "SimCam.Stream",
                                    streamID: streamID,
                                    direction: .source,
                                    clockType: .hostTime,
                                    source: placeholder)
        self.stream = s
        super.init()
        placeholder.delegate = self
        self.sourceShim = placeholder
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
    // 一旦 sink stream 收到 host 推过来的真实帧，就停掉这个
    // demoTimer，从此走真实帧。
    private var demoTimer: DispatchSourceTimer?
    private var demoY: Int = 0
    private let realFrameLock = NSLock()
    private var receivedRealFrame = false

    func startStream() throws {
        os_log("SimCam stream startStream() entered", log: Self.streamLog, type: .default)
        // 启动 demo 扫描线作为 fallback。一旦真实帧抵达，handleRealFrame
        // 会把它停掉。host 端帧通道由 sink stream 提供，无需在这里启动。
        let q = DispatchQueue(label: "dev.simcam.extension.demo", qos: .userInteractive)
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now(), repeating: .milliseconds(33))
        t.setEventHandler { [weak self] in self?.tickDemoIfNoRealFrame() }
        demoTimer = t
        t.resume()
        os_log("SimCam stream START (demo pattern armed; sink stream will deliver real frames)",
               log: Self.streamLog, type: .default)
    }
    func stopStream() throws {
        demoTimer?.cancel(); demoTimer = nil
        realFrameLock.lock(); receivedRealFrame = false; realFrameLock.unlock()
        os_log("SimCam stream STOP", log: Self.streamLog, type: .default)
    }

    /// host 推过来的真帧（来自 sink stream consumeSampleBuffer，或包好的
    /// CVPixelBuffer）→ CMSampleBuffer → stream.send。
    /// 这是 source / sink 共享的 send 入口。
    func handleRealFrame(pb: CVPixelBuffer, hostTime: CMTime, slot: UInt8) {
        // 第一次收到真实帧就熄掉 demo
        realFrameLock.lock()
        let firstReal = !receivedRealFrame
        receivedRealFrame = true
        realFrameLock.unlock()
        if firstReal {
            demoTimer?.cancel(); demoTimer = nil
            os_log("SimCam stream: switched from demo to host frames (slot=%{public}d)",
                   log: Self.streamLog, type: .default, Int(slot))
        }

        // 用 host 推过来的尺寸更新一次 formatDescription（首帧或尺寸变化时）
        let w = Int32(CVPixelBufferGetWidth(pb))
        let h = Int32(CVPixelBufferGetHeight(pb))
        if w != width || h != height || formatDescription == nil {
            width = w; height = h
            formatDescription = Self.makeFormat(width: w, height: h)
        }
        guard let fmt = formatDescription else { return }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: hostTime,
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
                    hostTimeInNanoseconds: UInt64(hostTime.value))
    }

    /// host 端通过 sink stream 直接 enqueue 的 CMSampleBuffer —— 已经是
    /// sample buffer 形态，不需要二次封装。这里负责熄 demo + 直接 send。
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
    /// handleRealFrame 立刻 cancel，所以这个判断只是个保险。
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
            // 背景：深灰色
            memset(base, 0x22, bpr * h)
            // 一条移动的白线
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

/// 占位 source —— 解决 `CMIOExtensionStream(source:)` 必须传非 nil
/// 而 self 还没 super.init 的鸡生蛋问题。
@available(macOS 13.0, *)
private final class StreamSourceShim: NSObject, CMIOExtensionStreamSource {
    weak var delegate: SimCamCMIOStreamSource?

    var formats: [CMIOExtensionStreamFormat] { delegate?.formats ?? [] }
    var availableProperties: Set<CMIOExtensionProperty> { delegate?.availableProperties ?? [] }
    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        try delegate?.streamProperties(forProperties: properties) ?? CMIOExtensionStreamProperties(dictionary: [:])
    }
    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        try delegate?.setStreamProperties(streamProperties)
    }
    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        delegate?.authorizedToStartStream(for: client) ?? false
    }
    func startStream() throws { try delegate?.startStream() }
    func stopStream() throws { try delegate?.stopStream() }
}

// MARK: - Sink stream source (host → extension data path)

/// host 端通过 CMIO C API（CMIOStreamCopyBufferQueue + CMSimpleQueueEnqueue）
/// 把 CMSampleBuffer 推到这条 sink stream 关联的 CMSimpleQueue。框架
/// 会调到 startStream，然后我们调 stream.consumeSampleBuffer(from:) 拿到
/// 每一帧并把它 forward 到 source stream 的 send 逻辑。
@available(macOS 13.0, *)
final class SimCamCMIOSinkSource: NSObject, CMIOExtensionStreamSource {

    let stream: CMIOExtensionStream
    private let streamFormats: [CMIOExtensionStreamFormat]
    private weak var device: CMIOExtensionDevice?
    private weak var sourceStream: SimCamCMIOStreamSource?
    private var sourceShim: SinkSourceShim?
    private weak var client: CMIOExtensionClient?
    private var streaming = false

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
        let placeholder = SinkSourceShim()
        let s = CMIOExtensionStream(localizedName: "SimCam.Sink",
                                    streamID: streamID,
                                    direction: .sink,
                                    clockType: .hostTime,
                                    source: placeholder)
        self.stream = s
        super.init()
        placeholder.delegate = self
        self.sourceShim = placeholder
    }

    // MARK: CMIOExtensionStreamSource

    var formats: [CMIOExtensionStreamFormat] { streamFormats }

    var availableProperties: Set<CMIOExtensionProperty> {
        [
            .streamActiveFormatIndex,
            .streamFrameDuration,
            .streamSinkBufferQueueSize,
            .streamSinkBuffersRequiredForStartup,
        ]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let p = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            p.activeFormatIndex = 0
        }
        if properties.contains(.streamFrameDuration) {
            p.frameDuration = CMTime(value: 1, timescale: 30)
        }
        if properties.contains(.streamSinkBufferQueueSize) {
            p.sinkBufferQueueSize = 2
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

    func startStream() throws {
        os_log("SimCam sink stream START", log: SimCamCMIOStreamSource.streamLog, type: .default)
        streaming = true
        consumeNext()
    }

    func stopStream() throws {
        os_log("SimCam sink stream STOP", log: SimCamCMIOStreamSource.streamLog, type: .default)
        streaming = false
    }

    /// 反复调用 consumeSampleBuffer(from:) 把 host 端 enqueue 进来的
    /// CMSampleBuffer 取出来，立刻喂给 source stream 的 send 逻辑。
    private func consumeNext() {
        guard streaming else { return }
        guard let client = self.client else {
            // 还没 authorized；下一帧再试
            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
                self?.consumeNext()
            }
            return
        }
        stream.consumeSampleBuffer(from: client) { [weak self] sample, seq, _, _, error in
            guard let self else { return }
            if let error {
                os_log("sink consumeSampleBuffer error: %{public}s",
                       log: SimCamCMIOStreamSource.streamLog, type: .error,
                       error.localizedDescription)
            }
            if let sample, let src = self.sourceStream {
                let pts = sample.presentationTimeStamp
                let ns: UInt64
                if pts.isValid {
                    ns = UInt64(max(0, pts.seconds * Double(NSEC_PER_SEC)))
                } else {
                    ns = UInt64(CMClockGetTime(CMClockGetHostTimeClock()).value)
                }
                src.handleRealSampleBuffer(sample, hostTimeNs: ns)
                let output = CMIOExtensionScheduledOutput(sequenceNumber: seq,
                                                          hostTimeInNanoseconds: ns)
                self.stream.notifyScheduledOutputChanged(output)
            }
            // 继续拉下一帧
            if self.streaming {
                self.consumeNext()
            }
        }
    }
}

@available(macOS 13.0, *)
private final class SinkSourceShim: NSObject, CMIOExtensionStreamSource {
    weak var delegate: SimCamCMIOSinkSource?

    var formats: [CMIOExtensionStreamFormat] { delegate?.formats ?? [] }
    var availableProperties: Set<CMIOExtensionProperty> { delegate?.availableProperties ?? [] }
    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        try delegate?.streamProperties(forProperties: properties) ?? CMIOExtensionStreamProperties(dictionary: [:])
    }
    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        try delegate?.setStreamProperties(streamProperties)
    }
    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        delegate?.authorizedToStartStream(for: client) ?? false
    }
    func startStream() throws { try delegate?.startStream() }
    func stopStream() throws { try delegate?.stopStream() }
}
