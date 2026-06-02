import AppKit
import SwiftUI

@main
struct SimCamAppMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // 没有 dock 图标，仅 menubar
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()
        configurePopover()
        // 启动后默认进入 demo 源，让用户立即在模拟器看到效果。
        SimCamEngine.shared.start()
        // 触发 .systemextension 激活，让虚拟相机出现在 cmiod / iOS Simulator 里。
        if #available(macOS 13.0, *) {
            ExtensionActivator.shared.activate()
        }
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "camera.aperture", accessibilityDescription: "SimCam")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
    }

    private func configurePopover() {
        popover = NSPopover()
        popover.behavior = .transient
        // 必须跟 MenubarView .frame(width:520, height:760) 对齐，
        // 否则 NSPopover 的 NSWindow bounds 比 SwiftUI 视图小，
        // 超出 popover bounds 的 SwiftUI 视图能被画出来但收不到 mouse event
        // —— 表现为「能看到 row 但点了没反应」。
        popover.contentSize = NSSize(width: 520, height: 760)
        popover.contentViewController = NSHostingController(rootView: MenubarView())
    }

    @objc func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
