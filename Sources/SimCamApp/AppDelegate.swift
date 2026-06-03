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
        // 先让 sysext 完成 activation/replacement，再启动会触碰 CMIO 的
        // engine。否则 host 可能连到正在被替换的旧 sink stream，第一帧入队
        // 后收不到 alteredProc ack，QuickTime 就一直停在 extension fallback 扫描线。
        if #available(macOS 13.0, *) {
            ExtensionActivator.shared.activate {
                SimCamEngine.shared.start()
            }
        } else {
            SimCamEngine.shared.start()
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
