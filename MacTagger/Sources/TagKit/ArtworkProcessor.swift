//
//  ArtworkProcessor.swift
//  MacTagger — 封面图像处理（缩放 / 转 JPEG / 限制体积）
//
//  对应原版三个封面选项：
//    · 「更改分辨率 / 取消更改分辨率」  → resize(_:maxEdge:)
//    · 「内置图片大小限制」            → limit(_:maxBytes:)
//    · 「固定为 JPG」                  → convertToJPEG(_:quality:)
//
//  实现约束：
//  1. 只用 ImageIO / CoreGraphics，**不碰 AppKit** —— 本文件与整个 TagKit 一样要能在
//     命令行 probe 里跑（NSImage 在无窗口进程里也能用，但会拖起整套 AppKit，没必要）。
//  2. 缩放走 `CGImageSourceCreateThumbnailAtIndex`（ImageIO 的降采样通道），
//     不是「解码整图再画到小画布」—— 后者对 3000×3000 的原图会吃掉几十 MB 峰值内存。
//  3. **绝不放大**：目标边长 ≥ 原图最长边时原样返回，字节数一个不动。
//     原版「取消更改分辨率」是不再处理新图，不是把已缩小的图还原（信息已丢失）。
//  4. 只输出 JPEG / PNG 两种。ID3v2 APIC 与 FLAC PICTURE 实际只有这两种能被各播放器
//     普遍认出；源图是 HEIC/WebP/TIFF 时一律转 JPEG。
//

import Foundation
import ImageIO
import CoreGraphics

// MARK: - 错误

public enum ArtworkProcessError: LocalizedError, Equatable, Sendable {
    case notAnImage
    case decodeFailed
    case encodeFailed(String)
    case invalidArgument(String)

    public var errorDescription: String? {
        switch self {
        case .notAnImage:            return "这段数据不是可识别的图片"
        case .decodeFailed:          return "图片解码失败"
        case .encodeFailed(let m):   return "图片编码失败：\(m)"
        case .invalidArgument(let m):return "参数非法：\(m)"
        }
    }
}

// MARK: - 输出格式

public enum ArtworkOutputFormat: String, CaseIterable, Sendable, Hashable {
    /// 保持原格式（原格式不是 JPEG/PNG 时自动转 JPEG）
    case keep
    case jpeg

    public var localizedName: String {
        switch self {
        case .keep: return "保持原格式"
        case .jpeg: return "JPEG"
        }
    }
}

// MARK: - 处理选项

/// 一次「调整」的完整描述。全部字段取默认值时 `process` 是恒等变换。
public struct ArtworkProcessOptions: Sendable, Equatable, Hashable {
    /// 最长边上限，0 = 不限制（原始尺寸）。
    public var maxEdge: Int
    public var format: ArtworkOutputFormat
    /// JPEG 质量 0…1。仅在实际产出 JPEG 时有意义。
    public var jpegQuality: Double
    /// 字节上限，0 = 不限制。逐步降质 → 逐步缩边，直到达标。
    public var maxBytes: Int

    public init(maxEdge: Int = 0,
                format: ArtworkOutputFormat = .keep,
                jpegQuality: Double = 0.85,
                maxBytes: Int = 0) {
        self.maxEdge = maxEdge
        self.format = format
        self.jpegQuality = jpegQuality
        self.maxBytes = maxBytes
    }

    /// 什么都不做。
    public static let identity = ArtworkProcessOptions()

    public var isIdentity: Bool {
        maxEdge <= 0 && format == .keep && maxBytes <= 0
    }

    /// 界面上的最长边档位（0 = 原始）。
    public static let maxEdgeChoices: [Int] = [0, 300, 500, 800, 1000, 1200]

    public static func maxEdgeLabel(_ v: Int) -> String {
        v <= 0 ? "原始" : "\(v) px"
    }
}

// MARK: - 处理结果

public struct ArtworkProcessResult: Sendable, Equatable {
    public var data: Data
    public var width: Int
    public var height: Int
    public var mimeType: String
    /// 处理前的字节数，供界面显示「1.2 MB → 180 KB」。
    public var originalByteCount: Int

    public var byteCount: Int { data.count }
    public var changed: Bool { data.count != originalByteCount }

    public init(data: Data, width: Int, height: Int, mimeType: String, originalByteCount: Int) {
        self.data = data
        self.width = width
        self.height = height
        self.mimeType = mimeType
        self.originalByteCount = originalByteCount
    }

    public var summary: String {
        let kb = Double(data.count) / 1024.0
        let dims = (width > 0 && height > 0) ? "\(width)×\(height)" : "尺寸未知"
        return String(format: "%@ · %.0f KB", dims, kb)
    }
}

// MARK: - 处理器

public enum ArtworkProcessor {

    // MARK: 读元数据

    /// 只读图头拿像素尺寸，不解码整张图。识别不了返回 (0, 0)。
    public static func pixelSize(_ data: Data) -> (width: Int, height: Int) {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return (0, 0) }
        return (w, h)
    }

    /// 由字节内容判定 MIME（不看扩展名、不看标签里声明的值 —— 两者都常年写错）。
    public static func mimeType(_ data: Data) -> String? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let uti = CGImageSourceGetType(src) as String? else { return nil }
        return Self.mime(forUTI: uti)
    }

    static func mime(forUTI uti: String) -> String {
        switch uti {
        case "public.png":                       return "image/png"
        case "public.jpeg", "public.jpeg-2000":  return "image/jpeg"
        case "com.compuserve.gif":               return "image/gif"
        case "public.tiff":                      return "image/tiff"
        case "org.webmproject.webp":             return "image/webp"
        case "public.heic", "public.heif":       return "image/heic"
        default:                                 return "application/octet-stream"
        }
    }

    /// 输出只允许 JPEG / PNG；其余一律落到 JPEG。
    static func outputUTI(sourceUTI: String?, format: ArtworkOutputFormat) -> String {
        if format == .jpeg { return "public.jpeg" }
        switch sourceUTI {
        case "public.png": return "public.png"
        case "public.jpeg": return "public.jpeg"
        default: return "public.jpeg"       // HEIC / WebP / TIFF / GIF → JPEG
        }
    }

    // MARK: 单步操作

    /// 缩放到最长边 ≤ maxEdge。原图已经更小则原样返回（**绝不放大**）。
    /// 格式保持不变（PNG 仍是 PNG），仅像素变少。
    public static func resize(_ data: Data, maxEdge: Int) throws -> Data {
        guard maxEdge > 0 else { return data }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ArtworkProcessError.notAnImage
        }
        let size = pixelSize(data)
        guard size.width > 0, size.height > 0 else { throw ArtworkProcessError.notAnImage }
        if max(size.width, size.height) <= maxEdge { return data }

        let uti = CGImageSourceGetType(src) as String?
        guard let image = downsample(src, maxEdge: maxEdge) else {
            throw ArtworkProcessError.decodeFailed
        }
        return try encode(image,
                          uti: outputUTI(sourceUTI: uti, format: .keep),
                          quality: 0.9)
    }

    /// 无论原格式是什么，一律重编码为 JPEG。质量 0…1。
    public static func convertToJPEG(_ data: Data, quality: Double) throws -> Data {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw ArtworkProcessError.notAnImage
        }
        return try encode(image, uti: "public.jpeg", quality: clampQuality(quality))
    }

    /// 压到 ≤ maxBytes：先逐步降 JPEG 质量，仍不达标再逐步缩边。
    /// 已经达标就原样返回（**不会为了「处理一下」而无谓重编码**）。
    /// 缩到 `minEdge` 且质量降到 `minQuality` 仍超标时，返回当前最好的结果 —— 不抛错，
    /// 由调用方决定是否接受（原版同样是尽力而为）。
    public static func limit(_ data: Data,
                             maxBytes: Int,
                             minQuality: Double = 0.4,
                             minEdge: Int = 200) throws -> Data {
        guard maxBytes > 0 else { return data }
        if data.count <= maxBytes { return data }

        var best = try convertToJPEG(data, quality: 0.85)
        if best.count <= maxBytes { return best }

        // ① 降质
        var q = 0.85
        while q > minQuality {
            q -= 0.15
            let candidate = try convertToJPEG(data, quality: max(q, minQuality))
            best = candidate
            if candidate.count <= maxBytes { return candidate }
        }

        // ② 缩边（每轮 ×0.8），质量固定在下限
        var edge = max(pixelSize(data).width, pixelSize(data).height)
        while edge > minEdge {
            edge = max(minEdge, Int(Double(edge) * 0.8))
            let shrunk = try resize(data, maxEdge: edge)
            let candidate = try convertToJPEG(shrunk, quality: minQuality)
            best = candidate
            if candidate.count <= maxBytes { return candidate }
        }
        return best
    }

    // MARK: 组合

    /// 按选项跑完整流水线：缩放 → 转格式 → 限体积。
    public static func process(_ data: Data, options: ArtworkProcessOptions) throws -> ArtworkProcessResult {
        let originalCount = data.count
        guard !data.isEmpty else { throw ArtworkProcessError.notAnImage }

        var work = data
        if options.maxEdge > 0 {
            work = try resize(work, maxEdge: options.maxEdge)
        }
        if options.format == .jpeg {
            work = try convertToJPEG(work, quality: options.jpegQuality)
        } else if options.maxEdge > 0 {
            // resize 已按原格式重编码过，这里不再动
        }
        if options.maxBytes > 0 {
            work = try limit(work, maxBytes: options.maxBytes)
        }

        let size = pixelSize(work)
        return ArtworkProcessResult(data: work,
                                    width: size.width,
                                    height: size.height,
                                    mimeType: mimeType(work) ?? "image/jpeg",
                                    originalByteCount: originalCount)
    }

    /// 处理一张 `Artwork`，并把新的 mimeType 与声明尺寸一并更新。
    /// 声明尺寸不更新的话，FLAC 的 PICTURE 块会带着旧的 1200×1200 写进文件，
    /// 检查器读回来显示的尺寸与实际像素对不上。
    public static func process(_ artwork: Artwork, options: ArtworkProcessOptions) throws -> Artwork {
        let result = try process(artwork.data, options: options)
        var out = artwork
        out.data = result.data
        out.mimeType = result.mimeType
        out.declaredWidth = result.width
        out.declaredHeight = result.height
        return out
    }

    /// 「添加封面时自动限制」用的便捷入口：处理失败时原样返回，绝不因为压缩失败丢掉封面。
    public static func processLeniently(_ artwork: Artwork, options: ArtworkProcessOptions) -> Artwork {
        guard !options.isIdentity else { return artwork }
        return (try? process(artwork, options: options)) ?? artwork
    }

    /// 用当前字节重新校准 `Artwork` 的 mimeType 与声明尺寸（不改像素）。
    public static func refreshedMetadata(_ artwork: Artwork) -> Artwork {
        var out = artwork
        let size = pixelSize(artwork.data)
        if size.width > 0 { out.declaredWidth = size.width; out.declaredHeight = size.height }
        if let m = mimeType(artwork.data) { out.mimeType = m }
        return out
    }

    // MARK: 内部

    static func clampQuality(_ q: Double) -> Double { min(max(q, 0.1), 1.0) }

    private static func downsample(_ src: CGImageSource, maxEdge: Int) -> CGImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxEdge
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    private static func encode(_ image: CGImage, uti: String, quality: Double) throws -> Data {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, uti as CFString, 1, nil) else {
            throw ArtworkProcessError.encodeFailed("无法创建 \(uti) 编码器")
        }
        var props: [CFString: Any] = [:]
        if uti == "public.jpeg" {
            props[kCGImageDestinationLossyCompressionQuality] = clampQuality(quality)
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ArtworkProcessError.encodeFailed("写出失败")
        }
        return out as Data
    }
}
