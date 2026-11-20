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
        configureMainMenu()
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

    /// 装一条最小主菜单。
    ///
    /// 这个 app 是 `.accessory`（无 Dock 图标、无菜单栏），但 SwiftUI 的
    /// TextField 依赖 **菜单项上的键盘等价物** 来实现 ⌘A / ⌘C / ⌘V / ⌘X
    /// —— 没有 Edit 菜单时这些快捷键在输入框里完全没反应（用户实测：
    /// QR 文本区域选不中、复制粘贴无效）。这里补上标准 Edit 项，
    /// target 留 nil 交给 responder chain。
    private func configureMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 SimCam",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "退出 SimCam",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApplication.shared.mainMenu = mainMenu
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
