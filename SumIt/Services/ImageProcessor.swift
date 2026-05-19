import UIKit
import ImageIO
import MobileCoreServices

/// Downscales and strips EXIF (incl. GPS) from receipt photos before upload.
enum ImageProcessor {

    /// Returns redrawn JPEG with no EXIF metadata, long-edge clamped to `maxEdge`.
    /// Returns nil if image cannot be encoded.
    static func sanitizedJPEG(_ image: UIImage,
                              maxEdge: CGFloat = AppConfig.imageMaxEdge,
                              quality: CGFloat = 0.7) -> Data? {
        let resized = downscale(image, maxEdge: maxEdge)
        // Re-drawing into a fresh CGContext drops every EXIF dictionary including {GPS}.
        guard let cg = resized.cgImage else { return nil }
        let rect = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil,
                                  width: cg.width, height: cg.height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(cg, in: rect)
        guard let stripped = ctx.makeImage() else { return nil }
        return UIImage(cgImage: stripped).jpegData(compressionQuality: quality)
    }

    /// Smaller preview for chat bubble. Saves SwiftData store size and memory.
    static func thumbnailJPEG(_ image: UIImage, maxEdge: CGFloat = 400, quality: CGFloat = 0.5) -> Data? {
        let resized = downscale(image, maxEdge: maxEdge)
        return resized.jpegData(compressionQuality: quality)
    }

    private static func downscale(_ image: UIImage, maxEdge: CGFloat) -> UIImage {
        let size = image.size
        let longEdge = max(size.width, size.height)
        guard longEdge > maxEdge else { return image }
        let scale = maxEdge / longEdge
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
    }
}
