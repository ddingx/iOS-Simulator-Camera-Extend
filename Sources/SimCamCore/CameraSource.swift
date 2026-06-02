import Foundation
import CoreGraphics

/// 表示当前 SimCam 提供给 iOS Simulator 的输入源类型。
/// 这是一个稳定的对外协议，CLI 与 GUI 共用，序列化为 JSON 后通过 IPC 传输。
public enum CameraSource: Codable, Equatable, CustomStringConvertible {
    /// 无源（占位 / 关闭）
    case none
    /// 内置 Demo 视频（Trial 版唯一可用项）
    case demo
    /// 一台真实的物理 / 虚拟摄像头（uniqueID 由 AVCaptureDevice 提供）
    case macCamera(uniqueID: String, localizedName: String)
    /// 注入一张静态图片
    case image(path: String)
    /// 注入一段视频文件，循环播放
    case video(path: String, loop: Bool)
    /// 由 SimCam 现场生成的 QR Code，内容为 payload
    case qr(payload: String)
    /// 桌面 / 窗口捕获（基于 ScreenCaptureKit）。
    /// displayID == 0 时表示主屏；windowID == 0 时表示整屏。
    case screen(displayID: UInt32, windowID: UInt32, includeMouse: Bool)
    /// **Simulator passthrough**（SimCam 商业版默认 back 行为）：
    /// 自动定位 booted iOS Simulator 的 macOS 窗口，把那块矩形当 sourceRect
    /// 输出，并把 Simulator 窗口本身从录制中排除（防止套娃）。
    /// 视觉效果 = iPhone 相机透过 simulator 这个「窗户」看背后的桌面。
    case simulatorPassthrough(includeMouse: Bool)

    public var description: String {
        switch self {
        case .none:                                  return "none"
        case .demo:                                  return "demo"
        case .macCamera(_, let name):                return "camera://\(name)"
        case .image(let p):                          return "image://\(p)"
        case .video(let p, let loop):                return "video://\(p)?loop=\(loop)"
        case .qr(let payload):                       return "qr://\(payload)"
        case .screen(let d, let w, let m):           return "screen://display=\(d)/window=\(w)?cursor=\(m)"
        case .simulatorPassthrough(let m):           return "simulator-passthrough?cursor=\(m)"
        }
    }

    /// 是否需要 Pro 许可。本地复刻版不做付费限制——所有源全部免费可用。
    public var requiresPro: Bool { false }
}

/// 输入帧分辨率与方向描述。
public struct FrameFormat: Codable, Equatable {
    public var width: Int
    public var height: Int
    public var fps: Int
    public var isFrontFacing: Bool

    public init(width: Int = 1080, height: Int = 1920, fps: Int = 30, isFrontFacing: Bool = false) {
        self.width = width
        self.height = height
        self.fps = fps
        self.isFrontFacing = isFrontFacing
    }

    public static let `default` = FrameFormat()
}

/// 双路输入：被测 iOS app 拿到的两台 AVCaptureDevice 各自由这里独立选源。
/// SimCam 商业版同样是 back / front 两路独立配置。
public enum CameraSlot: Int, Codable, Equatable, CaseIterable {
    case back  = 0
    case front = 1

    public var label: String { self == .back ? "Back" : "Front" }
}
