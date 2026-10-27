//
//  AppModel+Rename.swift
//  MacTagger — 「文件名 ↔ 标签」互转与「撤消重命名」的状态与动作
//
//  对应原版 FormFilenameRel（StartRenameFiles / StartChangeTags）与 FormMain.UndoRename。
//
//  为什么状态不放进 AppModel：AppModel 与 ContentView 已定稿，本轮只允许定点增行。
//  这里照搬 `LyricsSettings.shared` 的做法，用一个独立的 ObservableObject 单例装表单状态，
//  sheet 的挂载点也自带（`FilenameRelationSheetsModifier`），对既有文件零侵入。
//

import Foundation
import SwiftUI
import AppKit

// MARK: - 表单状态（持久化）

@MainActor
final class RenameState: ObservableObject {

    static let shared = RenameState()

    private enum Key {
        static let mode      = "MacTagger.rename.mode"
        static let method    = "MacTagger.rename.method"
        static let template  = "MacTagger.rename.template"
        static let regex     = "MacTagger.rename.regex"
        static let groups    = "MacTagger.rename.regexGroups"
        static let companion = "MacTagger.rename.renameCompanions"
        static let customs   = "MacTagger.rename.customTemplates"
    }

    /// 出厂模板：原版帮助里举的例子。
    static let defaultTemplate = "@5 - @2 - @1"
    static let defaultRegex = "^(\\d+) - (.+) - (.+)$"
    /// 「保存的自定义模板」里预置几条常见写法，省得用户从空白开始。
    static let presetTemplates = [
        "@5 - @2 - @1",
        "@2 - @1",
        "@5. @1",
        "@3 - @5 - @1",
        "[@6] @2 - @1",
        "@4-@5 @2 - @1"
    ]

    /// sheet 开关。
    @Published var isPresented = false

    @Published var mode: FilenameRelationMode = .rename {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Key.mode) }
    }
    @Published var method: FilenameMatchMethod = .template {
        didSet { UserDefaults.standard.set(method.rawValue, forKey: Key.method) }
    }
    @Published var templateText: String = RenameState.defaultTemplate {
        didSet { UserDefaults.standard.set(templateText, forKey: Key.template) }
    }
    @Published var regexText: String = RenameState.defaultRegex {
        didSet { UserDefaults.standard.set(regexText, forKey: Key.regex) }
    }
    /// 捕获组编号（1 起）→ 字段。没映射的组不写任何字段。
    @Published var groupFields: [Int: FilenameField] = [1: .track, 2: .artist, 3: .title] {
        didSet { persistGroups() }
    }
    @Published var renameCompanions = true {
        didSet { UserDefaults.standard.set(renameCompanions, forKey: Key.companion) }
    }
    @Published var customTemplates: [String] = RenameState.presetTemplates {
        didSet { UserDefaults.standard.set(customTemplates, forKey: Key.customs) }
    }

    /// 预览表。由界面在输入变化时重算（不在 body 里算，否则每帧都跑一次磁盘检查）。
    @Published var preview: [RenamePreviewRow] = []
    /// 模板 / 正则本身的校验错误（非空时「应用」禁用）。
    @Published var ruleError: String?

    private init() {
        let d = UserDefaults.standard
        mode = FilenameRelationMode(rawValue: d.string(forKey: Key.mode) ?? "") ?? .rename
        method = FilenameMatchMethod(rawValue: d.string(forKey: Key.method) ?? "") ?? .template
        templateText = d.string(forKey: Key.template) ?? RenameState.defaultTemplate
        regexText = d.string(forKey: Key.regex) ?? RenameState.defaultRegex
        renameCompanions = d.object(forKey: Key.companion) as? Bool ?? true
        customTemplates = d.stringArray(forKey: Key.customs) ?? RenameState.presetTemplates
        if let raw = d.dictionary(forKey: Key.groups) as? [String: Int] {
            var restored: [Int: FilenameField] = [:]
            for (k, v) in raw {
                if let g = Int(k), let f = FilenameField(rawValue: v) { restored[g] = f }
            }
            if !restored.isEmpty { groupFields = restored }
        }
    }

    private func persistGroups() {
        let raw = Dictionary(uniqueKeysWithValues: groupFields.map { (String($0.key), $0.value.rawValue) })
        UserDefaults.standard.set(raw, forKey: Key.groups)
    }

    // MARK: 派生

    /// 已编译的模板；不合法时为 nil，原因在 `ruleError`。
    var compiledTemplate: FilenameTemplate? {
        try? FilenameTemplate.parse(templateText, mode: mode)
    }

    var compiledRegexRule: FilenameRegexRule {
        FilenameRegexRule(pattern: regexText, groupFields: groupFields)
    }

    /// 正则里的捕获组个数；正则非法时为 0。
    var captureGroupCount: Int { compiledRegexRule.captureGroupCount ?? 0 }

    /// 当前规则的校验结论（nil = 通过）。
    func validate() -> String? {
        switch method {
        case .template: return FilenameTemplate.validate(templateText, mode: mode)
        case .regex:    return compiledRegexRule.validationMessage(mode: mode)
        }
    }

    var renderOptions: FilenameRenderOptions { .default }

    var renameOptions: RenameOptions {
        RenameOptions(renameCompanions: renameCompanions, render: renderOptions)
    }

    // MARK: 自定义模板

    func saveCurrentTemplate() {
        let t = templateText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !customTemplates.contains(t) else { return }
        customTemplates.append(t)
    }

    func deleteTemplate(_ t: String) {
        customTemplates.removeAll { $0 == t }
    }

    /// 原版的「清空捕获组」。
    func clearGroupFields() { groupFields = [:] }

    /// 参数按钮：把 `@n` 追加到模板末尾。
    func appendParameter(_ field: FilenameField) {
        templateText += field.token
    }
}

// MARK: - 预览行

struct RenamePreviewRow: Identifiable, Equatable {

    enum Kind: Equatable {
        /// 可执行。
        case ready
        /// 无需处理（文件名没变 / 没解析出任何字段变化）。
        case ignored(String)
        /// 失败，附中文原因。
        case failed(String)
    }

    var id: URL
    var currentName: String
    /// 重命名模式：新文件名。
    var newName: String
    /// 解析模式：解出的字段，按参数编号排好序。
    var parsed: [(field: FilenameField, value: String)]
    /// 伴随文件的新名字（只用于显示）。
    var companionNames: [String]
    var kind: Kind

    var reason: String? {
        switch kind {
        case .ready: return nil
        case .ignored(let r), .failed(let r): return r
        }
    }

    var isFailed: Bool { if case .failed = kind { return true }; return false }
    var isReady: Bool { if case .ready = kind { return true }; return false }

    static func == (a: RenamePreviewRow, b: RenamePreviewRow) -> Bool {
        a.id == b.id && a.currentName == b.currentName && a.newName == b.newName
            && a.kind == b.kind && a.companionNames == b.companionNames
            && a.parsed.map(\.field) == b.parsed.map(\.field)
            && a.parsed.map(\.value) == b.parsed.map(\.value)
    }
}


// MARK: - 后台批处理控制块（A 组四条入口共用）

/// 一次后台批处理的控制块。
///
/// - 浮层「取消」/ 表内「取消读取」在主线程调 `cancel()`，后台循环在两步之间查 `isCancelled`；
/// - 收尾时 `finish()`，之后才到的进度回调一律丢弃 —— 进度是 `Task { @MainActor … }` 异步投递的，
///   不挡这一下，迟到的一拍会把已经收起的浮层又顶出来。
final class BatchRunToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var finished = false

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func finish() { lock.lock(); finished = true; lock.unlock() }
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
}

// MARK: - 待读行补读（A 组四条入口共用）
//
// 「文件名 → 标签 / 统一标签 / 简繁（标签）」要按磁盘现状记撤消快照，
// 「标签 → 文件名 / 按标签整理 / 简繁（标签）/ 统一标签」要拿标签算改动。
// 两段式导入下，还没轮到的行是**待读行**：`file.tags` 与 `draft` 都是空壳 `Tags()`。
// 拿空壳记快照，撤消时 6 个文本字段会被当成 nil 逐个删掉（BO P0-1）；拿空壳算整理路径，
// 整行会被排进「未知艺术家 / 未知专辑」（BO P1-12）。所以这几条入口一律**先读回来再算**。

extension AppModel {

    /// 每块多少个文件。块小：取消更灵、主线程每次占得更短；块大：来回跳线程更少。
    static let pendingTagLoadChunk = 16

    /// `ids` 里此刻仍是待读状态的那些（保持原顺序）。
    func pendingTagIDs(in ids: [URL]) -> [URL] {
        ids.filter { row(id: $0)?.tagsState.isPending == true }
    }

    /// 标签没读 / 读不出的行在预览与结果里的统一说法。
    static func unreadTagsReason(_ state: TagsState) -> String {
        switch state {
        case .pending:         return "标签未读取，已跳过（不拿空标签去算）"
        case .failed(let m):   return "标签读取失败，已跳过：\(m)"
        case .loaded:          return ""
        }
    }

    /// 上面那两种原因的判别（整理结果里要把它们单独列出来）。
    static func isUnreadTagsReason(_ reason: String) -> Bool {
        reason.hasPrefix("标签未读取") || reason.hasPrefix("标签读取失败")
    }

    /// 「k 个文件标签未读或读不出，已跳过：a、b、c…」
    static func unreadableNote(_ names: [String]) -> String? {
        guard !names.isEmpty else { return nil }
        let head = names.prefix(5).joined(separator: "、")
        let tail = names.count > 5 ? " 等" : ""
        return "\(names.count) 个文件标签未读或读不出，已跳过：\(head)\(tail)"
    }

    /// 把 `ids` 里的待读行真正读回来（核心，不碰浮层；进度与收尾交给调用方）。
    ///
    /// 磁盘 IO 在后台：每块先 `Task.detached` 冷读一遍（TF 卡 / 网络卷上真正慢的就是这一步），
    /// 读完回主线程把这一块交给 `materializePendingTags(in:)` 落行 —— 落行时的第二次读取
    /// 走的是刚热过的页缓存，主线程上只剩解析；草稿合并、计数、失败标记也都沿用它的口径。
    /// 块与块之间查取消、报进度。
    ///
    /// - Parameter completion: `cancelled == true` 表示被取消（已读完的块照样落了行）。
    func readPendingTagsInBackground(_ ids: [URL],
                                     token: BatchRunToken,
                                     progress: @escaping @MainActor (_ done: Int, _ total: Int) -> Void,
                                     completion: @escaping @MainActor (_ cancelled: Bool) -> Void) {
        let todo = pendingTagIDs(in: ids)
        guard !todo.isEmpty else { completion(false); return }
        let chunk = Self.pendingTagLoadChunk
        Task { @MainActor [weak self] in
            var done = 0
            var cancelled = false
            progress(0, todo.count)
            for start in stride(from: 0, to: todo.count, by: chunk) {
                if token.isCancelled { cancelled = true; break }
                let slice = Array(todo[start..<min(start + chunk, todo.count)])
                await Task.detached(priority: .userInitiated) { _ = TagService.readAll(slice) }.value
                guard let self else { return }
                if token.isCancelled { cancelled = true; break }
                // 以**此刻**的行为准：这一块里可能已有几行被后台队列读到了，
                // 拿发起时的旧快照去 materialize 会把它们（连同用户刚改的 draft）再覆盖一遍。
                let fresh = slice.compactMap { self.row(id: $0) }.filter { $0.tagsState.isPending }
                if !fresh.isEmpty { self.materializePendingTags(in: fresh) }
                done += slice.count
                progress(done, todo.count)
            }
            completion(cancelled)
        }
    }

    /// 批量入口的兜底：目标里有待读行 → 先读回来（后台 + 进度浮层 + 可取消），读完再 `then()`；
    /// 没有待读行 → 立刻同步 `then()`，与改动前的时序一模一样。
    ///
    /// 浮层文案「正在读取 N 个待读文件的标签…」，「取消」后 `then` 不执行，状态栏说明原因。
    func withPendingTagsLoaded(_ ids: [URL],
                               purpose: String,
                               then: @escaping @MainActor () -> Void) {
        let todo = pendingTagIDs(in: ids)
        guard !todo.isEmpty else { then(); return }
        guard !isBusy else {
            statusMessage = "正在处理其它任务，请稍后再试「\(purpose)」"
            return
        }
        let token = BatchRunToken()
        let started = Date()
        let note = "读完才能「\(purpose)」"
        isBusy = true
        progressTitle = "正在读取 \(todo.count) 个待读文件的标签…"
        progress = BatchProgress(completed: 0, total: todo.count, note: note, startedAt: started)
        cancelHandler = { token.cancel() }
        readPendingTagsInBackground(todo, token: token, progress: { [weak self] done, total in
            guard let self, !token.isFinished else { return }
            self.progress = BatchProgress(completed: done, total: total, note: note, startedAt: started)
        }, completion: { [weak self] cancelled in
            token.finish()
            guard let self else { return }
            self.isBusy = false
            self.progress = nil
            self.cancelHandler = nil
            if cancelled {
                let left = self.pendingTagIDs(in: todo).count
                self.statusMessage = "已取消读取标签（还有 \(left) 个文件未读），「\(purpose)」未执行"
                return
            }
            // 盖掉 materializePendingTags 逐块留下的「正在补读 N 首…」；`then` 里有新文案会再覆盖。
            self.statusMessage = "已读取 \(todo.count) 个待读文件的标签"
            then()
        })
    }
}

// MARK: - 动作

extension AppModel {

    /// 批处理目标：有选中就只处理选中项，没选中则处理列表里全部（与自动匹配 / 歌词一致）。
    var renameTargets: [FileRow] {
        selection.isEmpty ? displayRows : selectedRows
    }

    // MARK: 入口

    func presentFilenameRelation() {
        guard !allRows.isEmpty else {
            statusMessage = "列表是空的，先添加文件"
            return
        }
        // 「标签 → 文件名」的预览要拿标签算新文件名，「文件名 → 标签」要按磁盘现状记撤消快照：
        // 待读行一律先读回来再开表，免得预览把「还没读」说成「相关标签都是空的」。
        withPendingTagsLoaded(renameTargets.map(\.id), purpose: "文件名 ↔ 标签") {
            RenameState.shared.isPresented = true
        }
    }

    // MARK: 预览

    /// 重算预览表。规则不合法时清空预览并把原因写进 `ruleError`。
    func refreshRenamePreview(_ state: RenameState) {
        if let problem = state.validate() {
            state.ruleError = problem
            state.preview = []
            return
        }
        state.ruleError = nil
        let rows = renameTargets
        guard !rows.isEmpty else { state.preview = []; return }

        switch state.mode {
        case .rename:
            state.preview = renamePlans(state, rows: rows).map { plan in
                RenamePreviewRow(id: plan.sourceURL,
                                 currentName: plan.currentName,
                                 newName: plan.newName,
                                 parsed: [],
                                 companionNames: plan.companions.map { $0.to.lastPathComponent },
                                 kind: {
                                     switch plan.status {
                                     case .ready:              return .ready
                                     case .unchanged(let r):   return .ignored(r)
                                     case .invalid(let r):     return .failed(r)
                                     }
                                 }())
            }

        case .updateTags:
            state.preview = rows.map { row in
                let name = row.fileName
                // 读不出标签的文件没有可信的「写前现状」，撤消快照记不了 —— 不写它。
                // （还待读的行照常显示解析结果：应用时会先把它读回来再记快照。）
                if case .failed = row.tagsState {
                    return RenamePreviewRow(id: row.id, currentName: name, newName: "",
                                            parsed: [], companionNames: [],
                                            kind: .failed(Self.unreadTagsReason(row.tagsState)))
                }
                do {
                    let map = try parseFilename(state, filename: name)
                    let ordered = map.keys.sorted { $0.rawValue < $1.rawValue }
                        .compactMap { f -> (FilenameField, String)? in
                            guard f != .discard, let v = map[f] else { return nil }
                            return (f, v)
                        }
                    guard !ordered.isEmpty else {
                        return RenamePreviewRow(id: row.id, currentName: name, newName: "",
                                                parsed: [], companionNames: [],
                                                kind: .failed("没有解析出任何字段"))
                    }
                    return RenamePreviewRow(id: row.id, currentName: name, newName: "",
                                            parsed: ordered, companionNames: [], kind: .ready)
                } catch let e as FilenameTemplateError {
                    return RenamePreviewRow(id: row.id, currentName: name, newName: "",
                                            parsed: [], companionNames: [], kind: .failed(e.message))
                } catch {
                    return RenamePreviewRow(id: row.id, currentName: name, newName: "",
                                            parsed: [], companionNames: [],
                                            kind: .failed(error.localizedDescription))
                }
            }
        }
    }

    /// 组装重命名计划（模板 / 正则两种方式共用出口）。
    ///
    /// 只有标签**已读出**的行参与：待读行的 draft 是空壳，拿它去渲染只会得到
    /// 「生成的文件名为空（相关标签都是空的）」这种误导性结论（BO #38）。
    /// 没读 / 读不出的行照样出现在计划里，状态是 `.invalid(原因)`，执行时计入失败、不动文件。
    private func renamePlans(_ state: RenameState, rows: [FileRow]) -> [RenamePlanItem] {
        let usable = rows.filter { $0.tagsState.isLoaded }
        // 用 draft（工作副本）而不是磁盘现状：检查器里刚改还没保存的值也能立刻反映到新文件名上。
        let items = usable.map { (url: $0.file.url, tags: $0.draft) }
        let plans: [RenamePlanItem]
        switch state.method {
        case .template:
            guard let t = state.compiledTemplate else { return [] }
            plans = RenameService.plan(items: items, template: t, options: state.renameOptions)
        case .regex:
            plans = RenameService.plan(items: items, regex: state.compiledRegexRule,
                                       options: state.renameOptions)
        }
        guard usable.count < rows.count else { return plans }
        var byURL: [URL: RenamePlanItem] = [:]
        for p in plans { byURL[p.sourceURL] = p }
        return rows.map { row in
            byURL[row.id] ?? RenamePlanItem(sourceURL: row.id, newName: "", targetURL: row.id,
                                            companions: [],
                                            status: .invalid(Self.unreadTagsReason(row.tagsState)))
        }
    }

    private func parseFilename(_ state: RenameState, filename: String) throws -> [FilenameField: String] {
        switch state.method {
        case .template:
            guard let t = state.compiledTemplate else {
                throw FilenameTemplateError("模板不合法")
            }
            return try t.match(filename: filename)
        case .regex:
            return try state.compiledRegexRule.match(filename: filename)
        }
    }

    // MARK: 应用

    func applyFilenameRelation(_ state: RenameState) {
        guard state.validate() == nil else { return }
        switch state.mode {
        case .rename:     performRename(state)
        case .updateTags: performTagsFromFilename(state)
        }
    }

    // MARK: 重命名文件（标签 → 文件名）

    private func performRename(_ state: RenameState) {
        let rows = renameTargets
        guard !rows.isEmpty else {
            statusMessage = "没有可重命名的文件"
            return
        }
        let plans = renamePlans(state, rows: rows)
        guard plans.contains(where: { $0.status.isReady }) else {
            alert = AlertBox(title: "重命名文件",
                             message: "没有任何一行可以执行。请看预览里的失败原因。",
                             isError: true)
            return
        }
        runRenamePlans(plans, title: "重命名文件")
    }

    /// 真正搬文件：「标签 → 文件名」与「简繁转换（文件名）」共用。
    ///
    /// 早先是主线程上同步 `RenameService.apply`：网络卷 / TF 卡上几千首会整段卡住，
    /// 既不能取消也不置 `isBusy`（BO #40）。现在：
    /// - 置忙 + 进度浮层 + 「取消」（在文件之间生效，已搬的照常记日志、可整批撤消）；
    /// - 搬动在后台线程逐条调 `RenameService.apply([plan])`（单条语义与整批完全一致：
    ///   搬主文件 → 同步历史库路径 → 搬伴随文件），日志在最后**合成一批**记下，
    ///   「撤消重命名」仍是一次撤回整批；
    /// - 收尾就地改行（`relocateRowsInPlace`），保留选择、表内位置与未保存改动（BO #39）。
    func runRenamePlans(_ plans: [RenamePlanItem], title: String, statusSuffix: String = "") {
        guard !isBusy else {
            statusMessage = "正在处理其它任务，请稍后再试「\(title)」"
            return
        }
        let token = BatchRunToken()
        let started = Date()
        isBusy = true
        progressTitle = title + "…"
        progress = BatchProgress(completed: 0, total: plans.count, startedAt: started)
        cancelHandler = { token.cancel() }
        let history = historyStore
        let journal = RenameJournal.shared

        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                AppModel.applyRenamePlansOffMain(plans, journal: journal, history: history,
                                                 token: token) { p in
                    Task { @MainActor [weak self] in
                        guard let self, !token.isFinished else { return }
                        self.progress = BatchProgress(completed: p.completed, total: p.total,
                                                      currentPath: p.currentPath, startedAt: started)
                    }
                }
            }.value
            token.finish()
            guard let self else { return }
            self.isBusy = false
            self.progress = nil
            self.cancelHandler = nil
            var notes: [String] = []
            if result.outcome.summary.isCancelled {
                notes.append("已取消，\(result.outcome.summary.unprocessed) 个未处理")
            }
            if let e = result.journalError { notes.append("重命名日志写入失败，本批无法「撤消重命名」：\(e)") }
            self.finishRename(result.outcome.summary,
                              old: result.outcome.moved.map(\.from),
                              new: result.outcome.moved.map(\.to),
                              title: title,
                              extraNote: (notes.isEmpty ? "" : "（" + notes.joined(separator: "；") + "）")
                                         + statusSuffix)
        }
    }

    /// `runRenamePlans` 的后台部分。逐条搬、逐条报进度、条与条之间查取消；日志最后合成一批。
    nonisolated static func applyRenamePlansOffMain(
        _ plans: [RenamePlanItem],
        journal: RenameJournal?,
        history: TagsHistoryStore?,
        token: BatchRunToken,
        progress: @escaping (BatchProgress) -> Void
    ) -> (outcome: RenameService.RenameOutcome, journalError: String?) {
        let started = Date()
        var summary = BatchSummary(total: plans.count)
        var moved: [(from: URL, to: URL)] = []
        var movedCompanions: [(from: URL, to: URL)] = []
        var journalItems: [RenameJournalItem] = []

        for (i, plan) in plans.enumerated() {
            if token.isCancelled { summary.isCancelled = true; break }
            // 单条走原函数：搬主文件 → 同步历史库路径 → 搬伴随文件，一步不落。日志不让它记（journal: nil），
            // 否则每个文件各成一批，「撤消重命名」只能撤回最后一个。
            let o = RenameService.apply([plan], journal: nil, history: history)
            summary.succeeded += o.summary.succeeded
            summary.failed += o.summary.failed
            summary.ignored += o.summary.ignored
            summary.failures.append(contentsOf: o.summary.failures)
            summary.ignoredItems.append(contentsOf: o.summary.ignoredItems)
            // 日志顺序与 `RenameService.apply` 整批时一致：主文件在前、它的伴随文件紧随其后。
            for m in o.moved {
                moved.append(m)
                journalItems.append(RenameJournalItem(from: m.from.path, to: m.to.path, isCompanion: false))
            }
            for c in o.movedCompanions {
                movedCompanions.append(c)
                journalItems.append(RenameJournalItem(from: c.from.path, to: c.to.path, isCompanion: true))
            }
            progress(BatchProgress(completed: i + 1, total: plans.count, currentPath: plan.sourceURL.path))
        }

        var journalError: String?
        if !journalItems.isEmpty, let journal {
            do { try journal.record(journalItems) } catch { journalError = error.localizedDescription }
        }
        summary.elapsed = Date().timeIntervalSince(started)
        return (RenameService.RenameOutcome(summary: summary, moved: moved, movedCompanions: movedCompanions),
                journalError)
    }

    // MARK: 撤消重命名

    func requestUndoRename() {
        guard let journal = RenameJournal.shared, let batch = journal.lastBatch() else {
            statusMessage = "没有可撤消的重命名"
            return
        }
        // 最近一批是「整理」时不能在这里撤：整理的撤消含删除跨卷副本，确认框却只说「改回原来的文件名」
        // （BO #41）。与「撤消整理」反向查 kind 的做法对称。
        guard batch.kind == .rename else {
            alert = AlertBox(title: "撤消重命名",
                             message: "最近一批是「\(batch.kind.localizedName)」，不是重命名。"
                                    + "请用「撤消整理」。",
                             isError: true)
            return
        }
        let extra = batch.companionCount > 0 ? "（另含 \(batch.companionCount) 个 Lrc / 图片）" : ""
        let batchID = batch.id
        confirm = ConfirmBox(title: "撤消重命名",
                             message: "确认要撤回最近一批重命名？共 \(batch.fileCount) 个文件\(extra)，将改回原来的文件名。",
                             confirmTitle: "撤消重命名") { [weak self] in
            self?.performUndoRename(expectedBatchID: batchID)
        }
    }

    private func performUndoRename(expectedBatchID: String) {
        guard let journal = RenameJournal.shared else { return }
        // 确认框开着的这段时间里可能又产生了新的一批（例如整理）：认准确认时的那一批再撤。
        guard let batch = journal.lastBatch(), batch.id == expectedBatchID, batch.kind == .rename else {
            alert = AlertBox(title: "撤消重命名",
                             message: "最近一批已经不是刚才确认的那批重命名，未执行。请重新点「撤消重命名」。",
                             isError: true)
            return
        }
        guard !isBusy else {
            statusMessage = "正在处理其它任务，请稍后再试「撤消重命名」"
            return
        }
        isBusy = true
        progressTitle = "撤消重命名…"
        progress = BatchProgress(completed: 0, total: batch.items.count, startedAt: Date())
        let history = historyStore
        Task { @MainActor [weak self] in
            // 反向搬动同样是同步文件 IO，放后台线程（撤消没有中途取消的钩子，不挂「取消」）。
            let outcome = await Task.detached(priority: .userInitiated) {
                journal.undoLastBatch(history: history)
            }.value
            guard let self else { return }
            self.isBusy = false
            self.progress = nil
            guard outcome.summary.total > 0 else {
                self.statusMessage = "没有可撤消的重命名"
                return
            }
            // restored 里含伴随文件（.lrc / 图片），列表只关心音频。
            let audio = Set(ImportOptions.defaultExtensions.map { $0.lowercased() })
            let old = outcome.restored.map(\.from).filter { audio.contains($0.pathExtension.lowercased()) }
            let new = outcome.restored.map(\.to).filter { audio.contains($0.pathExtension.lowercased()) }
            self.finishRename(outcome.summary, old: old, new: new, title: "撤消重命名")
        }
    }

    // MARK: 从文件名更改标签（文件名 → 标签）

    private func performTagsFromFilename(_ state: RenameState) {
        let targets = renameTargets.map(\.id)
        guard !targets.isEmpty else {
            statusMessage = "没有可处理的文件"
            return
        }
        // 写前要按**磁盘现状**记撤消快照。待读行的 `file.tags` 是空壳，拿它记快照，
        // 撤消时标题/艺术家/专辑/年份/音轨/碟号会被当成 nil 全部删掉（BO P0-1）。
        // 所以先把待读行读回来（后台 + 浮层 + 可取消），读完再解析、再记快照。
        withPendingTagsLoaded(targets, purpose: "从文件名更改标签") { [weak self] in
            self?.tagsFromFilenameAfterLoad(state, targets: targets)
        }
    }

    private func tagsFromFilenameAfterLoad(_ state: RenameState, targets: [URL]) {
        var payload: [(url: URL, edit: TagEdit)] = []
        var unmatched = 0
        var unreadable: [String] = []

        for id in targets {
            guard let row = row(id: id) else { continue }
            // 读不回来的（损坏 / 无权限）没有可信的写前现状：不写、不记快照，结果里列出来。
            guard row.tagsState.isLoaded else { unreadable.append(row.fileName); continue }
            guard let map = try? parseFilename(state, filename: row.fileName) else {
                unmatched += 1
                continue
            }
            var edit = TagEdit()
            for field in map.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                guard let target = field.tagField, let value = map[field], !value.isEmpty else { continue }
                edit.set(target, value)
            }
            guard !edit.isEmpty else { unmatched += 1; continue }
            payload.append((row.file.url, edit))
        }

        guard !payload.isEmpty else {
            var message = "没有任何文件名能按当前规则解析出字段。"
            if let n = Self.unreadableNote(unreadable) { message += "\n" + n }
            alert = AlertBox(title: "从文件名更改标签", message: message, isError: true)
            return
        }

        var notes: [String] = []
        if unmatched > 0 { notes.append("\(unmatched) 个文件名未匹配，已跳过") }
        if let n = Self.unreadableNote(unreadable) { notes.append(n) }
        // 写入走「统一标签」那条五步链：撤消快照在后台逐条记（不再压主线程，BO #16），
        // 并发度按卷决定、带预留填充（BO #43），保留修改时间 / afterBatch 与手动保存一致。
        performTagPropagation(payload,
                              title: "从文件名更改标签",
                              extraNotes: notes,
                              refreshPropagationStore: false)
    }

    // MARK: 列表刷新

    /// 重命名 / 撤消重命名之后把列表对上：**就地改行**，列表里本来没有的新路径才导入。
    private func finishRename(_ summary: BatchSummary, old: [URL], new: [URL],
                              title: String, extraNote: String = "") {
        let leftovers = relocateRowsInPlace(Array(zip(old, new)))
        if !leftovers.isEmpty { importURLs(leftovers) }

        if summary.failed > 0 {
            let detail = summary.failures.prefix(8)
                .map { "· \($0.url.lastPathComponent)：\($0.error.localizedDescription)" }
                .joined(separator: "\n")
            alert = AlertBox(title: "\(title)：\(summary.description)", message: detail, isError: true)
        }

        let text = "\(title)：\(summary.description)\(extraNote)"
        guard !leftovers.isEmpty else {
            statusMessage = text
            return
        }
        // importURLs 是异步的，`finishImport` 会在结束时把 statusMessage 改成「已添加 N 个文件」。
        // 等它落地后再把本次统计压回去，否则用户只看得到导入文案、看不到成功/失败数。
        Task { @MainActor [weak self] in
            for _ in 0..<400 {
                guard let self, self.isBusy else { break }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            self?.statusMessage = text
        }
    }

    /// 文件搬走之后把对应的行**就地**换成新路径：保留 draft、选择、表内位置与读标签状态。
    ///
    /// 行的 id 就是 URL。早先的做法是「选中旧行 → 删除项 → 重新导入新路径」，代价是
    /// 用户的选择被清掉、这些行跑到表尾、行上没保存的改动全丢，追加导入还会掐断
    /// 正在进行的全量读标签（BO #39）。这里用 `mutate` 就地改 `file.url`（按旧 id 定位，
    /// 同一批里的链式改名 A→B、B→C 也不会串），再 `rebuildDisplay()` 重建索引与排序。
    ///
    /// - Returns: 列表里本来没有的那些新路径（撤消一批当初不在列表里的改名时会出现），
    ///   由调用方照旧导入。
    @discardableResult
    func relocateRowsInPlace(_ moves: [(from: URL, to: URL)]) -> [URL] {
        var mapping: [URL: URL] = [:]
        var leftovers: [URL] = []
        for (from, to) in moves where from != to {
            if row(id: from) != nil { mapping[from] = to } else { leftovers.append(to) }
        }
        leftovers = leftovers.filter { row(id: $0) == nil }
        guard !mapping.isEmpty else { return leftovers }

        // 改完之后 id 必须仍然唯一；万一撞了（列表里另有一行恰好就是目标路径），退回旧做法。
        let finalIDs = allRows.map { mapping[$0.id] ?? $0.id }
        guard Set(finalIDs).count == finalIDs.count else {
            selection = Set(mapping.keys)
            removeSelectedItems()
            return Array(mapping.values) + leftovers
        }

        let oldSelection = selection
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            for (from, to) in mapping {
                mutate(from) { $0.file.url = to }
            }
            // 重建索引（`reindex`）+ 按当前排序 / 过滤重排。它会把选择里已经不存在的旧 id 裁掉，
            // 所以下面再按映射把选择换成新 id。
            rebuildDisplay()
        }
        let visible = Set(displayRows.map(\.id))
        let newSelection = Set(oldSelection.map { mapping[$0] ?? $0 }).intersection(visible)
        if newSelection != selection { selection = newSelection }
        return leftovers
    }
}
