import UIKit
import AVFoundation
import SwiftUI

/// SimCamDemoApp ── 这是一个"被测 app"。
///
/// 它**只用标准 AVFoundation API**——`AVCaptureDevice` / `AVCaptureSession`
/// / `AVCaptureVideoPreviewLayer` / `AVCaptureMetadataOutput`。没有任何
/// SimCam 自家 framework / SDK。
///
/// 跑法：
/// 1. host 端跑 SimCamApp（menubar），它起了 unix sock /tmp/com.simcam.frames.sock；
/// 2. `scripts/inject-simulator.sh dev.simcam.demo` 用 `xcrun simctl launch
///    --setenv DYLD_INSERT_LIBRARIES=...SimCamHook.dylib` 启动这个 demo；
/// 3. SimCamHook 在 dyld 阶段就 swizzle 了 AVFoundation，下面这段代码原样
///    跑就能拿到 host 推过来的画面 + QR。
///
/// 这就是 SimCam 商业版的"零改动"承诺：你拿你自己 app 的源码不改一行，
/// 用同一个 inject 脚本跑就行。

@main
struct SimCamDemoAppMain {
    static func main() {
        UIApplicationMain(
            CommandLine.argc, CommandLine.unsafeArgv,
            nil, NSStringFromClass(AppDelegate.self))
    }
}

final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let win = UIWindow(frame: UIScreen.main.bounds)
        win.rootViewController = UIHostingController(rootView: ContentView())
        win.makeKeyAndVisible()
        window = win
        return true
    }
}
