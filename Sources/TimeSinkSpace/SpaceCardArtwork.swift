import AppKit
import ImageIO
import CoreText

@MainActor
enum SpaceImages {
    private static let thumbnails = NSCache<NSString, NSImage>()
    static func thumbnail(_ url: URL, maxPixel: Int = 240) -> NSImage? {
        thumbnails.countLimit = 100
        thumbnails.totalCostLimit = 48 * 1024 * 1024
        let key = "\(maxPixel):\(url.path)" as NSString
        if let image = thumbnails.object(forKey: key) { return image }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        thumbnails.setObject(image, forKey: key, cost: cgImage.width * cgImage.height * 4)
        return image
    }
}

/// Immutable pixel data crosses from a background decoder to the texture uploader.
struct SpaceRaster: Sendable {
    let width: Int
    let height: Int
    let pixels: Data
}

enum SpaceCardArtwork {
    static func raster(for event: SpaceEvent, snapshot: SpaceSnapshot?, width: Int) -> SpaceRaster? {
        let height = width * 2 / 3
        guard let context = CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
        context.scaleBy(x: CGFloat(width) / 1200, y: CGFloat(height) / 800)
        context.setFillColor(CGColor(red: 0.055, green: 0.060, blue: 0.064, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
        if let url = snapshot?.url, let image = decode(url, maxPixel: width) {
            let ratio = min(1200 / CGFloat(image.width), 724 / CGFloat(image.height))
            let w = CGFloat(image.width) * ratio, h = CGFloat(image.height) * ratio
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: (1200 - w) / 2, y: 76 + (724 - h) / 2, width: w, height: h))
        } else {
            drawText("这段记忆没有保存画面", x: 40, y: 360, width: 1120, size: 25, brightness: 0.72, context: context)
        }
        let color = event.category.rgb
        context.setFillColor(CGColor(red: CGFloat(color.x), green: CGFloat(color.y), blue: CGFloat(color.z), alpha: 1))
        context.fillEllipse(in: CGRect(x: 22, y: 49, width: 7, height: 7))
        drawText(event.app, x: 40, y: 44, width: 750, size: 18, brightness: 0.77, context: context)
        drawText("\(event.time) — \(event.endTime)", x: 980, y: 44, width: 198, size: 18, brightness: 0.72, context: context)
        drawText(event.title, x: 22, y: 12, width: 1156, size: 23, brightness: 0.96, context: context)
        guard let data = context.data else { return nil }
        return SpaceRaster(width: width, height: height, pixels: Data(bytes: data, count: width * height * 4))
    }

    static func decode(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }

    private static func drawText(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat,
                                 size: CGFloat, brightness: CGFloat, context: CGContext) {
        let font = CTFontCreateUIFontForLanguage(.system, size, nil)!
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: brightness, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
        let fitted = CTLineCreateTruncatedLine(line, width, .end, ellipsis) ?? line
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(fitted, context)
    }
}
