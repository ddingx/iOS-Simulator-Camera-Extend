import Foundation

/// 通过 systemextensionsctl 列表推断 SimCam Camera Extension 是否已经被
/// 系统注册到 cmiod。这条信息让 ExtensionVerification 知道 expected:
/// "找不到虚拟摄像头" 在没装扩展时是预期内的（CI 应该 pass），
/// 在装了扩展时则是真 bug（CI 应该 fail）。
public enum SystemExtensionProbe {

    /// SimCamExtension target 的 bundle id。便于 systemextensionsctl 输出里直接 grep。
    public static let bundleID = "dev.simcam.app.extension"

    /// 通过 `/usr/bin/systemextensionsctl list` 探测扩展是否激活。
    /// 在 sandbox / 路径不存在 / 命令失败的情况下返回 false。
    public static func isSimCamExtensionInstalled() -> Bool {
        if let forced = ProcessInfo.processInfo.environment["SIMCAM_EXTENSION_INSTALLED"] {
            return forced == "1" || forced.lowercased() == "true"
        }

        let url = URL(fileURLWithPath: "/usr/bin/systemextensionsctl")
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return false }

        let task = Process()
        task.executableURL = url
        task.arguments = ["list"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return false
        }
        guard task.terminationStatus == 0 else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return false }
        for line in text.split(separator: "\n") {
            if line.contains(bundleID) && line.contains("activated") {
                return true
            }
        }
        return false
    }
}
