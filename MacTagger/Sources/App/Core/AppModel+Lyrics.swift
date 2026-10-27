//
//  AppModel+Lyrics.swift
//  MacTagger — 歌词功能的界面状态机
//
//  对应原版四个窗体：
//      FormLyric（编辑歌词 + 五个变换）
//      FormLyricAdjustTimetag（调整时间轴）
//      FormLyricSearch（从网络搜索歌词）
//      FormFindReplace（查找与替换，作用于歌词文本）
//  外加「下载歌词」（批量）与 Lrc 文件导入导出。
//
//  与自动匹配同样的底线：**批量下载的结果绝不直接落盘**。歌词选错的概率不比标签低，
//  而覆盖用户已有歌词同样不可逆，所以下载完只产出一张复核清单，勾选后才走
//  既有写入路径（写前记历史 → 可撤消）。
//

import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 编辑窗上下文

/// 打开歌词编辑窗需要的一切。`targets` 为空表示只是看看，不写回。
struct LyricsEditorContext: Identifiable {
    let id = UUID()
    var targets: [URL]
    var fileName: String
    var title: String
    var artist: String
    var duration: TimeInterval
    var initialText: String

    var isMultiple: Bool { targets.count > 1 }
}

// MARK: - 批量下载复核清单

struct LyricsBatchItem: Identifiable {
    enum Status: String {
        case downloaded      // 下载到了歌词
        case notFound        // 搜到候选但都没词，或压根没候选
        case skipped         // 已有歌词且未勾选覆盖（BL2 起批量下载不再产出：改为照常下载 + `hadExistingTagLyrics`）
        case failed          // 所有源都出错
        case noQuery         // 无标题也无文件名

        var label: String {
            switch self {
            case .downloaded: return "已下载"
            case .notFound:   return "未找到"
            case .skipped:    return "已跳过"
            case .failed:     return "失败"
            case .noQuery:    return "无查询条件"
            }
        }

        var symbol: String {
            switch self {
            case .downloaded: return "checkmark.circle.fill"
            case .notFound:   return "magnifyingglass"
            case .skipped:    return "circle.dashed"
            case .failed:     return "xmark.octagon.fill"
            case .noQuery:    return "questionmark.circle"
            }
        }

        var rank: Int {
            switch self {
            case .downloaded: return 0
            case .skipped:    return 1
            case .notFound:   return 2
            case .noQuery:    return 3
            case .failed:     return 4
            }
        }
    }

    var id: URL { url }
    let url: URL
    let fileName: String
    let status: Status
    let sourceID: String?
    let sourceName: String?
    let matchedTitle: String?
    let matchedArtist: String?
    let score: Double
    let hasTranslation: Bool
    let hasWordByWord: Bool
    let oldLyrics: String
    /// 已按当前合并格式合成好的最终文本。
    let newLyrics: String
    let candidateCount: Int
    let errorText: String?
    var accepted: Bool
    /// 下载时标签里已有歌词、且下载设置没开「覆盖已有歌词」（BL2 轮）—— 即从前在下载阶段
    /// 就被标成「已跳过」、压根不搜的那些行。现在照常下载，只打这个标记：写标签模式沿用
    /// 原规则（`canWrite` 为假，不覆盖标签里的词）；仅存文件模式下载到词就能勾（`canSaveFile`）。
    var hadExistingTagLyrics = false

    /// 写标签模式的可选口径：新词与标签里的不同，且不是「标签已有词、未开覆盖」的行。
    var canWrite: Bool {
        status == .downloaded && !newLyrics.isEmpty && newLyrics != oldLyrics && !hadExistingTagLyrics
    }

    /// 「仅保存文件」时的可选口径（BL 轮）：下载到了词就能存，**不要求**与标签里的不同 ——
    /// 「标签里早就是这份词、只差一份 .lrc」恰恰是「单独下载歌词文件」最典型的场景。
    var canSaveFile: Bool {
        status == .downloaded && !newLyrics.isEmpty
    }

    var matchDescription: String {
        guard matchedTitle != nil || matchedArtist != nil else { return "—" }
        return "《\(matchedTitle ?? "未知")》— \(matchedArtist ?? "未知")"
    }

    var lineCount: Int {
        newLyrics.isEmpty ? 0 : newLyrics.components(separatedBy: "\n").count
    }

    var summary: String { summary(writesTag: true) }

    /// `writesTag == false`（仅存文件）时不说「将覆盖原有歌词」—— 那种模式根本不碰标签。
    func summary(writesTag: Bool) -> String {
        switch status {
        case .downloaded:
            var parts = ["\(lineCount) 行"]
            if hasTranslation { parts.append("含翻译") }
            if hasWordByWord { parts.append("含逐字") }
            if writesTag && !oldLyrics.isEmpty { parts.append("将覆盖原有歌词") }
            return parts.joined(separator: " · ")
        case .skipped:   return "已有歌词，未勾选覆盖"
        case .notFound:  return candidateCount > 0 ? "\(candidateCount) 条候选都没有歌词" : "没有搜到候选"
        case .failed:    return errorText ?? "全部来源失败"
        case .noQuery:   return "该文件既无标题也无可用文件名"
        }
    }
}

struct LyricsBatchReview {
    var items: [LyricsBatchItem]
    var elapsed: TimeInterval
    /// 本次下载采用的合并选项，复核窗里回显给用户看。
    var options: LyricsMergeOptions

    /// 整批压成一条的逐源结果条，复核窗顶部那排 chips 读它。
    ///
    /// **实数据**：由每个文件的 `LyricsSearchOutcome.sourceOutcomes` 经
    /// `SourceOutcomeAggregator.merge` 聚合而来，口径是「这个源一共搜到了多少条候选、
    /// 整轮失败了几次、失败原因是什么」。界面从前是拿 `LyricsBatchItem.sourceID`
    /// 反推的（只数得出「最终采用了谁的词」，且失败源要从错误摘要里解析字符串），
    /// 一首都没下到时那份近似口径恰好什么也说不出来 —— 而那正是最需要它的时候。
    ///
    /// 之所以挂在这个结构体上而不是 `AppModel` 上：Swift 扩展加不了存储属性，
    /// 而 `AppModel` 的定义不在本轮改动范围内。它随 `@Published var lyricsBatchReview`
    /// 一起发布，对视图而言与直接挂在 model 上没有区别。
    var sourceOutcomes: [SourceOutcome] = []

    /// 整轮里失败过半的源（复核窗底部的橙色提示读它）。
    var failedSourceNote: String? {
        let bad = sourceOutcomes.filter { $0.status.isFailure }
        guard !bad.isEmpty else { return nil }
        return bad.map { "\($0.displayName)：\($0.chipLabel)" }.joined(separator: "；")
    }

    // MARK: 写入方式与完成态（BL 轮）

    /// 脚注「写入标签」复选框，默认开。每张复核表各记各的，不进偏好。
    /// 另一个复选框「保存为歌词文件」直接绑 `settings.lyricsFile.enabled`（下次记住），不在这里。
    var writeTags = true
    /// 复核中 → 应用中（写标签是异步的）→ 完成（留在复核表上给用户看每一行落了什么）。
    var phase: LyricsBatchPhase = .reviewing
    /// 每个已应用项的结果，完成态的「状态」「说明」两列读它。
    var outcomes: [URL: LyricsBatchItemOutcome] = [:]
    /// 本张复核表的编号：写标签是异步回来的，用户中途关掉窗口后，结果不能回填到下一张表上。
    let applyID = UUID()

    /// 这一行在当前写入方式下能不能勾。写标签要求「新词与标签里的不同」且不是「标签已有词、
    /// 未开覆盖」的行；仅存文件只要求有词（BL2 轮：标签已有词的行也能单独存文件）。
    func isSelectable(_ item: LyricsBatchItem) -> Bool {
        writeTags ? item.canWrite : item.canSaveFile
    }

    /// 复核中「说明」列。随写入方式变（BL2 轮）：
    ///   · 标签已有词、未开覆盖的行：写标签时「标签已有歌词」（不可勾）；仅存文件时「标签已有歌词，仅存文件」（可勾）；
    ///   · 仅存文件时不碰标签，「将覆盖原有歌词」不成立，不说。
    func note(for item: LyricsBatchItem) -> String {
        if item.hadExistingTagLyrics && item.status == .downloaded {
            return writeTags ? "标签已有歌词" : "标签已有歌词，仅存文件"
        }
        return item.summary(writesTag: writeTags)
    }

    /// 「说明」列的悬停全文：标签已有词的行把规则说全。
    func noteHelp(for item: LyricsBatchItem) -> String {
        let base = note(for: item)
        guard item.hadExistingTagLyrics && item.status == .downloaded else { return base }
        return base + "（\(item.summary(writesTag: false))）\n"
            + "标签里已有歌词，且下载设置未开「覆盖已有歌词」：写入标签时不动它；"
            + "只勾「保存为歌词文件」、取消「写入标签」时，可以单独给它存一份歌词文件。"
    }

    var isReviewing: Bool {
        if case .reviewing = phase { return true }
        return false
    }

    var acceptedItems: [LyricsBatchItem] { items.filter { $0.accepted && isSelectable($0) } }
    var acceptedCount: Int { acceptedItems.count }
    var writableCount: Int { items.filter { isSelectable($0) }.count }
    var downloadedCount: Int { items.filter { $0.status == .downloaded }.count }
}

// MARK: - 批量复核表的写入方式 / 文件统计 / 完成态（BL 轮）
//
// 用户反馈「批量获取歌词的时候好像没有单独下载歌词文件的选项」。病根三条：
//   ① 应用只有「写标签 → 成功后顺带存文件」一条路，没有「只存文件、不碰标签」；
//   ② 存不存文件取决于藏在折叠面板里的全局开关，脚注上看不出来；
//   ③ 开关没开时静默不存，事后状态栏也不说，用户不知道到底存没存。
// 现在脚注是两个明确的复选框，按钮文案随组合变，结果逐行、逐项报出来。

/// 脚注两个复选框组合出的写入方式。两个都不勾不算一种方式（应用按钮禁用）。
enum LyricsBatchApplyMode: Equatable {
    case tagsAndFiles
    case filesOnly
    case tagsOnly

    init?(writeTags: Bool, saveFiles: Bool) {
        switch (writeTags, saveFiles) {
        case (true, true):   self = .tagsAndFiles
        case (false, true):  self = .filesOnly
        case (true, false):  self = .tagsOnly
        case (false, false): return nil
        }
    }

    var writesTags: Bool { self != .filesOnly }
    var savesFiles: Bool { self != .tagsOnly }

    /// 应用按钮文案（不含计数）。
    var actionTitle: String {
        switch self {
        case .tagsAndFiles: return "写入标签并保存文件"
        case .filesOnly:    return "仅保存文件"
        case .tagsOnly:     return "仅写入标签"
        }
    }
}

/// 一趟「保存歌词文件」的统计。口径（`mactagger-probe lyric batch-file-demo` 按同一口径断言）：
///   已保存文件 = `.written`；升级为含译文 = `.upgraded`（BI 轮的纠错式覆盖）；
///   已存在跳过 = `.skippedExisting` + `.unchanged`（目标位置已经有文件，一个字节没动）；
///   失败 = 抛错；`.skippedEmpty`（渲染为空，如无时间轴导 SRT）另记，只在非零时出现。
struct LyricsFileTally: Equatable {
    var written = 0
    var upgraded = 0
    var skippedExisting = 0
    var failed = 0
    var skippedEmpty = 0

    init() {}

    init(results: [LyricsFileWriteResult], failed: Int) {
        for r in results { add(r.status) }
        self.failed = failed
    }

    mutating func add(_ status: LyricsFileWriteResult.Status) {
        switch status {
        case .written:                    written += 1
        case .upgraded:                   upgraded += 1
        case .skippedExisting, .unchanged: skippedExisting += 1
        case .skippedEmpty:               skippedEmpty += 1
        }
    }

    /// 真往磁盘写了字节的份数。
    var saved: Int { written + upgraded }
    var total: Int { written + upgraded + skippedExisting + failed + skippedEmpty }

    /// 「已保存文件 N · 升级为含译文 M · 已存在跳过 K · 失败 J」—— 四项一律列出，0 也写，
    /// 用户要的就是「到底存没存」的明确答案。
    var line: String {
        var s = "已保存文件 \(written) · 升级为含译文 \(upgraded) · 已存在跳过 \(skippedExisting) · 失败 \(failed)"
        if skippedEmpty > 0 { s += " · 内容为空未存 \(skippedEmpty)" }
        return s
    }
}

/// 一项歌词文件的落盘结果（按音频 URL 回填到复核行）。
enum LyricsBatchFileResult: Equatable {
    case done(LyricsFileWriteResult.Status, reason: String?, file: URL)
    case failed(String)
}

/// 复核表的阶段。
enum LyricsBatchPhase {
    case reviewing
    case applying(LyricsBatchApplyMode)
    case done(LyricsBatchCompletion)
}

/// 完成态：复核表脚注与状态栏共用的那一句总账。
struct LyricsBatchCompletion {
    let mode: LyricsBatchApplyMode
    var tagSucceeded = 0
    var tagFailed = 0
    /// nil = 本次没存文件（仅写入标签）。
    var files: LyricsFileTally?
    /// 第一份真写出的文件，完成态给「在访达中显示」用。
    var firstSavedFile: URL?

    /// 「写入标签 成功 3 · 失败 0；歌词文件：已保存文件 2 · 升级为含译文 1 · 已存在跳过 0 · 失败 0」
    var line: String {
        let tags = "写入标签 成功 \(tagSucceeded) · 失败 \(tagFailed)"
        switch mode {
        case .filesOnly:    return "仅保存文件（未写标签）：" + (files?.line ?? "")
        case .tagsAndFiles: return tags + "；歌词文件：" + (files?.line ?? "")
        case .tagsOnly:     return tags + "；未保存歌词文件"
        }
    }
}

/// 一个已应用项的结果：复核行「状态」「说明」两列在完成态读它。
struct LyricsBatchItemOutcome: Equatable {
    enum Tone: Equatable { case ok, neutral, failed }

    /// nil = 本模式不写标签；非 nil 的字符串 = 写标签失败原因；空串 = 写成功。
    var tagError: String?
    var wroteTag: Bool
    /// nil = 本模式不存文件，或标签失败没轮到。
    var file: LyricsBatchFileResult?
    var savesFiles: Bool

    enum Kind: Equatable {
        case tagAndFile, tagOnly, fileOnly, fileExists, fileNotSaved, tagFailed, fileFailed
    }

    var kind: Kind {
        if let e = tagError, !e.isEmpty { return .tagFailed }
        switch file {
        case .failed:
            return .fileFailed
        case .done(let s, _, _) where s == .written || s == .upgraded:
            return wroteTag ? .tagAndFile : .fileOnly
        case .done(let s, _, _) where !wroteTag && (s == .skippedExisting || s == .unchanged):
            return .fileExists
        default:
            return wroteTag ? .tagOnly : .fileNotSaved
        }
    }

    /// 状态列：「已存文件」/「已写标签」/「标签+文件」，失败与跳过另给短语。
    var label: String {
        switch kind {
        case .tagAndFile:   return "标签+文件"
        case .tagOnly:      return "已写标签"
        case .fileOnly:     return "已存文件"
        case .fileExists:   return "文件已存在"
        case .fileNotSaved: return "未存文件"
        case .tagFailed:    return "写标签失败"
        case .fileFailed:   return "文件失败"
        }
    }

    var tone: Tone {
        switch kind {
        case .tagAndFile, .tagOnly, .fileOnly: return .ok
        case .fileExists, .fileNotSaved:       return .neutral
        case .tagFailed, .fileFailed:          return .failed
        }
    }

    /// 说明列：文件落到哪儿、为什么跳过、为什么失败。
    var note: String {
        if let e = tagError, !e.isEmpty { return "标签写入失败：\(e)（未存文件）" }
        switch file {
        case .done(let s, let reason, let url):
            switch s {
            case .written:          return "已存 \(url.lastPathComponent)"
            case .upgraded:         return "\(url.lastPathComponent) 升级为含译文版"
            case .unchanged:        return "\(url.lastPathComponent) 已存在且内容一致，未重写"
            case .skippedExisting:  return "\(url.lastPathComponent) 已存在，跳过（\(reason ?? "未开启覆盖")）"
            case .skippedEmpty:     return "未存文件：\(reason ?? "内容为空")"
            }
        case .failed(let msg):
            return wroteTag ? "标签已写入；文件写出失败：\(msg)" : "文件写出失败：\(msg)"
        case nil:
            return savesFiles ? "未存文件（该行已不在列表中）" : "标签已写入，未保存歌词文件"
        }
    }
}

// MARK: - 歌词文件设置的一行摘要（复核表脚注用）

extension LyricsFileOptions {
    /// 「LRC · 与音频同目录 · 同名 · UTF-8」—— 复选框旁那行小字。
    var footerSummary: String {
        let place: String
        switch location {
        case .songFolder:              place = "与音频同目录"
        case .songSubfolder:           place = "子目录「\(location.subfolderName)」"
        case .fixedDirectory(let url): place = "目录「\(url.lastPathComponent)」"
        case .askEachTime:             place = "应用时询问位置"
        }
        let name: String
        switch naming {
        case .sameAsAudio: name = "同名"
        case .artistTitle: name = "艺术家 - 标题"
        case .titleArtist: name = "标题 - 艺术家"
        }
        let enc: String
        switch encoding {
        case .utf8:    enc = "UTF-8"
        case .utf8BOM: enc = "UTF-8 BOM"
        case .gb18030: enc = "GB18030"
        case .utf16LE: enc = "UTF-16 LE"
        }
        return [format.shortName, place, name, enc].joined(separator: " · ")
    }

    /// 摘要的悬停全文：多给覆盖与译文两项。
    var footerSummaryHelp: String {
        footerSummary
            + (overwriteExisting ? "\n目标文件已存在时覆盖" : "\n目标文件已存在时跳过（无译文旧 .lrc 会升级为含译文版）")
    }
}

// MARK: - 状态机

extension AppModel {

    /// 歌词操作的作用域：与自动匹配一致 —— 无选中时对全部，有选中时只对选中。
    var lyricsTargets: [FileRow] {
        selection.isEmpty ? displayRows : selectedRows
    }

    var lyricsScopeLabel: String {
        selection.isEmpty
            ? "全部 \(displayRows.count) 个文件"
            : "选中的 \(selection.count) 个文件"
    }

    /// 编辑器 / 搜索窗默认带入的查询条件。
    func lyricsQuery(for row: FileRow) -> TrackQuery {
        TrackQuery(title: row.draft.title,
                   artist: row.draft.artist,
                   album: row.draft.album,
                   filename: row.file.url.deletingPathExtension().lastPathComponent,
                   duration: row.file.technical.duration)
    }

    // MARK: - 1. 编辑歌词（FormLyric）

    func presentLyricsEditor() {
        guard let row = focusRow else {
            statusMessage = "请先选择一个文件"
            return
        }
        let targets = selectedRows.map(\.id)
        // 多选且歌词不一致时，编辑窗从焦点行取文本，写回时覆盖全部选中项（与右栏字段一致）。
        let text = (mergedValue(.lyrics) ?? row.draft.lyrics) ?? ""
        // 同上：多选时把「文本取自谁 / 待会儿动谁」写进状态栏。
        // 措辞与搜索窗那句有意不同 —— 编辑器**确实**会写 N 首（只是文本只有一份），
        // 说成「只对当前 1 首操作」会把人骗过去。
        if selection.count > 1 {
            statusMessage = "已选 \(selection.count) 首，编辑器文本取自当前 1 首"
                + "（\(row.fileName)），应用后覆盖全部 \(selection.count) 首"
        }
        lyricsEditorContext = LyricsEditorContext(
            targets: targets.isEmpty ? [row.id] : targets,
            fileName: row.fileName,
            title: row.draft.title ?? "",
            artist: row.draft.artist ?? "",
            duration: row.file.technical.duration,
            initialText: text)
    }

    /// 把文本写回选中行的工作副本（不落盘，用户再按「保存标签」）。
    func applyLyricsText(_ text: String, to targets: [URL]? = nil) {
        let ids = targets ?? Array(selection)
        guard !ids.isEmpty else { return }
        for id in ids {
            mutate(id) { row in
                row.draft.lyrics = text.isEmpty ? nil : text
            }
        }
        objectWillChange.send()
        statusMessage = ids.count > 1
            ? "已把歌词写入 \(ids.count) 个文件的工作副本，按「保存标签」落盘"
            : "已更新歌词，按「保存标签」落盘"
    }

    /// 原版「重置歌词」——把歌词字段清空（工作副本层面，可撤销）。
    func requestResetLyrics() {
        let rows = selectedRows
        guard !rows.isEmpty else {
            statusMessage = "请至少选择一项"
            return
        }
        confirm = ConfirmBox(title: "重置歌词",
                             message: "确认要清空 \(rows.count) 个文件的歌词？保存标签后生效。",
                             confirmTitle: "重置歌词",
                             destructive: true) { [weak self] in
            guard let self else { return }
            self.mutateSelection { $0.draft.lyrics = nil }
            self.objectWillChange.send()
            self.statusMessage = "已清空 \(rows.count) 项歌词，按「保存标签」落盘"
        }
    }

    // MARK: - 2. 从网络搜索歌词（FormLyricSearch）

    func presentLyricsSearch() {
        guard let row = focusRow else {
            statusMessage = "请先选择一个文件"
            return
        }
        // 多选时的状态栏短提示。走既有的 `statusMessage` 通道（StatusBarView 左侧直接读它），
        // 不另造一套提示机制。
        //
        // 这扇窗是**单曲**语义：菜单「歌词 › 从网络搜索歌词…」与检查器的「搜索歌词」
        // 都只搜焦点那一首。窗内已经有一条带「改为批量下载这 N 首」按钮的提示条，
        // 这一句是留给「窗被挡住 / 已经关掉了」时的那份底 —— 事后回头看状态栏，
        // 也知道刚才那一趟只动了一首。
        if selection.count > 1 {
            statusMessage = "已选 \(selection.count) 首，正在对当前 1 首操作（\(row.fileName)）"
        }
        showLyricsSearch = true
    }

    // MARK: - 3. 批量下载歌词

    func startLyricsBatchDownload() {
        guard !lyricsTargets.isEmpty else {
            statusMessage = "列表为空，请先添加音频文件"
            return
        }
        // 另一批还在跑（写入 / 回读 / 导入）时不开工：否则浮层与「取消」会被这一轮抢走（BO#7 同类）。
        if refuseWhileBusy() { return }
        // 待读行必须先补读标签再开工：懒加载导入（见 AL 报告）之后，列表里的行可能还是
        // `tagsState == .pending` 的占位行，`draft.title/artist` 全是空的。
        // 不补就直接搜的话，`lyricsQuery(for:)` 只剩文件名一个线索，歌词查询整个退化成
        // 「按文件名匹配」——对「01.mp3」这种命名等于随机抓一首词写进去。
        //
        // BO#16（BP-E）：原先这里是同步的 `materializePendingTags` —— 懒加载的 3000 首 TF 卡目录
        // ⌘A 之后点「批量下载歌词」，主线程被同步整读占住，「正在补读 N 首」的状态栏都画不出来。
        // 现在与自动匹配选项窗同一口径：少量（≤ `syncMaterializeLimit`）照旧同步（几十毫秒）；
        // 更多就后台补读（有进度浮层、可取消），读完再接着开工。
        let targets = lyricsTargets
        let pendingCount = targets.reduce(0) { $0 + ($1.tagsState.isPending ? 1 : 0) }
        if pendingCount > AppModel.syncMaterializeLimit {
            Task { [weak self] in
                guard let self else { return }
                guard await self.materializePendingTagsInBackground(in: targets,
                                                                   title: "下载歌词前补读标签…") else { return }
                self.beginLyricsBatchDownload(materialized: pendingCount)
            }
            return
        }
        let pending = materializePendingTags(in: targets)
        beginLyricsBatchDownload(materialized: pending)
    }

    /// 批量下载歌词的正式开工（目标行都已读过标签）。
    private func beginLyricsBatchDownload(materialized pending: Int) {
        // 补读会整行替换，必须重新取一遍才拿得到带标签的行。
        let rows = lyricsTargets
        guard !rows.isEmpty else {
            statusMessage = "列表为空，请先添加音频文件"
            return
        }
        let settings = lyricsSettings
        let sourceIDs = settings.activeSourceIDs
        guard !sourceIDs.isEmpty else {
            alert = AlertBox(title: "无法下载歌词",
                             message: "请至少勾选一个提供歌词的来源。", isError: true)
            return
        }

        let options = settings.mergeOptions
        let overwrite = settings.overwriteExisting
        let skipInst = settings.skipInstrumental
        let limit = settings.limitPerSource

        struct Job: Sendable {
            let url: URL
            let fileName: String
            let query: TrackQuery
            let existing: String
        }
        let jobs: [Job] = rows.map {
            Job(url: $0.id, fileName: $0.fileName,
                query: lyricsQuery(for: $0), existing: $0.draft.lyrics ?? "")
        }

        lyricsRunID &+= 1
        let runID = lyricsRunID

        isBusy = true
        isDownloadingLyrics = true
        progressTitle = "下载歌词…"
        progress = BatchProgress(completed: 0, total: jobs.count)
        // 用 `lyricsScopeLabel` 而不是干巴巴的 `jobs.count`：与自动匹配那扇窗
        // （AutoMatchSheets.swift:30「将处理 」+ `autoMatchScopeLabel`）同一套措辞，
        // 把「全部」还是「选中的」写在脸上 —— 这一轮的用户反馈正是栽在作用域看不出来。
        statusMessage = "正在为\(lyricsScopeLabel)联网搜索歌词…"
            + (pending > 0 ? "（已先补读 \(pending) 首的标签）" : "")
        cancelHandler = { [weak self] in self?.cancelLyricsDownload() }

        lyricsTask = Task { [weak self] in
            let started = Date()
            var items: [LyricsBatchItem] = []
            // 每个文件的逐源结果条，收尾时压成一条给复核窗顶部的 chips 用。
            // 只有真正发起过搜索的文件才进来 —— 「无查询条件」根本没碰过数据源，
            // 把它们记成「各源 0 条」会凭空把源画成没结果。
            var perFileOutcomes: [[SourceOutcome]] = []
            var done = 0

            // 逐个跑：歌词搜索本身已在各源内部并发，再叠一层并发容易触发限流。
            for job in jobs {
                if Task.isCancelled { break }

                var item: LyricsBatchItem
                // BL2 轮：标签已有歌词、未开「覆盖已有歌词」的文件不再在这里标「已跳过」，照常下载。
                // 写入方式（写标签 / 仅存文件）要到复核表脚注才选，下载时还不知道要不要这份词，
                // 所以不能为省请求而跳过。只打 `hadExistingTagLyrics`：写标签模式由 `canWrite` 挡住
                // （沿用原规则，不覆盖标签里的词），仅存文件模式下载到词就能勾。
                let keepsExistingTag = !overwrite && !job.existing.isEmpty
                if job.query.isEmpty {
                    item = LyricsBatchItem(url: job.url, fileName: job.fileName, status: .noQuery,
                                           sourceID: nil, sourceName: nil,
                                           matchedTitle: nil, matchedArtist: nil, score: 0,
                                           hasTranslation: false, hasWordByWord: false,
                                           oldLyrics: job.existing, newLyrics: "",
                                           candidateCount: 0, errorText: nil, accepted: false)
                } else {
                    let (best, outcome) = await LyricsService.bestLyrics(
                        for: job.query, sourceIDs: sourceIDs,
                        limitPerSource: limit, skipInstrumental: skipInst)
                    perFileOutcomes.append(outcome.sourceOutcomes)
                    item = await MainActor.run {
                        AppModel.makeBatchItem(job.url, job.fileName, job.existing,
                                               best: best, outcome: outcome, options: options)
                    }
                }
                if keepsExistingTag {
                    item.hadExistingTagLyrics = true
                    item.accepted = false      // 默认写标签模式下不可勾；仅存文件时由用户自己勾
                }

                items.append(item)
                done += 1
                let snapshot = done
                let path = job.url.path
                await MainActor.run { [weak self] in
                    guard let self, self.lyricsRunID == runID else { return }
                    self.progress = BatchProgress(completed: snapshot, total: jobs.count,
                                                  currentPath: path)
                }
            }

            let elapsed = Date().timeIntervalSince(started)
            let finalItems = items
            let merged = SourceOutcomeAggregator.merge(perFileOutcomes)
            await MainActor.run { [weak self] in
                self?.finishLyricsBatch(runID: runID, items: finalItems,
                                        elapsed: elapsed, options: options,
                                        outcomes: merged)
            }
        }
    }

    /// 把一次下载结果整理成复核行。留在 AppModel 上是为了让批量与单曲共用同一套判定。
    static func makeBatchItem(_ url: URL, _ fileName: String, _ existing: String,
                              best: LyricsCandidate?,
                              outcome: LyricsSearchOutcome,
                              options: LyricsMergeOptions) -> LyricsBatchItem {
        if let best, let bundle = best.bundle, !bundle.isEmpty {
            let merged = LyricsService.merge(bundle, options: options)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return LyricsBatchItem(
                url: url, fileName: fileName,
                status: merged.isEmpty ? .notFound : .downloaded,
                sourceID: best.sourceID,
                sourceName: SourceBootstrap.displayName(best.sourceID),
                matchedTitle: best.title, matchedArtist: best.artist,
                score: best.score,
                hasTranslation: best.hasTranslation,
                hasWordByWord: best.hasWordByWord,
                oldLyrics: existing, newLyrics: merged,
                candidateCount: outcome.candidates.count,
                errorText: outcome.errorSummary,
                accepted: !merged.isEmpty && merged != existing)
        }

        let allFailed = !outcome.attempts.isEmpty
            && outcome.attempts.allSatisfy { $0.outcome == .failed }
        return LyricsBatchItem(
            url: url, fileName: fileName,
            status: allFailed ? .failed : .notFound,
            sourceID: nil, sourceName: nil,
            matchedTitle: nil, matchedArtist: nil, score: 0,
            hasTranslation: false, hasWordByWord: false,
            oldLyrics: existing, newLyrics: "",
            candidateCount: outcome.candidates.count,
            errorText: outcome.errorSummary,
            accepted: false)
    }

    func cancelLyricsDownload() {
        guard isDownloadingLyrics else { return }
        lyricsRunID &+= 1
        lyricsTask?.cancel()
        lyricsTask = nil
        isDownloadingLyrics = false
        isBusy = false
        progress = nil
        cancelHandler = nil
        statusMessage = "已取消歌词下载"
    }

    private func finishLyricsBatch(runID: Int, items: [LyricsBatchItem],
                                   elapsed: TimeInterval, options: LyricsMergeOptions,
                                   outcomes: [SourceOutcome] = []) {
        guard runID == lyricsRunID else { return }
        isDownloadingLyrics = false
        isBusy = false
        progress = nil
        cancelHandler = nil
        lyricsTask = nil

        // 「标签已有歌词」的下载行排在其余下载行之后（原先「已跳过」也紧跟在「已下载」后面）。
        func key(_ i: LyricsBatchItem) -> (Int, Int) { (i.status.rank, i.hadExistingTagLyrics ? 1 : 0) }
        let sorted = items.sorted { a, b in
            key(a) != key(b) ? key(a) < key(b) : a.score > b.score
        }
        lyricsBatchReview = LyricsBatchReview(items: sorted, elapsed: elapsed, options: options,
                                              sourceOutcomes: outcomes)
        let ok = sorted.filter { $0.status == .downloaded }.count
        let kept = sorted.filter { $0.status == .downloaded && $0.hadExistingTagLyrics }.count
        statusMessage = "歌词下载完成 —— 成功 \(ok)，共 \(sorted.count) 项，待复核"
            + (kept > 0 ? "（其中 \(kept) 首标签已有歌词：写标签时不覆盖，可仅存文件）" : "")
    }

    // MARK: 复核勾选

    func setLyricsAccepted(_ id: URL, _ on: Bool) {
        guard let i = lyricsBatchReview?.items.firstIndex(where: { $0.id == id }) else { return }
        lyricsBatchReview?.items[i].accepted = on
    }

    func setAllLyricsAccepted(_ on: Bool) {
        guard let review = lyricsBatchReview else { return }
        for i in review.items.indices where review.isSelectable(review.items[i]) {
            lyricsBatchReview!.items[i].accepted = on
        }
    }

    /// 「只选不会覆盖已有歌词的」——最保守的一键勾选。
    func selectOnlyEmptyTargetLyrics() {
        guard let review = lyricsBatchReview else { return }
        for i in review.items.indices {
            let item = review.items[i]
            lyricsBatchReview!.items[i].accepted = review.isSelectable(item) && item.oldLyrics.isEmpty
        }
    }

    func discardLyricsBatchReview() {
        lyricsBatchReview = nil
        statusMessage = "已放弃本次歌词下载结果"
    }

    /// 完成态的「完成」：只关窗，状态栏保留刚才那句总账。
    func closeLyricsBatchReview() {
        lyricsBatchReview = nil
    }

    /// 脚注「写入标签」复选框（BL 轮）。
    func setLyricsBatchWriteTags(_ on: Bool) {
        guard lyricsBatchReview?.isReviewing == true else { return }
        lyricsBatchReview?.writeTags = on
    }

    /// 脚注两个复选框当前组合出的写入方式；两个都不勾 → nil（应用按钮禁用）。
    /// 「保存为歌词文件」就是 `settings.lyricsFile.enabled` 本身 —— 勾选即写回偏好，下次记住。
    var lyricsBatchApplyMode: LyricsBatchApplyMode? {
        guard let review = lyricsBatchReview else { return nil }
        return LyricsBatchApplyMode(writeTags: review.writeTags,
                                    saveFiles: settings.lyricsFile.enabled)
    }

    /// 自动匹配 / 专辑模式这一轮会不会写歌词字段 —— 两张复核表的「保存为歌词文件」复选框
    /// 只在这时出现（口径与 `AppModel+AlbumMatch` 组装选项时那句一致）。
    var autoMatchWritesLyrics: Bool {
        autoMatchSettings.fetchLyrics && autoMatchSettings.isFieldEnabled(.lyrics)
    }

    // MARK: 写入

    /// 三种写入方式（BL 轮）：
    ///   · 仅保存文件 —— 不写标签、不记撤销快照、音频文件一个字节不碰，直接落 .lrc；
    ///   · 写标签并保存文件 —— 原路径（记历史 → 写入 → 可撤消），标签写成功的那些再各存一份文件；
    ///   · 仅写入标签 —— 原路径，明确不存文件（状态栏也明说）。
    /// 文件文本一律是复核表里合成好的那份（含译文，与写进标签的逐字相同）。
    /// 应用后复核表**不关**，转入完成态逐行报结果；点「完成」才关。
    func applyLyricsBatchSelection() {
        guard let review = lyricsBatchReview, review.isReviewing else { return }
        guard let mode = lyricsBatchApplyMode else {
            statusMessage = "「写入标签」与「保存为歌词文件」至少要勾一项"
            return
        }
        let picked = review.acceptedItems
        guard !picked.isEmpty else {
            statusMessage = "没有勾选任何可写入的项"
            return
        }
        // 上一批还在写 / 回读时不开工（复核表不关，结果留着，等一下再点）。
        if mode.writesTags, refuseWhileBusy() { return }
        // 歌词文件落点选了「每次询问」：整批只问一次（取消 = 本次不应用）。
        var directory: URL?
        if mode.savesFiles, settings.lyricsFile.location.kind == .askEachTime {
            guard let dir = askLyricsDirectory(message: "选择这 \(picked.count) 份歌词文件的保存目录") else {
                statusMessage = "已取消：没有选择歌词文件的保存目录"
                return
            }
            directory = dir
        }

        lyricsBatchReview?.phase = .applying(mode)
        lyricsBatchReview?.outcomes = [:]

        switch mode {
        case .filesOnly:
            finishLyricsBatchApply(mode: mode, picked: picked, tagSummary: nil, missing: [],
                                   directory: directory, applyID: review.applyID)
        case .tagsAndFiles, .tagsOnly:
            performLyricsWrite(picked, mode: mode, directory: directory, applyID: review.applyID)
        }
    }

    private func performLyricsWrite(_ items: [LyricsBatchItem], mode: LyricsBatchApplyMode,
                                    directory: URL?, applyID: UUID) {
        let preserveDate = settings.preserveModificationDate
        var payload: [(url: URL, edit: TagEdit)] = []
        var snapshots: [(file: AudioFile, edit: TagEdit)] = []
        var mtimes: [URL: Date] = [:]
        var missing: [URL] = []

        for item in items {
            guard let row = row(id: item.url) else { missing.append(item.url); continue }
            // 先排入用户尚未保存的手工改动，再让下载结果覆盖歌词字段，
            // 否则写盘后重新读取会把用户的活儿吞掉（与自动匹配同样的坑）。
            var edit = row.pendingEdit
            edit.artworkAction = .keep
            edit.set(.lyrics, item.newLyrics)

            // 记历史统一走 writeUndoSnapshot（与保存、自动匹配同一条路径）：edit 已组装完成，
            // 助手据它决定要旁存哪些表外字段，并在会动封面时先从磁盘读回旧封面。
            // BO#16：这里只查行（主线程状态），磁盘 IO 留到下面的后台阶段。
            snapshots.append((row.file, edit))

            payload.append((row.file.url, edit))
            if preserveDate, let d = row.modifiedAt { mtimes[row.file.url] = d }
        }

        guard !payload.isEmpty else {
            statusMessage = "没有需要写入的改动"
            if lyricsBatchReview?.applyID == applyID { lyricsBatchReview?.phase = .reviewing }
            return
        }

        let finalPayload = payload
        let finalMtimes = mtimes
        let finalMissing = missing
        let history = historyStore
        let sideCar = sideCarStore
        let total = finalPayload.count

        // BO#16：先置浮层再干活；写前快照逐条甩到后台线程，带进度、可取消。
        isBusy = true
        progressTitle = "写入歌词…"
        progress = BatchProgress(completed: 0, total: total,
                                 note: "记录撤消数据 0/\(snapshots.count)", startedAt: Date())

        let task = Task { [weak self] in
            var historyFailures = 0
            var recorded = 0
            let startedAt = self?.progress?.startedAt
            for s in snapshots {
                if Task.isCancelled { break }
                let ok = await AppModel.writeUndoSnapshotOffMain(file: s.file, edit: s.edit,
                                                                 history: history, sideCar: sideCar)
                if !ok { historyFailures += 1 }
                recorded += 1
                self?.progress = BatchProgress(completed: 0, total: total,
                                               currentPath: s.file.url.path,
                                               note: "记录撤消数据 \(recorded)/\(snapshots.count)",
                                               startedAt: startedAt)
            }
            if Task.isCancelled {
                // 一个文件都没写：复核表退回可复核状态，结果还在，可以重新「应用」。
                guard let self else { return }
                self.abandonBatchBeforeWrite("写入歌词", recordedSnapshots: recorded)
                if self.lyricsBatchReview?.applyID == applyID { self.lyricsBatchReview?.phase = .reviewing }
                return
            }
            let noteCount = historyFailures
            // 写入阶段不再提供「取消」：歌词只是几 KB 文本、写得很快，而复核表的完成态要逐行报
            // 「标签写没写上」—— 中途取消后 BatchSummary 说不清哪些没轮到，逐行结果会报错账。
            self?.cancelHandler = nil
            let summary = await BatchEngine.applyEdits(finalPayload,
                                                       concurrency: BatchEngine.recommendedConcurrency(for: finalPayload.map(\.url))) { p in
                Task { @MainActor [weak self] in self?.progress = p }
            }
            await MainActor.run {
                guard let self else { return }
                if preserveDate {
                    for (url, date) in finalMtimes {
                        try? FileManager.default.setAttributes([.modificationDate: date],
                                                               ofItemAtPath: url.path)
                    }
                }
                // 标题不再是「下载歌词」：afterBatch 见到那个标题会按全局开关**自己**顺带存一遍文件
                // （用重读回来的标签文本、结果不回报）。存不存文件现在由脚注复选框决定，
                // 由下面的 finishLyricsBatchApply 显式地存、逐项回填、明确报数。
                self.afterBatch(summary,
                                reloadURLs: finalPayload.map(\.url),
                                title: "写入歌词",
                                extraNote: noteCount > 0 ? "（\(noteCount) 条历史记录失败）" : nil)
                self.finishLyricsBatchApply(mode: mode, picked: items, tagSummary: summary,
                                            missing: finalMissing, directory: directory,
                                            applyID: applyID)
            }
        }
        cancelHandler = { task.cancel() }
    }

    /// 应用的后半段：按模式存文件、逐行回填结果、写状态栏、复核表转完成态。
    /// - Parameters:
    ///   - tagSummary: 写标签的结果；`nil` = 仅保存文件模式，标签一个字没写。
    ///   - missing: 写标签前就已不在列表里的行（算写标签失败）。
    private func finishLyricsBatchApply(mode: LyricsBatchApplyMode, picked: [LyricsBatchItem],
                                        tagSummary: BatchSummary?, missing: [URL],
                                        directory: URL?, applyID: UUID) {
        // —— 标签那一半 ——
        var tagErrors: [URL: String] = [:]
        if let s = tagSummary {
            for f in s.failures { tagErrors[f.url] = f.error.localizedDescription }
        }
        for url in missing { tagErrors[url] = "该行已不在列表中" }

        // —— 文件那一半：仅文件模式存全部勾选项；写标签模式只存标签写成功的 ——
        var tally: LyricsFileTally?
        var perFile: [URL: LyricsBatchFileResult] = [:]
        if mode.savesFiles {
            let eligible = picked.filter { tagErrors[$0.url] == nil }
            let r = saveBatchLyricsFiles(eligible, directory: directory)
            tally = r.tally
            perFile = r.perItem
        }

        // —— 逐行回填 ——
        var outcomes: [URL: LyricsBatchItemOutcome] = [:]
        var completion = LyricsBatchCompletion(mode: mode, files: tally)
        for item in picked {
            let tagError: String? = mode.writesTags ? (tagErrors[item.url] ?? "") : nil
            let wroteTag = mode.writesTags && tagErrors[item.url] == nil
            if mode.writesTags { if wroteTag { completion.tagSucceeded += 1 } else { completion.tagFailed += 1 } }
            let file = perFile[item.url]
            if completion.firstSavedFile == nil, case .done(let s, _, let url) = file,
               s == .written || s == .upgraded {
                completion.firstSavedFile = url
            }
            outcomes[item.url] = LyricsBatchItemOutcome(tagError: tagError, wroteTag: wroteTag,
                                                        file: file, savesFiles: mode.savesFiles)
        }

        // —— 状态栏 ——
        switch mode {
        case .filesOnly:
            statusMessage = "仅保存歌词文件（未写标签）—— " + (tally?.line ?? "")
        case .tagsAndFiles:
            // afterBatch 已写好「成功: …, 失败: …」，这里接着把文件那本账明确列出来。
            statusMessage += "；歌词文件：" + (tally?.line ?? "")
        case .tagsOnly:
            statusMessage += "；未保存歌词文件"
        }

        // —— 复核表完成态（用户中途关掉了就不回填）——
        guard lyricsBatchReview?.applyID == applyID else { return }
        lyricsBatchReview?.outcomes = outcomes
        lyricsBatchReview?.phase = .done(completion)
    }

    /// 复核表「保存为歌词文件」的落盘（BL 轮）：文本就是复核行里合成好的 `newLyrics`
    /// （含译文，沿用下载时的合并口径），交给 `LyricsService.saveLyricsFiles`，
    /// 再把逐项结果按**音频 URL** 回填 —— `results` 里的 url 是歌词文件的路径，对不上复核行。
    ///
    /// `saveLyricsFiles` 对没抛错的作业按顺序各出一条 result、抛错的进 `summary.failures`，
    /// 所以按作业顺序走一遍、跳过失败项，就能一一对上。
    /// 「每次询问」没给目录时退回歌曲所在文件夹（与 `saveLyricsFilesIfNeeded` 同一口径）。
    func saveBatchLyricsFiles(_ items: [LyricsBatchItem], directory: URL?)
        -> (tally: LyricsFileTally, perItem: [URL: LyricsBatchFileResult]) {
        var options = settings.lyricsFile
        if directory == nil, options.location.kind == .askEachTime { options.location = .songFolder }

        var texts: [URL: String] = [:]
        for item in items { texts[item.url] = item.newLyrics }
        let jobs = lyricsFileJobs(for: items.map(\.url), texts: texts)
        guard !jobs.isEmpty else { return (LyricsFileTally(), [:]) }

        let (_, results, summary) = LyricsService.saveLyricsFiles(jobs, options: options,
                                                                   directoryOverride: directory)
        var failed: [URL: String] = [:]
        for f in summary.failures { failed[f.url] = f.error.localizedDescription }

        var perItem: [URL: LyricsBatchFileResult] = [:]
        var next = results.makeIterator()
        for job in jobs {
            let url = job.file.url
            if let msg = failed[url] {
                perItem[url] = .failed(msg)
            } else if let r = next.next() {
                perItem[url] = .done(r.status, reason: r.reason, file: r.url)
            }
        }
        return (LyricsFileTally(results: results, failed: summary.failed), perItem)
    }

    // MARK: - 4. Lrc 文件导入导出

    /// 原版「导入 Lrc 文件…」。
    func presentImportLRC() {
        guard !selection.isEmpty else {
            statusMessage = "请先选择要写入歌词的文件"
            return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择要导入的 Lrc 歌词文件"
        panel.prompt = "导入"
        if let lrc = UTType(filenameExtension: "lrc") {
            panel.allowedContentTypes = [lrc, .plainText, .text]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importLRC(from: url)
    }

    func importLRC(from url: URL) {
        do {
            let text = try LyricsService.importLrc(from: url)
            applyLyricsText(text)
            statusMessage = "已导入 \(url.lastPathComponent)（\(text.components(separatedBy: "\n").count) 行），按「保存标签」落盘"
        } catch {
            alert = AlertBox(title: "导入 Lrc 文件失败",
                             message: error.localizedDescription, isError: true)
        }
    }

    /// 原版批量歌词里的「导入 Lrc」：为每个选中文件找同目录同名的 .lrc。
    func batchImportSideCarLRC() {
        let rows = lyricsTargets
        guard !rows.isEmpty else {
            statusMessage = "列表为空"
            return
        }
        var ok = 0, missing = 0, failed = 0
        for row in rows {
            let candidates = [
                row.file.url.deletingPathExtension().appendingPathExtension("lrc"),
                row.file.url.deletingPathExtension().appendingPathExtension("LRC")
            ]
            guard let lrc = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
                missing += 1
                continue
            }
            do {
                let text = try LyricsService.importLrc(from: lrc)
                mutate(row.id) { $0.draft.lyrics = text.isEmpty ? nil : text }
                ok += 1
            } catch { failed += 1 }
        }
        objectWillChange.send()
        statusMessage = "成功: \(ok), 失败: \(failed), 忽略: \(missing), 总共: \(rows.count)"
        alert = AlertBox(title: "导入同名 Lrc 文件",
                         message: "已写入工作副本，按「保存标签」落盘。\n" + statusMessage)
    }


    // MARK: - 5. 保存为歌词文件（.lrc / 增强 .lrc / .txt / .srt）
    //
    // 五条路径共用同一份 `AppSettings.lyricsFile` 选项与同一个落盘执行器：
    //   ① 保存标签顺带存（afterBatch）  ② 批量下载复核表（BL 轮起走 saveBatchLyricsFiles，可仅存文件）
    //   ③ 自动匹配写入后（afterBatch + AppModel+AutoMatch 的补写）
    //   ④ 搜索窗「保存为文件…」        ⑤ 编辑器「另存为文件…」/ 菜单「另存为歌词文件…」
    // 选项只有一处、渲染只有一处、落盘只有一处，不会出现三套命名规则互相打架。

    var lyricsFileOptions: LyricsFileOptions { settings.lyricsFile }

    /// 把若干文件整理成落盘作业。
    /// - Parameter texts: 指定文本（自动匹配/批量下载给的是刚合成好的词）；缺省用行上的歌词。
    func lyricsFileJobs(for urls: [URL], texts: [URL: String]? = nil) -> [LyricsFileJob] {
        urls.compactMap { url in
            guard let row = row(id: url) else { return nil }
            let text = texts?[url] ?? row.file.tags.lyrics ?? row.draft.lyrics ?? ""
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            // 命名用工作副本的标题/艺术家：用户刚敲进去还没保存的也算数。
            var file = row.file
            file.tags.title = row.draft.title ?? file.tags.title
            file.tags.artist = row.draft.artist ?? file.tags.artist
            return LyricsFileJob(file: file, text: text)
        }
    }

    /// 弹目录选择面板（「每次询问」用）。取消返回 nil。
    func askLyricsDirectory(message: String = "选择歌词文件的保存目录") -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = message
        panel.prompt = "保存到这里"
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// 落盘执行器。返回实际写出的份数；`nil` 表示用户在目录面板上取消了。
    @discardableResult
    func runLyricsFileSave(_ jobs: [LyricsFileJob],
                           options: LyricsFileOptions,
                           directoryOverride: URL? = nil,
                           announce: Bool = true,
                           title: String = "保存歌词文件") -> Int? {
        guard !jobs.isEmpty else {
            if announce { statusMessage = "没有可保存的歌词" }
            return 0
        }
        var dir = directoryOverride
        if dir == nil, options.location.kind == .askEachTime {
            guard let picked = askLyricsDirectory() else { return nil }
            dir = picked
        }

        let (written, results, summary) =
            LyricsService.saveLyricsFiles(jobs, options: options, directoryOverride: dir)

        guard announce else { return written.count }

        statusMessage = "成功: \(summary.succeeded), 失败: \(summary.failed), "
            + "忽略: \(summary.ignored), 总共: \(summary.total)"

        var lines: [String] = []
        if let first = written.first {
            lines.append("已写出 \(written.count) 份 \(options.format.shortName)，例如：")
            lines.append(first.path)
        }
        // BI 轮：没开覆盖也会把「本程序写的无译文旧文件」纠正成含译文版，单拎出来报。
        let upgraded = results.filter(\.didUpgrade)
        if let first = upgraded.first {
            lines.append(".lrc 升级为含译文版 \(upgraded.count) 个，例如「\(first.url.lastPathComponent)」")
        }
        if let skipped = results.first(where: { !$0.didWrite }) {
            lines.append("跳过 \(summary.ignored) 份，例如「\(skipped.url.lastPathComponent)」：\(skipped.reason ?? "已跳过")")
        }
        if let fail = summary.failures.first {
            lines.append("首个错误：\(fail.url.lastPathComponent) — \(fail.error.localizedDescription)")
        }
        alert = AlertBox(title: title,
                         message: (lines.isEmpty ? statusMessage : lines.joined(separator: "\n")),
                         isError: summary.failed > 0)
        return written.count
    }

    /// 偏好「保存标签的同时保存歌词文件」的落点。由 `afterBatch` 在保存成功后调用
    /// （「保存标签」「自动匹配标签」两条路径；专辑模式写入也走后者）。
    ///
    /// 静默执行：绝不弹窗打断保存流程。「每次询问」在这条自动路径上退回歌曲所在文件夹 ——
    /// 批量保存标签时连弹目录面板会把人逼疯；那个选项服务的是手动的「保存为文件…／另存为…」。
    ///
    /// BL 轮：状态栏追加**四项总账**「已保存文件 N · 升级为含译文 M · 已存在跳过 K · 失败 J」——
    /// 原先只在真写出时追一句，没写出就一声不吭，用户分不清「没开」「没存」「早就有了」。
    /// BL2 轮：只在**真的尝试过存文件**时追加（四项之和 > 0）。开关开着、但这批文件都没有歌词
    /// （没有作业）或渲染后全为空时，不追一句全 0 的总账去吵「保存标签」的结果。
    /// 开关没开时仍然什么都不追加（那时脚注复选框就是没勾的，界面上已经看得见）。
    ///
    /// - Parameter supplement: 同一次写入里的**补存**（自动匹配写完后按匹配到的文本再走一遍）。
    ///   第一遍（afterBatch）已把总账写进状态栏；补存那一遍只在真多写出或失败时追一句，
    ///   否则「内容一致」的空操作会被第二次算成「已存在跳过」，同一批文件报两遍。
    @discardableResult
    func saveLyricsFilesIfNeeded(_ urls: [URL], texts: [URL: String]? = nil,
                                 supplement: Bool = false) -> LyricsFileTally? {
        var options = settings.lyricsFile
        guard options.enabled, !urls.isEmpty else { return nil }
        if options.location.kind == .askEachTime { options.location = .songFolder }

        let jobs = lyricsFileJobs(for: urls, texts: texts)
        guard !jobs.isEmpty else { return nil }

        // BI 轮：关着覆盖时仍会把本程序写出的**无译文**旧 .lrc 纠正成含译文版 ——
        // 这一笔既不是「新存」也不是「跳过」，总账里单列「升级为含译文」。
        let (_, results, summary) = LyricsService.saveLyricsFiles(jobs, options: options)
        let tally = LyricsFileTally(results: results, failed: summary.failed)
        if supplement {
            if tally.saved > 0 || tally.failed > 0 {
                statusMessage += "（补存歌词文件：已保存 \(tally.written) · 升级为含译文 \(tally.upgraded)"
                    + " · 失败 \(tally.failed)）"
            }
        } else if tally.written + tally.upgraded + tally.skippedExisting + tally.failed > 0 {
            statusMessage += "；歌词文件（\(options.format.shortName)）：" + tally.line
        }
        return tally
    }

    /// 单文件保存：搜索窗「保存为文件…」与编辑器「另存为文件…」共用。
    /// `formatOverride` 让编辑器的菜单能直接点四种格式而不必先去改选项。
    func saveLyricsFile(text: String,
                        bundle: LyricsBundle? = nil,
                        for row: FileRow,
                        formatOverride: LyricsFileFormat? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusMessage = "没有可保存的歌词"
            return
        }
        var options = settings.lyricsFile
        if let formatOverride { options.format = formatOverride }
        // 手动另存是明确的用户意图，不该被「不覆盖」默默挡掉。
        options.overwriteExisting = true

        var file = row.file
        file.tags.title = row.draft.title ?? file.tags.title
        file.tags.artist = row.draft.artist ?? file.tags.artist

        // 「每次询问」用保存面板：既能挑目录，也能顺手改文件名。
        if options.location.kind == .askEachTime {
            let suggested = LyricsService.lyricsFileURL(for: file, options: options,
                                                        directoryOverride: file.url.deletingLastPathComponent())
            let panel = NSSavePanel()
            panel.nameFieldStringValue = suggested.lastPathComponent
            panel.directoryURL = file.url.deletingLastPathComponent()
            panel.canCreateDirectories = true
            panel.message = "保存 \(options.format.shortName) 歌词文件"
            panel.prompt = "保存"
            if let type = UTType(filenameExtension: options.format.fileExtension) {
                panel.allowedContentTypes = [type, .plainText, .text]
            }
            guard panel.runModal() == .OK, let dest = panel.url else { return }
            do {
                let rendered = LyricsService.renderLyricsFile(text, bundle: bundle, options: options)
                guard !rendered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw TagError.invalidArgument(options.format == .srt
                        ? "这段歌词没有时间轴，无法导出 SRT 字幕" : "歌词为空")
                }
                let data = try LyricsService.encodeLyricsData(rendered, encoding: options.encoding)
                try data.write(to: dest, options: .atomic)
                statusMessage = "已保存 \(dest.lastPathComponent)"
            } catch {
                alert = AlertBox(title: "保存歌词文件失败",
                                 message: error.localizedDescription, isError: true)
            }
            return
        }

        do {
            let result = try LyricsService.writeLyricsFile(text, bundle: bundle,
                                                           for: file, options: options)
            switch result.status {
            case .written, .unchanged:
                statusMessage = "已保存 \(result.url.lastPathComponent)（\(result.url.deletingLastPathComponent().path)）"
            case .upgraded:
                // BI 轮：旧文件是本程序写的无译文版，被纠正成含译文版。动过别人的文件就要说。
                statusMessage = "已把 \(result.url.lastPathComponent) 升级为含译文版（\(result.url.deletingLastPathComponent().path)）"
            case .skippedExisting, .skippedEmpty:
                alert = AlertBox(title: "未保存歌词文件",
                                 message: (result.reason ?? "已跳过") + "\n" + result.url.path,
                                 isError: false)
            }
        } catch {
            alert = AlertBox(title: "保存歌词文件失败",
                             message: error.localizedDescription, isError: true)
        }
    }

    // MARK: - 6. 菜单「另存为歌词文件…」（原「另存为 Lrc 文件…」升级版）

    /// 原版「另存为 Lrc 文件…」——弹选项窗（格式 / 位置 / 命名 / 编码 / 覆盖）。
    func presentExportLRC() {
        let rows = lyricsTargets.filter { !($0.draft.lyrics ?? "").isEmpty }
        guard !rows.isEmpty else {
            statusMessage = "选中的文件都没有歌词，无需另存"
            alert = AlertBox(title: "另存为歌词文件",
                             message: "选中的文件都没有歌词。", isError: false)
            return
        }
        showLrcExportOptions = true
    }

    var lrcExportCandidates: [FileRow] {
        lyricsTargets.filter { !($0.draft.lyrics ?? "").isEmpty }
    }

    /// 真正写出歌词文件。沿用原版「成功/失败/忽略/总共」文案。
    func performExportLRC() {
        let rows = lrcExportCandidates
        guard !rows.isEmpty else { return }
        var options = settings.lyricsFile
        // 菜单里点「另存为」是明确的一次性动作，不该被总开关左右。
        options.enabled = true

        let jobs: [LyricsFileJob] = rows.compactMap { row in
            let text = row.draft.lyrics ?? ""
            guard !text.isEmpty else { return nil }
            var file = row.file
            file.tags.title = row.draft.title ?? file.tags.title
            file.tags.artist = row.draft.artist ?? file.tags.artist
            return LyricsFileJob(file: file, text: text)
        }
        runLyricsFileSave(jobs, options: options, title: "另存为歌词文件")
    }
}
