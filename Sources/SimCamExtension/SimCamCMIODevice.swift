import Foundation
import CoreMedia
import CoreMediaIO
import CoreVideo
import IOSurface
import OSLog

/// 真正接入 CoreMediaIO 的 device / stream / provider。
/// 这个文件只属于 SimCamExtension target —— 所以不需要任何条件编译。
///
/// 系统装好后：
/// `AVCaptureDevice.DiscoverySession(... mediaType: .video ...)` 会枚举到一个
/// localizedName 为 "SimCam Virtual Camera" 的设备 —— iOS 17+ Simulator 上同样可见。

@available(macOS 13.0, *)
public final class SimCamCMIODevice: NSObject {

    public static let shared = SimCamCMIODevice()

    private let log = Logger(subsystem: "dev.simcam.extension", category: "cmio")
    private let providerSource: SimCamCMIOProviderSource

    private override init() {
        self.providerSource = SimCamCMIOProviderSource()
        super.init()
        // 不要在 system extension（sandbox=true）里自己 resume 一个
        // NSXPCListener(machServiceName:) ——sandboxd 会拒绝注册并让整个
        // CMIOExtensionProvider.startService 静默失败（host 通过 cmio
        // framework 看到的 device 列表会变成空数组）。
        // host ↔ extension 的帧通道改走 CMIOExtensionStreamSource 自己的
        // pushSurface 路径；如果未来确实需要带外控制信道，应改用 cmio 的
        // setProperty 协议而不是另起 NSXPCListener。
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
        let stream = SimCamCMIOStreamSource(device: device)
        self.streamSource = stream
        do {
            try provider.addDevice(device)
            try device.addStream(stream.stream)
            NSLog("SimCam CMIO addDevice/addStream succeeded: device=%@, stream=%@",
                  String(describing: device), String(describing: stream.stream))
        } catch {
            NSLog("SimCam CMIO add device/stream FAILED: %@", error.localizedDescription)
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
    private var demoTimer: DispatchSourceTimer?
    private var demoY: Int = 0
    func startStream() throws {
        let q = DispatchQueue(label: "dev.simcam.extension.demo", qos: .userInteractive)
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now(), repeating: .milliseconds(33))
        t.setEventHandler { [weak self] in self?.tickDemo() }
        demoTimer = t
        t.resume()
        NSLog("SimCam stream START (demo pattern)")
    }
    func stopStream() throws {
        demoTimer?.cancel(); demoTimer = nil
        NSLog("SimCam stream STOP")
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
