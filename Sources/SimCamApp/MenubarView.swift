import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import os.log

private let uiLog = OSLog(subsystem: "dev.simcam", category: "ui")

struct MenubarView: View {
    @StateObject private var model = MenubarViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            statusBanner
            Divider().opacity(0.4)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    slotsSection
                    qrSection
                    injectSection
                    diagnosticsSection
                }
                .padding(16)
            }
            footer
        }
        .frame(width: 520, height: 760)
        .background(.ultraThinMaterial)
        .onAppear { model.refresh() }
    }

    @ViewBuilder
    private var statusBanner: some View {
        let cmioOK = model.diagnostics.first(where: { $0.key == "cmio extension" })?.ok ?? false
        let hookOK = model.hookConnections > 0
        VStack(alignment: .leading, spacing: 6) {
            row(dot: cmioOK ? .green : .orange,
                title: cmioOK
                    ? "macOS host: SimCam Virtual Camera ready"
                    : "macOS host: CMIO extension not activated",
                detail: cmioOK
                    ? "Any AVFoundation client on this Mac sees the SimCam camera."
                    : "Run `scripts/install-systemext.sh` then enable in System Settings.")
            row(dot: hookOK ? .green : .gray,
                title: hookOK
                    ? "iOS Simulator: \(model.hookConnections) app(s) injected"
                    : "iOS Simulator: no app injected yet",
                detail: hookOK
                    ? "Frames stream over /tmp/com.simcam.frames.sock — apps see it as standard AVFoundation."
                    : "Build SimCamDemo, install it on a booted simulator, then click Inject below.")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func row(dot: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(dot).frame(width: 8, height: 8).padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("SimCam").font(.headline)
                Text(headerSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { model.state.isStreaming },
                set: { model.setStreaming($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var headerSubtitle: String {
        if model.state.isStreaming {
            let parts = CameraSlot.allCases.compactMap { slot -> String? in
                guard model.state.isStreaming(slot: slot) else { return nil }
                return "\(slot.label.lowercased())=\(model.state.source(for: slot).shortLabel)"
            }
            return "● live · \(parts.joined(separator: " · "))"
        }
        return "idle · pick sources for back / front"
    }

    // MARK: - Two-column slot picker (mirrors SimCam's menubar)

    private var slotsSection: some View {
        HStack(alignment: .top, spacing: 12) {
            slotColumn(.back)
            Divider()
            slotColumn(.front)
        }
    }

    private func slotColumn(_ slot: CameraSlot) -> some View {
        let current = model.state.source(for: slot)
        let isOn = model.state.isStreaming(slot: slot)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: slot == .back ? "video" : "person.crop.square")
                    .foregroundStyle(.secondary)
                Text("\(slot.label) camera source".uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .tracking(1.2)
                Spacer()
                Circle().fill(isOn ? Color.green : Color.gray.opacity(0.4))
                    .frame(width: 7, height: 7)
            }
            // None
            sourceRow(slot: slot, icon: "circle.slash", label: "None",
                      selected: current == .none) {
                model.setSource(.none, slot: slot)
            }
            // Demo
            sourceRow(slot: slot, icon: "play.rectangle", label: "Demo (built-in)",
                      selected: current == .demo) {
                model.setSource(.demo, slot: slot)
            }
            // Simulator passthrough —— 抠出 booted simulator 窗口背后那块桌面
            // 当画面，并把 simulator 自己从 SCStream 里 excludingWindows 掉，
            // 这样不会拍到 simulator 窗口本身（避免递归套娃）。
            sourceRow(slot: slot, icon: "iphone.gen3",
                      label: "Simulator passthrough",
                      selected: { if case .simulatorPassthrough = current { return true } else { return false } }()) {
                model.setSource(.simulatorPassthrough(includeMouse: true), slot: slot)
            }
            // Real cameras —— ForEach 渲染 + Button hit-test。
            // 加显眼的 NSLog "TAP-FIRED-V2" 字符串，便于实测确认这次 build
            // 出来的二进制和你正在点的进程是同一个。
            ForEach(Array(model.cameras.enumerated()), id: \.offset) { idx, cam in
                Button(action: {
                    os_log("TAP-V3 slot=%{public}@ idx=%d name=%{public}@", log: uiLog, type: .default,
                           slot.label, idx, cam.localizedName)
                    model.setSource(.macCamera(uniqueID: cam.uniqueID,
                                               localizedName: cam.localizedName),
                                    slot: slot)
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: icon(for: cam.kind)).frame(width: 16)
                        Text(cam.localizedName).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                        let badge = cam.kind.displayLabel
                        if !badge.isEmpty {
                            Text(badge).font(.system(size: 9, design: .monospaced))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.secondary.opacity(0.15), in: Capsule())
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        if current == .macCamera(uniqueID: cam.uniqueID, localizedName: cam.localizedName) {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(current == .macCamera(uniqueID: cam.uniqueID, localizedName: cam.localizedName)
                                ? Color.accentColor.opacity(0.12) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            }
            // Screen capture —— 永远显示这个区域，没授权时给用户一个明确的
            // Grant 入口。否则界面会"时有时无"——用户最讨厌的不一致体验。
            screenCaptureSection(slot: slot, current: current)
            // Files
            HStack(spacing: 6) {
                Button {
                    model.pickImage(slot: slot)
                } label: { Label("Image", systemImage: "photo") }
                Button {
                    model.pickVideo(slot: slot)
                } label: { Label("Video", systemImage: "film") }
            }
            .controlSize(.small)
            .padding(.top, 4)

            if isOn {
                Button(role: .destructive) {
                    model.stopSlot(slot)
                } label: { Label("Stop \(slot.label.lowercased())", systemImage: "stop.fill") }
                    .controlSize(.small)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func icon(for kind: CameraKind) -> String {
        switch kind {
        case .builtIn:       return "video"
        case .external:      return "camera"
        case .continuity:    return "iphone"
        case .deskView:      return "rectangle.inset.topleft.filled"
        case .simcamVirtual: return "camera.aperture"
        case .front:         return "person.crop.square"
        case .unknown:       return "questionmark.video"
        }
    }

    private var qrSection: some View {
        Section(title: "QR injection") {
            HStack(spacing: 8) {
                TextField("Payload (e.g. AUTH_TOKEN_XYZ)", text: $model.qrPayload)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                Button("→ Back") {
                    model.setSource(.qr(payload: model.qrPayload), slot: .back)
                }
                .disabled(model.qrPayload.isEmpty)
                Button("→ Front") {
                    model.setSource(.qr(payload: model.qrPayload), slot: .front)
                }
                .disabled(model.qrPayload.isEmpty)
            }
        }
    }

    private var injectSection: some View {
        Section(title: "Inject into iOS Simulator") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField("Bundle id (e.g. dev.simcam.demo)",
                              text: $model.simulatorBundleID)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    Button("Boot Sim") { model.bootSimulator() }
                    Button("Inject") { model.injectIntoSimulator() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.simulatorBundleID.isEmpty)
                }
                if !model.lastInjectLog.isEmpty {
                    ScrollView { Text(model.lastInjectLog)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 90)
                    .padding(6)
                    .background(Color.black.opacity(0.06))
                    .cornerRadius(6)
                }
                Text("Calls scripts/inject-simulator.sh — DYLD_INSERT_LIBRARIES=libSimCamHook.dylib. The injected hook now routes the back slot to AVCaptureDevicePosition.back and the front slot to .front independently.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var diagnosticsSection: some View {
        Section(title: "Diagnostics") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.diagnostics, id: \.key) { d in
                    HStack {
                        Image(systemName: d.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(d.ok ? .green : .orange)
                            .font(.system(size: 11))
                        Text(d.key).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(d.detail).font(.system(size: 11))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("v\(SimCam.version) · \(model.state.license.label)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.thinMaterial)
    }

    @ViewBuilder
    private func cameraRow(slot: CameraSlot,
                           cam: CameraDescriptor,
                           current: CameraSource) -> some View {
        // 抽出来避免在 ForEach 闭包里写 `let xxx = ...` 然后跟 View ——
        // 那种写法在某些 Swift/SwiftUI 版本下 ViewBuilder 解析异常，
        // 整行变成隐式 EmptyView，看上去就是「row 渲染出来但点不动」。
        let src = CameraSource.macCamera(uniqueID: cam.uniqueID,
                                         localizedName: cam.localizedName)
        return sourceRow(slot: slot,
                         icon: icon(for: cam.kind),
                         label: cam.localizedName,
                         badge: cam.kind.displayLabel,
                         selected: current == src) {
            NSLog("[SimCam.UI] tap camera slot=\(slot.label) name=\(cam.localizedName)")
            model.setSource(src, slot: slot)
        }
    }

    @ViewBuilder
    private func screenCaptureSection(slot: CameraSlot,
                                      current: CameraSource) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Screen capture")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                // 状态指示 + 视情况一个 Refresh 按钮
                switch model.screenAuth {
                case .authorized:
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundStyle(.green).font(.system(size: 10))
                    Button {
                        if #available(macOS 12.3, *) { model.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                case .denied:
                    Image(systemName: "exclamationmark.shield.fill")
                        .foregroundStyle(.orange).font(.system(size: 10))
                case .unknown:
                    ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                case .requesting:
                    ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                }
            }
            .padding(.top, 4)

            switch model.screenAuth {
            case .authorized:
                if model.screens.isEmpty {
                    Text("No display reported.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    ForEach(model.screens) { src in
                        screenRow(slot: slot, src: src, current: current)
                    }
                }
            case .denied:
                VStack(alignment: .leading, spacing: 4) {
                    Text("Screen Recording permission required.")
                        .font(.system(size: 11)).foregroundStyle(.primary)
                    Text("ad-hoc 签名每次 build 后 cdhash 变化都会让授权失效；点下方按钮重新申请。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Button {
                            if #available(macOS 12.3, *) {
                                model.requestScreenAuthorization()
                            }
                        } label: {
                            Label("Grant Screen Recording", systemImage: "lock.shield")
                        }
                        .controlSize(.small)
                        Button {
                            // 一键打开系统设置面板，方便用户手动确认开关
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            Label("Open Settings", systemImage: "gearshape")
                        }
                        .controlSize(.small)
                    }
                }
                .padding(8)
                .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
            case .unknown:
                Text("Querying screen sources…")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            case .requesting:
                Text("Asking macOS for permission… (a system dialog should appear)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func screenRow(slot: CameraSlot,
                           src: ScreenSourceDescriptor,
                           current: CameraSource) -> some View {
        let cs = CameraSource.screen(displayID: src.displayID,
                                     windowID: src.windowID,
                                     includeMouse: true)
        return sourceRow(slot: slot,
                         icon: src.kind == .display ? "display" : "macwindow",
                         label: src.title,
                         badge: src.kind == .display ? "display" : (src.ownerApp ?? "window"),
                         selected: current == cs) {
            NSLog("[SimCam.UI] tap screen slot=\(slot.label) title=\(src.title) display=\(src.displayID) window=\(src.windowID)")
            model.setSource(cs, slot: slot)
        }
    }

    private func sourceRow(slot: CameraSlot, icon: String, label: String,
                           badge: String? = nil, selected: Bool,
                           action: @escaping () -> Void) -> some View {
        // 用原生 Button + .buttonStyle(.borderless) —— 在 NSPopover 容纳的
        // SwiftUI 内容里，AppKit 的 hit-test 给 Button 走的是 NSControl 路径，
        // 不会被 ScrollView / VStack 的 hit-shape 屏蔽。
        // 之前用 .onTapGesture 在 ForEach 里点不到的真因：onTapGesture 是
        // SwiftUI 自家 GestureRecognizer，layout 一抖就重 attach；Button 内
        // 部状态由 AppKit 维护，layout 重算不影响 hit-test。
        Button(action: {
            NSLog("[SimCam.UI] tap row slot=\(slot.label) label=\(label)")
            action()
        }) {
            HStack(spacing: 8) {
                Image(systemName: icon).frame(width: 16)
                Text(label).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                if let badge, !badge.isEmpty {
                    Text(badge).font(.system(size: 9, design: .monospaced))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.secondary.opacity(0.15), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if selected { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
    }
}

struct Section<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .tracking(1.5)
            content
        }
    }
}

private extension CameraSource {
    var shortLabel: String {
        switch self {
        case .none:                            return "none"
        case .demo:                            return "demo"
        case .macCamera(_, let n):             return n
        case .image(let p):                    return URL(fileURLWithPath: p).lastPathComponent
        case .video(let p, _):                 return URL(fileURLWithPath: p).lastPathComponent
        case .qr(let payload):                 return "QR · \(payload.prefix(10))"
        case .screen(let d, let w, _):
            return w != 0 ? "window#\(w)" : "display#\(d == 0 ? 1 : Int(d))"
        case .simulatorPassthrough:            return "Simulator passthrough"
        }
    }
}
