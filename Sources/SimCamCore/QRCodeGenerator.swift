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

        let context = CIContext()
        return context.createCGImage(ci, from: ci.extent)
    }
}
