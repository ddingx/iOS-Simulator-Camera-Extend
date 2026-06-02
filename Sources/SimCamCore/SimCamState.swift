import Foundation

/// SimCam 当前运行状态的快照，供 GUI 共享。
///
/// 双路源：和 SimCam 商业版一致，back / front 各自独立配置。
public struct SimCamState: Codable, Equatable {
    public var version: String
    public var backSource: CameraSource
    public var frontSource: CameraSource
    public var isBackStreaming: Bool
    public var isFrontStreaming: Bool
    public var format: FrameFormat
    public var connectedSimulators: Int
    public var license: License

    public init(
        version: String = SimCam.version,
        backSource: CameraSource = .none,
        frontSource: CameraSource = .none,
        isBackStreaming: Bool = false,
        isFrontStreaming: Bool = false,
        format: FrameFormat = .default,
        connectedSimulators: Int = 0,
        license: License = .trial
    ) {
        self.version = version
        self.backSource = backSource
        self.frontSource = frontSource
        self.isBackStreaming = isBackStreaming
        self.isFrontStreaming = isFrontStreaming
        self.format = format
        self.connectedSimulators = connectedSimulators
        self.license = license
    }

    /// 任一路在跑就算 streaming。
    public var isStreaming: Bool { isBackStreaming || isFrontStreaming }

    /// 兼容老调用方的便利属性 —— 等同于 `backSource`。
    /// 新代码应该显式用 `source(for:)`。
    public var source: CameraSource { backSource }

    public func source(for slot: CameraSlot) -> CameraSource {
        slot == .back ? backSource : frontSource
    }

    public func isStreaming(slot: CameraSlot) -> Bool {
        slot == .back ? isBackStreaming : isFrontStreaming
    }
}

public enum License: String, Codable, Equatable {
    case trial
    case pro

    public var label: String {
        switch self {
        case .trial: return "Trial"
        case .pro:   return "Pro · Lifetime"
        }
    }
}

public enum SimCam {
    public static let version = "1.0.0"
}

/// 让 menubar 不再瞎打 `back` 标签。
/// 由 host 端 [CameraDiscovery.list()] 根据 AVCaptureDevice.DeviceType + position 解算。
public enum CameraKind: String, Codable, Equatable {
    /// macOS 内置摄像头 / FaceTime HD（一律 unspecified position）
    case builtIn
    /// 外接 USB / 雷电摄像头
    case external
    /// iOS Continuity Camera（连续互通相机）
    case continuity
    /// Desk View Camera（俯瞰桌面那台）
    case deskView
    /// SimCam 自家 CMIO Camera Extension 暴露的虚拟相机（默认会被过滤）
    case simcamVirtual
    /// 真正的 iOS 端 front-facing（macOS 上不会出现，仅占位）
    case front
    /// 兜底
    case unknown

    public var displayLabel: String {
        switch self {
        case .builtIn:       return "built-in"
        case .external:      return "external"
        case .continuity:    return "continuity"
        case .deskView:      return "desk view"
        case .simcamVirtual: return "simcam"
        case .front:         return "front"
        case .unknown:       return ""
        }
    }
}

public struct CameraDescriptor: Codable, Equatable {
    public var uniqueID: String
    public var localizedName: String
    public var kind: CameraKind
    /// 仅供老调用方兼容；新代码应该读 `kind`。
    public var isFrontFacing: Bool { kind == .front }

    public init(uniqueID: String, localizedName: String, kind: CameraKind) {
        self.uniqueID = uniqueID
        self.localizedName = localizedName
        self.kind = kind
    }
}

public struct Diagnostic: Codable, Equatable {
    public var key: String
    public var ok: Bool
    public var detail: String
    public init(key: String, ok: Bool, detail: String) {
        self.key = key; self.ok = ok; self.detail = detail
    }
}

/// ScreenCaptureKit 列举出来的可选屏幕 / 窗口（通用描述符，给 menubar 用）。
public struct ScreenSourceDescriptor: Codable, Equatable, Identifiable {
    public enum Kind: String, Codable { case display, window }
    public var id: String  // "display:1" / "window:42"
    public var kind: Kind
    public var displayID: UInt32
    public var windowID: UInt32
    public var title: String
    public var ownerApp: String?

    public init(id: String, kind: Kind, displayID: UInt32, windowID: UInt32,
                title: String, ownerApp: String? = nil) {
        self.id = id; self.kind = kind
        self.displayID = displayID; self.windowID = windowID
        self.title = title; self.ownerApp = ownerApp
    }
}
