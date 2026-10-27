//
//  PaddingReserver.swift
//  MacTagger — 文件头预留填充（让以后的保存都别再整文件重写）
//
//  问题：用户的无损库在 TF 卡上。TagLib 保存标签时先渲染新标签区，再
//  `File::insert(data, offset, oldLength)`；新标签区塞得进原标签区就原地覆盖
//  （写几 KB，毫秒级），塞不进就得把**整段音频后移**（几十 MB，秒级，还多写
//  一遍闪存）。FLAC 出厂时头部填充通常只有几 KB，第一次嵌封面必然重写。
//
//  对策：反正那一次要重写，就在重写**之后**把 PADDING 一次扩到位。之后换封面、
//  改标题只要不超过预留量，全部原地完成。
//
//  上限（**实测纠正了事前的假设，很重要**）：
//  事前以为「填充 ≤ 1 MB 就会被 TagLib 保留」。实测 TagLib 2.3.1 不是这样 ——
//  每次保存它都重算一遍填充，**只要渲染完剩下的填充超过 min(文件长度 / 100, 1 MB)，
//  就直接砸回 4096 字节并整文件重写**。三档文件尺寸的扫描结果（padding limit）：
//
//      文件 11.6 MB → 120 KB 保住 / 128 KB 被砸    （1% ≈ 124 KB）
//      文件 48.7 MB → 480 KB 保住 / 512 KB 被砸    （1% ≈ 516 KB）
//      文件  202 MB → 1024 KB 保住 / 1152 KB 被砸  （1 MB 封顶生效）
//
//  所以**固定 512 KB 是错的**：51 MB 以下的文件一律会在下一次保存时被收缩，
//  白白多一次整文件重写。预留量必须按文件大小算，见 `maxKeepablePadding`。
//
//  另一条实测出来的坑：**把封面换小是危险方向**。剩余填充 = 原填充 + 旧封面 − 新封面，
//  换小会让剩余填充变大，一旦越线同样触发收缩重写。要「换任何封面都原地」，
//  得让「填充 + 当前封面」整体待在 min(文件长度 / 100, 1 MB) 以内。
//
//  为什么不在 TagLib 重写的同时就留够：TagLib 的 padding 策略写死在 `save()` 里，
//  没有开放接口，我们插不进去。所以早先只能「它写完 → 我们看一眼 → 不够就补一次」。
//  这一次补是有代价的（音频再搬一次），因此只在**确认刚刚发生过整文件重写**时做，
//  绝不为了预留而凭空多制造一次重写。
//
//  ──「两次搬动 → 一次」（本轮）──────────────────────────────────────────
//
//  上面那条路径在 SSD 上第二次只要 30 ms，在 TF 卡上等于把总时长翻倍
//  （159 首 24-bit FLAC 写封面，用户实测 15 分钟）。既然插不进 TagLib 的 save()，
//  就换个方向：**在它写之前把填充扩到位，让它那一次变成原地改写**。
//
//  记 `L` 当前文件字节、`P` 当前 PADDING、`S` 当前可复用空间（`slackBytes`，
//  已含本次会被换掉的旧封面）、`N` 本次新元数据字节（`needBytes`）。
//  把 PADDING 扩到 `P + Δ` 之后可复用空间同步变成 `S + Δ`，TagLib 保存后剩余填充：
//
//      R = S + Δ − N
//
//  要它同时满足「原地」（R > 0，否则 TagLib 砸回 4096 并重写）与「不被收缩」
//  （R ≤ min(保存时文件长度 / 100, 1 MB)）。保存时文件长度 L₁ = L + Δ = L + R + N − S，
//  代入第二条：
//
//      100·R ≤ L + R + N − S   →   R ≤ (L − S + N) / 99      （再与 1 MB 取小）
//
//  正好就是 `maxKeepablePadding(fileBytes: L, currentPadding: S − N)` ——
//  与「保存后再补」用的是同一条公式，口径不分裂。选定 R 后扩填充目标 = P + R + N − S。
//
//  于是整轮只搬一次：扩填充把音频整体后移一次，随后 TagLib 因为 N ≤ S + Δ 必然原地。
//  见 `planExpandBeforeWrite(...)` / `expandBeforeWrite(...)`。
//
//  **兜底不变**：预估有偏差（TagLib 渲染出来的字节比我们估的少，剩余填充越线）时，
//  最坏也只是退回「TagLib 自己重写一次」，绝不会比旧流程更差。判定见调用方
//  `BatchEngine.applyEdits`：写前扩过填充的文件**不再**走保存后补填充那一步，
//  免得出现第三次搬动。
//

import Foundation

// MARK: - 只读结构

/// FLAC 元数据块表里的一项（`inspect` 顺带带回，给 probe / 诊断用）。
public struct FLACMetadataBlock: Sendable, Hashable {
    public var type: Int
    public var name: String
    public var offset: Int64
    public var length: Int64
    public var isLast: Bool
}

/// 文件头填充的只读快照。
public struct PaddingInfo: Sendable {
    public var url: URL
    /// 该格式是否做了结构解析。false 时其余字段无意义。
    public var isSupported: Bool
    public var container: String
    public var fileBytes: Int64
    /// 当前可原地复用的填充字节。
    public var currentPadding: Int64
    /// 元数据区总字节（含填充）。
    public var metadataBytes: Int64
    /// 音频数据起点。**判断有没有发生整文件重写就看它动没动。**
    public var audioOffset: Int64
    public var blocks: [FLACMetadataBlock]
    public var note: String

    public var fileName: String { url.lastPathComponent }

    public var summary: String {
        guard isSupported else { return "\(fileName)：\(note)" }
        return "\(container) · 填充 \(TagService.humanBytes(currentPadding))"
            + " · 元数据区 \(TagService.humanBytes(metadataBytes))"
            + " · 音频起点 \(audioOffset)"
    }
}

/// 一次扩填充的结果。
public struct ReserveOutcome: Sendable {
    public var url: URL
    /// 是否真的改写了文件（当前填充已够大时为 false，文件一个字节没动）。
    public var changed: Bool
    public var paddingBefore: Int64
    public var paddingAfter: Int64
    public var fileBytesBefore: Int64
    public var fileBytesAfter: Int64
    /// 实际被搬动的音频字节。
    public var movedBytes: Int64
    public var elapsed: TimeInterval
    public var note: String

    public var fileName: String { url.lastPathComponent }
}

// MARK: - 服务

public enum PaddingReserver {

    // MARK: 常量

    /// TagLib 的填充硬上限：1 MB。实测 202 MB 的文件预留 1024 KB 保住、1152 KB 被砸，
    /// 边界精确落在 1048576 —— 判据是「剩余填充 > 上限」才收缩，等于不收缩。
    public static let taglibMaxPadding = 1024 * 1024

    /// TagLib 的另一半上限：**文件长度的 1%**。真正生效的是两者取小。
    public static let taglibPaddingFileRatio = 100

    /// 用户设置里的默认预留量。实际写入前一律再过一遍 `recommendedTarget(...)`
    /// 按文件大小压低 —— 固定值对小文件必然越界。
    public static let defaultReserveBytes = 512 * 1024

    /// 设置项允许的最大值（UI 滑块上限）。**不是**实际预留量的保证值。
    public static let maxSafeReserveBytes = 960 * 1024

    /// 桥接层 `reservePaddingAtPath:targetBytes:` 能接受的最大目标值。
    /// FLAC 的 METADATA_BLOCK 长度是 24 位（`0xFFFFFE`），同一个上限也顺手挡住了
    /// 荒唐的 ID3v2 预留值。**写前扩填充时目标 = 预留量 + 本次新元数据**，
    /// 嵌一张十几 MB 的巨图就会顶到这条线 —— 顶到了就老老实实退回旧流程。
    public static let maxReservableBytes = 0xFF_FFFE

    /// 写前扩填充专用的额外安全带（字节）。
    ///
    /// `recommendedTarget` 的 5% 安全系数管的是「两次保存之间文件长度会变」；
    /// 写前扩填充还多一层风险：我们是拿**预估的**新元数据字节 `needBytes` 反推目标的，
    /// 而 `estimatedWriteCost` 对文本字段是「只加不减」的保守估计
    /// （每个改动字段 +32 字节余量、封面容器 +64），真实渲染出来往往更小 ——
    /// 于是实际剩余填充会比算出来的**大**，有越过 1% 线的风险。
    /// 越线的后果只是退回旧流程（TagLib 自己重写一次），不会写坏文件，
    /// 但白搭一次搬动不值当，所以再让出 8 KB。
    public static let preExpandGuardBytes = 8 * 1024

    /// 安全系数：算出来的硬边界再打 95 折。TagLib 的「理想值」是拿保存那一刻的
    /// 文件长度算的，而两次保存之间文件长度会变（文本标签涨几十字节也算），
    /// 贴着边界走迟早翻车。
    public static let safetyRatio = 0.95

    /// 判断「是否发生整文件重写」时，文件大小的容忍值。0 = 严格。
    static let sizeTolerance: Int64 = 0

    /// 目前能扩填充的容器。
    public static let reservableExtensions: Set<String> = ["flac", "mp3"]

    /// 能做只读 inspect 的容器。
    public static let inspectableExtensions: Set<String> = ["flac", "mp3", "mp4", "m4a", "m4b", "aac"]

    /// 把设置值夹到 UI 允许的区间。**这只是夹设置项**，不代表能写这么多 ——
    /// 实际预留量还要过 `recommendedTarget(...)`。
    public static func safeTarget(_ bytes: Int) -> Int {
        min(max(0, bytes), maxSafeReserveBytes)
    }

    /// 这个文件**最多**能留住多少填充而不被 TagLib 在下次保存时砸回 4096。
    ///
    /// 推导：TagLib 的判据是「渲染后剩余填充 > min(保存时的文件长度 / 100, 1 MB)」。
    /// 我们把填充从 `currentPadding` 扩到 `target` 后，文件长度变成
    /// `L - currentPadding + target`，于是要求
    ///
    ///     target ≤ (L - currentPadding + target) / 100
    ///  →  target ≤ (L - currentPadding) / 99
    ///
    /// 再与 1 MB 硬上限取小。三档实测（11.6 / 48.7 / 202 MB）与这条式子逐项吻合。
    public static func maxKeepablePadding(fileBytes: Int64, currentPadding: Int64) -> Int {
        let body = max(0, fileBytes - currentPadding)
        let byRatio = body / Int64(taglibPaddingFileRatio - 1)
        return Int(min(byRatio, Int64(taglibMaxPadding)))
    }

    /// 这个文件实际该预留多少：用户设置值、尺寸硬边界、安全系数三者取小。
    public static func recommendedTarget(fileBytes: Int64,
                                         currentPadding: Int64,
                                         preferred: Int = defaultReserveBytes) -> Int {
        let hard = maxKeepablePadding(fileBytes: fileBytes, currentPadding: currentPadding)
        return max(0, min(safeTarget(preferred), Int(Double(hard) * safetyRatio)))
    }

    /// 同上，直接吃一份 `inspect` 快照。
    public static func recommendedTarget(for info: PaddingInfo,
                                         preferred: Int = defaultReserveBytes) -> Int {
        recommendedTarget(fileBytes: info.fileBytes,
                          currentPadding: info.currentPadding,
                          preferred: preferred)
    }

    // MARK: 写前扩填充的方案（纯算术，不碰文件）

    /// 「这次写入能不能只搬一次」的方案书。
    ///
    /// `feasible == false` 时其余字段无意义，`reason` 给出人话原因（进确认框文案）。
    public struct PreExpandPlan: Sendable {
        /// 能不能靠「写前扩填充」把两次搬动并成一次。
        public var feasible: Bool = false
        /// 扩填充的目标 PADDING 字节（传给 `reserve(_:target:)` 的值）。
        public var expandTo: Int = 0
        /// 相对当前填充要新增的字节（= 这一次实际多写进磁盘的零字节）。
        public var deltaBytes: Int = 0
        /// TagLib 保存完之后预计**剩下**的填充 —— 这才是真正留给下一次的预留量。
        public var reserveAfterSave: Int = 0
        /// TagLib 在这次保存时的保留上限 min(保存时文件长度 / 100, 1 MB)。
        public var keepLimit: Int = 0
        public var reason: String = ""

        static func no(_ why: String) -> PreExpandPlan { PreExpandPlan(reason: why) }
    }

    /// 算一算这次写入能不能「先扩填充、再让 TagLib 原地写」，一次搬动收工。
    ///
    /// - Parameters:
    ///   - fileBytes: 当前文件字节（`WriteCostEstimate.fileBytes`）。
    ///   - currentPadding: 当前 PADDING（`inspect(...).currentPadding`）。
    ///   - slackBytes: 当前**可复用**空间（`WriteCostEstimate.slackBytes`，
    ///     已把本次会被换掉的旧封面算进去了）。它与 `currentPadding` 不是一回事：
    ///     FLAC 下 `slack = 填充 + 被回收的 PICTURE 块 + 4`，扩填充只影响两者的**差值之外**
    ///     的部分 —— 扩 Δ 字节，`slack` 也正好涨 Δ，所以下面只用得到 Δ。
    ///   - requiredMetadataBytes: 本次新元数据字节（`WriteCostEstimate.needBytes`）。
    ///   - preferred: 用户设置的预留意愿（上限）。
    ///
    /// 只在「本次**会**因为空间不足而整文件重写」时才有意义 —— 塞得进的情况要么本来就原地
    /// （不该凭空制造搬动），要么是「换小封面 → 剩余填充越线 → 收缩重写」，
    /// 那种情况需要把填充**缩小**，而桥接层的 `reserve` 只能往大里走，合并不了。
    public static func planExpandBeforeWrite(fileBytes: Int64,
                                            currentPadding: Int64,
                                            slackBytes: Int64,
                                            requiredMetadataBytes: Int64,
                                            preferred: Int = defaultReserveBytes) -> PreExpandPlan {
        guard safeTarget(preferred) > 0 else { return .no("未开启预留填充") }
        guard fileBytes > 0 else { return .no("拿不到文件大小") }
        guard requiredMetadataBytes > slackBytes else {
            return .no("本次不会因空间不足而重写，无需写前扩填充")
        }

        // R ≤ (L − S + N) / 99，再与 1 MB 取小 —— 与「保存后再补」同一条公式。
        let hard = maxKeepablePadding(fileBytes: fileBytes,
                                      currentPadding: slackBytes - requiredMetadataBytes)
        let guarded = max(0, hard - preExpandGuardBytes)
        let reserveAfter = max(0, min(safeTarget(preferred), Int(Double(guarded) * safetyRatio)))

        // 留不下比 TagLib 自己给的默认填充更多的东西，就别折腾了：
        // 让 TagLib 自己重写一次（同样是一次搬动），结果一模一样。
        guard reserveAfter > minPaddingAfterRewrite else {
            return .no("这个尺寸留不下有意义的填充（上限 \(hard) 字节），交给 TagLib 自己重写一次")
        }

        let expandTo64 = Int64(reserveAfter) + requiredMetadataBytes - slackBytes + currentPadding
        guard expandTo64 > currentPadding else { return .no("当前填充已经够用") }
        guard expandTo64 <= Int64(maxReservableBytes) else {
            return .no("本次新元数据 \(requiredMetadataBytes) 字节过大，"
                       + "扩后填充 \(expandTo64) 超出块长上限 \(maxReservableBytes)，只能让 TagLib 重写")
        }

        let expandTo = Int(expandTo64)
        let fileAtSave = fileBytes - currentPadding + expandTo64
        let keepLimit = Int(min(fileAtSave / Int64(taglibPaddingFileRatio), Int64(taglibMaxPadding)))
        return PreExpandPlan(feasible: true,
                             expandTo: expandTo,
                             deltaBytes: expandTo - Int(currentPadding),
                             reserveAfterSave: reserveAfter,
                             keepLimit: keepLimit,
                             reason: "")
    }

    /// TagLib 整文件重写之后会把填充落到的最小值（FLAC `MinPaddingLength` = 4096；
    /// ID3v2 是 1024，取大的那个当门槛更保守）。
    public static let minPaddingAfterRewrite = 4096

    public static func canInspect(_ url: URL) -> Bool {
        inspectableExtensions.contains(url.pathExtension.lowercased())
    }

    public static func canReserve(_ url: URL) -> Bool {
        reservableExtensions.contains(url.pathExtension.lowercased())
    }

    // MARK: 只读

    /// 解析文件头，看现在预留了多少填充。**一个字节都不改。**
    public static func inspect(_ url: URL) -> PaddingInfo {
        let d = MTTagLibBridge.inspectPadding(atPath: url.path)
        let rawBlocks = (d["blocks"] as? [[String: Any]]) ?? []
        let blocks = rawBlocks.map { b in
            FLACMetadataBlock(type: (b["type"] as? NSNumber)?.intValue ?? 0,
                              name: (b["name"] as? String) ?? "?",
                              offset: (b["offset"] as? NSNumber)?.int64Value ?? 0,
                              length: (b["length"] as? NSNumber)?.int64Value ?? 0,
                              isLast: (b["isLast"] as? NSNumber)?.boolValue ?? false)
        }
        return PaddingInfo(url: url,
                           isSupported: (d["supported"] as? NSNumber)?.boolValue ?? false,
                           container: (d["container"] as? String) ?? url.pathExtension,
                           fileBytes: (d["fileBytes"] as? NSNumber)?.int64Value ?? 0,
                           currentPadding: (d["currentPadding"] as? NSNumber)?.int64Value ?? 0,
                           metadataBytes: (d["metadataBytes"] as? NSNumber)?.int64Value ?? 0,
                           audioOffset: (d["audioOffset"] as? NSNumber)?.int64Value ?? 0,
                           blocks: blocks,
                           note: (d["note"] as? String) ?? "")
    }

    // MARK: 判定

    /// 这次保存到底有没有让 TagLib 把整个文件重写一遍？
    ///
    /// 判据（两条都够充分，取或）：
    /// 1. **音频起点变了** —— 标签区变长/变短，后面的音频被整体挪过位置；
    /// 2. 音频起点没变，但**文件总字节变了** —— 原地覆盖不可能改变文件长度，
    ///    变了说明发生过 `insert()`（例如尾部标签同时被改写）。
    public static func didFullRewrite(before: PaddingInfo, after: PaddingInfo) -> Bool {
        guard before.isSupported, after.isSupported else { return false }
        if before.audioOffset != after.audioOffset { return true }
        return abs(after.fileBytes - before.fileBytes) > sizeTolerance
    }

    /// 这次保存有没有把**整段音频**挪过位置。比 `didFullRewrite` 严格，判据只有一条：
    /// **音频起点动没动**。
    ///
    /// 为什么要单独一条：`didFullRewrite` 还认「音频起点没变但文件总长变了」——
    /// 那是为了在读不准结构时保守地多判一次重写。但它对 MP3 有个实测出来的假阳性：
    /// TagLib 保存时会在文件**尾部**补一个 128 字节的 ID3v1 标签（`syncID3v1`），
    /// 文件长了 128 字节而音频一个字节没挪。实测（写 1.6 MB 封面到 11.45 MB 的 MP3）：
    ///
    ///     扩填充后  文件 13842768  音频起点 1840026
    ///     保存后    文件 13842896（Δ128）  音频起点 1840026（Δ0）   ← 尾部 ID3v1，不是搬动
    ///
    /// 尾部追加是几百字节的活儿，跟几十 MB 的整段搬动完全不是一回事。
    /// 「要不要为预留再搬一次」「写前扩填充有没有命中」这两个判断都必须按这条走，
    /// 否则每个 MP3 都会被误判成「刚重写过」，白白多搬一次。
    ///
    /// 对我们解析得了结构的容器（FLAC / MP3 / MP4），音频起点就是元数据区的末尾：
    /// 起点没动 ⟺ 元数据区长度没变 ⟺ TagLib 走的是等长 `insert()`，即原地覆盖。
    public static func didMoveAudio(before: PaddingInfo, after: PaddingInfo) -> Bool {
        guard before.isSupported, after.isSupported else { return false }
        return before.audioOffset != after.audioOffset
    }

    /// 「这次保存之后要不要顺手把填充补到位」。
    ///
    /// 三个条件全满足才补：
    /// * 格式支持扩填充；
    /// * 现有填充**不够**目标值（够了就白搬一次）；
    /// * 这次保存**确实**把整段音频挪过位置 —— 文件反正刚被搬过一遍，
    ///   这时候再搬一次换来的是以后每次都原地。否则我们等于凭空制造一次重写。
    ///
    /// 第三条用的是 `didMoveAudio` 而不是 `didFullRewrite`：MP3 每次保存都会在尾部补
    /// 128 字节的 ID3v1，`didFullRewrite` 会把它当成重写，于是「原地写完的 MP3」也被
    /// 判成该补填充 —— 那就成了凭空制造一次搬动，正好违反本函数的设计初衷。
    public static func shouldReserveAfterSave(before: PaddingInfo,
                                              after: PaddingInfo,
                                              target: Int = defaultReserveBytes) -> Bool {
        guard after.isSupported, canReserve(after.url) else { return false }
        // 目标值先按文件大小压一遍：小文件根本留不下 512 KB，硬留只会在下次保存
        // 被砸回 4096，等于白搬一次音频。
        let actual = recommendedTarget(for: after, preferred: target)
        guard actual > 0, after.currentPadding < Int64(actual) else { return false }
        return didMoveAudio(before: before, after: after)
    }

    // MARK: 写

    /// 把文件头填充扩到 `target` 字节。当前填充已经够大时不动文件。
    ///
    /// - Parameters:
    ///   - target: 目标预留字节。**调用方自己负责夹上限**（用 `safeTarget(_:)`），
    ///             这里刻意不夹 —— probe 要能故意越过 1 MB 去证明收缩规则。
    ///   - preserveModificationDate: 改写后把修改时间恢复成原值。
    ///
    /// 安全保证（全部由桥接层落实）：写同目录临时文件 → 用 TagLib 复核临时文件的
    /// 时长 / 采样率 / 声道与原文件一致 → `rename()` 原子替换。任何一步失败都会删掉
    /// 临时文件，**原文件一个字节不动**。
    ///
    /// 「整文件替换」换掉的是 inode，文件身上挂的东西不会自己跟过来（BO 报告 #47，BP-G 轮修）：
    /// - **扩展属性**（Finder 颜色标签 `com.apple.FinderInfo` + `com.apple.metadata:_kMDItemUserTags`、
    ///   `kMDItemWhereFroms`、第三方工具写的自定义属性……）与 **ACL**：替换前整份记下，
    ///   替换后原样写回新文件（`FileIdentityStash`）。权限位 / 属主桥接层已继承；
    ///   创建日期一并恢复（TagLib 原地写本来就不动它，这里不能因为换了 inode 就变）。
    /// - **硬链接**：换 inode 必然把链接拆成两份不同内容的文件，这无法事后补救 ——
    ///   链接数 > 1 时**不做整文件替换**，抛「硬链接文件已跳过预留」，原文件一个字节不动；
    ///   随后的标签写入由 TagLib 原地完成，链接保持完好。
    /// - **符号链接**：先解析到真实文件再操作（否则 rename 会把链接本身换成一个普通文件，
    ///   链接指向的原文件反而没改）。
    @discardableResult
    public static func reserve(_ url: URL,
                               target: Int,
                               preserveModificationDate: Bool = false) throws -> ReserveOutcome {
        guard canReserve(url) else {
            throw TagError.capabilityMissing(
                "\(url.pathExtension.uppercased()) 暂不支持扩填充（当前支持 FLAC 与 MP3）")
        }
        let real = url.resolvingSymlinksInPath()
        if let links = hardLinkCount(real), links > 1 {
            throw HardLinkSkipped(links: links)
        }
        let started = Date()
        let attrs = try? FileManager.default.attributesOfItem(atPath: real.path)
        let mtime = preserveModificationDate ? attrs?[.modificationDate] as? Date : nil
        let birth = attrs?[.creationDate] as? Date
        // 替换前把「文件身份」整份记下（xattr + ACL）。读失败只意味着没东西可恢复，不拦扩填充。
        let stash = FileIdentityStash.capture(real.path)

        let d: [String: Any]
        do {
            d = try MTTagLibBridge.reservePadding(atPath: real.path, targetBytes: Int64(target))
        } catch {
            throw translate(error as NSError)
        }

        let changed = (d["changed"] as? NSNumber)?.boolValue ?? false
        var note = (d["note"] as? String) ?? ""
        if changed {
            // 顺序：先 xattr / ACL（只动 ctime），最后才回填时间 —— 回填必须是最后一笔。
            let restored = stash.restore(to: real.path)
            if !restored.isEmpty { note += "；" + restored }
            var dates: [FileAttributeKey: Any] = [:]
            if let birth { dates[.creationDate] = birth }
            if let mtime { dates[.modificationDate] = mtime }
            if !dates.isEmpty {
                try? FileManager.default.setAttributes(dates, ofItemAtPath: real.path)
            }
        }
        return ReserveOutcome(url: url,
                              changed: changed,
                              paddingBefore: (d["paddingBefore"] as? NSNumber)?.int64Value ?? 0,
                              paddingAfter: (d["paddingAfter"] as? NSNumber)?.int64Value ?? 0,
                              fileBytesBefore: (d["fileBytesBefore"] as? NSNumber)?.int64Value ?? 0,
                              fileBytesAfter: (d["fileBytesAfter"] as? NSNumber)?.int64Value ?? 0,
                              movedBytes: (d["movedBytes"] as? NSNumber)?.int64Value ?? 0,
                              elapsed: Date().timeIntervalSince(started),
                              note: note)
    }

    /// 文件的硬链接数（跟随符号链接）。stat 失败返回 nil（交给桥接层去报真正的错）。
    public static func hardLinkCount(_ url: URL) -> Int? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return Int(st.st_nlink)
    }

    /// 结果里注明的那句话。悬停/详单里是这句原话 —— 用户能看出是**刻意跳过**，不是写坏了。
    static func hardLinkSkipMessage(_ links: Int) -> String {
        "硬链接文件已跳过预留（该文件有 \(links) 个硬链接，整文件替换会把链接拆开；标签照常由 TagLib 原地写入）"
    }

    /// `reserve` 遇到硬链接时抛的错（BP-H 轮起单独成类型）。
    ///
    /// 这是**刻意跳过**，不是失败：`BatchEngine` 按**类型**把它记进 `BatchSummary.reserveSkips`，
    /// 状态栏显示「跳过 M（硬链接）」，不再混进「预留失败」。`localizedDescription` 仍是
    /// `hardLinkSkipMessage` 那句原话，详单照旧。
    public struct HardLinkSkipped: LocalizedError, Sendable {
        public let links: Int
        public var errorDescription: String? { PaddingReserver.hardLinkSkipMessage(links) }
    }

    // MARK: 写前扩填充（一次搬动）

    /// 在 TagLib 写入**之前**把 PADDING 一次扩到位，让紧接着的 `TagService.write` 变成原地改写。
    ///
    /// 返回 nil = 本次不适合这么做（不是失败）：要么根本不会重写，要么这个尺寸留不下东西，
    /// 要么新元数据大到扩不动。调用方照常写入，走旧的「写完再补」兜底即可。
    ///
    /// 抛错 = 扩填充本身失败（例如 MP3 还没有 ID3v2 标签、文件只读）。此时**原文件一个字节没动**
    /// （桥接层是临时文件 + TagLib 复核 + 原子 rename），调用方照常写入即可，不要当成写入失败。
    ///
    /// 抛 `HardLinkSkipped` = 硬链接文件刻意跳过（未碰文件），调用方应计为「跳过」而非「失败」，
    /// 并照常写标签。
    ///
    /// - Parameters:
    ///   - requiredMetadataBytes: 本次新元数据字节（`WriteCostEstimate.needBytes`）。
    ///   - slackBytes: 当前可复用空间（`WriteCostEstimate.slackBytes`）。
    ///     必须由调用方给出 —— 它取决于「本次会不会回收旧封面」，只看文件本身推不出来。
    ///   - target: 用户设置的预留意愿（上限）。
    @discardableResult
    public static func expandBeforeWrite(url: URL,
                                         requiredMetadataBytes: Int64,
                                         slackBytes: Int64,
                                         target: Int = defaultReserveBytes,
                                         preserveModificationDate: Bool = false)
        throws -> ReserveOutcome?
    {
        guard canReserve(url) else { return nil }
        let info = inspect(url)
        guard info.isSupported else { return nil }
        let plan = planExpandBeforeWrite(fileBytes: info.fileBytes,
                                         currentPadding: info.currentPadding,
                                         slackBytes: slackBytes,
                                         requiredMetadataBytes: requiredMetadataBytes,
                                         preferred: target)
        guard plan.feasible else { return nil }
        // 硬链接：与 `reserve()` 同构，抛 `HardLinkSkipped`（BP-I 轮起；此前静默 return nil，
        // 跳过只能指望事后兜底那一处再撞一次才被记下）。放在方案可行**之后**：只有「本来真要扩」
        // 才算跳过，小文件本来就留不下填充时仍返回 nil，不凭空多出一条「跳过」。
        // 这是**刻意跳过**，不是失败：文件一个字节没动，调用方照常让 TagLib 原地写标签。
        // `BatchEngine` 按类型把它记进 `reserveSkips`，并且**不再**走 `reserveAfterSaveIfNeeded`
        // 兜底（那里会对同一文件再抛一次），一个文件只记一条。
        if let links = hardLinkCount(url.resolvingSymlinksInPath()), links > 1 {
            throw HardLinkSkipped(links: links)
        }
        return try reserve(url, target: plan.expandTo, preserveModificationDate: preserveModificationDate)
    }

    /// 同上，直接吃一份编辑集（probe / 单文件路径省事用）。
    /// 内部用 `TagService.estimatedWriteCost` 把 `needBytes` / `slackBytes` 算出来。
    @discardableResult
    public static func expandBeforeWrite(url: URL,
                                         edit: TagEdit,
                                         target: Int = defaultReserveBytes,
                                         preserveModificationDate: Bool = false)
        throws -> ReserveOutcome?
    {
        guard canReserve(url) else { return nil }
        let e = TagService.estimatedWriteCost(url: url, edit: edit)
        guard e.isConfident else { return nil }
        return try expandBeforeWrite(url: url,
                                     requiredMetadataBytes: e.needBytes,
                                     slackBytes: e.slackBytes,
                                     target: target,
                                     preserveModificationDate: preserveModificationDate)
    }

    // MARK: 内部

    /// 桥接层 NSError → `TagError`。（`TagService.translate` 是 private，这里照抄同一张表。）
    static func translate(_ e: NSError) -> TagError {
        let msg = e.localizedDescription
        guard e.domain == MTTagLibErrorDomain,
              let code = MTTagLibErrorCode(rawValue: e.code) else { return .unknown(msg) }
        switch code {
        case .fileNotFound:      return .fileNotFound(msg)
        case .unsupportedFormat: return .unsupportedFormat(msg)
        case .corruptedFile:     return .corruptedFile(msg)
        case .notWritable:       return .notWritable(msg)
        case .writeFailed:       return .writeFailed(msg)
        case .nativeException:   return .nativeException(msg)
        case .invalidArgument:   return .invalidArgument(msg)
        case .capabilityMissing: return .capabilityMissing(msg)
        @unknown default:        return .unknown(msg)
        }
    }

    /// 保存路径的一站式收尾：拿保存前后的快照判断，该补就补，不该补什么也不做。
    ///
    /// 返回 nil 表示「这次不需要补」（不是失败）。抛错表示补的过程出了问题 ——
    /// 那时原文件仍是保存后的正常状态，只是没预留成，调用方降级成一条提示即可，
    /// **不要**当成保存失败。
    ///
    /// - Parameter after: 保存后的快照。调用方已经 inspect 过就传进来，省一次头部读；
    ///   传 nil 则这里自己读一次（旧调用方的行为不变）。
    @discardableResult
    public static func reserveAfterSaveIfNeeded(url: URL,
                                                before: PaddingInfo,
                                                after: PaddingInfo? = nil,
                                                target: Int = defaultReserveBytes,
                                                preserveModificationDate: Bool = false)
        throws -> ReserveOutcome?
    {
        guard safeTarget(target) > 0 else { return nil }
        let after = after ?? inspect(url)
        guard shouldReserveAfterSave(before: before, after: after, target: target) else { return nil }
        let actual = recommendedTarget(for: after, preferred: target)
        guard actual > Int(after.currentPadding) else { return nil }
        return try reserve(url, target: actual, preserveModificationDate: preserveModificationDate)
    }
}

// MARK: - 文件身份（扩展属性 + ACL）的暂存与回填

/// 「临时文件 + rename」换掉 inode 前，把原文件的扩展属性与 ACL 整份记下，替换后写回新文件。
///
/// 为什么不用 `copyfile(COPYFILE_XATTR | COPYFILE_ACL)`：临时文件由桥接层创建并在其内部
/// rename，Swift 这一层拿不到临时文件路径；而 rename 之后原 inode 已经没了。
/// 所以只能「先记下 → 替换 → 再写回」，中间只有一次 rename 的时间窗。
///
/// 不回填的属性：`com.apple.provenance`（内核维护，用户态写不进去，新文件由系统自己打）。
/// 其余任何一项写回失败都**不影响扩填充的成败**（音频已安全替换），只在 note 里注明。
struct FileIdentityStash {
    var xattrs: [(name: String, value: [UInt8])] = []
    var acl: acl_t?

    static let skipped: Set<String> = ["com.apple.provenance"]

    static func capture(_ path: String) -> FileIdentityStash {
        var s = FileIdentityStash()
        let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        if size > 0 {
            var buf = [CChar](repeating: 0, count: size)
            let got = listxattr(path, &buf, size, XATTR_NOFOLLOW)
            if got > 0 {
                let names = buf[0..<got].split(separator: 0).map {
                    String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                }
                for name in names where !skipped.contains(name) {
                    let n = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
                    guard n >= 0 else { continue }
                    var value = [UInt8](repeating: 0, count: n)
                    let r = n == 0 ? 0 : getxattr(path, name, &value, n, 0, XATTR_NOFOLLOW)
                    guard r >= 0 else { continue }
                    s.xattrs.append((name, Array(value[0..<r])))
                }
            }
        }
        // 没有扩展 ACL 的文件可能拿回一份**空** ACL：当作没有，免得 note 里谎称「已恢复 ACL」。
        if let a = acl_get_link_np(path, ACL_TYPE_EXTENDED) {
            var entry: acl_entry_t?
            if acl_get_entry(a, ACL_FIRST_ENTRY.rawValue, &entry) == 0 {
                s.acl = a
            } else {
                acl_free(UnsafeMutableRawPointer(a))
            }
        }
        return s
    }

    /// 写回，返回给 note 的一句话（没有可恢复的东西时为空串）。会释放 ACL。
    func restore(to path: String) -> String {
        var ok = 0
        var failed: [String] = []
        for (name, value) in xattrs {
            let r = value.withUnsafeBytes { raw in
                setxattr(path, name, raw.baseAddress, value.count, 0, XATTR_NOFOLLOW)
            }
            if r == 0 { ok += 1 } else { failed.append(name) }
        }
        var aclNote = ""
        if let acl {
            aclNote = acl_set_link_np(path, ACL_TYPE_EXTENDED, acl) == 0 ? "、ACL" : "（ACL 未能恢复）"
            acl_free(UnsafeMutableRawPointer(acl))
        }
        guard !xattrs.isEmpty || !aclNote.isEmpty else { return "" }
        var s = "已恢复 \(ok) 个扩展属性\(aclNote)"
        if !failed.isEmpty { s += "（\(failed.count) 个未能恢复：\(failed.joined(separator: "、"))）" }
        return s
    }
}
