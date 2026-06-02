import Foundation
import CoreMediaIO

/// Camera Extension 进程入口。这是 SimCamExtension target 的可执行文件主入口。
@available(macOS 13.0, *)
@main
enum SimCamExtensionMain {
    static func main() {
        let providerSource = SimCamCMIODevice.shared.provider()
        CMIOExtensionProvider.startService(provider: providerSource.provider)
        RunLoop.main.run()
    }
}
