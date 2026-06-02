import Foundation
import AVFoundation
import CoreMedia
import ImageIO
import os.log

/// SimCamEngine 是核心控制器：
/// • 维护 back / front 两个独立的 [FrameProducer]（对齐 SimCam 商业版双路）
/// • 把每一帧推到 LocalSocketFrameServer 的对应 slot；hook 端按 slot
///   分别喂给被测 app 的 .back / .front AVCaptureDevice
/// • 维护当前 SimCamState
public final class SimCamEngine {
    public static let shared = SimCamEngine()

    private let log = OSLog(subsystem: "dev.simcam", category: "engine")
    private let frameSocket = LocalSocketFrameServer()
    private let stateLock = NSLock()
    private var producers: [CameraSlot: FrameProducer] = [:]
    private var _state = SimCamState()
    private var listeners: [(SimCamState) -> Void] = []

    public private(set) var license: LicenseManager = LicenseManager()

    private init() {
        _state.license = license.current
        frameSocket.start()
    }

    /// host→simulator 的 unix domain socket 路径，用于 menubar 展示。
    public var frameSocketPath: String { LocalSocketFrameServer.socketPath }

    /// 当前连上来的 simulator hook 数（每次 hook 注入到 simulator 进程都会
    /// 多一条 client 连接）。
    public var connectedHookCount: Int { frameSocket.clientCount }

    public var state: SimCamState {
        stateLock.lock(); defer { stateLock.unlock() }
        return _state
    }

    public func subscribe(_ block: @escaping (SimCamState) -> Void) {
        stateLock.lock()
        listeners.append(block)
        let snapshot = _state
        stateLock.unlock()
        block(snapshot)
    }

    /// 老式单参 API —— 等同于设置 back 槽位。新代码应显式传 slot。
    @discardableResult
    public func setSource(_ source: CameraSource) -> Result<SimCamState, EngineError> {
        setSource(source, slot: .back)
    }

    /// 设置某一个槽位（back/front）的输入源。
    @discardableResult
    public func setSource(_ source: CameraSource, slot: CameraSlot) -> Result<SimCamState, EngineError> {
        if source.requiresPro && license.current != .pro {
            return .failure(.licenseRequired)
        }
        // 停掉旧的
        producers[slot]?.stop()
        producers.removeValue(forKey: slot)

        // 设 QR payload（其它源类型 nil）
        switch source {
        case .qr(let payload): frameSocket.setQRPayload(payload, slot: slot)
        default:               frameSocket.setQRPayload(nil, slot: slot)
        }

        if source == .none {
            mutate { st in
                st.set(source: .none, for: slot)
                st.setStreaming(false, for: slot)
            }
            return .success(state)
        }

        do {
            let p = try makeProducer(for: source, format: state.format)
            try p.start { [weak self, slot] sample in
                self?.frameSocket.push(sample, slot: slot)
            }
            producers[slot] = p
            mutate { st in
                st.set(source: source, for: slot)
                st.setStreaming(true, for: slot)
            }
            os_log("[%{public}@] source -> %{public}@", log: log, slot.label, source.description)
            return .success(state)
        } catch {
            os_log("[%{public}@] FAIL setSource %{public}@ — %{public}@",
                   log: log, type: .error,
                   slot.label, source.description, error.localizedDescription)
            mutate { st in
                st.set(source: .none, for: slot)
                st.setStreaming(false, for: slot)
            }
            return .failure(.producer(error.localizedDescription))
        }
    }

    public func setFormat(_ format: FrameFormat) {
        mutate { $0.format = format }
        // 重建当前两路 producer，应用新尺寸
        let snapshot = state
        for slot in CameraSlot.allCases where snapshot.source(for: slot) != .none {
            _ = setSource(snapshot.source(for: slot), slot: slot)
        }
    }

    public func start() {
        // 1. 先把 UserDefaults 里上次手动选过的覆盖恢复出来（没有的 slot 就走智能默认）
        let backDefault: CameraSource = persistedSource(for: .back) ?? smartDefault(for: .back)
        let frontDefault: CameraSource = persistedSource(for: .front) ?? smartDefault(for: .front)

        // 2. 若 state 已经是非 none（从 menubar UI 主动设置过），尊重当前 state；
        //    否则按上面计算出来的默认拉起来
        let s = state
        let backTarget = (s.backSource == .none) ? backDefault : s.backSource
        let frontTarget = (s.frontSource == .none) ? frontDefault : s.frontSource

        // 3. 启动 back 槽，失败回退 demo（譬如桌面捕获没权限）
        if !state.isBackStreaming {
            if case .failure = setSource(backTarget, slot: .back) {
                _ = setSource(.demo, slot: .back)
            }
        }
        // 4. 启动 front 槽，失败回退 demo（譬如没插 mac 摄像头）
        if !state.isFrontStreaming {
            if case .failure = setSource(frontTarget, slot: .front) {
                _ = setSource(.demo, slot: .front)
            }
        }
    }

    /// 是否「这个 slot 之前用户在 menu 里手动选过」。返回 nil 即没选过、应该用智能默认。
    private func persistedSource(for slot: CameraSlot) -> CameraSource? {
        let key = "simcam.source.\(slot.rawValue)"
        guard let data = UserDefaults.standard.data(forKey: key),
              let src = try? JSONDecoder().decode(CameraSource.self, from: data) else {
            return nil
        }
        // 持久化里存的 macCamera uniqueID 可能已不存在（设备拔了），回退 nil
        if case .macCamera(let uid, _) = src,
           CameraDiscovery.device(uniqueID: uid) == nil {
            return nil
        }
        return src
    }

    /// 没有用户覆盖时的「开箱即用智能默认」：
    /// • back  = 模拟器所在桌面（主显，整屏，含鼠标）
    /// • front = mac 内置/默认前置摄像头（FaceTime HD 等）
    /// 任意一个不可用时，让 setSource 失败回退到 demo（在 start() 里处理）。
    private func smartDefault(for slot: CameraSlot) -> CameraSource {
        switch slot {
        case .back:
            // 默认 back = SimCam 商业版同款「Simulator passthrough」：
            // 自动定位 booted Simulator 的窗口，相机看到的就是 simulator
            // 窗户背后那块桌面（跟随窗口移动）。
            return .simulatorPassthrough(includeMouse: true)
        case .front:
            // 优先找内置前摄；找不到（Mac mini / 外置）就用第一台可用相机
            let cams = CameraDiscovery.list()
            if let front = cams.first(where: { $0.localizedName.localizedCaseInsensitiveContains("FaceTime") }) {
                return .macCamera(uniqueID: front.uniqueID, localizedName: front.localizedName)
            }
            if let any = cams.first {
                return .macCamera(uniqueID: any.uniqueID, localizedName: any.localizedName)
            }
            return .demo
        }
    }

    /// menu UI 里用户手动改源时调一下，把覆盖落盘。
    public func persistOverride(_ source: CameraSource, slot: CameraSlot) {
        let key = "simcam.source.\(slot.rawValue)"
        if source == .none {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        if let data = try? JSONEncoder().encode(source) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    public func stop() {
        for (_, p) in producers { p.stop() }
        producers.removeAll()
        mutate { st in
            st.isBackStreaming = false
            st.isFrontStreaming = false
        }
    }

    /// 单路停止（menubar UI 上「这一路」的开关）。
    public func stop(slot: CameraSlot) {
        producers[slot]?.stop()
        producers.removeValue(forKey: slot)
        mutate { st in st.setStreaming(false, for: slot) }
    }

    @discardableResult
    public func activateLicense(key: String) -> Result<License, EngineError> {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.lowercased() == "trial" {
            license.activate(.trial)
            mutate { $0.license = .trial }
            return .success(.trial)
        }
        if LicenseManager.isValidProKey(trimmed) {
            license.activate(.pro)
            mutate { $0.license = .pro }
            return .success(.pro)
        }
        return .failure(.licenseRequired)
    }

    public func diagnose() -> [Diagnostic] {
        var out: [Diagnostic] = []
        out.append(.init(key: "license", ok: true, detail: license.current.label))
        let installed = SystemExtensionProbe.isSimCamExtensionInstalled()
        out.append(.init(key: "cmio extension",
                         ok: installed,
                         detail: installed
                            ? "Camera Extension activated (host AVCapture sees SimCam Virtual Camera)"
                            : "Camera Extension not activated (run scripts/install-systemext.sh)"))
        let hooks = connectedHookCount
        out.append(.init(key: "simulator hooks",
                         ok: hooks > 0,
                         detail: hooks > 0
                            ? "\(hooks) simulator process(es) connected"
                            : "no simulator app injected (run scripts/inject-simulator.sh)"))
        let cams = CameraDiscovery.list()
        out.append(.init(key: "cameras",
                         ok: !cams.isEmpty,
                         detail: "\(cams.count) device(s) detected"))
        out.append(.init(key: "macos",
                         ok: ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 13,
                         detail: ProcessInfo.processInfo.operatingSystemVersionString))
        return out
    }

    // MARK: - Private

    private func mutate(_ block: (inout SimCamState) -> Void) {
        stateLock.lock()
        block(&_state)
        let snapshot = _state
        let observers = listeners
        stateLock.unlock()
        observers.forEach { $0(snapshot) }
    }

    private func makeProducer(for source: CameraSource, format: FrameFormat) throws -> FrameProducer {
        switch source {
        case .none:
            throw EngineError.invalidSource("none")
        case .demo:
            return DemoCardFrameProducer(format: format)
        case .macCamera(let uniqueID, _):
            guard let dev = CameraDiscovery.device(uniqueID: uniqueID) else {
                throw EngineError.invalidSource("camera not found: \(uniqueID)")
            }
            return CameraDeviceFrameProducer(device: dev, format: format)
        case .image(let path):
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                throw EngineError.invalidSource("cannot read image: \(path)")
            }
            return StillImageFrameProducer(image: img, format: format)
        case .video(let path, let loop):
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw EngineError.invalidSource("video not found: \(path)")
            }
            return VideoFileFrameProducer(url: url, loop: loop, format: format)
        case .qr(let payload):
            guard let img = QRCodeGenerator.makeImage(payload: payload, size: 1024) else {
                throw EngineError.invalidSource("cannot encode qr payload")
            }
            return StillImageFrameProducer(image: img, format: format)
        case .screen(let displayID, let windowID, let includeMouse):
            if #available(macOS 12.3, *) {
                return ScreenFrameProducer(displayID: displayID,
                                           windowID: windowID,
                                           includeMouse: includeMouse,
                                           format: format)
            } else {
                throw EngineError.invalidSource("screen capture requires macOS 12.3+")
            }
        case .simulatorPassthrough(let includeMouse):
            if #available(macOS 12.3, *) {
                // displayID=0 → 主屏；followSimulator=true → 自动定位 Simulator 窗口
                return ScreenFrameProducer(displayID: 0,
                                           windowID: 0,
                                           includeMouse: includeMouse,
                                           format: format,
                                           followSimulator: true)
            } else {
                throw EngineError.invalidSource("simulator passthrough requires macOS 12.3+")
            }
        }
    }
}

public enum EngineError: Error, CustomStringConvertible {
    case licenseRequired
    case invalidSource(String)
    case producer(String)

    public var description: String {
        switch self {
        case .licenseRequired:        return "Pro license required for this source."
        case .invalidSource(let m):   return "Invalid source: \(m)"
        case .producer(let m):        return "Producer failed: \(m)"
        }
    }
}

// MARK: - SimCamState slot helpers

private extension SimCamState {
    mutating func set(source: CameraSource, for slot: CameraSlot) {
        switch slot {
        case .back:  backSource = source
        case .front: frontSource = source
        }
    }
    mutating func setStreaming(_ on: Bool, for slot: CameraSlot) {
        switch slot {
        case .back:  isBackStreaming = on
        case .front: isFrontStreaming = on
        }
    }
}

public final class LicenseManager {
    private let url: URL
    public private(set) var current: License = .trial

    public init() {
        let dir = NSString(string: "~/Library/Application Support/SimCam").expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        self.url = URL(fileURLWithPath: dir).appendingPathComponent("license.json")
        if let data = try? Data(contentsOf: url),
           let raw = try? JSONDecoder().decode([String: String].self, from: data),
           let kind = raw["kind"], kind == "pro" {
            current = .pro
        }
    }

    public func activate(_ license: License) {
        current = license
        let dict = ["kind": license.rawValue]
        if let data = try? JSONEncoder().encode(dict) {
            try? data.write(to: url, options: .atomic)
        }
    }

    public static func isValidProKey(_ key: String) -> Bool {
        let prefix = "SIMCAM-PRO-"
        guard key.hasPrefix(prefix) else { return false }
        let tail = String(key.dropFirst(prefix.count))
        guard tail.count >= 6 else { return false }
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "-_"))
        return tail.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
