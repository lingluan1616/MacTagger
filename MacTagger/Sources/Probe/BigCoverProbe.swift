//
//  BigCoverProbe.swift
//  mactagger-probe — 超大封面上限（AT-04）的验证子命令
//
//    mactagger-probe bigcover <音频副本> [--mb 17] [--m4a <m4a副本>] [--keep]
//
//  背景：FLAC 的 METADATA_BLOCK 长度字段只有 24 bit（上限 16,777,215 B）。
//  超过这个数的 PICTURE 块会被 TagLib 在渲染阶段整块跳过 —— `save()` 照样返回 true，
//  可原有封面早已被换下去，于是「报成功 + 封面凭空消失」。这就是 AT-04。
//
//  四组断言：
//    ① 直写 17 MiB   → 必须**拒写**（TagError.artworkTooLarge），且原封面**字节不变**
//    ② 自动压缩后写   → TagService.fitArtworks 压到 15 MiB 以内，写入成功
//    ③ 直写 16.5 MB   → 16,500,000 B 在限内，应当直接成功
//    ④ m4a 直写 17 MiB → MP4 没有这个上限，应当成功
//
//  全程在 `NSTemporaryDirectory()` 下的副本上做，**传入的文件零改动**，跑完自动删除
//  （`--keep` 保留现场）。本文件所有符号以 big 前缀命名，避免与同目录其它 probe 冲突。
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - 小工具

private func bigBytes(_ n: Int) -> String {
    let mib = Double(n) / (1024.0 * 1024.0)
    return String(format: "%@ B（%.2f MiB）",
                  NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal),
                  mib)
}

/// 把一组封面的字节数拍成可比对的指纹：张数 + 每张字节数 + 每张内容哈希。
private func bigFingerprint(_ arts: [Artwork]) -> String {
    guard !arts.isEmpty else { return "（0 张）" }
    return arts.map { "\($0.byteCount)B/\($0.data.hashValue)" }.joined(separator: " + ")
}

private func bigOK(_ pass: Bool) -> String { pass ? "✔ 通过" : "✘ 失败" }

/// 造一张**恰好** `targetBytes` 字节的噪声 JPEG。
///
/// 噪声不可压缩，才能稳定拿到十几 MB 的封面（纯色图 JPEG 只有几 KB）。
/// 先按估算的边长编码，逼近但**不超过**目标，再用随机字节补到刚好 ——
/// JPEG 的 EOI 之后是什么解码器都不看，ImageIO 照样解得开，
/// 而「刚好这么大」对上限测试是必须的（差几百字节就跨过 16,777,215 那条线）。
private func bigNoiseJPEG(targetBytes: Int) -> Data? {
    guard targetBytes > 4096 else { return nil }
    // 噪声 JPEG 在 q=1.0 下约 3.5 字节/像素，据此起手，再按实测比例迭代逼近。
    var edge = max(16, Int((Double(targetBytes) / 3.5).squareRoot()))
    var best: Data?

    for _ in 0..<8 {
        guard let d = bigEncodeNoise(edge: edge, quality: 1.0) else { return nil }
        if d.count <= targetBytes {
            best = d
            // 已经在目标的 75% 以上就够了，剩下的用填充补齐，别为了几个百分点再编一遍。
            if Double(d.count) >= Double(targetBytes) * 0.75 { break }
            // 两个方向都强制**单调**变化：否则边长被下限夹住时会原地打转，
            // 8 轮全部越界，best 一直是 nil，最后静默返回 nil（第一版就栽在这儿：
            // 200 KB 的种子图压根没造出来，「原封面完好」那条断言成了 0 张比 0 张）。
            edge = max(edge + 1,
                       Int(Double(edge) * (Double(targetBytes) / Double(d.count)).squareRoot() * 0.97))
        } else {
            edge = max(16, min(edge - 1,
                               Int(Double(edge) * (Double(targetBytes) / Double(d.count)).squareRoot() * 0.95)))
        }
    }
    guard var data = best else { return nil }
    if data.count < targetBytes {
        var seed: UInt64 = 0xD1B54A32D192ED03
        var filler = [UInt8](repeating: 0, count: targetBytes - data.count)
        for i in filler.indices {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            filler[i] = UInt8(truncatingIfNeeded: seed >> 33)
        }
        data.append(contentsOf: filler)
    }
    return data
}

private func bigEncodeNoise(edge: Int, quality: CGFloat) -> Data? {
    let bytesPerRow = edge * 4
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * edge)
    var seed: UInt64 = 0x9E3779B97F4A7C15
    for i in pixels.indices {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        pixels[i] = UInt8(truncatingIfNeeded: seed >> 33)
    }
    guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    var image: CGImage?
    pixels.withUnsafeMutableBytes { raw in
        guard let ctx = CGContext(data: raw.baseAddress,
                                  width: edge, height: edge,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        image = ctx.makeImage()
    }
    guard let cg = image else { return nil }
    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return out as Data
}

private func bigArtwork(_ data: Data, caption: String) -> Artwork {
    Artwork(data: data,
            mimeType: ArtworkProcessor.mimeType(data) ?? "image/jpeg",
            caption: caption,
            type: .frontCover)
}

// MARK: - bigcover

func cmdBigCover(_ path: String, args: [String]) {
    let source = URL(fileURLWithPath: path)
    hr("超大封面上限 AT-04 \(source.lastPathComponent)")

    var mib = 17
    if let i = args.firstIndex(of: "--mb"), i + 1 < args.count, let n = Int(args[i + 1]) { mib = n }
    let keep = args.contains("--keep")
    var m4aPath: String?
    if let i = args.firstIndex(of: "--m4a"), i + 1 < args.count { m4aPath = args[i + 1] }

    guard FileManager.default.fileExists(atPath: source.path) else {
        print("  文件不存在：\(source.path)"); return
    }

    // 工作目录：临时目录下的独立副本，传入的文件全程只读。
    let work = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mactagger-bigcover-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    defer { if !keep { try? FileManager.default.removeItem(at: work) } }
    print("  工作目录: \(work.path)" + (keep ? "（--keep，保留）" : "（跑完自动删除）"))

    // ---- 造图 ----
    let overBytes = mib * 1024 * 1024
    let underBytes = 16_500_000                 // 16.5 MB（十进制），在 16,777,215 的限内
    print("  上限     : FLAC METADATA_BLOCK = 24 bit → \(bigBytes(0xFF_FFFF))；"
          + "扣掉块头后允许的图片数据 \(bigBytes(ArtworkContainerLimit.flacDataLimit))")
    guard let over = bigNoiseJPEG(targetBytes: overBytes) else { print("  造不出超限大图"); return }
    guard let under = bigNoiseJPEG(targetBytes: underBytes) else { print("  造不出限内大图"); return }
    print("  超限图   : \(bigBytes(over.count))   \(ArtworkProcessor.pixelSize(over).width)px 见方")
    print("  限内图   : \(bigBytes(under.count))  \(ArtworkProcessor.pixelSize(under).width)px 见方")

    var passed = 0, failed = 0
    func score(_ ok: Bool) { if ok { passed += 1 } else { failed += 1 } }

    // 每组一份全新副本，互不污染。
    func freshCopy(_ tag: String, from src: URL) -> URL? {
        let dst = work.appendingPathComponent("\(tag).\(src.pathExtension)")
        try? FileManager.default.removeItem(at: dst)
        guard (try? FileManager.default.copyItem(at: src, to: dst)) != nil else {
            print("  复制失败：\(tag)"); return nil
        }
        return dst
    }

    /// 保证副本里**有**一张封面 —— 「原封面完好」这条断言得有东西可比。
    @discardableResult
    func seedCover(_ url: URL) -> [Artwork] {
        var arts = (try? TagService.readArtworks(url)) ?? []
        if arts.isEmpty {
            let seed = bigNoiseJPEG(targetBytes: 200 * 1024) ?? Data()
            var edit = TagEdit()
            edit.artworkAction = .replace([bigArtwork(seed, caption: "bigcover-seed")])
            _ = try? TagService.write(edit, to: url)
            arts = (try? TagService.readArtworks(url)) ?? []
        }
        return arts
    }

    // ------------------------------------------------ ① 超限直写：拒写 + 原封面完好
    print()
    print("  ① 直写 \(bigBytes(over.count)) 到 FLAC —— 期望「拒写 + 原封面完好」")
    if let copy = freshCopy("t1-reject", from: source) {
        let before = seedCover(copy)
        let beforeFP = bigFingerprint(before)
        let beforeSize = (try? FileManager.default.attributesOfItem(atPath: copy.path))?[.size] as? Int64 ?? -1
        print("     写前封面: \(before.count) 张，\(beforeFP)")
        // 没有原封面 = 「原封面完好」无从谈起，这一组必须有东西可比。
        if before.isEmpty { print("     ✘ 种子封面没写进去，本组结论不作数"); }

        var edit = TagEdit()
        edit.artworkAction = .replace([bigArtwork(over, caption: "bigcover")])
        var rejected = false
        var errText = "（没有抛错 —— 这正是 AT-04 的症状）"
        do {
            _ = try TagService.write(edit, to: copy)
        } catch let e as TagError {
            if case .artworkTooLarge = e { rejected = true }
            errText = e.localizedDescription
        } catch {
            errText = error.localizedDescription
        }

        let after = (try? TagService.readArtworks(copy)) ?? []
        let afterFP = bigFingerprint(after)
        let afterSize = (try? FileManager.default.attributesOfItem(atPath: copy.path))?[.size] as? Int64 ?? -2
        let intact = !before.isEmpty && (afterFP == beforeFP) && (afterSize == beforeSize)
        print("     返回    : \(rejected ? "TagError.artworkTooLarge" : "未拒写")｜\(errText)")
        print("     写后封面: \(after.count) 张，\(afterFP)")
        print("     文件长度: \(beforeSize) → \(afterSize) B")
        print("     \(bigOK(rejected && intact))  拒写=\(rejected)  原封面完好=\(intact)")
        score(rejected && intact)
    } else { score(false) }

    // ------------------------------------------------ ② 自动压缩后写入成功
    print()
    print("  ② 走「自动压缩」路径（TagService.fitArtworks，目标 "
          + "\(bigBytes(ArtworkContainerLimit.flacSafeTarget))）—— 期望「成功且 ≤ 15 MiB」")
    if let copy = freshCopy("t2-shrink", from: source) {
        seedCover(copy)
        var edit = TagEdit()
        edit.artworkAction = .replace([bigArtwork(over, caption: "bigcover")])
        let didShrink = TagService.fitArtworks(in: &edit, for: copy)
        var shrunkBytes = -1
        if case .replace(let arts) = edit.artworkAction { shrunkBytes = arts.first?.byteCount ?? -1 }
        print("     压缩    : \(didShrink ? "已压缩" : "未动手")｜\(bigBytes(over.count)) → \(bigBytes(max(shrunkBytes, 0)))")

        var wrote = false
        var errText = "-"
        do { _ = try TagService.write(edit, to: copy); wrote = true }
        catch { errText = error.localizedDescription }

        let after = (try? TagService.readArtworks(copy)) ?? []
        let backBytes = after.first?.byteCount ?? -1
        let withinTarget = backBytes > 0 && backBytes <= ArtworkContainerLimit.flacSafeTarget
        let withinHard = backBytes > 0 && backBytes <= ArtworkContainerLimit.flacDataLimit
        print("     写入    : \(wrote ? "成功" : "失败：\(errText)")")
        print("     回读    : \(after.count) 张，\(bigBytes(max(backBytes, 0)))")
        print("     \(bigOK(didShrink && wrote && withinTarget && withinHard))"
              + "  压过=\(didShrink)  写成功=\(wrote)  ≤15MiB=\(withinTarget)  ≤硬上限=\(withinHard)")
        score(didShrink && wrote && withinTarget && withinHard)
    } else { score(false) }

    // ------------------------------------------------ ③ 限内直写：直接成功
    print()
    print("  ③ 直写 \(bigBytes(under.count))（限内）到 FLAC —— 期望「直接成功」")
    if let copy = freshCopy("t3-under", from: source) {
        seedCover(copy)
        var edit = TagEdit()
        edit.artworkAction = .replace([bigArtwork(under, caption: "bigcover")])
        var wrote = false
        var errText = "-"
        do { _ = try TagService.write(edit, to: copy); wrote = true }
        catch { errText = error.localizedDescription }
        let after = (try? TagService.readArtworks(copy)) ?? []
        let backBytes = after.first?.byteCount ?? -1
        let sameBytes = backBytes == under.count
        print("     写入    : \(wrote ? "成功" : "失败：\(errText)")")
        print("     回读    : \(after.count) 张，\(bigBytes(max(backBytes, 0)))")
        print("     \(bigOK(wrote && sameBytes))  写成功=\(wrote)  字节一致=\(sameBytes)")
        score(wrote && sameBytes)
    } else { score(false) }

    // ------------------------------------------------ ③b 边界：恰好卡在 24 bit 上限的两侧
    //
    // 这一组才是真正证明「没有静默丢图的窗口」：桥接层算出来的开销必须**分毫不差**，
    // 否则「刚好比拒写线小一点」的图会顺利通过预检、却在 TagLib 渲染时被丢掉，
    // AT-04 就换个尺寸原样复发。
    //   块体 = 32（类型/长度/宽高/色深/颜色数）+ MIME + 描述 + 图片数据 ≤ 0xFFFFFF
    print()
    let caption = "bigcover"
    let overhead = 32 + "image/jpeg".utf8.count + caption.utf8.count
    let exactMax = 0xFF_FFFF - overhead
    print("  ③b 边界对拍：块头开销 \(overhead) B → 允许的最大图片数据 = \(bigBytes(exactMax))")
    for (label, size, shouldWrite) in [("恰好上限", exactMax, true), ("上限 +1", exactMax + 1, false)] {
        guard let img = bigNoiseJPEG(targetBytes: size), img.count == size else {
            print("     \(label): 造图失败"); score(false); continue
        }
        guard let copy = freshCopy("t3b-\(size)", from: source) else { score(false); continue }
        let seedBytes = seedCover(copy).first?.byteCount ?? -1
        var edit = TagEdit()
        edit.artworkAction = .replace([bigArtwork(img, caption: caption)])
        var wrote = false
        var errText = "-"
        do { _ = try TagService.write(edit, to: copy); wrote = true }
        catch { errText = error.localizedDescription }
        let after = (try? TagService.readArtworks(copy)) ?? []
        let backBytes = after.first?.byteCount ?? -1
        // 期望写成功时：必须真的读得回同样的字节（这一条专抓「报成功但图没了」）。
        // 期望拒写时：必须抛错，且原来那张种子封面还在。
        let ok = shouldWrite ? (wrote && backBytes == size)
                             : (!wrote && seedBytes > 0 && backBytes == seedBytes)
        print("     \(label)（\(size) B）: 写入=\(wrote ? "成功" : "拒写")"
              + "  回读=\(after.count) 张/\(backBytes) B"
              + (wrote ? "" : "  ｜\(errText)"))
        print("     \(bigOK(ok))")
        score(ok)
    }

    // ------------------------------------------------ ④ m4a 同尺寸：没有这个上限
    print()
    if let m4a = m4aPath {
        let src = URL(fileURLWithPath: m4a)
        print("  ④ 直写 \(bigBytes(over.count)) 到 \(src.lastPathComponent) —— 期望「成功（MP4 无此上限）」")
        if FileManager.default.fileExists(atPath: src.path), let copy = freshCopy("t4-m4a", from: src) {
            var edit = TagEdit()
            edit.artworkAction = .replace([bigArtwork(over, caption: "bigcover")])
            // 走的是与 App 相同的前置：m4a 不该被压。
            let didShrink = TagService.fitArtworks(in: &edit, for: copy)
            var wrote = false
            var errText = "-"
            do { _ = try TagService.write(edit, to: copy); wrote = true }
            catch { errText = error.localizedDescription }
            let after = (try? TagService.readArtworks(copy)) ?? []
            let backBytes = after.first?.byteCount ?? -1
            let sameBytes = backBytes == over.count
            print("     自动压缩: \(didShrink ? "被压了（不应该）" : "未动手（正确，MP4 不设限）")")
            print("     写入    : \(wrote ? "成功" : "失败：\(errText)")")
            print("     回读    : \(after.count) 张，\(bigBytes(max(backBytes, 0)))")
            print("     \(bigOK(wrote && sameBytes && !didShrink))"
                  + "  写成功=\(wrote)  字节一致=\(sameBytes)  未误压=\(!didShrink)")
            score(wrote && sameBytes && !didShrink)
        } else {
            print("     文件不存在，跳过：\(src.path)")
        }
    } else {
        print("  ④ 未传 --m4a <m4a副本>，跳过 MP4 对照组")
    }

    print()
    print("  合计: 通过 \(passed)｜失败 \(failed)")
}
