//
//  PaddingProbe.swift
//  mactagger-probe — 文件头预留填充的验证子命令
//
//    mactagger-probe padding inspect <file>
//    mactagger-probe padding reserve <file副本> [--bytes N]
//    mactagger-probe padding demo    <flac副本> <大图>
//
//  demo 完整走一遍五步，证明「预留填充」这条对策成立：
//    ① 第一次嵌封面        → 整文件重写（大小 / 耗时 / PADDING 前后）
//    ② 扩填充到 512 KB
//    ③ 再换一张 300 KB 封面 → 原地改写（大小不变、毫秒级）
//    ④ 再改标题            → 原地
//    ⑤ 扩到 1.5 MB 后保存   → 触发收缩（证 TagLib 的 1 MB 上限规则）
//
//  本文件所有符号以 pad 前缀命名，避免与同目录其余 probe 冲突。
//
//    mactagger-probe padding identity <音频副本...>   （BP-G：扩填充不丢 xattr / Finder 标签 / 不拆硬链接）
//

import Foundation
import CoreGraphics
import ImageIO

// MARK: - 小工具

func padKB(_ n: Int64) -> String { String(format: "%.1f KB", Double(n) / 1024.0) }
func padMB(_ n: Int64) -> String { String(format: "%.2f MB", Double(n) / 1048576.0) }
func padMS(_ t: TimeInterval) -> String { String(format: "%.0f ms", t * 1000.0) }

func padPrintInfo(_ info: PaddingInfo, indent: String = "  ") {
    guard info.isSupported else {
        print(indent + "不支持解析：\(info.note)")
        return
    }
    print(indent + "容器 \(info.container)  文件 \(padMB(info.fileBytes))"
          + "  PADDING \(padKB(info.currentPadding))（\(info.currentPadding) 字节）"
          + "  元数据区 \(padKB(info.metadataBytes))  音频起点 \(info.audioOffset)")
    if !info.blocks.isEmpty {
        for b in info.blocks {
            print(indent + "  · " + intlPad(b.name, 16)
                  + intlPad("\(b.length) 字节", 14)
                  + "offset \(b.offset)" + (b.isLast ? "  [last]" : ""))
        }
    }
}

/// 一次「保存 → 观察」：返回耗时与前后快照。
@discardableResult
func padSave(_ url: URL, _ edit: TagEdit, label: String) -> (before: PaddingInfo, after: PaddingInfo, seconds: TimeInterval) {
    let before = PaddingReserver.inspect(url)
    let t0 = Date()
    do { try TagService.write(edit, to: url) }
    catch { print("  \(label) 写入失败：\(error.localizedDescription)") }
    let seconds = Date().timeIntervalSince(t0)
    let after = PaddingReserver.inspect(url)
    return (before, after, seconds)
}

func padMakeArtwork(_ data: Data) -> Artwork {
    ArtworkProcessor.refreshedMetadata(
        Artwork(data: data, mimeType: ArtworkProcessor.mimeType(data) ?? "image/jpeg",
                caption: nil, type: .frontCover))
}

// MARK: - padding inspect

func cmdPaddingInspect(_ path: String) {
    let url = URL(fileURLWithPath: path)
    hr("填充结构 \(url.lastPathComponent)")
    let info = PaddingReserver.inspect(url)
    padPrintInfo(info)
    print()
    print("  说明        : \(info.note)")
    print("  可扩填充    : " + (PaddingReserver.canReserve(url) ? "是" : "否（当前只支持 FLAC / MP3）"))
    guard info.isSupported else { return }
    let hard = PaddingReserver.maxKeepablePadding(fileBytes: info.fileBytes,
                                                  currentPadding: info.currentPadding)
    print("  留得住上限  : \(padKB(Int64(hard)))"
          + "  = min((文件 − 填充) / 99, \(padKB(Int64(PaddingReserver.taglibMaxPadding))))")
    print("  推荐预留    : \(padKB(Int64(PaddingReserver.recommendedTarget(for: info))))"
          + "（设置值 \(padKB(Int64(PaddingReserver.defaultReserveBytes))) 与上限 × 0.95 取小）")
}

// MARK: - padding reserve

func cmdPaddingReserve(_ path: String, args: [String]) {
    let url = URL(fileURLWithPath: path)
    var target = PaddingReserver.defaultReserveBytes
    if let i = args.firstIndex(of: "--bytes"), i + 1 < args.count, let n = Int(args[i + 1]) {
        target = n
    }
    hr("扩填充 \(url.lastPathComponent) → \(padKB(Int64(target)))")

    print("  改写前：")
    padPrintInfo(PaddingReserver.inspect(url), indent: "    ")
    let techBefore = try? TagService.readTechnicalInfo(url)
    let tagsBefore = try? TagService.read(url)

    do {
        let r = try PaddingReserver.reserve(url, target: target)
        print()
        print("  结果        : " + (r.changed ? "已改写" : "未改动"))
        print("  填充        : \(r.paddingBefore) → \(r.paddingAfter) 字节")
        print("  文件大小    : \(r.fileBytesBefore) → \(r.fileBytesAfter) 字节"
              + "（+\(r.fileBytesAfter - r.fileBytesBefore)）")
        print("  搬动音频    : \(padMB(r.movedBytes))")
        print("  耗时        : \(padMS(r.elapsed))")
        print("  说明        : \(r.note)")
    } catch {
        print("  失败：\(error.localizedDescription)")
        return
    }

    print()
    print("  改写后：")
    padPrintInfo(PaddingReserver.inspect(url), indent: "    ")

    // 复核：技术参数与标签必须原样
    if let a = techBefore, let b = try? TagService.readTechnicalInfo(url) {
        let same = a.durationMilliseconds == b.durationMilliseconds
                && a.sampleRate == b.sampleRate && a.channels == b.channels
        print("  技术参数    : " + (same
            ? "✔ 时长 \(b.durationMilliseconds) ms / 采样率 \(b.sampleRate) Hz / 声道 \(b.channels) 均未变"
            : "✘ 变了！\(a.durationMilliseconds)→\(b.durationMilliseconds) ms"))
    }
    if let a = tagsBefore?.tags, let b = (try? TagService.read(url))?.tags {
        print("  标签复核    : " + (a == b ? "✔ 全部字段原样" : "✘ 标签变了！"))
    }
}

// MARK: - padding demo（完整演示）

/// 完整走一遍，把「预留填充」这条对策的成立条件与边界全部量出来。
func cmdPaddingDemo(_ flacPath: String, _ imagePath: String) {
    let url = URL(fileURLWithPath: flacPath)
    hr("预留填充完整演示 \(url.lastPathComponent)")

    guard let bigImage = try? Data(contentsOf: URL(fileURLWithPath: imagePath)), !bigImage.isEmpty else {
        print("  读不到图片：\(imagePath)"); return
    }
    guard let cover300 = try? ArtworkProcessor.limit(bigImage, maxBytes: 300 * 1024),
          let cover290 = try? ArtworkProcessor.limit(bigImage, maxBytes: 290 * 1024),
          let cover60  = try? ArtworkProcessor.limit(bigImage, maxBytes: 60 * 1024) else {
        print("  压不出演示用的封面"); return
    }

    let start = PaddingReserver.inspect(url)
    print("  素材        : 大图 \(padKB(Int64(bigImage.count)))"
          + "，封面A \(padKB(Int64(cover300.count)))"
          + "，封面B \(padKB(Int64(cover290.count)))"
          + "，小封面 \(padKB(Int64(cover60.count)))")
    print("  起点        :")
    padPrintInfo(start, indent: "    ")
    print("  尺寸推算    : 硬边界 min((文件−填充)/99, 1 MB) = "
          + padKB(Int64(PaddingReserver.maxKeepablePadding(fileBytes: start.fileBytes,
                                                           currentPadding: start.currentPadding)))
          + "，打 95 折后推荐预留 "
          + padKB(Int64(PaddingReserver.recommendedTarget(for: start))))
    print("  注意        : 以下耗时全部跑在内建 SSD 上；TF 卡的整文件重写要慢一到两个数量级。")

    // ---------------------------------------------------------------- ①
    print()
    print("  ── ① 第一次嵌封面（\(padKB(Int64(bigImage.count)))大图）"
          + String(repeating: "─", count: 26))
    var e1 = TagEdit()
    e1.artworkAction = .replace([padMakeArtwork(bigImage)])
    let s1 = padSave(url, e1, label: "①")
    padStep(s1, extra: "TagLib 把填充砸到了 \(s1.after.currentPadding) 字节（= MinPaddingLength）")
    print("     要不要补填充：" + (PaddingReserver.shouldReserveAfterSave(before: s1.before, after: s1.after)
                                 ? "要（刚重写过 + 填充不足推荐值）" : "不用"))

    // ---------------------------------------------------------------- ②
    print()
    print("  ── ② 换成常规大小的封面 A（\(padKB(Int64(cover300.count)))）"
          + String(repeating: "─", count: 20))
    print("     说明：这一步把文件带到「一张正常封面 + 极小填充」的稳态，")
    print("           也顺带演示了**把封面换小是危险方向**（旧封面腾出的空间会撑爆剩余填充）。")
    var e2 = TagEdit()
    e2.artworkAction = .replace([padMakeArtwork(cover300)])
    let s2 = padSave(url, e2, label: "②")
    padStep(s2)

    // ---------------------------------------------------------------- ③
    print()
    print("  ── ③ 扩填充到推荐值 " + String(repeating: "─", count: 39))
    let cur = PaddingReserver.inspect(url)
    let target = PaddingReserver.recommendedTarget(for: cur)
    print("     硬边界    : \(padKB(Int64(PaddingReserver.maxKeepablePadding(fileBytes: cur.fileBytes, currentPadding: cur.currentPadding))))"
          + "    推荐预留：\(padKB(Int64(target)))")
    do {
        let r = try PaddingReserver.reserve(url, target: target)
        print("     填充      : \(r.paddingBefore) → \(r.paddingAfter) 字节")
        print("     文件大小  : \(r.fileBytesBefore) → \(r.fileBytesAfter) 字节")
        print("     搬动音频  : \(padMB(r.movedBytes))   耗时 \(padMS(r.elapsed))")
        print("     \(r.note)")
    } catch {
        print("     失败：\(error.localizedDescription)"); return
    }

    // ---------------------------------------------------------------- ④
    print()
    print("  ── ④ 换封面 B（\(padKB(Int64(cover290.count)))，与 A 同量级）"
          + String(repeating: "─", count: 18))
    var e4 = TagEdit()
    e4.artworkAction = .replace([padMakeArtwork(cover290)])
    let s4 = padSave(url, e4, label: "④")
    padStep(s4)

    // ---------------------------------------------------------------- ⑤
    print()
    print("  ── ⑤ 只改标题 " + String(repeating: "─", count: 45))
    var e5 = TagEdit()
    e5.set(.title, "预留填充验证 \(Int(Date().timeIntervalSince1970))")
    let s5 = padSave(url, e5, label: "⑤")
    padStep(s5)

    // ---------------------------------------------------------------- ⑥
    print()
    print("  ── ⑥ 危险方向：换成 \(padKB(Int64(cover60.count))) 的小封面 "
          + String(repeating: "─", count: 20))
    var e6 = TagEdit()
    e6.artworkAction = .replace([padMakeArtwork(cover60)])
    let s6 = padSave(url, e6, label: "⑥")
    padStep(s6, extra: "剩余填充 = 原填充 + 旧封面 − 新封面，换小会把它撑过 1% 线")

    // ---------------------------------------------------------------- ⑦
    print()
    print("  ── ⑦ 故意预留 1.5 MB（越过 TagLib 硬上限）后保存 "
          + String(repeating: "─", count: 12))
    let over = 1536 * 1024
    do {
        let r = try PaddingReserver.reserve(url, target: over)
        print("     填充      : \(r.paddingBefore) → \(r.paddingAfter) 字节   耗时 \(padMS(r.elapsed))")
    } catch {
        print("     失败：\(error.localizedDescription)")
    }
    var e7 = TagEdit()
    e7.set(.comment, "1.5MB 上限验证")
    let s7 = padSave(url, e7, label: "⑦")
    padStep(s7, extra: s7.after.currentPadding < s7.before.currentPadding
            ? "✔ 填充被 TagLib 收缩，证实上限规则" : "○ 未收缩")

    // ---------------------------------------------------------------- 收尾
    print()
    print("  ── 收尾复核 " + String(repeating: "─", count: 47))
    if let tech = try? TagService.readTechnicalInfo(url) {
        print("     时长 \(tech.durationMilliseconds) ms"
              + "  采样率 \(tech.sampleRate) Hz  声道 \(tech.channels)"
              + "  位深 \(tech.bitsPerSample)")
    }
    if let f = try? TagService.read(url) {
        let arts = (try? TagService.readArtworks(url)) ?? []
        print("     标题 \(fmt(f.tags.title))   封面 \(arts.count) 张"
              + (arts.first.map { "（\(padKB(Int64($0.byteCount)))）" } ?? ""))
    }
    padPrintInfo(PaddingReserver.inspect(url), indent: "     ")
}

/// 一步保存的统一输出。
func padStep(_ s: (before: PaddingInfo, after: PaddingInfo, seconds: TimeInterval), extra: String? = nil) {
    let inPlace = (s.before.audioOffset == s.after.audioOffset) && (s.before.fileBytes == s.after.fileBytes)
    print("     文件大小  : \(s.before.fileBytes) → \(s.after.fileBytes) 字节"
          + (s.before.fileBytes == s.after.fileBytes ? "   ✔ 完全不变" : "   （变了）"))
    print("     音频起点  : \(s.before.audioOffset) → \(s.after.audioOffset)"
          + (s.before.audioOffset == s.after.audioOffset ? "   ✔ 没挪" : "   ✘ 挪了"))
    print("     PADDING   : \(s.before.currentPadding) → \(s.after.currentPadding) 字节")
    print("     耗时      : \(padMS(s.seconds))")
    print("     判定      : " + (inPlace ? "✔ 原地改写" : "✘ 整文件重写"))
    if let extra { print("     备注      : \(extra)") }
}

// MARK: - padding limit（找出「预留多少才不会被 TagLib 收缩」的真实边界）

/// 五步演示暴露出一个和事前假设**不一样**的事实：TagLib 并不是「填充 ≤ 1 MB 就保留」，
/// 而是每次保存都会重算一遍填充，超过某个「理想值」就直接砸回 4096 并整文件重写。
/// 这个子命令用扫描法把那条线量出来：
///
///   对每个候选预留量 T：
///     pristine 副本 → 嵌入封面（必然重写，填充落到 TagLib 的默认值）
///     → 扩填充到 T → 再存一次同样大小的封面
///     → 看音频起点动没动、填充剩多少
///
/// 音频起点没动 = 原地改写 = 这个 T 是安全的。
func cmdPaddingLimit(_ flacPath: String, _ imagePath: String, args: [String]) {
    let source = URL(fileURLWithPath: flacPath)
    hr("预留上限扫描 \(source.lastPathComponent)")

    guard let big = try? Data(contentsOf: URL(fileURLWithPath: imagePath)), !big.isEmpty else {
        print("  读不到图片：\(imagePath)"); return
    }
    var coverKB = 300
    if let i = args.firstIndex(of: "--cover-kb"), i + 1 < args.count, let n = Int(args[i + 1]) { coverKB = n }
    guard let cover = try? ArtworkProcessor.limit(big, maxBytes: coverKB * 1024) else {
        print("  压不出 \(coverKB) KB 封面"); return
    }

    var targets = [128, 256, 384, 448, 480, 512, 640, 768, 960].map { $0 * 1024 }
    if let i = args.firstIndex(of: "--targets"), i + 1 < args.count {
        targets = args[i + 1].split(separator: ",").compactMap { Int($0).map { $0 * 1024 } }
    }

    let baseSize = (try? FileManager.default.attributesOfItem(atPath: source.path))?[.size] as? Int64 ?? 0
    print("  源文件      : \(padMB(baseSize))    封面 \(padKB(Int64(cover.count)))")
    print("  假设        : TagLib 保留剩余填充的上限 ≈ min(文件长度 / 100, 1 MB)"
          + " → 本例约 \(padKB(baseSize / 100))")
    print()
    print("  " + intlPad("预留量", 12) + intlPad("保存后填充", 14)
          + intlPad("音频起点", 22) + intlPad("耗时", 10) + "结论")
    print("  " + String(repeating: "-", count: 84))

    let work = source.deletingLastPathComponent()
        .appendingPathComponent("padlimit-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }

    // -1 是哨兵：跑一遍 `recommendedTarget(...)` 实际给出的值，验证出厂公式站得住。
    for target in targets + [-1] {
        let label = target < 0 ? "推荐值" : padKB(Int64(target))
        // 扩展名必须跟源文件一致 —— TagLib 是按扩展名认容器的。
        let copy = work.appendingPathComponent("t\(abs(target))." + source.pathExtension)
        try? FileManager.default.removeItem(at: copy)
        guard (try? FileManager.default.copyItem(at: source, to: copy)) != nil else { continue }

        // ① 先把封面嵌进去（这一步必然重写，把文件带到「刚保存完」的状态）
        var seed = TagEdit()
        seed.artworkAction = .replace([padMakeArtwork(cover)])
        try? TagService.write(seed, to: copy)

        // ② 扩填充到候选值
        let actual = target < 0
            ? PaddingReserver.recommendedTarget(for: PaddingReserver.inspect(copy))
            : target
        do {
            _ = try PaddingReserver.reserve(copy, target: actual)
        } catch {
            print("  " + intlPad(label, 12) + "扩填充失败：\(error.localizedDescription)")
            try? FileManager.default.removeItem(at: copy)
            continue
        }

        // ③ 再存一次同样的封面 + 一个短标题：看是不是原地
        var again = TagEdit()
        again.artworkAction = .replace([padMakeArtwork(cover)])
        again.set(.title, "T\(target)")
        let s = padSave(copy, again, label: "limit")

        let inPlace = (s.before.audioOffset == s.after.audioOffset)
        print("  " + intlPad(target < 0 ? "推荐 \(padKB(Int64(actual)))" : label, 12)
              + intlPad(padKB(s.after.currentPadding), 14)
              + intlPad("\(s.before.audioOffset) → \(s.after.audioOffset)", 22)
              + intlPad(padMS(s.seconds), 10)
              + (inPlace ? "✔ 原地（预留保住了）" : "✘ 被收缩 + 整文件重写"))
        try? FileManager.default.removeItem(at: copy)
    }
    print()
    print("  读法：最后一个 ✔ 就是这个文件尺寸下的安全预留上限。")
}

// MARK: - padding onemove（两次搬动 → 一次：A/B 对照）
//
//    mactagger-probe padding onemove <dir> <大图> [--cover-kb N] [--legacy] [--new] [--keep]
//
//  验的是本轮那条改动：写封面时**先把 PADDING 扩到位、再让 TagLib 原地写**，
//  于是「TagLib 重写（搬动 1）+ 事后补填充（搬动 2）」并成一次。
//
//  两条流程各跑一份**独立副本**（同一批源文件），逐文件贴表对照：
//    · 搬动次数 —— 以 `BatchSummary.moveCounts` 为准，它是按「音频起点 / 文件大小
//      动没动」实测出来的，不是估的（`BatchEngine` 在写入路径里逐文件数的）；
//    · 耗时、写后 PADDING；
//    · 之后再改一次标题 / 换同尺寸封面 —— 应当 0 ms 原地；
//    · 最后换一张更小的封面 —— 预估应当提前报「收缩重写」。
//
//  `<dir>` 只读：所有文件先复制进临时工作目录，结束即删（`--keep` 保留）。

/// 一个文件在某一刻的可观测量。
struct OneShot {
    var url: URL
    var size: Int64
    var audioOffset: Int64
    var padding: Int64
    var name: String { url.lastPathComponent }
}

func oneSnapshot(_ url: URL) -> OneShot {
    let info = PaddingReserver.inspect(url)
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 ?? 0
    return OneShot(url: url, size: size, audioOffset: info.audioOffset, padding: info.currentPadding)
}

/// 并发回调里收集每个文件的完成时刻（`applyEdits` 只给总耗时）。并发度 1 时即为单文件耗时。
final class OneTimer: @unchecked Sendable {
    private let lock = NSLock()
    private var marks: [(path: String, at: Date)] = []
    let started = Date()

    func mark(_ path: String?) {
        guard let path else { return }
        lock.lock(); marks.append((path, Date())); lock.unlock()
    }

    func durations() -> [String: TimeInterval] {
        lock.lock(); defer { lock.unlock() }
        var out: [String: TimeInterval] = [:]
        var prev = started
        for m in marks { out[m.path] = m.at.timeIntervalSince(prev); prev = m.at }
        return out
    }
}

/// 同步跑一遍 `BatchEngine.applyEdits`（probe 是命令行，直接等）。**并发度 1**：
/// 要的是每个文件各自的耗时与搬动次数，并发会互相污染。
/// 节流器显式关掉 —— 这里量的是搬动次数与纯耗时，不该混进暂停时间。
func oneApply(_ payload: [(url: URL, edit: TagEdit)],
              padding: PaddingPolicy?) -> (BatchSummary, [String: TimeInterval]) {
    guard !payload.isEmpty else { return (BatchSummary(), [:]) }
    let timer = OneTimer()
    let sem = DispatchSemaphore(value: 0)
    var summary = BatchSummary()
    Task {
        let s = await BatchEngine.applyEdits(payload, concurrency: 1,
                                             pacing: .disabled, paddingPolicy: padding) { p in
            timer.mark(p.currentPath)
        }
        summary = s
        sem.signal()
    }
    sem.wait()
    return (summary, timer.durations())
}

/// 把源目录复制一份到临时工作区（子目录结构照搬）。**源目录只读。**
func oneStage(_ dir: URL, tag: String) -> (work: URL, files: [URL]) {
    let fm = FileManager.default
    let work = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mactagger-onemove-\(tag)-\(getpid())", isDirectory: true)
    try? fm.removeItem(at: work)
    try? fm.createDirectory(at: work, withIntermediateDirectories: true)

    var files: [URL] = []
    let exts = Set(["flac", "mp3", "m4a", "mp4", "ogg", "opus", "wav", "aiff"])
    let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey])
    while let u = e?.nextObject() as? URL {
        guard exts.contains(u.pathExtension.lowercased()) else { continue }
        let rel = u.path.replacingOccurrences(of: dir.path + "/", with: "")
        let dst = work.appendingPathComponent(rel)
        try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        // APFS 上 copyItem 走 clonefile（写时复制），几十 MB 也是瞬间。
        do { try fm.copyItem(at: u, to: dst); files.append(dst) }
        catch { print("  ! 复制失败 \(u.lastPathComponent)：\(error.localizedDescription)") }
    }
    return (work, files.sorted { $0.path < $1.path })
}

/// 压出「大约 target 字节」的一张图（走产品代码，按质量二分）。
func oneShrink(_ data: Data, target: Int) -> Data {
    var lo = 0.05, hi = 1.0, best = data
    for _ in 0..<12 {
        let q = (lo + hi) / 2
        guard let r = try? ArtworkProcessor.process(
            data, options: ArtworkProcessOptions(maxEdge: 0, format: .jpeg,
                                                 jpegQuality: q, maxBytes: 0)) else { break }
        // `best` 必须记「见过的最小的一张」而不是「第一个不超标的」——
        // 纯噪点大图在最低质量下也压不到目标，那时候要给出最小的那张，
        // 而不是原样退回原图（退回原图会让「换更小的封面」那一步根本没换）。
        if r.data.count < best.count { best = r.data }
        if r.data.count > target { hi = q } else { lo = q }
        if abs(r.data.count - target) < target / 20 { return r.data }
    }
    // 降质到底还差得远（纯噪点图就是这样）→ 让产品代码连缩边一起上。
    if best.count > target + target / 4,
       let r = try? ArtworkProcessor.process(
        data, options: ArtworkProcessOptions(maxEdge: 0, format: .jpeg,
                                             jpegQuality: 0.85, maxBytes: target)) {
        return r.data
    }
    return best
}

/// 逐步快照的诊断：把「写前扩填充 → TagLib 保存」拆开量，看搬动到底出在哪一步。
/// 走的是与 `BatchEngine` 完全相同的产品调用，只是在每一步之间插了只读 inspect。
func oneTrace(_ files: [URL], artwork: Data, preferred: Int) {
    print()
    print("  ── 逐步诊断（写前扩填充 → TagLib 保存，拆开量） " + String(repeating: "─", count: 14))
    for f in files {
        var edit = TagEdit()
        edit.artworkAction = .replace([padMakeArtwork(artwork)])
        let e = TagService.estimatedWriteCost(url: f, edit: edit)
        let s0 = oneSnapshot(f)
        let plan = PaddingReserver.planExpandBeforeWrite(fileBytes: s0.size,
                                                        currentPadding: s0.padding,
                                                        slackBytes: e.slackBytes,
                                                        requiredMetadataBytes: e.needBytes,
                                                        preferred: preferred)
        print("     \(f.lastPathComponent)")
        print("       起点      : 文件 \(s0.size)  PADDING \(s0.padding)  音频起点 \(s0.audioOffset)")
        print("       预估      : needBytes \(e.needBytes)  slackBytes \(e.slackBytes)"
              + "  fullRewrite \(e.fullRewrite)")
        guard plan.feasible else { print("       方案      : 合并不了 —— \(plan.reason)"); continue }
        print("       方案      : 扩到 \(plan.expandTo)（+\(plan.deltaBytes)）"
              + "，预期保存后剩余填充 \(plan.reserveAfterSave)"
              + "，TagLib 保留上限 \(plan.keepLimit)")
        do {
            _ = try PaddingReserver.expandBeforeWrite(url: f,
                                                      requiredMetadataBytes: e.needBytes,
                                                      slackBytes: e.slackBytes,
                                                      target: preferred)
        } catch let skip as PaddingReserver.HardLinkSkipped {
            // BP-I：硬链接从「静默 nil」改为抛跳过。语义不变 —— 不预留，照常往下写标签。
            print("       扩填充    : 跳过 \(skip.localizedDescription)")
        } catch {
            print("       扩填充    : 失败 \(error.localizedDescription)"); continue
        }
        let s1 = oneSnapshot(f)
        print("       扩填充后  : 文件 \(s1.size)  PADDING \(s1.padding)  音频起点 \(s1.audioOffset)")
        let t0 = Date()
        do { try TagService.write(edit, to: f) } catch { print("       写入失败：\(error)"); continue }
        let ms = Date().timeIntervalSince(t0)
        let s2 = oneSnapshot(f)
        let moved = (s1.audioOffset != s2.audioOffset) || (s1.size != s2.size)
        print("       保存后    : 文件 \(s2.size)（Δ\(s2.size - s1.size)）"
              + "  PADDING \(s2.padding)（预期 \(plan.reserveAfterSave)，差 \(s2.padding - Int64(plan.reserveAfterSave))）"
              + "  音频起点 \(s2.audioOffset)（Δ\(s2.audioOffset - s1.audioOffset)）")
        print("       判定      : " + (moved ? "✘ TagLib 仍然搬了一次" : "✔ 原地")
              + "   耗时 \(padMS(ms))")
    }
}

/// 压出一张**明显更小**的封面：先缩边再降质。
///
/// 只降质是不够的 —— 纯噪点大图在最低 JPEG 质量下也压不下去（实测 4 MB 的噪点图
/// 压到底仍有 1.6 MB），于是「换更小的封面」那一步根本没换成，验证不到收缩重写。
func oneSmallCover(_ data: Data, maxEdge: Int = 400, quality: Double = 0.6) -> Data {
    guard let r = try? ArtworkProcessor.process(
        data, options: ArtworkProcessOptions(maxEdge: maxEdge, format: .jpeg,
                                             jpegQuality: quality, maxBytes: 0)) else { return data }
    return r.data
}

/// 同尺寸不同内容的一张图（验「换封面」而不是「换大小」）。
func oneVariant(of data: Data) -> Data {
    var d = data
    guard d.count > 4096 else { return d }
    let start = d.count / 2
    for i in start..<min(start + 2048, d.count) { d[i] = UInt8.random(in: 0...255) }
    return d
}

/// 跑一整轮「写封面」，把逐文件的实测量贴成表，返回（总耗时, 总搬动次数, 摘要）。
@discardableResult
func oneRound(_ title: String,
              files: [URL],
              artwork: Data,
              padding: PaddingPolicy?,
              showPlan: Bool = true) -> (seconds: TimeInterval, moves: Int, summary: BatchSummary) {
    print()
    print("  ── \(title) " + String(repeating: "─", count: max(4, 56 - title.count)))

    var payload: [(url: URL, edit: TagEdit)] = []
    for f in files {
        var e = TagEdit()
        e.artworkAction = .replace([padMakeArtwork(artwork)])
        payload.append((f, e))
    }

    if showPlan {
        let plan = TagService.estimatedWriteCost(payload, padding: padding)
        print("     预估      : 重写 \(plan.fullRewriteCount) 个"
              + "，收缩重写 \(plan.shrinkCount) 个"
              + "，预留 \(plan.reserveCount) 个（合并 \(plan.mergedReserveCount) / 另搬 \(plan.reserveExtraMoveCount)）")
        print("     确认框文案: " + (plan.warningText ?? "（无整文件重写，不提示）"))
    }

    let before = files.map(oneSnapshot)
    let (summary, durations) = oneApply(payload, padding: padding)
    let after = files.map(oneSnapshot)
    let moveByPath = Dictionary(uniqueKeysWithValues: summary.moveCounts.map { ($0.url.path, $0.moves) })

    print("     " + intlPad("文件", 20) + intlPad("大小 前→后", 24)
          + intlPad("搬动", 6) + intlPad("耗时", 10)
          + intlPad("音频起点 前→后", 26) + "写后 PADDING")
    print("     " + String(repeating: "-", count: 100))
    var moves = 0
    for (b, a) in zip(before, after) {
        // 兜底口径：没开预留策略时 BatchEngine 不数搬动，这里按快照自己判一次。
        let m = moveByPath[a.url.path] ?? ((b.audioOffset != a.audioOffset || b.size != a.size) ? 1 : 0)
        moves += m
        print("     " + intlPad(b.name, 20)
              + intlPad("\(padMB(b.size)) → \(padMB(a.size))", 24)
              + intlPad("\(m) 次", 6)
              + intlPad(padMS(durations[a.url.path] ?? 0), 10)
              + intlPad("\(b.audioOffset) → \(a.audioOffset)", 26)
              + padKB(a.padding))
    }
    print("     " + String(repeating: "-", count: 100))
    print("     合计      : \(summary.description)"
          + "  搬动 \(moves) 次  耗时 \(padMS(summary.elapsed))")
    if let n = summary.reserveNote { print("     \(n)") }
    for f in summary.reserveSkips { print("     · 预留跳过 \(f.url.lastPathComponent)：\(f.message)") }
    for f in summary.reserveFailures { print("     ! 预留失败 \(f.url.lastPathComponent)：\(f.message)") }
    return (summary.elapsed, moves, summary)
}

/// 复验一步：应当 0 ms 原地。
func oneVerifyInPlace(_ title: String, files: [URL], edits: [URL: TagEdit], padding: PaddingPolicy?) {
    print()
    print("  ── \(title) " + String(repeating: "─", count: max(4, 56 - title.count)))
    let payload = files.compactMap { u in edits[u].map { (url: u, edit: $0) } }
    let before = files.map(oneSnapshot)
    let (_, durations) = oneApply(payload, padding: padding)
    let after = files.map(oneSnapshot)
    var allInPlace = true
    print("     " + intlPad("文件", 20) + intlPad("大小变化", 14)
          + intlPad("音频起点", 24) + intlPad("耗时", 10) + "判定")
    for (b, a) in zip(before, after) {
        let inPlace = (b.audioOffset == a.audioOffset) && (b.size == a.size)
        if !inPlace { allInPlace = false }
        print("     " + intlPad(b.name, 20)
              + intlPad(b.size == a.size ? "不变" : "\(a.size - b.size)", 14)
              + intlPad(b.audioOffset == a.audioOffset ? "没挪 \(a.audioOffset)" : "\(b.audioOffset) → \(a.audioOffset)", 24)
              + intlPad(padMS(durations[a.url.path] ?? 0), 10)
              + (inPlace ? "✔ 原地" : "✘ 整文件重写"))
    }
    print("     结论      : " + (allInPlace ? "✔ 全部原地改写" : "✘ 有文件被重写"))
}

func cmdPaddingOneMove(_ dirPath: String, _ imagePath: String, args: [String]) {
    let dir = URL(fileURLWithPath: dirPath, isDirectory: true)
    hr("合并搬动对照（写前扩填充 vs 旧两段流程）")

    guard let big = try? Data(contentsOf: URL(fileURLWithPath: imagePath)), !big.isEmpty else {
        print("  读不到图片：\(imagePath)"); return
    }
    var coverKB = 1536
    if let i = args.firstIndex(of: "--cover-kb"), i + 1 < args.count, let n = Int(args[i + 1]) { coverKB = n }
    let cover = big.count > coverKB * 1024 ? oneShrink(big, target: coverKB * 1024) : big
    let sameSize = oneVariant(of: cover)
    let smaller = oneSmallCover(cover)

    let keep = args.contains("--keep")
    let runLegacy = !args.contains("--new")
    let runNew = !args.contains("--legacy")
    let preferred = PaddingReserver.defaultReserveBytes

    print("  素材        : 封面 \(padKB(Int64(cover.count)))"
          + "，同尺寸变体 \(padKB(Int64(sameSize.count)))"
          + "，小封面 \(padKB(Int64(smaller.count)))")
    print("  设置        : 预留意愿 \(padKB(Int64(preferred)))，并发 1，节流器关闭")
    print("  搬动口径    : BatchEngine 逐文件实测（音频起点 / 文件大小动没动），不是预估")
    print("  注意        : 耗时跑在内建 SSD 上；TF 卡的整文件重写要慢一到两个数量级，")
    print("                所以**看次数**，绝对值只作参考。")

    var legacySeconds: TimeInterval = 0, legacyMoves = 0
    var newSeconds: TimeInterval = 0, newMoves = 0
    var works: [URL] = []
    defer {
        for w in works {
            if keep { print("\n  工作目录已保留：\(w.path)") }
            else { try? FileManager.default.removeItem(at: w) }
        }
        if !keep { print("\n  已删除临时工作目录。") }
    }

    // ---------------------------------------------------------------- 旧流程
    if runLegacy {
        let (work, files) = oneStage(dir, tag: "legacy")
        works.append(work)
        guard !files.isEmpty else { print("  目录里没有可用的音频文件"); return }
        let policy = PaddingPolicy(enabled: true, preferredBytes: preferred, mergeWithWrite: false)
        let r = oneRound("旧流程：TagLib 重写 → 事后补填充（--legacy）",
                         files: files, artwork: cover, padding: policy)
        legacySeconds = r.seconds; legacyMoves = r.moves
    }

    // ---------------------------------------------------------------- 逐步诊断
    if args.contains("--trace") {
        let (work, files) = oneStage(dir, tag: "trace")
        works.append(work)
        oneTrace(files, artwork: cover, preferred: preferred)
    }

    // ---------------------------------------------------------------- 新流程
    if runNew {
        let (work, files) = oneStage(dir, tag: "new")
        works.append(work)
        guard !files.isEmpty else { print("  目录里没有可用的音频文件"); return }
        let policy = PaddingPolicy(enabled: true, preferredBytes: preferred, mergeWithWrite: true)
        let r = oneRound("新流程：写前扩填充 → TagLib 原地写",
                         files: files, artwork: cover, padding: policy)
        newSeconds = r.seconds; newMoves = r.moves

        // 复验①：只改标题 —— 预留生效的话应当 0 ms 原地。
        var titleEdits: [URL: TagEdit] = [:]
        for (n, f) in files.enumerated() {
            var e = TagEdit()
            e.set(.title, "合并搬动验证 \(n)-\(Int(Date().timeIntervalSince1970))")
            titleEdits[f] = e
        }
        oneVerifyInPlace("复验①：只改标题 → 应当 0 ms 原地", files: files, edits: titleEdits, padding: policy)

        // 复验②：换同尺寸封面 —— 同样应当原地。
        var sameEdits: [URL: TagEdit] = [:]
        for f in files {
            var e = TagEdit()
            e.artworkAction = .replace([padMakeArtwork(sameSize)])
            sameEdits[f] = e
        }
        oneVerifyInPlace("复验②：换同尺寸封面 → 应当原地", files: files, edits: sameEdits, padding: policy)

        // 复验③：换更小的封面 —— 剩余填充会越过 1% 线，预估要提前报「收缩重写」。
        oneRound("复验③：换更小的封面（\(padKB(Int64(smaller.count)))）→ 预估应提前报收缩重写",
                 files: files, artwork: smaller, padding: policy)
    }

    // ---------------------------------------------------------------- 对照
    if runLegacy && runNew {
        print()
        print("  ── 对照 " + String(repeating: "─", count: 51))
        print("     " + intlPad("流程", 34) + intlPad("搬动次数", 12) + "耗时")
        print("     " + intlPad("旧（TagLib 重写 + 事后补填充）", 34)
              + intlPad("\(legacyMoves) 次", 12) + padMS(legacySeconds))
        print("     " + intlPad("新（写前扩填充 + 原地写）", 34)
              + intlPad("\(newMoves) 次", 12) + padMS(newSeconds))
        let ratio = legacySeconds > 0 ? newSeconds / legacySeconds : 0
        print("     搬动次数 \(legacyMoves) → \(newMoves)"
              + String(format: "，耗时比 %.2f（1.00 = 没变，0.50 = 减半）", ratio))
    }
}

// MARK: - padding identity（BP-G：扩填充不丢文件身份）

//
//  「临时文件 + rename」式扩填充会换掉 inode。本探针验证换完之后文件身上挂的东西都还在：
//    ① Finder 颜色标签（`_kMDItemUserTags` + `FinderInfo`，用 URLResourceValues 读回「红色」/ 颜色号 6）
//    ② 自定义扩展属性（逐项十六进制对比，除内核维护的 com.apple.provenance）
//    ③ ACL、创建日期、权限位
//    ④ 硬链接副本：扩填充**跳过**并注明「硬链接文件已跳过预留」，inode / 链接数 / 两个名字内容都不变
//    ⑤ 符号链接：扩的是链接指向的文件，链接本身仍是链接
//    ⑥ 真实保存路径（BatchEngine.applyEdits + 预留策略 + 换一张更大的封面）：同样不丢标签、不拆链接；
//       统计行把硬链接记为「跳过 1（硬链接）」而不是失败，详单保留原话（BP-H）
//  全部在 NSTemporaryDirectory 下的副本上做，传入的文件只读。
//

/// 除 provenance 外的全部扩展属性：名字 → 十六进制。与产品代码的暂存实现互相独立。
func padXattrs(_ path: String) -> [String: String] {
    var out: [String: String] = [:]
    let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
    guard size > 0 else { return out }
    var buf = [CChar](repeating: 0, count: size)
    guard listxattr(path, &buf, size, XATTR_NOFOLLOW) > 0 else { return out }
    for raw in buf.split(separator: 0) {
        let name = String(decoding: raw.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        if name == "com.apple.provenance" { continue }
        let n = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard n >= 0 else { continue }
        var v = [UInt8](repeating: 0, count: max(n, 1))
        let r = n == 0 ? 0 : getxattr(path, name, &v, n, 0, XATTR_NOFOLLOW)
        out[name] = v.prefix(max(0, r)).map { String(format: "%02X", $0) }.joined()
    }
    return out
}

func padACLText(_ path: String) -> String {
    guard let a = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return "（无）" }
    defer { acl_free(UnsafeMutableRawPointer(a)) }
    var len = 0
    guard let t = acl_to_text(a, &len) else { return "（无）" }
    defer { acl_free(UnsafeMutableRawPointer(t)) }
    let s = String(cString: t).split(separator: "\n").dropFirst().joined(separator: " | ")
    return s.isEmpty ? "（无）" : s
}

func padStat(_ path: String) -> (ino: UInt64, links: Int, mode: UInt16)? {
    var st = stat()
    guard stat(path, &st) == 0 else { return nil }
    return (st.st_ino, Int(st.st_nlink), st.st_mode & 0o7777)
}

struct PadIdentity: Equatable {
    var xattrs: [String: String]
    var tags: [String]
    var label: Int
    var acl: String
    var created: Date?
    var mode: UInt16

    static func of(_ url: URL) -> PadIdentity {
        var u = url
        u.removeAllCachedResourceValues()
        let rv = try? u.resourceValues(forKeys: [.tagNamesKey, .labelNumberKey, .creationDateKey])
        return PadIdentity(xattrs: padXattrs(url.path),
                           tags: rv?.tagNames ?? [],
                           label: rv?.labelNumber ?? 0,
                           acl: padACLText(url.path),
                           created: rv?.creationDate,
                           mode: padStat(url.path)?.mode ?? 0)
    }

    var summary: String {
        "标签=\(tags) 颜色号=\(label) xattr=\(xattrs.keys.sorted().joined(separator: ","))"
            + " ACL=\(acl) 创建=\(created.map { "\($0)" } ?? "-") 权限=\(String(mode, radix: 8))"
    }
}

/// 给副本打上「用户在 Finder 里会有的那些东西」：红色标签、自定义 xattr、一条 ACL、旧的创建日期、640 权限。
func padDecorate(_ url: URL) {
    // tagNames 的 Swift setter 要 macOS 26，走 NSURL 的老接口（14.4 起可用）。
    do {
        try (url as NSURL).setResourceValue(["红色"], forKey: .tagNamesKey)
        try (url as NSURL).setResourceValue(6, forKey: .labelNumberKey)
        try (url as NSURL).setResourceValue(Date(timeIntervalSince1970: 1_577_934_245),   // 2020-01-02
                                            forKey: .creationDateKey)
    } catch { print("  ! 打标签失败：\(error.localizedDescription)") }
    let v = Array("keepme-BP-G".utf8)
    _ = v.withUnsafeBytes { setxattr(url.path, "com.lingluan.bpg.test", $0.baseAddress, v.count, 0, XATTR_NOFOLLOW) }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/chmod")
    p.arguments = ["+a", "everyone allow readextattr", url.path]
    try? p.run(); p.waitUntilExit()
    chmod(url.path, 0o640)
}

/// 合成一张约 N KB 的噪点 JPEG（写封面用；比文件头现有填充大得多，必然触发整文件重写）。
func padNoiseJPEG(edge: Int = 520) -> Data {
    var px = [UInt8](repeating: 0, count: edge * edge * 4)
    arc4random_buf(&px, px.count)
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: &px, width: edge, height: edge, bitsPerComponent: 8, bytesPerRow: edge * 4,
                              space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
          let img = ctx.makeImage() else { return Data() }
    let out = NSMutableData()
    guard let dst = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return Data() }
    CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
    CGImageDestinationFinalize(dst)
    return out as Data
}

func cmdPaddingIdentity(_ paths: [String]) {
    hr("扩填充不丢文件身份（padding identity，BP-G）")
    let fm = FileManager.default
    let work = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mactagger-identity-\(getpid())", isDirectory: true)
    try? fm.removeItem(at: work)
    try? fm.createDirectory(at: work, withIntermediateDirectories: true)
    print("  工作区 : \(work.path)（全部副本，传入文件只读）")
    var verdicts: [(String, Bool)] = []
    func verdict(_ n: String, _ ok: Bool) { verdicts.append((n, ok)); print("   判定 \(n): \(ok ? "✔ 通过" : "✘ 未通过")") }
    func copy(_ src: URL, _ name: String) -> URL? {
        let dst = work.appendingPathComponent(name)
        do { try fm.copyItem(at: src, to: dst); return dst }
        catch { print("  ! 复制失败：\(error.localizedDescription)"); return nil }
    }
    let cover = padNoiseJPEG()
    print("  合成封面 : \(padKB(Int64(cover.count)))")

    for path in paths {
        let src = URL(fileURLWithPath: path)
        let ext = src.pathExtension.lowercased()
        guard PaddingReserver.canReserve(src) else { print("  跳过 \(src.lastPathComponent)：格式不支持扩填充"); continue }
        print()
        print("  ── \(src.lastPathComponent) ─────────────────────────────")

        // ①②③ 直接扩填充：带标签副本
        if let f = copy(src, "tagged.\(ext)") {
            padDecorate(f)
            let before = PadIdentity.of(f)
            let ino0 = padStat(f.path)?.ino ?? 0
            print("   改前 \(before.summary)")
            do {
                let r = try PaddingReserver.reserve(f, target: 65_536)
                print("   扩填充 : \(r.changed ? "已改写" : "未改动") \(r.paddingBefore) → \(r.paddingAfter) 字节；\(r.note)")
            } catch { print("   扩填充失败：\(error.localizedDescription)") }
            let after = PadIdentity.of(f)
            let ino1 = padStat(f.path)?.ino ?? 0
            print("   改后 \(after.summary)  inode \(ino0)→\(ino1)（整文件替换，换 inode 属预期）")
            verdict("[\(ext)] ① Finder 红色标签仍在（tagNames=[红色]、颜色号 6）",
                    after.tags == ["红色"] && after.label == 6)
            verdict("[\(ext)] ② 扩展属性逐项一致（\(before.xattrs.count) 项，含 FinderInfo / _kMDItemUserTags / 自定义）",
                    !before.xattrs.isEmpty && before.xattrs == after.xattrs)
            verdict("[\(ext)] ③ ACL / 创建日期 / 权限位一致", before.acl == after.acl
                    && before.created == after.created && before.mode == after.mode)
        }

        // ④ 硬链接：跳过
        if let h = copy(src, "hl.\(ext)") {
            let link = work.appendingPathComponent("hl-link.\(ext)")
            try? fm.linkItem(at: h, to: link)
            let s0 = padStat(h.path)
            let data0 = try? Data(contentsOf: h)
            var msg = "（未抛错）"
            do { let r = try PaddingReserver.reserve(h, target: 65_536); msg = "未跳过！changed=\(r.changed)" }
            catch { msg = error.localizedDescription }
            let s1 = padStat(h.path)
            print("   硬链接 : ino \(s0?.ino ?? 0)→\(s1?.ino ?? 0) 链接数 \(s0?.links ?? 0)→\(s1?.links ?? 0)；\(msg)")
            let same = (try? Data(contentsOf: link)) == (try? Data(contentsOf: h))
            verdict("[\(ext)] ④ 硬链接跳过预留并注明、inode 与链接数不变、文件一字节未动",
                    msg.contains("硬链接文件已跳过预留") && s0?.ino == s1?.ino && s1?.links == 2
                    && same && data0 == (try? Data(contentsOf: h)))
        }

        // ⑤ 符号链接：扩的是目标
        if let t = copy(src, "sym-target.\(ext)") {
            let sym = work.appendingPathComponent("sym.\(ext)")
            try? fm.createSymbolicLink(at: sym, withDestinationURL: t)
            let size0 = padStat(t.path).map { _ in (try? fm.attributesOfItem(atPath: t.path)[.size] as? Int) ?? 0 } ?? 0
            _ = try? PaddingReserver.reserve(sym, target: 65_536)
            let isLink = (try? fm.destinationOfSymbolicLink(atPath: sym.path)) != nil
            let size1 = (try? fm.attributesOfItem(atPath: t.path)[.size] as? Int) ?? 0
            print("   符号链接 : 仍是链接=\(isLink)  目标大小 \(size0) → \(size1)")
            verdict("[\(ext)] ⑤ 经符号链接扩填充：链接仍是链接、目标文件被扩", isLink && size1 > size0)
        }

        // ⑥ 真实保存路径：BatchEngine + 预留策略 + 更大的封面
        var edit = TagEdit()
        edit.artworkAction = .replace([padMakeArtwork(cover)])
        let policy = PaddingPolicy(enabled: true, preferredBytes: PaddingReserver.defaultReserveBytes,
                                   preserveModificationDate: true)
        if let f = copy(src, "batch-tagged.\(ext)"), let h = copy(src, "batch-hl.\(ext)") {
            padDecorate(f)
            let link = work.appendingPathComponent("batch-hl-link.\(ext)")
            try? fm.linkItem(at: h, to: link)
            let before = PadIdentity.of(f)
            let hs0 = padStat(h.path)
            let (summary, _) = oneApply([(f, edit), (h, edit)], padding: policy)
            let after = PadIdentity.of(f)
            let hs1 = padStat(h.path)
            print("   保存 : \(summary.description)")
            if let n = summary.reserveNote { print("   \(n)") }
            for x in summary.reserveSkips { print("   · 预留跳过 \(x.url.lastPathComponent)：\(x.message)") }
            for x in summary.reserveFailures { print("   ! 预留失败 \(x.url.lastPathComponent)：\(x.message)") }
            let pad = PaddingReserver.inspect(f)
            print("   带标签副本保存后 : 填充 \(padKB(pad.currentPadding))  \(after.summary)")
            let artOK = ((try? TagService.read(link))?.tags.artworks.first?.data.count ?? 0) == cover.count
            print("   硬链接副本 : ino \(hs0?.ino ?? 0)→\(hs1?.ino ?? 0) 链接数 \(hs1?.links ?? 0)；经另一个名字读到新封面=\(artOK)")
            verdict("[\(ext)] ⑥a 保存（换大封面）后 Finder 标签 / xattr / ACL / 创建日期 仍在",
                    summary.failed == 0 && after.tags == ["红色"] && after.label == 6
                    && after.xattrs == before.xattrs && after.acl == before.acl && after.created == before.created)
            verdict("[\(ext)] ⑥b 保存后硬链接未拆（inode 不变、链接数 2、另一个名字也是新封面）",
                    hs0?.ino == hs1?.ino && hs1?.links == 2 && artOK)
            let note = summary.reserveNote ?? ""
            // 同内容的普通副本 f 真的预留了 → 硬链接副本 h 应计「跳过 1」；
            // f 也没预留（文件太小：TagLib 重写后的默认填充已超过这个尺寸能保住的上限）→
            // 两者本来都不预留，h 不该凭空多出一条「跳过」，只要求不计失败。
            let fReserved = summary.reserves.contains { $0.url.lastPathComponent == f.lastPathComponent }
            if fReserved {
                verdict("[\(ext)] ⑥c 统计行：硬链接计为「跳过 1（硬链接）」、不计失败；详单保留原话",
                        note.contains("跳过 1（硬链接）") && !note.contains("失败")
                        && summary.reserveSkips.count == 1 && summary.reserveFailures.isEmpty
                        && summary.reserveSkips.first?.url.lastPathComponent == h.lastPathComponent
                        && summary.reserveSkips.first?.message.contains("硬链接文件已跳过预留") == true)
            } else {
                verdict("[\(ext)] ⑥c 统计行：本尺寸不预留（普通副本也未预留），硬链接不计跳过、不计失败",
                        summary.reserveSkips.isEmpty && summary.reserveFailures.isEmpty && !note.contains("失败"))
            }
        }
    }
    try? fm.removeItem(at: work)
    print()
    let passed = verdicts.filter(\.1).count
    print("  汇总：\(passed)/\(verdicts.count) 通过" + (passed == verdicts.count ? " ✔" : " ✘"))
    if passed != verdicts.count || verdicts.isEmpty { exit(1) }
}
