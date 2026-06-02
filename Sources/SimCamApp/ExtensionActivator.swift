import Foundation
import SystemExtensions
import Combine
import OSLog

/// 在 SimCamApp 启动时调用 OSSystemExtensionManager.shared 把
/// dev.simcam.app.bridge 这个 .systemextension 提交给系统去激活。
///
/// 第一次安装会弹"系统扩展被阻止" → 用户跳到 System Settings ▸ Privacy &
/// Security ▸ Allow → 系统会替我们调 cmiod，让 SimCam Virtual Camera 出现在
/// AVCaptureDevice.DiscoverySession 列表里 —— 然后 iOS 17+ Simulator 也能看见。
///
/// 重点：必须用一个真实的 Apple Developer Team ID 签名，否则
/// `OSSystemExtensionErrorDomain.codeValidationFailed` 会立刻出现。
@available(macOS 13.0, *)
public final class ExtensionActivator: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {

    public static let shared = ExtensionActivator()

    public enum Status: Equatable {
        case idle
        case requesting
        case awaitingApproval        // 用户需要去系统设置点允许
        case activated
        case failed(String)
    }

    @Published public private(set) var status: Status = .idle

    private let log = Logger(subsystem: "dev.simcam.app", category: "extension-activator")
    private let bundleID = "dev.simcam.app.extension"

    public func activate() {
        log.info("➡️  Submitting OSSystemExtensionRequest for \(self.bundleID, privacy: .public)")
        status = .requesting
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: bundleID,
            queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    public func deactivate() {
        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: bundleID,
            queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    // MARK: - OSSystemExtensionRequestDelegate
    public func request(_ request: OSSystemExtensionRequest,
                        actionForReplacingExtension existing: OSSystemExtensionProperties,
                        withExtension new: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        return .replace
    }

    public func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        log.info("⏳ Extension awaiting user approval in System Settings ▸ Privacy & Security")
        status = .awaitingApproval
    }

    public func request(_ request: OSSystemExtensionRequest,
                        didFinishWithResult result: OSSystemExtensionRequest.Result) {
        log.info("✅ Extension request finished: \(String(describing: result), privacy: .public)")
        status = .activated
    }

    public func request(_ request: OSSystemExtensionRequest,
                        didFailWithError error: Error) {
        log.error("❌ Extension request failed: \(error.localizedDescription, privacy: .public)")
        status = .failed(error.localizedDescription)
    }
}
