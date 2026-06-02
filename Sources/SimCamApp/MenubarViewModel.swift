import Foundation
import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers

@MainActor
final class MenubarViewModel: ObservableObject {
    @Published var state: SimCamState = SimCamEngine.shared.state
    @Published var cameras: [CameraDescriptor] = []
    @Published var screens: [ScreenSourceDescriptor] = []
    /// 屏幕录制权限的当前状态（用 UI 区分「正在查」「已授权」「未授权」「真无 display」）。
    /// 注意：macOS 14+ 下 SCShareableContent 不会主动弹对话框，未授权也不抛错——
    /// 必须显式调 SCStream.startCapture 才会弹。所以 UI 必须暴露一个 Grant 按钮。
    @Published var screenAuth: ScreenAuthDisplayState = .unknown
    @Published var diagnostics: [Diagnostic] = []
    @Published var qrPayload: String = "AUTH_TOKEN_XYZ"
    @Published var hookConnections: Int = 0
    @Published var simulatorBundleID: String = "dev.simcam.demo"
    @Published var lastInjectLog: String = ""

    /// UI 友好的屏幕录制权限状态。Engine 端 ScreenSourceDiscovery.AuthState
    /// 是 enum with associated value，UI 只需 4 个互斥状态。
    enum ScreenAuthDisplayState: Equatable {
        case unknown        // 还没查过
        case authorized     // 已授权
        case denied         // 未授权 / cdhash 失效
        case requesting     // 正在拉系统对话框
    }

    private var timer: Timer?

    init() {
        SimCamEngine.shared.subscribe { [weak self] new in
            DispatchQueue.main.async { self?.state = new }
        }
        // 1.5 秒只刷"廉价"项（cameras / diagnostics / state / hookConnections），
        // **不要**在 timer 里调 ScreenSourceDiscovery.list() —— 它内部走
        // SCShareableContent，是个 async API，没授屏幕录制权限时每次调用都
        // 触发系统权限对话框，授权后也会每次跑回 main thread 一段非平凡的
        // 时间，把 SwiftUI ForEach 子树的 hit-test 抢占掉。
        // 屏幕源列表只在 init 一次性 + 用户手动 refresh 时才拉。
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshCheap() }
        }
        if #available(macOS 12.3, *) {
            Task { [weak self] in await self?.refreshScreens() }
        }
    }

    deinit { timer?.invalidate() }

    /// 全量 refresh：UI 显式调（onAppear / 手动）才会拉屏幕源。
    func refresh() {
        refreshCheap()
        if #available(macOS 12.3, *) {
            Task { [weak self] in await self?.refreshScreens() }
        }
    }

    /// 1.5 秒 timer 里只跑这部分 —— 廉价、不 IPC、不弹权限。
    private func refreshCheap() {
        let newCameras = CameraDiscovery.list()
        if newCameras.map(\.uniqueID) != cameras.map(\.uniqueID) {
            cameras = newCameras
        }
        let newDiag = SimCamEngine.shared.diagnose()
        if newDiag.map({ "\($0.key)=\($0.ok)" }) != diagnostics.map({ "\($0.key)=\($0.ok)" }) {
            diagnostics = newDiag
        }
        let newState = SimCamEngine.shared.state
        if newState != state { state = newState }
        let newHook = SimCamEngine.shared.connectedHookCount
        if newHook != hookConnections { hookConnections = newHook }
    }

    @available(macOS 12.3, *)
    private func refreshScreens() async {
        let (s, auth) = await ScreenSourceDiscovery.listWithAuth()
        await MainActor.run {
            let newKey = s.map { "\($0.displayID)/\($0.windowID)/\($0.title)" }
            let oldKey = self.screens.map { "\($0.displayID)/\($0.windowID)/\($0.title)" }
            if newKey != oldKey { self.screens = s }
            switch auth {
            case .authorized:    self.screenAuth = .authorized
            case .denied:        self.screenAuth = .denied
            case .unknown:       self.screenAuth = .denied
            }
        }
    }

    /// UI 上点 "Grant" 按钮调这个 —— 显式触发 SCStream.startCapture 让
    /// macOS 弹系统对话框；用户允许后自动重 list。这是 macOS 14+ 唯一
    /// 能让用户看到对话框的方式（SCShareableContent 自身不再弹）。
    @available(macOS 12.3, *)
    func requestScreenAuthorization() {
        screenAuth = .requesting
        Task { [weak self] in
            _ = await ScreenSourceDiscovery.requestAuthorizationByProbingCapture()
            await self?.refreshScreens()
        }
    }

    /// 设置某一槽位（back/front）的输入源 —— 这是和 SimCam 商业版菜单栏对齐的核心动作。
    /// 用户在 menu 里改源 = 「手动覆盖」，落 UserDefaults，下次启动恢复。
    func setSource(_ source: CameraSource, slot: CameraSlot) {
        _ = SimCamEngine.shared.setSource(source, slot: slot)
        SimCamEngine.shared.persistOverride(source, slot: slot)
        // 不要在 setSource 里调 refresh()。SimCamEngine 已经通过 subscribe
        // 推 state，UI 会自然更新；refresh() 会重建 cameras/screens 数组，
        // 把同一帧里 SwiftUI 正在处理的 hitTest 流弄飞。
    }

    /// 单路停止
    func stopSlot(_ slot: CameraSlot) {
        SimCamEngine.shared.stop(slot: slot)
    }

    func setStreaming(_ on: Bool) {
        if on { SimCamEngine.shared.start() } else { SimCamEngine.shared.stop() }
    }

    func pickImage(slot: CameraSlot) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .png, .jpeg, .heic]
        if panel.runModal() == .OK, let url = panel.url {
            setSource(.image(path: url.path), slot: slot)
        }
    }

    func pickVideo(slot: CameraSlot) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .quickTimeMovie, .mpeg4Movie]
        if panel.runModal() == .OK, let url = panel.url {
            setSource(.video(path: url.path, loop: true), slot: slot)
        }
    }

    func bootSimulator() {
        NSWorkspace.shared.launchApplication("Simulator")
    }

    /// 调 scripts/inject-simulator.sh 把 SimCamHook 注入到指定 bundle id
    /// 的 simulator app。这是 SimCam 商业版的对应操作。
    func injectIntoSimulator() {
        let proc = Process()
        proc.launchPath = "/bin/zsh"
        let scriptURL = projectRoot().appendingPathComponent("scripts/inject-simulator.sh")
        proc.arguments = [scriptURL.path, simulatorBundleID]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        proc.environment = ProcessInfo.processInfo.environment
        do {
            try proc.run()
            DispatchQueue.global().async { [weak self] in
                proc.waitUntilExit()
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8) ?? ""
                DispatchQueue.main.async {
                    self?.lastInjectLog = out
                    self?.refresh()
                }
            }
        } catch {
            lastInjectLog = "failed: \(error.localizedDescription)"
        }
    }

    private func projectRoot() -> URL {
        // SimCamApp.app/Contents/MacOS/SimCamApp → 回退两级到工程根
        // 但用户既可能从 /Applications 跑，也可能从 DerivedData 跑；
        // 优先靠 SOURCE_ROOT/PWD 定位。
        if let env = ProcessInfo.processInfo.environment["SIMCAM_PROJECT_ROOT"] {
            return URL(fileURLWithPath: env)
        }
        // fallback：尝试常见位置
        let candidates = [
            "~/workspace/swmansion-copy",
            "~/Developer/swmansion-copy",
        ].map { NSString(string: $0).expandingTildeInPath }
        for c in candidates where FileManager.default.fileExists(atPath: c + "/scripts/inject-simulator.sh") {
            return URL(fileURLWithPath: c)
        }
        return URL(fileURLWithPath: "/")
    }
}
