//
//  TagService.swift
//  MacTagger — Swift 侧的 TagLib 门面
//
//  职责：把 Objective-C++ 桥接层的 NSError / NSObject 模型翻译成 Swift 值类型与
//  throwing API。上层（SwiftUI、CLI、批处理）只依赖这一层。
//

import Foundation

/// 老旧中文标签的兼容读取策略。
public enum LegacyTextEncoding: Int, CaseIterable, Sendable {
    case strict = 0
    case gb18030 = 1
    case big5 = 2
    case shiftJIS = 3
    case utf8 = 4
    case autoDetect = 100

    public var localizedName: String {
        switch self {
        case .strict: return "按规范（Latin-1）"
        case .gb18030: return "简体中文 GB18030 / GBK"
        case .big5: return "繁体中文 Big5"
        case .shiftJIS: return "日文 Shift-JIS"
        case .utf8: return "UTF-8"
        case .autoDetect: return "自动识别（未实现，暂等同规范）"
        }
    }
}

public enum TagService {

    // MARK: 环境

    public static var taglibVersion: String { MTTagLibBridge.taglibVersion }

    /// TagLib 声明支持的全部扩展名。
    public static var supportedExtensions: [String] { MTTagLibBridge.supportedFileExtensions }

    public static func isSupported(url: URL) -> Bool {
        MTTagLibBridge.isExtensionSupported(url.pathExtension)
    }

    /// 老旧中文标签兼容策略（全局）。
    public static var legacyEncoding: LegacyTextEncoding {
        get { LegacyTextEncoding(rawValue: MTTagLibBridge.legacyEncoding.rawValue) ?? .strict }
        set { MTTagLibBridge.legacyEncoding = MTLegacyEncoding(rawValue: newValue.rawValue) ?? .strict }
    }

    // MARK: 读

    public static func read(_ url: URL) throws -> AudioFile {
        do {
            let info = try MTTagLibBridge.readFile(atPath: url.path)
            return convert(info, url: url)
        } catch {
            throw translate(error as NSError, fallback: "读取失败")
        }
    }

    /// 批量读取，单个文件失败不影响其余；返回成功项与失败项。
    public static func readAll(_ urls: [URL]) -> (files: [AudioFile], failures: [(URL, TagError)]) {
        var files: [AudioFile] = []
        var failures: [(URL, TagError)] = []
        for url in urls {
            do { files.append(try read(url)) }
            catch let e as TagError { failures.append((url, e)) }
            catch { failures.append((url, .unknown(error.localizedDescription))) }
        }
        return (files, failures)
    }

    public static func readTechnicalInfo(_ url: URL) throws -> AudioTechnicalInfo {
        do {
            return convert(try MTTagLibBridge.readAudioProperties(atPath: url.path))
        } catch {
            throw translate(error as NSError, fallback: "读取技术参数失败")
        }
    }

    public static func readArtworks(_ url: URL) throws -> [Artwork] {
        do {
            return try MTTagLibBridge.readArtworks(atPath: url.path).map(convert)
        } catch {
            throw translate(error as NSError, fallback: "读取封面失败")
        }
    }

    // MARK: 写

    @discardableResult
    public static func write(_ edit: TagEdit, to url: URL) throws -> WriteOutcome {
        let objcEdit = MTTagEdit()
        for change in edit.changes {
            objcEdit.setValue(change.value, forField: change.field.rawValue)
        }
        for raw in edit.rawChanges {
            objcEdit.setRawValues(raw.values, forKey: raw.key)
        }
        switch edit.artworkAction {
        case .keep:
            objcEdit.artworkMode = .keep
        case .removeAll:
            objcEdit.artworkMode = .removeAll
        case .replace(let arts):
            objcEdit.artworkMode = .replace
            objcEdit.artworks = arts.map { art in
                MTArtwork(data: art.data,
                          mimeType: art.mimeType,
                          description: art.caption,
                          type: MTPictureType(rawValue: art.type.rawValue) ?? .frontCover)
            }
        }
        objcEdit.syncID3v1 = edit.syncID3v1

        let result = MTTagLibBridge.write(objcEdit, toFileAtPath: url.path)
        guard result.success else {
            throw translate(result.error as NSError?, fallback: "写入失败")
        }
        if !result.rejectedKeys.isEmpty {
            return WriteOutcome(
                isComplete: false,
                rejectedKeys: result.rejectedKeys,
                message: "写入成功，但该格式不支持这些字段：\(result.rejectedKeys.joined(separator: ", "))")
        }
        return WriteOutcome(isComplete: true)
    }

    public static func stripAllTags(_ url: URL) throws {
        do {
            try MTTagLibBridge.stripAllTags(atPath: url.path)
        } catch {
            throw translate(error as NSError, fallback: "清除标签失败")
        }
    }

    // MARK: 写入代价预估（只读）

    /// 单个文件的写入代价预估。
    public struct WriteCostEstimate: Sendable {
        public var url: URL
        /// 本次保存会不会触发「整文件重写」（标签区放不下，音频数据整体位移）。
        public var fullRewrite: Bool
        /// 该格式的判定是否可信。flac / mp3 / mp4 / m4a 做了结构解析，其余是保守估计。
        public var isConfident: Bool
        public var fileBytes: Int64
        /// 标签区里可原地复用的空闲字节（FLAC 的 PADDING、ID3v2 的空隙、MP4 的 free，
        /// 外加本次会被覆盖掉的旧封面所占空间）。
        public var slackBytes: Int64
        /// 本次负载实际需要的字节（含容器包头开销）。
        public var needBytes: Int64
        /// 会被**物理搬动**的字节数 —— 决定耗时的就是它，不是图片多大。
        public var rewriteBytes: Int64
        public var container: String
        public var note: String

        public var fileName: String { url.lastPathComponent }
    }

    /// 单个文件的**完整**代价：把估算里看不见的两条路径也算进来。
    ///
    /// `WriteCostEstimate` 只回答「新标签区塞不塞得进旧标签区」，但实际还有两次搬动它看不见：
    ///
    /// 1. **收缩重写**：塞得进、却把剩余填充撑过了 TagLib 的 `min(文件长度/100, 1 MB)` 线，
    ///    TagLib 会把填充砸回 4096 并整文件重写。**把大封面换成小封面就是这种情况**——
    ///    看着是「省空间」，实际触发一次几十 MB 的搬动。
    /// 2. **预留填充**：我们自己在「反正重写过」之后补的那一次（`PaddingReserver`）。
    ///
    /// 进度条权重与确认框文案都从这里取，两处口径因此永远一致。
    public struct WriteCostDetail: Sendable {
        public var estimate: WriteCostEstimate
        /// TagLib 会不会真的搬动整段音频（含上面第 1 条隐藏路径）。
        public var rewrites: Bool
        /// 属于第 1 条：剩余填充超线被收缩重写。
        public var shrinks: Bool
        /// 属于第 2 条：这次会给文件留下一段预留填充。
        public var reserves: Bool
        /// 一次搬动的音频字节。
        public var audioBytes: Int64

        /// 预留填充是不是**并进了这一次搬动**（写前扩填充，见
        /// `PaddingReserver.expandBeforeWrite`）。`reserves == true` 时才有意义：
        /// true = 一次搬动（扩填充搬一次，随后 TagLib 原地写）；
        /// false = 两次搬动（TagLib 先重写，我们再补一次）。
        public var mergesReserve: Bool = false

        /// 想合并却合并不了的原因（`reserves && !mergesReserve` 时给出），进确认框文案。
        public var mergeBlockedReason: String? = nil

        /// 本文件预计要发生几次「整段音频搬动」。进度权重与耗时预估都按它算。
        ///
        /// 0 = 原地改写；1 = 只搬一次（TagLib 自己重写，或写前扩填充后 TagLib 原地写）；
        /// 2 = 旧的两段流程（TagLib 重写 + 事后补填充），只在合并不了时才会出现。
        public var moveCount: Int {
            guard rewrites else { return 0 }
            return (reserves && !mergesReserve) ? 2 : 1
        }

        /// 本次**新写进标签区**的字节：封面 + 文本字段 + 容器包头（= `estimate.needBytes`），
        /// 外加预留填充时补的那一段。
        ///
        /// 早先的预估只算 `audioBytes`（搬动量），于是「6 个 48 KB 的文件写一张 1.5 MB 封面」
        /// 报「约 290 KB」，换成 15.8 MB 的图数字纹丝不动 —— 用户看到的预计耗时跟实际
        /// 差了两个数量级。封面本身是要**真写进磁盘**的字节，必须计入。
        public var newMetadataBytes: Int64 = 0

        /// 本文件预计被搬动的总字节 = 一次搬动的音频 × 实际搬动次数。
        ///
        /// **只算搬动**，不含新写入的元数据：这个值是 `BatchEngine` 的进度权重，
        /// 口径要跟历史实测吞吐（MB/s，按搬动量标定）保持一致。
        ///
        /// 本轮改动：预留填充并进同一次搬动后，这里不再无脑 ×2 —— 否则进度条会
        /// 在一半的地方走完、ETA 归零之后还在写（口径与实际差一倍）。
        public var totalMovedBytes: Int64 { audioBytes * Int64(moveCount) }

        /// 本文件预计**真正落盘**的总字节 = 搬动 + 新元数据。确认框与 ETA 用它。
        public var totalWrittenBytes: Int64 { totalMovedBytes + newMetadataBytes }

        public var url: URL { estimate.url }
    }

    /// 单个文件的完整代价。`padding` 传 nil 表示不做预留填充（旧行为）。
    public static func writeCostDetail(url: URL,
                                       edit: TagEdit,
                                       padding: PaddingPolicy? = nil) -> WriteCostDetail {
        let e = estimatedWriteCost(url: url, edit: edit)
        var detail = WriteCostDetail(estimate: e,
                                     rewrites: e.fullRewrite,
                                     shrinks: false,
                                     reserves: false,
                                     audioBytes: e.rewriteBytes,
                                     // `needBytes` 就是本次编辑要新写进标签区的字节：
                                     // 封面（.replace 的图片字节之和）+ 文本字段估算 + 容器包头，
                                     // 由 `estimatedWriteCost(url:edit:)` 把 payload 交给桥接层算出。
                                     // 不动封面也不改文本时它是 0（删封面同理，不写新数据）。
                                     newMetadataBytes: e.needBytes)

        // 只有做过结构解析、且我们扩得了填充的格式（FLAC / MP3）才谈得上这两条。
        guard e.isConfident, PaddingReserver.canReserve(url) else { return detail }

        if !e.fullRewrite {
            // 塞得进，但塞进去之后剩多少填充？= 可复用空间 − 本次占用。
            // （`slackBytes` 已经把「本次会被换掉的旧封面」算进可复用空间里了。）
            let remaining = e.slackBytes - e.needBytes
            let limit = min(e.fileBytes / Int64(PaddingReserver.taglibPaddingFileRatio),
                            Int64(PaddingReserver.taglibMaxPadding))
            if remaining > limit {
                detail.shrinks = true
                detail.rewrites = true
                // 估算在 !fullRewrite 时不给 rewriteBytes，这里只能自己量一次音频起点。
                let info = PaddingReserver.inspect(url)
                detail.audioBytes = info.isSupported
                    ? max(0, info.fileBytes - info.audioOffset)
                    : e.fileBytes
            }
        }

        if detail.rewrites, let p = padding, p.applies(to: url) {
            // ---- 能不能「先扩填充、再让 TagLib 原地写」，一次搬动收工？----
            //
            // 只有「塞不进 → 重写」这条路能合并。收缩重写（换小封面）要把填充**缩小**
            // 才能原地，而桥接层的扩填充只能往大里走，合并不了，仍是两次搬动。
            var plan = PaddingReserver.PreExpandPlan.no("换小封面触发的收缩重写需要缩小填充，合并不了")
            if p.mergeWithWrite, !detail.shrinks {
                let info = PaddingReserver.inspect(url)
                plan = PaddingReserver.planExpandBeforeWrite(
                    fileBytes: e.fileBytes,
                    currentPadding: info.isSupported ? info.currentPadding : 0,
                    slackBytes: e.slackBytes,
                    requiredMetadataBytes: e.needBytes,
                    preferred: p.preferredBytes)
            } else if !p.mergeWithWrite {
                plan = .no("已关闭写前扩填充（对照用）")
            }

            if plan.feasible {
                detail.reserves = true
                detail.mergesReserve = true
                // 扩填充写进去的零字节也是实打实落盘的字节。
                detail.newMetadataBytes += Int64(plan.deltaBytes)
            } else {
                // 退回旧流程：TagLib 重写之后填充一律被砸回 4096，
                // 所以只要目标值算出来还大于它，就会再搬一次去补。
                let target = PaddingReserver.recommendedTarget(fileBytes: e.fileBytes,
                                                               currentPadding: 4096,
                                                               preferred: p.preferredBytes)
                detail.reserves = target > 4096
                detail.mergesReserve = false
                if detail.reserves {
                    detail.newMetadataBytes += Int64(target)
                    detail.mergeBlockedReason = plan.reason
                }
            }
        }
        return detail
    }

    /// 一批文件的写入代价汇总。
    public struct WriteCostPlan: Sendable {
        public var items: [WriteCostEstimate] = []
        public var fullRewriteCount: Int = 0
        /// 整文件重写的那批文件预计**落盘**的总字节 = 搬动的音频 + 新写入的元数据。
        /// （历史上这里只有音频搬动量，写 15.8 MB 封面也报「约 290 KB」，见 AK 报告。）
        public var totalRewriteBytes: Int64 = 0
        /// 其中「搬动的音频」部分。确认框里的 X。
        public var totalAudioMoveBytes: Int64 = 0
        /// 其中「新写入的元数据」部分（封面 + 文本 + 包头 + 预留填充）。确认框里的 Y。
        public var totalNewMetadataBytes: Int64 = 0
        /// **不**触发整文件重写的那批文件新写入的元数据字节（原地写进现成的空闲位）。
        public var totalInPlaceBytes: Int64 = 0
        public var totalFileBytes: Int64 = 0
        /// 单张封面的最大负载（用来提示「开启自动限制」）。
        public var largestPayloadBytes: Int64 = 0
        /// 有没有拿不准的格式（文案里要说「约」）。
        public var hasUnconfident: Bool = false
        /// 按当前实测吞吐推算的秒数。
        public var estimatedSeconds: Double = 0
        /// 其中「因剩余填充超过 TagLib 的 1% 线而被收缩重写」的文件数（换小封面的典型后果）。
        public var shrinkCount: Int = 0
        /// 其中会留下预留填充的文件数。
        public var reserveCount: Int = 0
        /// 其中「预留并进了同一次搬动」（写前扩填充）的文件数。
        public var mergedReserveCount: Int = 0
        /// **额外**多搬的字节 —— 只统计合并不了、只能写完再补的那部分。
        /// 合并成功的文件在这里是 0（它们没有第二次搬动）。
        public var reserveBytes: Int64 = 0
        /// 合并不了的文件数（`reserveCount − mergedReserveCount`，单列出来方便文案）。
        public var reserveExtraMoveCount: Int = 0
        /// 合并不了的第一条原因（文案里如实标注一句）。
        public var mergeBlockedReason: String? = nil

        public var isEmpty: Bool { items.isEmpty }

        /// 「将重写 N 个文件（约 X GB），预计 Y 分钟」——没有整文件重写时返回 nil。
        ///
        /// 后面几句说的是用户在别处看不到、但会体感到的事：**换小封面会触发收缩重写**、
        /// **预留填充**。本轮把预留那句从「再搬一次」改成「同一次搬动内完成」——
        /// 流程已经变成「先扩填充 → TagLib 原地写」，说「再搬一次」就是骗人了；
        /// 确实合并不了的那几个（尺寸留不下、巨图顶到块长上限、换小封面）如实单列。
        public var warningText: String? {
            guard fullRewriteCount > 0 else { return nil }
            var s = "将整文件重写 \(fullRewriteCount) 个文件（搬动约 "
                + TagService.humanBytes(totalAudioMoveBytes)
                + "，写入新数据约 " + TagService.humanBytes(totalNewMetadataBytes) + "）"
            s += "，预计 \(TagService.humanDuration(estimatedSeconds))"
            if hasUnconfident { s += "（含无法精确判定的格式，实际可能更快）" }
            if shrinkCount > 0 {
                s += "。其中 \(shrinkCount) 个文件因填充超限将被收缩重写"
                    + "（换上的封面比原来的小，剩余填充超过 TagLib 的 1% 线）"
            }
            if mergedReserveCount > 0 {
                s += "。其中 \(mergedReserveCount) 个文件将顺带预留填充"
                    + "（同一次搬动内完成，不额外搬动），之后换封面就不必再重写"
            }
            if reserveExtraMoveCount > 0 {
                s += "。另有 \(reserveExtraMoveCount) 个文件的预留只能在重写之后补"
                    + "（再搬一次，约 " + TagService.humanBytes(reserveBytes) + "）"
                if let why = mergeBlockedReason { s += "：\(why)" }
            }
            return s
        }
    }

    /// 估算这次写入会不会让 TagLib 整文件重写。**只读**，只解析文件头部的标签区结构。
    ///
    /// 判据：TagLib 保存时渲染新标签区再 `insert(data, offset, oldLength)`；
    /// 新标签区不超过原标签区就原地覆盖，超出则把后面的音频数据整体后移。
    /// 所以「封面字节 > 当前可复用空间」是整文件重写的充分条件，
    /// 而耗时由 `rewriteBytes`（要搬动的字节）决定，与图片大小几乎无关。
    public static func estimatedWriteCost(url: URL, edit: TagEdit) -> WriteCostEstimate {
        var payload: Int64 = 0
        var reclaims = false
        switch edit.artworkAction {
        case .keep:
            break
        case .removeAll:
            reclaims = true
        case .replace(let arts):
            reclaims = true
            payload = arts.reduce(0) { $0 + Int64($1.data.count) }
        }
        // 文本字段：新值的字节数 + 每字段的帧/注释包头开销。这里**只加不减**
        // （旧值占的空间已经算在「固定占用」里），属于保守估计：宁可多报一次重写。
        var textBytes: Int64 = 0
        for c in edit.changes { textBytes += Int64((c.value ?? "").utf8.count) + 32 }
        for r in edit.rawChanges {
            textBytes += Int64((r.values ?? []).reduce(0) { $0 + $1.utf8.count }) + 32
        }
        if payload > 0 || textBytes > 0 { payload += textBytes }

        let d = MTTagLibBridge.estimateWriteCost(atPath: url.path,
                                                 payloadBytes: payload,
                                                 reclaimsArtwork: reclaims)
        func i64(_ k: String) -> Int64 { (d[k] as? NSNumber)?.int64Value ?? 0 }
        return WriteCostEstimate(url: url,
                                 fullRewrite: (d["fullRewrite"] as? NSNumber)?.boolValue ?? false,
                                 isConfident: (d["confident"] as? NSNumber)?.boolValue ?? false,
                                 fileBytes: i64("fileBytes"),
                                 slackBytes: i64("slackBytes"),
                                 needBytes: i64("needBytes"),
                                 rewriteBytes: i64("rewriteBytes"),
                                 container: (d["container"] as? String) ?? url.pathExtension,
                                 note: (d["note"] as? String) ?? "")
    }

    /// 批量预估。`throughput` 是「整文件重写」的字节/秒，默认取 `BatchEngine` 的实测值。
    /// `padding` 传入当前的预留填充策略时，汇总里会多出「会再搬一次」的那部分。
    public static func estimatedWriteCost(_ items: [(url: URL, edit: TagEdit)],
                                          throughput: Double? = nil,
                                          padding: PaddingPolicy? = nil) -> WriteCostPlan {
        var plan = WriteCostPlan()
        for it in items {
            let d = writeCostDetail(url: it.url, edit: it.edit, padding: padding)
            let e = d.estimate
            plan.items.append(e)
            plan.totalFileBytes += e.fileBytes
            if d.rewrites {
                plan.fullRewriteCount += 1
                // 搬动的音频 + 本次新写进去的元数据，两笔都要落盘，两笔都算进耗时。
                plan.totalAudioMoveBytes += d.audioBytes
                plan.totalNewMetadataBytes += d.newMetadataBytes
                plan.totalRewriteBytes += d.audioBytes + d.newMetadataBytes
            } else {
                // 原地写：音频一个字节不动，但新数据照样要写进标签区的空闲位。
                plan.totalInPlaceBytes += d.newMetadataBytes
            }
            if d.shrinks { plan.shrinkCount += 1 }
            if d.reserves {
                plan.reserveCount += 1
                if d.mergesReserve {
                    plan.mergedReserveCount += 1      // 并进同一次搬动，没有额外字节
                } else {
                    plan.reserveExtraMoveCount += 1
                    plan.reserveBytes += d.audioBytes // 只有它才是真的「再搬一次」
                    if plan.mergeBlockedReason == nil { plan.mergeBlockedReason = d.mergeBlockedReason }
                }
            }
            if !e.isConfident { plan.hasUnconfident = true }
            plan.largestPayloadBytes = max(plan.largestPayloadBytes, e.needBytes)
        }
        let bps = throughput ?? BatchEngine.rewriteThroughput(for: items.map(\.url))
        // 每个文件的固定开销（打开/解析/关闭），实测量级见性能报告。
        let fixed = 0.012 * Double(plan.items.count)
        // `totalRewriteBytes` 现在是「搬动 X + 新写入 Y」，预留填充再搬一次单列。
        // 写 15.8 MB 封面的那 Y 也要花时间，早先漏掉它就是「预估 3 秒、实测 40 秒」的来源。
        let moved = plan.totalRewriteBytes + plan.reserveBytes
        plan.estimatedSeconds = fixed + (bps > 0 ? Double(moved) / bps : 0)
        return plan
    }

    /// `1.4 GB` / `823 MB` / `2.0 MB`
    public static func humanBytes(_ b: Int64) -> String {
        let x = Double(b)
        if x >= 1_073_741_824 { return String(format: "%.1f GB", x / 1_073_741_824) }
        if x >= 1_048_576     { return String(format: "%.0f MB", x / 1_048_576) }
        if x >= 1024          { return String(format: "%.0f KB", x / 1024) }
        return "\(b) B"
    }

    /// `不到 1 秒` / `12 秒` / `2 分 30 秒`
    public static func humanDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "不到 1 秒" }
        if seconds < 1 { return "不到 1 秒" }
        if seconds < 60 { return "\(Int(seconds.rounded())) 秒" }
        let m = Int(seconds) / 60, s = Int(seconds) % 60
        return s == 0 ? "\(m) 分钟" : "\(m) 分 \(s) 秒"
    }

    // MARK: 能力探测

    public struct ProbeResult: Sendable {
        public var path: String
        public var canRead: Bool
        public var canWrite: Bool
        public var canWriteArtwork: Bool
        public var container: String
        public var codec: String
        public var durationMs: Int
        public var sampleRate: Int
        public var channels: Int
        public var bitrate: Int
        public var containersAfterWrite: [String]
        public var note: String
    }

    /// 对真实文件做读—写—复核活体探测（在临时副本上写，不动原文件）。
    public static func probe(_ url: URL) -> ProbeResult {
        let d = MTTagLibBridge.probeFile(atPath: url.path)
        return ProbeResult(
            path: (d["path"] as? String) ?? url.path,
            canRead: (d["canRead"] as? NSNumber)?.boolValue ?? false,
            canWrite: (d["canWrite"] as? NSNumber)?.boolValue ?? false,
            canWriteArtwork: (d["canWriteArtwork"] as? NSNumber)?.boolValue ?? false,
            container: (d["container"] as? String) ?? "",
            codec: (d["codec"] as? String) ?? "",
            durationMs: (d["durationMs"] as? NSNumber)?.intValue ?? 0,
            sampleRate: (d["sampleRate"] as? NSNumber)?.intValue ?? 0,
            channels: (d["channels"] as? NSNumber)?.intValue ?? 0,
            bitrate: (d["bitrate"] as? NSNumber)?.intValue ?? 0,
            containersAfterWrite: (d["containersAfterWrite"] as? [String]) ?? [],
            note: (d["note"] as? String) ?? ""
        )
    }

    public static func tagContainerHint(forExtension ext: String) -> String {
        MTTagLibBridge.capability(forExtension: ext).tagContainer
    }

    // MARK: - 转换

    private static func convert(_ info: MTAudioFileInfo, url: URL) -> AudioFile {
        AudioFile(url: url,
                  tags: convert(info.tags),
                  technical: convert(info.audioProperties),
                  tagContainers: info.tagContainers,
                  isReadOnly: info.isReadOnly,
                  diagnostics: info.diagnostics)
    }

    private static func convert(_ t: MTTags) -> Tags {
        Tags(title: t.title,
             artist: t.artist,
             albumArtist: t.albumArtist,
             album: t.album,
             year: t.year,
             trackNumber: t.trackNumber?.intValue,
             trackTotal: t.trackTotal?.intValue,
             discNumber: t.discNumber?.intValue,
             discTotal: t.discTotal?.intValue,
             genre: t.genre,
             comment: t.comment,
             composer: t.composer,
             lyricist: t.lyricist,
             lyrics: t.lyrics,
             artworks: t.artworks.map(convert),
             rawProperties: t.rawProperties,
             unsupportedProperties: t.unsupportedProperties)
    }

    private static func convert(_ a: MTArtwork) -> Artwork {
        Artwork(data: a.data,
                mimeType: a.mimeType,
                caption: a.artworkDescription,
                type: PictureType(rawValue: a.type.rawValue) ?? .other,
                declaredWidth: a.declaredWidth,
                declaredHeight: a.declaredHeight,
                declaredColorDepth: a.declaredColorDepth)
    }

    private static func convert(_ p: MTAudioProperties) -> AudioTechnicalInfo {
        AudioTechnicalInfo(durationMilliseconds: p.durationMilliseconds,
                           bitrateKbps: p.bitrateKbps,
                           sampleRate: p.sampleRate,
                           channels: p.channels,
                           bitsPerSample: p.bitsPerSample,
                           codecName: p.codecName,
                           containerName: p.containerName,
                           isLossless: p.isLossless,
                           fileSizeBytes: p.fileSizeBytes)
    }

    private static func translate(_ error: NSError?, fallback: String) -> TagError {
        guard let e = error else { return .unknown(fallback) }
        let msg = e.localizedDescription
        guard e.domain == MTTagLibErrorDomain,
              let code = MTTagLibErrorCode(rawValue: e.code) else {
            return .unknown(msg)
        }
        switch code {
        case .fileNotFound:      return .fileNotFound(msg)
        case .unsupportedFormat: return .unsupportedFormat(msg)
        case .corruptedFile:     return .corruptedFile(msg)
        case .notWritable:       return .notWritable(msg)
        case .writeFailed:       return .writeFailed(msg)
        case .nativeException:   return .nativeException(msg)
        case .invalidArgument:   return .invalidArgument(msg)
        case .capabilityMissing: return .capabilityMissing(msg)
        case .artworkTooLarge:
            // 文案由桥接层生成（那边才知道具体容器与上限），这里只把三个数原样透出去，
            // 让上层能拿 limit 当自动压缩的目标值。
            let format = e.userInfo[MTArtworkLimitFormatKey] as? String ?? "该格式"
            let limit  = (e.userInfo[MTArtworkLimitBytesKey]  as? NSNumber)?.intValue ?? 0
            let actual = (e.userInfo[MTArtworkActualBytesKey] as? NSNumber)?.intValue ?? 0
            return .artworkTooLarge(format: format, limit: limit, actual: actual)
        @unknown default:        return .unknown(msg)
        }
    }
}

// MARK: - 封面体积上限

/// 各容器对「单张封面」的硬上限，以及写入前该把图压到多大。
///
/// 起因是 AT-04：FLAC 的 METADATA_BLOCK 长度字段只有 24 bit，超过 16 MB 的 PICTURE 块
/// 会在 TagLib 渲染阶段被整块跳过 —— `save()` 照样返回 true，可原有封面早就被换下去了，
/// 结果是「报成功 + 封面凭空消失」。桥接层现在会在动文件之前拒写（`TagError.artworkTooLarge`），
/// 界面侧则先用这里的数值把图自动压到限内，能压下去就不打扰用户。
public enum ArtworkContainerLimit {

    /// FLAC METADATA_BLOCK 长度字段 = 24 bit；块体里除图片数据外还有 32 字节固定字段
    /// 加 MIME / 描述。这里按最坏情况扣掉 256 字节，得到「图片数据」的保守上限。
    public static let flacDataLimit = 0xFF_FFFF - 256          // 16,776,959

    /// 自动压缩的目标体积。刻意比硬上限低一截，给 MIME / 描述 / 未来的字段留足余量。
    public static let flacSafeTarget = 15 * 1024 * 1024        // 15 MiB

    /// 该扩展名对应容器的单张封面硬上限；`nil` = 没有会踩到的上限。
    ///
    /// MP3 / WAV / AIFF / DSF / DFF 走 ID3v2，帧长是 syncsafe 28 bit（约 256 MB）；
    /// MP4 / Ogg / APE / ASF 的长度字段都是 32 bit。这些实际都够不着，返回 nil，
    /// 免得为一个永远不触发的判断白跑一遍压缩。
    public static func dataLimit(forPathExtension ext: String) -> Int? {
        ext.lowercased() == "flac" ? flacDataLimit : nil
    }

    /// 自动压缩的目标体积；`nil` = 该容器不需要压。
    public static func safeTarget(forPathExtension ext: String) -> Int? {
        ext.lowercased() == "flac" ? flacSafeTarget : nil
    }
}

extension TagService {

    /// 把 `artworks` 里超出 `url` 所在容器上限的图压到安全体积。
    ///
    /// 压不下去时**原样返回** —— 交给桥接层拒写并给出明确错误，绝不让它悄悄丢图。
    ///
    /// - Returns: `didCompress` 为 true 表示真动过手，调用方可据此在结果里补一句 note。
    public static func fittedArtworks(_ artworks: [Artwork],
                                      for url: URL) -> (artworks: [Artwork], didCompress: Bool) {
        guard let limit = ArtworkContainerLimit.dataLimit(forPathExtension: url.pathExtension),
              let target = ArtworkContainerLimit.safeTarget(forPathExtension: url.pathExtension),
              artworks.contains(where: { $0.data.count > limit })
        else { return (artworks, false) }

        var changed = false
        let fitted: [Artwork] = artworks.map { art in
            guard art.data.count > limit else { return art }
            guard let shrunk = try? ArtworkProcessor.limit(art.data, maxBytes: target),
                  shrunk.count <= limit else { return art }
            changed = true
            var copy = art
            copy.data = shrunk
            // 压过之后 MIME 与声明尺寸都变了，一并校准，免得标签里写着旧的宽高。
            return ArtworkProcessor.refreshedMetadata(copy)
        }
        return (fitted, changed)
    }

    /// 同上，但直接作用在一份 `TagEdit` 上（只有 `.replace` 会被动到）。
    public static func fitArtworks(in edit: inout TagEdit, for url: URL) -> Bool {
        guard case .replace(let arts) = edit.artworkAction, !arts.isEmpty else { return false }
        let (fitted, changed) = fittedArtworks(arts, for: url)
        if changed { edit.artworkAction = .replace(fitted) }
        return changed
    }
}
