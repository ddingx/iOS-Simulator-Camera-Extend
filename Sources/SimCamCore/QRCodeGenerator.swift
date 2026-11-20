import Foundation
import CoreImage

/// 用 CoreImage 把任意字符串编码成 QR 图片（CGImage），供后续注入帧广播器。
public enum QRCodeGenerator {
    public enum Correction: String {
        case low = "L", medium = "M", quartile = "Q", high = "H"
    }

    public static func makeImage(payload: String,
                                 size: Int = 1024,
                                 correction: Correction = .medium,
                                 foreground: (r: CGFloat, g: CGFloat, b: CGFloat) = (0, 0, 0),
                                 background: (r: CGFloat, g: CGFloat, b: CGFloat) = (1, 1, 1)) -> CGImage? {
        guard let data = payload.data(using: .utf8) else { return nil }
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue(correction.rawValue, forKey: "inputCorrectionLevel")
        guard var ci = filter.outputImage else { return nil }

        let scale = CGFloat(size) / ci.extent.width
        ci = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        if let color = CIFilter(name: "CIFalseColor") {
            color.setValue(ci, forKey: kCIInputImageKey)
            color.setValue(CIColor(red: foreground.r, green: foreground.g, blue: foreground.b), forKey: "inputColor0")
            color.setValue(CIColor(red: background.r, green: background.g, blue: background.b), forKey: "inputColor1")
            ci = color.outputImage ?? ci
        }

        // QR 规范要求四周有 quiet zone（≥4 模块）。CIQRCodeGenerator 的输出
        // 不带留白，贴边渲染时扫码器会拒识。这里把码缩到 84% 居中放到白色
        // 画布上，四周留出 ~8% 的静区。
        let margin = CGFloat(size) * 0.08
        let canvas = CGRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size))
        let inline = ci.transformed(by: CGAffineTransform(scaleX: 0.84, y: 0.84))
            .transformed(by: CGAffineTransform(translationX: margin, y: margin))
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: canvas)
        let composed = inline.composited(over: white)
        let context = CIContext()
        return context.createCGImage(composed, from: canvas)
    }
}
