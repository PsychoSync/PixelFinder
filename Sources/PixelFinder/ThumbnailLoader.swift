import AppKit
import ImageIO

/// A decoded image plus the bounding box of its non-transparent pixels
/// (in pixel coordinates, origin top-left).
final class Thumbnail {
    let image: CGImage
    let opaqueRect: CGRect

    init(image: CGImage) {
        self.image = image
        opaqueRect = Self.opaqueBounds(of: image)
    }

    var size: CGSize { CGSize(width: image.width, height: image.height) }

    private static func opaqueBounds(of image: CGImage) -> CGRect {
        let w = image.width, h = image.height
        let full = CGRect(x: 0, y: 0, width: w, height: h)
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return full
        default: break
        }
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue),
              let data = ctx.data else { return full }
        ctx.draw(image, in: full)
        let rowBytes = ctx.bytesPerRow
        let px = data.bindMemory(to: UInt8.self, capacity: rowBytes * h)
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            let row = px + y * rowBytes
            var x = 0
            while x < w && row[x] == 0 { x += 1 }
            guard x < w else { continue }
            var xr = w - 1
            while row[xr] == 0 { xr -= 1 }
            minX = min(minX, x); maxX = max(maxX, xr)
            minY = min(minY, y); maxY = y
        }
        guard maxX >= 0 else { return full }    // fully transparent: show as-is
        // Bitmap contexts store the top row first, so y is already top-down.
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}

/// Decodes images off the main thread and keeps decoded CGImages in memory.
/// Small images are decoded at their native resolution (no resampling at all);
/// the GPU scales them with nearest-neighbour filtering at display time.
final class ThumbnailLoader {
    static let shared = ThumbnailLoader()

    /// Images larger than this are pre-shrunk once to bound memory use.
    private let maxPixelSize = 1024
    private let cache = NSCache<NSString, Thumbnail>()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = max(2, ProcessInfo.processInfo.activeProcessorCount)
        q.qualityOfService = .userInitiated
        return q
    }()

    private init() {
        cache.totalCostLimit = 1024 * 1024 * 1024
    }

    func cached(_ entry: Entry) -> Thumbnail? {
        cache.object(forKey: entry.cacheKey as NSString)
    }

    func cancelAll() {
        queue.cancelAllOperations()
    }

    @discardableResult
    func load(_ entry: Entry, completion: @escaping (Thumbnail?) -> Void) -> Operation {
        let key = entry.cacheKey as NSString
        let url = entry.url
        let limit = maxPixelSize
        let op = BlockOperation()
        op.addExecutionBlock { [weak op, weak self] in
            guard let op, !op.isCancelled else { return }
            let thumb = Self.decode(url: url, maxPixelSize: limit).map(Thumbnail.init)
            if let thumb {
                self?.cache.setObject(thumb, forKey: key, cost: thumb.image.bytesPerRow * thumb.image.height)
            }
            DispatchQueue.main.async {
                if !op.isCancelled { completion(thumb) }
            }
        }
        queue.addOperation(op)
        return op
    }

    static func decode(url: URL, maxPixelSize: Int) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let orientation = props?[kCGImagePropertyOrientation] as? Int ?? 1

        if max(width, height) > maxPixelSize || orientation != 1 {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: min(maxPixelSize, max(width, height)),
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary)
        }
        let opts = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        return CGImageSourceCreateImageAtIndex(source, 0, opts)
    }
}

enum SystemIcons {
    private static var cache: [String: CGImage] = [:]

    static func folder(size: CGFloat, scale: CGFloat) -> CGImage? {
        icon(key: "folder", image: NSWorkspace.shared.icon(for: .folder), size: size, scale: scale)
    }

    static func file(for url: URL, size: CGFloat, scale: CGFloat) -> CGImage? {
        icon(key: "file:" + url.pathExtension.lowercased(),
             image: NSWorkspace.shared.icon(forFile: url.path), size: size, scale: scale)
    }

    private static func icon(key: String, image: NSImage, size: CGFloat, scale: CGFloat) -> CGImage? {
        let px = min(1024, max(16, ceil(size * scale)))
        let fullKey = "\(key)@\(px)"
        if let hit = cache[fullKey] { return hit }
        var rect = NSRect(x: 0, y: 0, width: px, height: px)
        let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        cache[fullKey] = cg
        return cg
    }
}
