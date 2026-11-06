import AppKit

enum ImageOutput {
    /// Where copies go; the silent e2e test swaps in a private pasteboard so the user's clipboard is untouched.
    static var pasteboard = NSPasteboard.general

    static func pngData(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    static func copyToPasteboard(_ image: CGImage, pointSize: CGSize) {
        guard let data = pngData(image) else { return }
        let pb = pasteboard
        pb.clearContents()
        pb.setData(data, forType: .png)
        // TIFF too, for apps that only read the legacy image type.
        let nsImage = NSImage(cgImage: image, size: pointSize)
        if let tiff = nsImage.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
    }

    @discardableResult
    static func save(_ image: CGImage, prefix: String = "截图") -> URL? {
        guard let data = pngData(image) else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let stem = "\(prefix) \(formatter.string(from: Date()))"
        let folder = Settings.saveFolder
        var url = folder.appendingPathComponent("\(stem).png")
        // Prevent silent overwrite when saving multiple screenshots within the same second.
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(stem)-\(suffix).png")
            suffix += 1
        }
        do {
            try data.write(to: url)
            return url
        } catch {
            NSAlert(error: error).runModal()
            return nil
        }
    }
}

extension CGImage {
    /// sRGB color of one pixel (top-left origin), converted from the image's own color space.
    func srgbPixel(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8)? {
        guard x >= 0, y >= 0, x < width, y < height,
              let crop = cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (px[0], px[1], px[2])
    }
}
