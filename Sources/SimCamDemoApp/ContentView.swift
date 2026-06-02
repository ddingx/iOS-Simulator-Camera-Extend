import SwiftUI
import AVFoundation
import UIKit

/// "被测 app" 的页面 —— 一段标准的扫码/预览代码。
/// 跑在 simulator 时由 SimCamHook.dylib 接管 AVFoundation。
struct ContentView: View {
    @State private var qrPayload: String = ""
    @State private var devices: [String] = []
    @State private var position: AVCaptureDevice.Position = .back

    var body: some View {
        ZStack(alignment: .bottom) {
            CameraPreview(position: position) { payload in
                qrPayload = payload
            } onDevices: { list in
                devices = list
            }
            .ignoresSafeArea()

            VStack(spacing: 12) {
                infoBanner
                qrBanner
                cameraToggle
            }
            .padding(.horizontal, 20).padding(.bottom, 32)
        }
    }

    private var infoBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("AVCaptureDevice list (\(devices.count)):")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
            ForEach(devices, id: \.self) {
                Text("• \($0)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.black.opacity(0.6)).cornerRadius(10)
    }

    @ViewBuilder
    private var qrBanner: some View {
        if !qrPayload.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("📷 QR detected (AVCaptureMetadataOutput):")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.green)
                Text(qrPayload)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundColor(.white).lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.black.opacity(0.7)).cornerRadius(10)
        }
    }

    private var cameraToggle: some View {
        HStack {
            Button(position == .back ? "Switch to Front" : "Switch to Back") {
                position = (position == .back) ? .front : .back
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Color.white.opacity(0.92)).foregroundColor(.black)
            .cornerRadius(8)
            Spacer()
        }
    }
}

/// 这就是一个 100% 标准的 AVCaptureSession + AVCaptureVideoPreviewLayer +
/// AVCaptureMetadataOutput demo —— 没有任何 SimCam 痕迹。模拟器里跑，
/// SimCamHook.dylib 已经在 dyld 阶段把这些 API 全部接管了。
struct CameraPreview: UIViewRepresentable {
    let position: AVCaptureDevice.Position
    let onQR: (String) -> Void
    let onDevices: ([String]) -> Void

    init(position: AVCaptureDevice.Position,
         onQR: @escaping (String) -> Void,
         onDevices: @escaping ([String]) -> Void) {
        self.position = position
        self.onQR = onQR
        self.onDevices = onDevices
    }

    func makeUIView(context: Context) -> PreviewUIView {
        let v = PreviewUIView()
        v.coordinator = context.coordinator
        v.configure(position: position)
        return v
    }
    func updateUIView(_ v: PreviewUIView, context: Context) {
        v.configure(position: position)
    }
    func makeCoordinator() -> Coordinator { Coordinator(onQR: onQR, onDevices: onDevices) }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let onQR: (String) -> Void
        let onDevices: ([String]) -> Void
        init(onQR: @escaping (String) -> Void, onDevices: @escaping ([String]) -> Void) {
            self.onQR = onQR; self.onDevices = onDevices
        }
        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            for obj in metadataObjects {
                if let m = obj as? AVMetadataMachineReadableCodeObject,
                   let s = m.stringValue {
                    DispatchQueue.main.async { self.onQR(s) }
                    break
                }
            }
        }
    }
}

final class PreviewUIView: UIView {
    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var currentInput: AVCaptureDeviceInput?
    weak var coordinator: CameraPreview.Coordinator?
    private var configured = false

    func configure(position: AVCaptureDevice.Position) {
        if !configured {
            configured = true
            backgroundColor = .black
            // —— 标准 AVFoundation 流程开始 ——
            // 1. discovery
            let disc = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInWideAngleCamera],
                mediaType: .video,
                position: .unspecified)
            let names = disc.devices.map { "\($0.localizedName) (\($0.position == .back ? "back" : "front"))" }
            DispatchQueue.main.async { self.coordinator?.onDevices(names) }

            session.sessionPreset = .high
            // 2. preview layer
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = bounds
            self.layer.addSublayer(layer)
            previewLayer = layer

            // 3. metadata output
            let meta = AVCaptureMetadataOutput()
            if session.canAddOutput(meta) {
                session.addOutput(meta)
                meta.setMetadataObjectsDelegate(coordinator, queue: .main)
                meta.metadataObjectTypes = [.qr]
            }
        }
        // 4. select device by position + plug as input
        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
            ?? AVCaptureDevice.default(for: .video)
        NSLog("[demo] configure requested=%d got_device_position=%d uniqueID=%@",
              position.rawValue,
              device?.position.rawValue ?? -1,
              device?.uniqueID ?? "nil")
        guard let device = device else { return }
        if let cur = currentInput { session.removeInput(cur) }
        if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
            currentInput = input
        }
        if !session.isRunning { session.startRunning() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
    }
}
