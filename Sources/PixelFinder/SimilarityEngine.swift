import Accelerate
import AppKit
import Vision

enum SortMode: String, CaseIterable {
    case name
    case similarVision
    case similarHash

    var title: String {
        switch self {
        case .name: return "Name"
        case .similarVision: return "Similarity (Vision + Hash + Palette)"
        case .similarHash: return "Similarity (Perceptual Hash)"
        }
    }
}

final class CancelToken {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

/// Per-image features. `vision` is only computed for the Vision mode.
struct ImageFeatures: Codable {
    var modified: Double
    var dHash: UInt64
    var aHash: UInt64
    var palette: Data          // 64 Float32 bins, L1-normalised
    var vision: Data?          // L2-normalised Float32 feature print
}

/// Orders images so that visually similar ones end up next to each other.
enum SimilarityEngine {
    private static let neighbours = 12
    private static let visionCandidates = 32
    private static let featureImageSize = 256

    /// Returns a permutation of `entries` (indices). Folders stay first in their
    /// original order; images that cannot be decoded go last.
    static func order(entries: [Entry], folder: URL, mode: SortMode, token: CancelToken,
                      progress: @escaping (Int, Int) -> Void) -> [Int]? {
        let folderIdx = entries.indices.filter { entries[$0].isDirectory }
        let imageIdx = entries.indices.filter { !entries[$0].isDirectory }
        guard mode != .name, imageIdx.count > 1 else { return Array(entries.indices) }

        let useVision = mode == .similarVision
        var cache = FeatureCache.load(folder: folder)
        var features = [ImageFeatures?](repeating: nil, count: imageIdx.count)
        var todo: [Int] = []
        for (i, e) in imageIdx.enumerated() {
            let modified = entries[e].modificationDate?.timeIntervalSinceReferenceDate ?? 0
            if let f = cache.records[entries[e].name], f.modified == modified, !useVision || f.vision != nil {
                features[i] = f
            } else {
                todo.append(i)
            }
        }

        if !todo.isEmpty {
            let lock = NSLock()
            var done = 0
            var lastReport = Date.distantPast
            progress(0, todo.count)
            features.withUnsafeMutableBufferPointer { out in
                DispatchQueue.concurrentPerform(iterations: todo.count) { n in
                    if token.isCancelled { return }
                    let i = todo[n]
                    let entry = entries[imageIdx[i]]
                    let previous = out[i] ?? cache.records[entry.name]
                    out[i] = autoreleasepool { extract(entry: entry, vision: useVision, reuse: previous) }
                    lock.lock()
                    done += 1
                    let d = done
                    let report = Date().timeIntervalSince(lastReport) > 0.1 || d == todo.count
                    if report { lastReport = Date() }
                    lock.unlock()
                    if report { DispatchQueue.main.async { progress(d, todo.count) } }
                }
            }
            if token.isCancelled { return nil }
            for (i, e) in imageIdx.enumerated() {
                if let f = features[i] { cache.records[entries[e].name] = f }
            }
            cache.prune(keeping: Set(imageIdx.map { entries[$0].name }))
            cache.save()
        }

        // Images we could not decode are appended unsorted.
        let valid = features.indices.filter { features[$0] != nil && (!useVision || features[$0]!.vision != nil) }
        let validSet = Set(valid)
        let invalid = features.indices.filter { !validSet.contains($0) }
        let feats = valid.map { features[$0]! }
        let space = FeatureSpace(features: feats, useVision: useVision)
        guard let chain = space.chainOrder(neighbours: neighbours, candidates: visionCandidates, token: token) else {
            return nil
        }
        return folderIdx + chain.map { imageIdx[valid[$0]] } + invalid.map { imageIdx[$0] }
    }

    // MARK: Feature extraction

    private static func extract(entry: Entry, vision: Bool, reuse: ImageFeatures?) -> ImageFeatures? {
        let modified = entry.modificationDate?.timeIntervalSinceReferenceDate ?? 0
        guard let image = ThumbnailLoader.decode(url: entry.url, maxPixelSize: featureImageSize) else { return nil }
        var f: ImageFeatures
        if let reuse, reuse.modified == modified {
            f = reuse
        } else {
            guard let rgba = RGBABuffer(image: image) else { return nil }
            let (d, a) = rgba.hashes()
            f = ImageFeatures(modified: modified, dHash: d, aHash: a, palette: rgba.palette(), vision: nil)
        }
        if vision && f.vision == nil {
            f.vision = visionPrint(image)
            if f.vision == nil { return nil }
        }
        return f
    }

    /// Vision sees a nearest-neighbour enlargement on white, so tiny sprites keep crisp edges.
    private static func visionPrint(_ image: CGImage) -> Data? {
        let maxSide = max(image.width, image.height)
        let target = 224
        let scale = maxSide >= target ? CGFloat(target) / CGFloat(maxSide)
                                      : CGFloat(max(1, target / maxSide))
        let w = max(1, Int(CGFloat(image.width) * scale)), h = max(1, Int(CGFloat(image.height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = scale >= 1 ? .none : .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let prepared = ctx.makeImage() else { return nil }

        let request = VNGenerateImageFeaturePrintRequest()
        request.imageCropAndScaleOption = .scaleFit
        let handler = VNImageRequestHandler(cgImage: prepared, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        guard let obs = request.results?.first as? VNFeaturePrintObservation else { return nil }

        var v: [Float]
        switch obs.elementType {
        case .float:
            v = obs.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        case .double:
            v = obs.data.withUnsafeBytes { $0.bindMemory(to: Double.self).map(Float.init) }
        default:
            return nil
        }
        var norm: Float = 0
        vDSP_svesq(v, 1, &norm, vDSP_Length(v.count))
        norm = sqrt(norm)
        if norm > 0 { vDSP_vsdiv(v, 1, &norm, &v, 1, vDSP_Length(v.count)) }
        return v.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

/// Straight (non-premultiplied) RGBA pixels of an image.
private struct RGBABuffer {
    let width: Int, height: Int
    var pixels: [UInt8]

    init?(image: CGImage) {
        width = image.width; height = image.height
        pixels = [UInt8](repeating: 0, count: width * height * 4)
        let ok = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }
    }

    /// Luminance composited over white (like the grid displays it).
    private func gray(_ i: Int) -> Float {
        let r = Float(pixels[i * 4]), g = Float(pixels[i * 4 + 1]), b = Float(pixels[i * 4 + 2])
        let a = Float(pixels[i * 4 + 3])
        let lum = 0.299 * r + 0.587 * g + 0.114 * b   // premultiplied
        return lum + (255 - a)
    }

    /// Area-averaged downsample of the grey image to cols x rows.
    private func downsample(cols: Int, rows: Int) -> [Float] {
        var out = [Float](repeating: 0, count: cols * rows)
        var weight = [Float](repeating: 0, count: cols * rows)
        for y in 0..<height {
            let cy = min(rows - 1, y * rows / height)
            for x in 0..<width {
                let cx = min(cols - 1, x * cols / width)
                out[cy * cols + cx] += gray(y * width + x)
                weight[cy * cols + cx] += 1
            }
        }
        // Images smaller than the grid: nearest-sample instead of leaving holes.
        for cy in 0..<rows {
            for cx in 0..<cols where weight[cy * cols + cx] == 0 {
                let x = min(width - 1, cx * width / cols), y = min(height - 1, cy * height / rows)
                out[cy * cols + cx] = gray(y * width + x)
                weight[cy * cols + cx] = 1
            }
        }
        return zip(out, weight).map { $0 / $1 }
    }

    func hashes() -> (UInt64, UInt64) {
        let d = downsample(cols: 9, rows: 8)
        var dHash: UInt64 = 0
        for y in 0..<8 { for x in 0..<8 where d[y * 9 + x] < d[y * 9 + x + 1] { dHash |= 1 << UInt64(y * 8 + x) } }
        let a = downsample(cols: 8, rows: 8)
        let mean = a.reduce(0, +) / 64
        var aHash: UInt64 = 0
        for i in 0..<64 where a[i] > mean { aHash |= 1 << UInt64(i) }
        return (dHash, aHash)
    }

    /// 4x4x4 RGB histogram of opaque pixels.
    func palette() -> Data {
        var bins = [Float](repeating: 0, count: 64)
        var total: Float = 0
        for i in 0..<(width * height) {
            let a = Int(pixels[i * 4 + 3])
            guard a >= 128 else { continue }
            let r = min(255, Int(pixels[i * 4]) * 255 / a)
            let g = min(255, Int(pixels[i * 4 + 1]) * 255 / a)
            let b = min(255, Int(pixels[i * 4 + 2]) * 255 / a)
            bins[(r >> 6) * 16 + (g >> 6) * 4 + (b >> 6)] += 1
            total += 1
        }
        if total > 0 { for i in 0..<64 { bins[i] /= total } }
        return bins.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

/// Distance computations + greedy nearest-neighbour chaining.
private struct FeatureSpace {
    let n: Int
    let useVision: Bool
    let dHash: [UInt64]
    let aHash: [UInt64]
    let palette: [Float]   // n x 64
    let vision: [Float]    // n x dim
    let dim: Int

    init(features: [ImageFeatures], useVision: Bool) {
        n = features.count
        self.useVision = useVision
        dHash = features.map(\.dHash)
        aHash = features.map(\.aHash)
        palette = features.flatMap { f in f.palette.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } }
        if useVision {
            let vecs = features.map { f in f.vision!.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } }
            let d = vecs.first?.count ?? 0
            dim = d
            vision = vecs.flatMap { $0.count == d ? $0 : [Float](repeating: 0, count: d) }
        } else {
            dim = 0
            vision = []
        }
    }

    private func hashDistance(_ i: Int, _ j: Int) -> Float {
        Float((dHash[i] ^ dHash[j]).nonzeroBitCount + (aHash[i] ^ aHash[j]).nonzeroBitCount) / 128
    }

    private func paletteDistance(_ i: Int, _ j: Int) -> Float {
        var s: Float = 0
        for k in 0..<64 { s += abs(palette[i * 64 + k] - palette[j * 64 + k]) }
        return s / 2
    }

    private func visionDistance(_ i: Int, _ j: Int) -> Float {
        var dot: Float = 0
        vision.withUnsafeBufferPointer { v in
            vDSP_dotpr(v.baseAddress! + i * dim, 1, v.baseAddress! + j * dim, 1, &dot, vDSP_Length(dim))
        }
        return visionDistance(similarity: dot)
    }

    private func visionDistance(similarity s: Float) -> Float { sqrt(max(0, 2 - 2 * s)) / 2 }

    func distance(_ i: Int, _ j: Int) -> Float {
        if useVision {
            return 0.6 * visionDistance(i, j) + 0.25 * hashDistance(i, j) + 0.15 * paletteDistance(i, j)
        }
        return hashDistance(i, j)
    }

    /// k nearest neighbours of every item, sorted by distance.
    private func knn(k: Int, candidates: Int, token: CancelToken) -> [[Int]]? {
        var result = [[Int]](repeating: [], count: n)
        let k = min(k, n - 1)
        let block = 128
        let blocks = (n + block - 1) / block
        result.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: blocks) { b in
                if token.isCancelled { return }
                let i0 = b * block, i1 = min(n, i0 + block)
                if useVision {
                    // Similarity block (rows i0..<i1) x all, via BLAS, then exact re-rank of candidates.
                    var sims = [Float](repeating: 0, count: (i1 - i0) * n)
                    vision.withUnsafeBufferPointer { v in
                        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(i1 - i0), Int32(n), Int32(dim),
                                    1, v.baseAddress! + i0 * dim, Int32(dim), v.baseAddress!, Int32(dim),
                                    0, &sims, Int32(n))
                    }
                    for i in i0..<i1 {
                        let row = (i - i0) * n
                        var top = TopK(k: min(candidates, n - 1))
                        for j in 0..<n where j != i { top.insert(j, -sims[row + j]) }
                        var best = TopK(k: k)
                        for j in top.items {
                            let d = 0.6 * visionDistance(similarity: sims[row + j]) + 0.25 * hashDistance(i, j)
                                + 0.15 * paletteDistance(i, j)
                            best.insert(j, d)
                        }
                        out[i] = best.items
                    }
                } else {
                    for i in i0..<i1 {
                        var top = TopK(k: k)
                        for j in 0..<n where j != i { top.insert(j, hashDistance(i, j)) }
                        out[i] = top.items
                    }
                }
            }
        }
        return token.isCancelled ? nil : result
    }

    /// Greedy walk: always step to the closest unvisited image; when a cluster is
    /// exhausted, jump to the closest remaining image anywhere.
    func chainOrder(neighbours: Int, candidates: Int, token: CancelToken) -> [Int]? {
        guard n > 1 else { return Array(0..<n) }
        guard let nn = knn(k: neighbours, candidates: candidates, token: token) else { return nil }
        var visited = [Bool](repeating: false, count: n)
        var order: [Int] = []
        order.reserveCapacity(n)
        var current = 0
        while true {
            visited[current] = true
            order.append(current)
            if order.count == n { break }
            if let next = nn[current].first(where: { !visited[$0] }) {
                current = next
                continue
            }
            if token.isCancelled { return nil }
            var best = -1
            var bestD = Float.infinity
            for j in 0..<n where !visited[j] {
                let d = distance(current, j)
                if d < bestD { bestD = d; best = j }
            }
            current = best
        }
        return order
    }
}

/// Small bounded "k smallest" collector; ties keep the lower index (name order).
private struct TopK {
    let k: Int
    private(set) var dist: [Float] = []
    private(set) var items: [Int] = []

    init(k: Int) {
        self.k = k
        dist.reserveCapacity(k + 1)
        items.reserveCapacity(k + 1)
    }

    mutating func insert(_ item: Int, _ d: Float) {
        guard k > 0 else { return }
        if items.count == k, d >= dist[k - 1] { return }
        var pos = items.count
        while pos > 0 && dist[pos - 1] > d { pos -= 1 }
        dist.insert(d, at: pos)
        items.insert(item, at: pos)
        if items.count > k { dist.removeLast(); items.removeLast() }
    }
}

/// Features persisted per folder in ~/Library/Caches so re-sorting is instant.
private struct FeatureCache: Codable {
    var folder: String
    var records: [String: ImageFeatures]

    private static func file(for folder: URL) -> URL {
        var hash: UInt64 = 0xcbf29ce484222325
        for b in folder.standardizedFileURL.path.utf8 { hash = (hash ^ UInt64(b)) &* 0x100000001b3 }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.anthonygillis.PixelFinder/features", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(String(hash, radix: 16) + ".plist")
    }

    static func load(folder: URL) -> FeatureCache {
        let path = folder.standardizedFileURL.path
        if let data = try? Data(contentsOf: file(for: folder)),
           let cache = try? PropertyListDecoder().decode(FeatureCache.self, from: data), cache.folder == path {
            return cache
        }
        return FeatureCache(folder: path, records: [:])
    }

    mutating func prune(keeping names: Set<String>) {
        records = records.filter { names.contains($0.key) }
    }

    func save() {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        if let data = try? encoder.encode(self) {
            try? data.write(to: Self.file(for: URL(fileURLWithPath: folder)), options: .atomic)
        }
    }
}
