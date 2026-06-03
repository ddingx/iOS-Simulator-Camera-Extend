import Foundation
import AVFoundation
import CoreImage
import CoreVideo
import CoreMedia
import AppKit
import ScreenCaptureKit
import os.log

private let producerLog = OSLog(subsystem: "dev.simcam", category: "producer")

/// 抽象：任何输入源都被归一化为持续输出 CMSampleBuffer 的"帧生产者"。
public protocol FrameProducer: AnyObject {
    var format: FrameFormat { get }
    func start(onFrame: @escaping (CMSampleBuffer) -> Void) throws
    func stop()
}

/// 简单的"静态 CGImage 重复输出"生产者：图片源、二维码源都基于它。
public final class StillImageFrameProducer: FrameProducer {
    public var format: FrameFormat
    private let image: CGImage
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "simcam.still.producer")

    public init(image: CGImage, format: FrameFormat = .default) {
        self.image = image
        self.format = format
    }

    public func start(onFrame: @escaping (CMSampleBuffer) -> Void) throws {
        let interval = 1.0 / Double(max(1, format.fps))
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            if let buf = SampleBufferFactory.makeBuffer(from: self.image, format: self.format) {
                onFrame(buf)
            }
        }
        t.resume()
        timer = t
    }

    public func stop() { timer?.cancel(); timer = nil }
}

/// 视频文件循环播放生产者，使用 AVAssetReader 解码。
public final class VideoFileFrameProducer: FrameProducer {
    public var format: FrameFormat
    private let url: URL
    private let loop: Bool
    private var task: Task<Void, Never>?

    public init(url: URL, loop: Bool = true, format: FrameFormat = .default) {
        self.url = url
        self.loop = loop
        self.format = format
    }

    public func start(onFrame: @escaping (CMSampleBuffer) -> Void) throws {
        task = Task.detached { [url, loop, format] in
            repeat {
                guard let asset = try? await Self.loadAsset(url: url),
                      let reader = try? AVAssetReader(asset: asset),
                      let track = try? await asset.loadTracks(withMediaType: .video).first
                else { return }

                let outputSettings: [String: Any] = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
                let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
                guard reader.canAdd(trackOutput) else { return }
                reader.add(trackOutput)
                guard reader.startReading() else { return }

                while !Task.isCancelled {
                    if let buf = trackOutput.copyNextSampleBuffer() {
                        var output = buf
                        if let normalized = SampleBufferFactory.retiming(buffer: buf, format: format) {
                            output = normalized
                        }
                        onFrame(output)
                    } else { break }
                    try? await Task.sleep(nanoseconds: UInt64(1_000_000_000 / max(1, format.fps)))
                }
                reader.cancelReading()
            } while loop && !Task.isCancelled
        }
    }

    private static func loadAsset(url: URL) async throws -> AVURLAsset {
        let asset = AVURLAsset(url: url)
        _ = try await asset.load(.tracks)
        return asset
    }

    public func stop() { task?.cancel(); task = nil }
}

/// 真实摄像头源：AVCaptureSession + AVCaptureVideoDataOutput。
public final class CameraDeviceFrameProducer: NSObject, FrameProducer, AVCaptureVideoDataOutputSampleBufferDelegate {
    public var format: FrameFormat
    private let device: AVCaptureDevice
    private let session = AVCaptureSession()
    private var onFrameHandler: ((CMSampleBuffer) -> Void)?
    private let queue = DispatchQueue(label: "simcam.camera.producer")

    public init(device: AVCaptureDevice, format: FrameFormat = .default) {
        self.device = device
        // macOS 上 device.position 几乎永远是 unspecified，不要拿它当
        // isFrontFacing 真值；front/back 是 simulator 端 hook 决定的，host
        // 这里只关心帧本身。
        self.format = format
    }

    public func start(onFrame: @escaping (CMSampleBuffer) -> Void) throws {
        // ===== TCC 摄像头权限 =====
        // 不管 authorizationStatus 当前是啥，统一调一次 requestAccess。
        // 系统行为：
        //   - 若 TCC 表里没有当前进程身份对应的条目 → 弹授权框
        //   - 若已 authorized → 直接 callback(true)
        //   - 若已 denied/restricted → 直接 callback(false)（不会重弹）
        // 注意：必须先在 entitlements 里声明 com.apple.security.device.camera，
        // 否则 Hardened Runtime 会让 requestAccess 静默返回 NO 且永不弹框。
        let preStatus = AVCaptureDevice.authorizationStatus(for: .video)
        let sema = DispatchSemaphore(value: 0)
        var granted = (preStatus == .authorized)
        if preStatus != .authorized {
            AVCaptureDevice.requestAccess(for: .video) { ok in
                granted = ok
                sema.signal()
            }
            _ = sema.wait(timeout: .now() + 30)
        }
        guard granted else {
            throw NSError(domain: "SimCam.Camera", code: -1,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Camera permission denied. Enable in System Settings → Privacy & Security → Camera → SimCamApp."])
        }

        onFrameHandler = onFrame
        session.beginConfiguration()
        session.sessionPreset = .high
        let input = try AVCaptureDeviceInput(device: device)
        if session.canAddInput(input) { session.addInput(input) }
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        session.startRunning()
        NSLog("[SimCam.Camera] session started for device=\(device.localizedName)")
    }

    public func stop() {
        session.stopRunning()
        onFrameHandler = nil
    }

    public func captureOutput(_ output: AVCaptureOutput,
                              didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        onFrameHandler?(sampleBuffer)
    }
}

/// 内置 demo 源：用 CoreImage 渲染一个测试图卡，让 Trial 用户可以立即看到效果。
public final class DemoCardFrameProducer: FrameProducer {
    public var format: FrameFormat
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "simcam.demo.producer")
    private var frameIndex: Int = 0

    public init(format: FrameFormat = .default) { self.format = format }

    public func start(onFrame: @escaping (CMSampleBuffer) -> Void) throws {
        let interval = 1.0 / Double(max(1, format.fps))
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.frameIndex &+= 1
            if let img = DemoCardRenderer.render(size: CGSize(width: self.format.width, height: self.format.height),
                                                  tick: self.frameIndex),
               let buf = SampleBufferFactory.makeBuffer(from: img, format: self.format) {
                onFrame(buf)
            }
        }
        t.resume()
        timer = t
    }

    public func stop() { timer?.cancel(); timer = nil }
}

/// 占位的渲染器：画一张带时间戳/版本号的卡片，足以让用户在模拟器里看到 SimCam 在工作。
enum DemoCardRenderer {
    static func render(size: CGSize, tick: Int) -> CGImage? {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil,
                                  width: Int(size.width),
                                  height: Int(size.height),
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        ctx.setFillColor(red: 0.03, green: 0.04, blue: 0.06, alpha: 1)
        ctx.fill(CGRect(origin: .zero, size: size))

        let cx = size.width / 2, cy = size.height / 2
        let radius = min(size.width, size.height) * 0.32
        let phase = Double(tick % 240) / 240.0 * .pi * 2
        ctx.setStrokeColor(red: 0.78, green: 0.96, blue: 0.38, alpha: 0.8)
        ctx.setLineWidth(6)
        ctx.addArc(center: CGPoint(x: cx, y: cy), radius: radius,
                   startAngle: phase, endAngle: phase + .pi * 1.4, clockwise: false)
        ctx.strokePath()

        ctx.setFillColor(red: 1, green: 0.54, blue: 0.24, alpha: 1)
        ctx.fillEllipse(in: CGRect(x: cx - 16, y: cy - 16, width: 32, height: 32))

        return ctx.makeImage()
    }
}

/// 把 CGImage 装进 CMSampleBuffer，供 Camera Extension 消费。
enum SampleBufferFactory {
    static func makeBuffer(from cgImage: CGImage, format: FrameFormat) -> CMSampleBuffer? {
        var pxbuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         format.width, format.height,
                                         kCVPixelFormatType_32BGRA,
                                         attrs as CFDictionary,
                                         &pxbuffer)
        guard status == kCVReturnSuccess, let pb = pxbuffer else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb),
                                  width: format.width,
                                  height: format.height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: format.width, height: format.height))

        var formatDesc: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                     imageBuffer: pb,
                                                     formatDescriptionOut: &formatDesc)
        guard let desc = formatDesc else { return nil }

        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(format.fps)),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                           imageBuffer: pb,
                                           dataReady: true,
                                           makeDataReadyCallback: nil,
                                           refcon: nil,
                                           formatDescription: desc,
                                           sampleTiming: &timing,
                                           sampleBufferOut: &sample)
        return sample
    }

    static func retiming(buffer: CMSampleBuffer, format: FrameFormat) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(format.fps)),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                                              sampleBuffer: buffer,
                                              sampleTimingEntryCount: 1,
                                              sampleTimingArray: &timing,
                                              sampleBufferOut: &copy)
        return copy
    }
}

/// 列出系统中所有可用的物理 / 虚拟摄像头，供 menubar 与 simcamctl list-cameras 使用。
public enum CameraDiscovery {
    /// SimCam 虚拟摄像头在 Camera Extension 里宣告的本地化名前缀。
    /// 真实 Extension 注册成什么名字，这里就识别什么名字。
    public static let virtualCameraName = "SimCam Virtual Camera"

    /// SimCam 虚拟摄像头在 Camera Extension 注册时使用的 UUID（device UID）。
    /// host 端 HAL 层用 `kCMIODevicePropertyDeviceUID` 反查 CMIODeviceID 时
    /// 用这个常量做 needle，避免 host 端 AVFoundation 被 cmiod 屏蔽的回环坑。
    public static let virtualCameraDeviceUID = "5C8F9A6E-2D11-4A5D-8E6E-3F1C4B1E0001"

    /// 列出 macOS 端所有可用摄像头。
    /// - Parameter includeSimCamVirtual: 是否包含 SimCam 自家虚拟相机。
    ///   默认 `false`：避免「back source 选 SimCam Virtual Camera → 自指 cycle」。
    public static func list(includeSimCamVirtual: Bool = false) -> [CameraDescriptor] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .deskViewCamera]
        if #available(macOS 14.0, *) {
            types.append(.external)
            types.append(.continuityCamera)
        } else {
            // macOS 13 fallback
            types.append(.externalUnknown)
        }
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: .unspecified
        )
        return session.devices.compactMap { d -> CameraDescriptor? in
            let kind = classify(device: d)
            if !includeSimCamVirtual && kind == .simcamVirtual { return nil }
            return CameraDescriptor(uniqueID: d.uniqueID,
                                    localizedName: d.localizedName,
                                    kind: kind)
        }
    }

    private static func classify(device d: AVCaptureDevice) -> CameraKind {
        if d.localizedName.lowercased().hasPrefix(virtualCameraName.lowercased()) {
            return .simcamVirtual
        }
        switch d.deviceType {
        case .deskViewCamera:                          return .deskView
        case .builtInWideAngleCamera:                  return .builtIn
        default: break
        }
        if #available(macOS 14.0, *) {
            switch d.deviceType {
            case .continuityCamera: return .continuity
            case .external:         return .external
            default: break
            }
        }
        if d.deviceType == .externalUnknown { return .external }
        return .unknown
    }

    public static func device(uniqueID: String) -> AVCaptureDevice? {
        AVCaptureDevice(uniqueID: uniqueID)
    }

    /// 在系统枚举里找 SimCam 虚拟摄像头（含 SimCam 自家），用于 diagnostic。
    public static func findVirtualCamera() -> CameraDescriptor? {
        list(includeSimCamVirtual: true).first { $0.kind == .simcamVirtual }
    }
}

/// ScreenCaptureKit 桌面 / 窗口源的发现与采集。
@available(macOS 12.3, *)
public enum ScreenSourceDiscovery {
    /// `SCShareableContent` 真实状态。注意：在 macOS 14+ 即便 TCC 拒绝，
    /// 该 API 仍会成功返回（不抛错），只是 `displays` 数组永远为空、`windows`
    /// 数组里所有 entry 的 `owningApplication` 都是 nil。这是判定「未授权」
    /// 唯一可靠的信号——单纯 `displays.isEmpty` 不行（极少数 headless mac
    /// 是真没显示器），不能跟「未授权」混为一谈。
    public enum AuthState {
        /// 已授权，且 SC 返回了至少 1 个 display。
        case authorized
        /// SC 返回成功但 displays 为空且所有 windows 缺 owningApplication，
        /// 这是 ad-hoc TCC 失效的典型表现（例如重 build 后 cdhash 变化）。
        case denied
        /// 未知错误（SC API 抛错），理论上极少。
        case unknown(Error)
    }

    /// 异步列出可选屏幕 + 顶层窗口（过滤掉 SimCamApp 自身，避免自指）。
    public static func list() async -> [ScreenSourceDescriptor] {
        let (sources, _) = await listWithAuth()
        return sources
    }

    /// 同时返回授权状态，方便 UI 区分「真无 display」和「未授权」。
    public static func listWithAuth() async -> ([ScreenSourceDescriptor], AuthState) {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent
                .excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            return ([], .unknown(error))
        }

        // 「未授权」探测：displays 全空 + windows 数组里**所有** entry
        // 都拿不到 owningApplication —— 这只在 SC 进入 TCC 退化路径时成立。
        // 真无显示器（极少）也是 displays 空，但那种情况下 windows 数组
        // 里至少能看到 SimCamApp 自身或别的 mac app 的 window。
        let allWindowsHaveNoOwner = !content.windows.isEmpty &&
            content.windows.allSatisfy { $0.owningApplication == nil }
        if content.displays.isEmpty && (content.windows.isEmpty || allWindowsHaveNoOwner) {
            return ([], .denied)
        }

        var out: [ScreenSourceDescriptor] = []
        for d in content.displays {
            out.append(.init(id: "display:\(d.displayID)",
                             kind: .display,
                             displayID: UInt32(d.displayID),
                             windowID: 0,
                             title: "Display \(d.displayID) (\(d.width)×\(d.height))"))
        }
        let myPid = ProcessInfo.processInfo.processIdentifier
        for w in content.windows {
            if w.owningApplication?.processID == myPid { continue }   // 过滤自己
            if (w.title ?? "").isEmpty && (w.owningApplication?.applicationName ?? "").isEmpty {
                continue
            }
            out.append(.init(id: "window:\(w.windowID)",
                             kind: .window,
                             displayID: 0,
                             windowID: UInt32(w.windowID),
                             title: w.title ?? "Untitled",
                             ownerApp: w.owningApplication?.applicationName))
        }
        return (out, .authorized)
    }

    /// 强制触发 TCC 系统授权对话框：用 SCStream.startCapture 拉一帧后立刻 stop。
    /// 这是当前已知**唯一**能在没装第三方 helper 的情况下让用户看到 macOS
    /// 系统对话框的方式（SCShareableContent 在 macOS 14+ 不再主动弹）。
    /// 调用线程不限，内部 await。返回值表示是否最终拿到了授权。
    public static func requestAuthorizationByProbingCapture() async -> AuthState {
        // 第一步：先看现状——也许已经授权了。
        let (_, before) = await listWithAuth()
        if case .authorized = before { return .authorized }

        // 第二步：用 SCStream 试启一次。这是触发 macOS 系统对话框的可靠路径。
        // 注意：必须在 main actor 之外的 task 跑，且要 try await。
        do {
            let content = try await SCShareableContent
                .excludingDesktopWindows(false, onScreenWindowsOnly: true)
            // 没 display 但 startCapture 也能弹对话框，所以构造一个「窗口」
            // filter——any window 即可。如果连 windows 都拿不到，就放弃。
            let filter: SCContentFilter
            if let display = content.displays.first {
                filter = SCContentFilter(display: display, excludingWindows: [])
            } else if let win = content.windows.first {
                filter = SCContentFilter(desktopIndependentWindow: win)
            } else {
                return .denied
            }
            let cfg = SCStreamConfiguration()
            cfg.width = 64
            cfg.height = 64
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            cfg.pixelFormat = kCVPixelFormatType_32BGRA
            let stream = SCStream(filter: filter, configuration: cfg, delegate: nil)
            try await stream.startCapture()
            try? await stream.stopCapture()
        } catch {
            os_log("[ScreenSourceDiscovery] probe stream failed: %{public}@",
                   log: .default, type: .error, String(describing: error))
        }

        // 第三步：再查一次最新状态。
        let (_, after) = await listWithAuth()
        return after
    }
}

/// 桌面 / 窗口捕获生产者：通过 ScreenCaptureKit 输出 CMSampleBuffer。
///
/// 首次 start 时若用户没给屏幕录制权限会在系统设置里弹「Privacy & Security →
/// Screen Recording → SimCamApp」，授权后第二次 start 即可正常出帧。
///
/// **`followSimulator` 模式**（SimCam 商业版默认 back 行为）：
/// 不再录整张主屏（会把 mac 整桌面塞进 iPhone preview），而是定位 iOS Simulator
/// 的窗口位置，把那块矩形当成 SCStream 的 `sourceRect`。等同于「相机透过
/// Simulator 这个窗户看背后的世界」。同时把 Simulator 窗口本身加入
/// `excludingWindows`，防止 simulator 录到自己（递归镜像套娃）。窗口移动 / 缩放
/// 时定期刷新 `sourceRect`。
@available(macOS 12.3, *)
public final class ScreenFrameProducer: NSObject, FrameProducer, SCStreamOutput {
    public var format: FrameFormat
    private let displayID: UInt32
    private let windowID: UInt32
    private let includeMouse: Bool
    private let followSimulator: Bool
    private var stream: SCStream?
    private var onFrameHandler: ((CMSampleBuffer) -> Void)?
    private let outputQueue = DispatchQueue(label: "simcam.screen.producer", qos: .userInteractive)

    // followSimulator 模式：周期刷新 simulator window frame，更新 sourceRect。
    private var followTimer: DispatchSourceTimer?
    private var lastSimulatorRect: CGRect = .zero
    private var lastSimulatorWindowID: CGWindowID = 0
    private var currentDisplay: SCDisplay?

    public init(displayID: UInt32, windowID: UInt32 = 0,
                includeMouse: Bool = true, format: FrameFormat = .default,
                followSimulator: Bool = false) {
        self.displayID = displayID
        self.windowID = windowID
        self.includeMouse = includeMouse
        self.format = format
        self.followSimulator = followSimulator
    }

    public func start(onFrame: @escaping (CMSampleBuffer) -> Void) throws {
        self.onFrameHandler = onFrame
        // 注意：**不再调** `CGPreflightScreenCaptureAccess()` / `CGRequestScreenCaptureAccess()`。
        // 那是 CoreGraphics 时代的 API，跟 ScreenCaptureKit 的 TCC 检测路径
        // 不一致 —— 实际表现是「在 System Settings 里把 SimCamApp 开了，
        // CGPreflight 仍然返回 false」（特别是 ad-hoc 签名 rebuild cdhash 变化后），
        // 然后 CGRequest 又会弹一次，永远授不过去。
        //
        // 正确做法：直接走 SCShareableContent。它内部自己跟 tccd 通讯，
        // 第一次会弹一次系统对话框（与 CG API 完全不同的、由 ReplayKit /
        // ScreenCaptureKit 私有 framework 触发的对话框），用户允许后**当前
        // 进程立刻可用**，**不必重启 SimCamApp**。失败时把错误抛出去，
        // 让 SimCamEngine.start() 回退 demo。
        Task { [weak self] in
            do {
                try await self?.startAsync()
            } catch {
                os_log("[ScreenFrameProducer] startAsync failed: %{public}@",
                       log: .default, type: .error,
                       String(describing: error))
            }
        }
    }

    private func startAsync() async throws {
        let content = try await SCShareableContent
            .excludingDesktopWindows(false, onScreenWindowsOnly: true)

        let filter: SCContentFilter
        // 输出 buffer 的「物理像素」尺寸：按源（display / window）的原始 aspect
        // 算，**绝不**强行套 format.width × format.height（默认 1080×1920，9:16
        // 纵向）。否则 SCStream 会把横向 mac 桌面 letterbox 进 9:16 buffer，
        // 上下塞两条黑边——hook 端的 AVCaptureVideoPreviewLayer 哪怕用
        // ResizeAspectFill 也救不回来（它看到的就是一张「带黑边的图」），
        // 显示效果就是图 2：iPhone 中间一小块画面 + 上下大黑边。
        //
        // 改成保留源原始 aspect：宽度上限 = format.width；高度按 aspect 等比
        // 缩放。这样 buffer 里没有黑边，layer 用 ResizeAspectFill 时会**裁掉
        // 左右**（横向桌面）而不是补黑边——这才是 SimCam 商业版（图 1）那种
        // 「相机画面铺满 iPhone 屏幕」的观感。
        var captureWidth = format.width
        var captureHeight = format.height
        var sourceRect: CGRect = .zero  // followSimulator 用
        if windowID != 0,
           let win = content.windows.first(where: { UInt32($0.windowID) == windowID }) {
            filter = SCContentFilter(desktopIndependentWindow: win)
            let f = win.frame
            if f.width > 0 && f.height > 0 {
                let scale: Double = min(Double(format.width) / Double(f.width),
                                        Double(format.height) / Double(f.height))
                captureWidth  = max(2, Int(Double(f.width)  * scale))
                captureHeight = max(2, Int(Double(f.height) * scale))
            }
        } else {
            let display: SCDisplay
            if let d = content.displays.first(where: { UInt32($0.displayID) == displayID }) {
                display = d
            } else if let d = content.displays.first {
                display = d
            } else {
                throw NSError(domain: "SimCam.Screen", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "no display available"])
            }
            self.currentDisplay = display

            if followSimulator,
               let simRect = Self.locateSimulatorWindowRect(on: display, content: content) {
                // followSimulator 路径：抠出 Simulator 窗口背后的桌面。
                // - sourceRect 用 macOS 「point」单位（不是像素），左上原点，
                //   原点 = display 左上角；
                // - excludingWindows 把 Simulator.app 所有窗口排除掉，否则
                //   simulator 录到自己 → 套娃；
                // - captureWidth/Height 按 sourceRect aspect 算，避免黑边。
                let simulatorWindows = content.windows.filter {
                    Self.isSimulatorApp($0.owningApplication?.bundleIdentifier)
                }
                filter = SCContentFilter(display: display, excludingWindows: simulatorWindows)
                sourceRect = simRect
                self.lastSimulatorRect = simRect
                let scale: Double = min(Double(format.width) / Double(simRect.width),
                                        Double(format.height) / Double(simRect.height))
                captureWidth  = max(2, Int(Double(simRect.width)  * scale))
                captureHeight = max(2, Int(Double(simRect.height) * scale))
                os_log("[ScreenFrameProducer] followSimulator rect=%{public}@ buffer=%dx%d",
                       log: .default, type: .info,
                       NSStringFromRect(simRect) as NSString, captureWidth, captureHeight)
            } else {
                filter = SCContentFilter(display: display, excludingWindows: [])
                let dw = display.width, dh = display.height
                if dw > 0 && dh > 0 {
                    let scale: Double = min(Double(format.width) / Double(dw),
                                            Double(format.height) / Double(dh))
                    captureWidth  = max(2, Int(Double(dw) * scale))
                    captureHeight = max(2, Int(Double(dh) * scale))
                }
            }
        }

        let cfg = SCStreamConfiguration()
        cfg.width = captureWidth
        cfg.height = captureHeight
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, format.fps)))
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.showsCursor = includeMouse
        cfg.queueDepth = 5
        if sourceRect.width > 0 && sourceRect.height > 0 {
            cfg.sourceRect = sourceRect
            cfg.destinationRect = CGRect(x: 0, y: 0, width: captureWidth, height: captureHeight)
        }

        let s = SCStream(filter: filter, configuration: cfg, delegate: nil)
        try s.addStreamOutput(self, type: .screen,
                              sampleHandlerQueue: outputQueue)
        try await s.startCapture()
        self.stream = s

        if followSimulator {
            startFollowTimer()
        }
    }

    public func stop() {
        followTimer?.cancel()
        followTimer = nil
        guard let s = stream else { return }
        Task { try? await s.stopCapture() }
        stream = nil
        onFrameHandler = nil
    }

    // MARK: SCStreamOutput
    public func stream(_ stream: SCStream,
                       didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                       of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        // SCStream 给的 sample 默认会带 attachment，需要确认 status==complete
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let info = attachments.first,
           let statusRaw = info[.status] as? Int,
           let status = SCFrameStatus(rawValue: statusRaw),
           status != .complete {
            return
        }
        onFrameHandler?(sampleBuffer)
    }

    // MARK: - followSimulator helpers

    /// Simulator.app 的 bundle id。注意 macOS Simulator 装 Xcode 自带的是
    /// `com.apple.iphonesimulator`（俗称 Simulator.app），跟 simulator 内部
    /// 跑的 demo app bundle id 完全无关。
    private static let simulatorBundleID = "com.apple.iphonesimulator"

    private static func isSimulatorApp(_ bundleID: String?) -> Bool {
        guard let id = bundleID else { return false }
        return id == simulatorBundleID
    }

    /// 在 SC 视野里找到当前 booted simulator 的窗口矩形。
    /// 返回值是 macOS **point** 坐标，原点 = 给定 display 左上角，y 轴向下。
    /// 若有多个 simulator 窗口（同时跑多台），优先选 frame 最大那个。
    private static func locateSimulatorWindowRect(on display: SCDisplay,
                                                  content: SCShareableContent) -> CGRect? {
        // SC 给的 window.frame 已经是 display-local 坐标（左上原点），方便
        // 直接喂给 SCStreamConfiguration.sourceRect。
        let candidates = content.windows.filter {
            isSimulatorApp($0.owningApplication?.bundleIdentifier)
                && $0.frame.width > 100 && $0.frame.height > 100
        }
        guard !candidates.isEmpty else {
            os_log("[ScreenFrameProducer] no Simulator window found in SC content (windows=%d)",
                   log: .default, type: .info, content.windows.count)
            return nil
        }
        // 选 area 最大的那个（一般就是当前活动 simulator 窗口）
        let best = candidates.max { lhs, rhs in
            lhs.frame.width * lhs.frame.height < rhs.frame.width * rhs.frame.height
        }!
        let f = best.frame
        let displayBounds = CGRect(x: 0, y: 0,
                                   width: CGFloat(display.width),
                                   height: CGFloat(display.height))
        // 裁剪到 display 范围内，防止跨屏窗口越界
        let clipped = f.intersection(displayBounds)
        return clipped.width > 50 && clipped.height > 50 ? clipped : nil
    }

    /// 启动定时器周期检测 simulator 窗口位置。窗口 frame 变化超阈值时
    /// 调 `stream.updateConfiguration` 实现「跟随移动」。
    private func startFollowTimer() {
        let timer = DispatchSource.makeTimerSource(queue: outputQueue)
        timer.schedule(deadline: .now() + .milliseconds(500),
                       repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            self?.refreshSourceRectIfNeeded()
        }
        timer.resume()
        followTimer = timer
    }

    private func refreshSourceRectIfNeeded() {
        guard let stream = self.stream, let display = self.currentDisplay else { return }
        Task { [weak self] in
            guard let self else { return }
            let content: SCShareableContent
            do {
                content = try await SCShareableContent
                    .excludingDesktopWindows(false, onScreenWindowsOnly: true)
            } catch {
                return
            }
            guard let newRect = Self.locateSimulatorWindowRect(on: display, content: content) else {
                return
            }
            // 抖动阈值：偏移 < 1pt 不动作（避免无意义 reconfigure）
            let dx = abs(newRect.origin.x - self.lastSimulatorRect.origin.x)
            let dy = abs(newRect.origin.y - self.lastSimulatorRect.origin.y)
            let dw = abs(newRect.width  - self.lastSimulatorRect.width)
            let dh = abs(newRect.height - self.lastSimulatorRect.height)
            if dx < 1 && dy < 1 && dw < 1 && dh < 1 { return }
            self.lastSimulatorRect = newRect

            // 重新算 buffer 大小（aspect 跟随 simulator 窗口）
            let scale: Double = min(Double(self.format.width)  / Double(newRect.width),
                                    Double(self.format.height) / Double(newRect.height))
            let bw = max(2, Int(Double(newRect.width)  * scale))
            let bh = max(2, Int(Double(newRect.height) * scale))

            let cfg = SCStreamConfiguration()
            cfg.width  = bw
            cfg.height = bh
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, self.format.fps)))
            cfg.pixelFormat = kCVPixelFormatType_32BGRA
            cfg.showsCursor = self.includeMouse
            cfg.queueDepth = 5
            cfg.sourceRect = newRect
            cfg.destinationRect = CGRect(x: 0, y: 0, width: bw, height: bh)

            do {
                try await stream.updateConfiguration(cfg)
                // excludingWindows 也得跟着刷（simulator 可能新增窗口）
                let simulatorWindows = content.windows.filter {
                    Self.isSimulatorApp($0.owningApplication?.bundleIdentifier)
                }
                let newFilter = SCContentFilter(display: display, excludingWindows: simulatorWindows)
                try await stream.updateContentFilter(newFilter)
            } catch {
                os_log("[ScreenFrameProducer] follow update failed: %{public}@",
                       log: .default, type: .error, String(describing: error))
            }
        }
    }
}

