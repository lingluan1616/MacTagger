//
//  AppModel+Organize.swift
//  MacTagger — 「按标签整理到文件夹」的状态与动作
//
//  与 `AppModel+Rename.swift` 同构：AppModel 与 ContentView 已定稿，本轮只允许定点增行，
//  所以表单状态装在独立的 `OrganizeState` 单例里，sheet 的挂载点也自带
//  （`OrganizeSheetModifier`），对既有文件零侵入。
//
//  这里**不改任何标签**，只搬文件：写入全部走 `LibraryOrganizer.execute` +
//  `RenameJournal`（kind = .organize），撤消走「撤消整理」。
//

import Foundation
import SwiftUI
import AppKit

// MARK: - 表单状态（持久化）

@MainActor
final class OrganizeState: ObservableObject {

    static let shared = OrganizeState()

    private enum Key {
        static let preset       = "MacTagger.organize.preset"
        static let template     = "MacTagger.organize.template"
        static let rootMode     = "MacTagger.organize.rootMode"
        static let rootPath     = "MacTagger.organize.rootPath"
        static let missing      = "MacTagger.organize.missingPolicy"
        static let conflict     = "MacTagger.organize.conflictPolicy"
        static let companions   = "MacTagger.organize.moveCompanions"
        static let folderArt    = "MacTagger.organize.moveFolderArtwork"
        static let deleteEmpty  = "MacTagger.organize.deleteEmptyFolders"
        static let deleteSource = "MacTagger.organize.deleteSourceAfterCopy"
        static let customs      = "MacTagger.organize.customTemplates"
    }

    /// sheet 开关。
    @Published var isPresented = false

    @Published var preset: OrganizeTemplatePreset = .default {
        didSet {
            UserDefaults.standard.set(preset.rawValue, forKey: Key.preset)
            // 选中预设即套用它的模板串；`.custom` 保留用户已经写好的那条。
            if let t = preset.template, t != templateText { templateText = t }
        }
    }
    @Published var templateText: String = OrganizeTemplatePreset.default.template! {
        didSet {
            UserDefaults.standard.set(templateText, forKey: Key.template)
            // 手改模板后，下拉自动跟着落到对应预设 / 自定义。
            let matched = OrganizeTemplatePreset.matching(templateText)
            if matched != preset { preset = matched }
        }
    }
    /// true = 就地整理；false = 指定目录。
    @Published var isInPlace = true {
        didSet { UserDefaults.standard.set(isInPlace, forKey: Key.rootMode) }
    }
    @Published var rootPath: String = "" {
        didSet { UserDefaults.standard.set(rootPath, forKey: Key.rootPath) }
    }
    @Published var missing: OrganizeMissingPolicy = .fillUnknown {
        didSet { UserDefaults.standard.set(missing.rawValue, forKey: Key.missing) }
    }
    @Published var conflict: OrganizeConflictPolicy = .suffix {
        didSet { UserDefaults.standard.set(conflict.rawValue, forKey: Key.conflict) }
    }
    @Published var moveCompanions = true {
        didSet { UserDefaults.standard.set(moveCompanions, forKey: Key.companions) }
    }
    @Published var moveFolderArtwork = true {
        didSet { UserDefaults.standard.set(moveFolderArtwork, forKey: Key.folderArt) }
    }
    @Published var deleteEmptyFolders = true {
        didSet { UserDefaults.standard.set(deleteEmptyFolders, forKey: Key.deleteEmpty) }
    }
    /// 跨卷复制后删源。默认 false —— 「复制不删源」是这条路上唯一不会丢文件的默认值。
    @Published var deleteSourceAfterCopy = false {
        didSet { UserDefaults.standard.set(deleteSourceAfterCopy, forKey: Key.deleteSource) }
    }
    /// 保存的自定义模板。与「文件名 ↔ 标签」分开存：那边是**文件名**模板，
    /// 这边是**路径**模板（带 `/`），混在一个列表里只会互相污染。
    @Published var customTemplates: [String] = [] {
        didSet { UserDefaults.standard.set(customTemplates, forKey: Key.customs) }
    }

    /// 预览计划。由界面在输入变化时重算（不在 body 里算，否则每帧都跑一次磁盘检查）。
    @Published var plan = OrganizePlan()
    /// 模板本身的校验错误（非空时「整理」禁用）。
    @Published var ruleError: String?
    /// 右栏「原 → 新」列表里被选中的行（跟预览树联动高亮）。
    @Published var selectedItemID: URL?

    private init() {
        let d = UserDefaults.standard
        // 先读模板串，再读预设：`templateText` 的 didSet 会推导出预设，顺序反了会被覆盖。
        templateText = d.string(forKey: Key.template) ?? OrganizeTemplatePreset.default.template!
        preset = OrganizeTemplatePreset(rawValue: d.string(forKey: Key.preset) ?? "")
            ?? OrganizeTemplatePreset.matching(templateText)
        isInPlace = d.object(forKey: Key.rootMode) as? Bool ?? true
        rootPath = d.string(forKey: Key.rootPath) ?? ""
        missing = OrganizeMissingPolicy(rawValue: d.string(forKey: Key.missing) ?? "") ?? .fillUnknown
        conflict = OrganizeConflictPolicy(rawValue: d.string(forKey: Key.conflict) ?? "") ?? .suffix
        moveCompanions = d.object(forKey: Key.companions) as? Bool ?? true
        moveFolderArtwork = d.object(forKey: Key.folderArt) as? Bool ?? true
        deleteEmptyFolders = d.object(forKey: Key.deleteEmpty) as? Bool ?? true
        deleteSourceAfterCopy = d.object(forKey: Key.deleteSource) as? Bool ?? false
        customTemplates = d.stringArray(forKey: Key.customs) ?? []
    }

    // MARK: 派生

    var rootURL: URL? {
        rootPath.isEmpty ? nil : URL(fileURLWithPath: rootPath, isDirectory: true)
    }

    var options: OrganizeOptions {
        OrganizeOptions(missing: missing,
                        conflict: conflict,
                        moveCompanions: moveCompanions,
                        moveFolderArtwork: moveFolderArtwork,
                        deleteEmptySourceFolders: deleteEmptyFolders,
                        deleteSourceAfterCrossVolumeCopy: deleteSourceAfterCopy,
                        render: .organize)
    }

    /// 已编译的模板；不合法时为 nil，原因在 `ruleError`。
    var compiledTemplate: FilenameTemplate? {
        guard FilenameTemplate.validatePath(templateText) == nil else { return nil }
        return try? FilenameTemplate.parse(templateText, mode: .rename)
    }

    func validate() -> String? { FilenameTemplate.validatePath(templateText) }

    /// 预览重算的触发键：任一项变了就重算。
    var previewKey: String {
        [templateText,
         isInPlace ? "1" : "0",
         rootPath,
         missing.rawValue,
         conflict.rawValue,
         moveCompanions ? "1" : "0",
         moveFolderArtwork ? "1" : "0",
         deleteSourceAfterCopy ? "1" : "0"
        ].joined(separator: "|")
    }

    // MARK: 自定义模板

    func saveCurrentTemplate() {
        let t = templateText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, validate() == nil, !customTemplates.contains(t) else { return }
        customTemplates.append(t)
    }

    func deleteTemplate(_ t: String) { customTemplates.removeAll { $0 == t } }

    /// 参数按钮：把 `@n` 追加到模板末尾。
    func appendParameter(_ field: FilenameField) { templateText += field.token }
    /// 「/」按钮：加一级目录。
    func appendSeparator() { templateText += "/" }
}

// MARK: - 动作

extension AppModel {

    /// 批处理目标：有选中就只处理选中项，没选中则处理列表里全部（与重命名 / 自动匹配一致）。
    var organizeTargets: [FileRow] {
        selection.isEmpty ? displayRows : selectedRows
    }

    // MARK: 入口

    func presentOrganize() {
        guard !allRows.isEmpty else {
            statusMessage = "列表是空的，先添加文件"
            return
        }
        // 整理路径全靠标签算：待读行的标签是空壳，不读回来会被排进「未知艺术家 / 未知专辑」
        // （BO P1-12）。先读回来（后台 + 进度浮层 + 可取消）再开表。
        withPendingTagsLoaded(organizeTargets.map(\.id), purpose: "按标签整理") { [weak self] in
            guard let self else { return }
            let state = OrganizeState.shared
            // 「指定目录」还没选过目录时，先把侧栏的工作目录填进去当默认值。
            if state.rootPath.isEmpty, let current = self.directories.current {
                state.rootPath = current.path
            }
            state.isPresented = true
        }
    }

    /// 「指定目录…」的目录选择器。
    func chooseOrganizeRoot(_ state: OrganizeState) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "选择整理后的目标根目录"
        panel.prompt = "选择"
        if let existing = state.rootURL, FileManager.default.fileExists(atPath: existing.path) {
            panel.directoryURL = existing
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.rootPath = url.path
        state.isInPlace = false
        refreshOrganizePreview(state)
    }

    // MARK: 预览

    /// 重算整理计划。规则不合法时清空计划并把原因写进 `ruleError`。
    func refreshOrganizePreview(_ state: OrganizeState) {
        if let problem = state.validate() {
            state.ruleError = problem
            state.plan = OrganizePlan(ruleError: problem)
            return
        }
        state.ruleError = nil
        guard let template = state.compiledTemplate else {
            state.plan = OrganizePlan()
            return
        }
        let rows = organizeTargets
        guard !rows.isEmpty else { state.plan = OrganizePlan(); return }

        // 只有标签**已读出**的行参与：待读行的 draft 是空壳，缺字段会按「未知艺术家 / 未知专辑」
        // 补齐，整行被搬进错的目录（BO P1-12）；读不出的（损坏 / 无权限）同理。
        let usable = rows.filter { $0.tagsState.isLoaded }
        // 用 draft（工作副本）而不是磁盘现状：检查器里刚改还没保存的值也能立刻反映到目录结构上。
        let items = usable.map { (url: $0.file.url, tags: $0.draft) }
        var plan = LibraryOrganizer.plan(items: items,
                                         template: template,
                                         root: organizeRoot(state),
                                         options: state.options)
        // 没读 / 读不出的行不算路径，明确标成「已跳过 + 原因」出现在预览与结果里，执行时原地不动。
        for row in rows where !row.tagsState.isLoaded {
            let folder = row.id.deletingLastPathComponent()
            plan.items.append(OrganizePlanItem(sourceURL: row.id,
                                               targetURL: row.id,
                                               rootURL: folder,
                                               components: [row.fileName],
                                               status: .skipped(Self.unreadTagsReason(row.tagsState))))
        }
        state.plan = plan
    }

    /// 目标根：
    /// - 「就地整理」优先以**侧栏的工作目录**为根（这才是用户心里的「这个库」），
    ///   没有工作目录时退回「每个文件当前所在的目录」；
    /// - 「指定目录…」用用户选的那个。
    private func organizeRoot(_ state: OrganizeState) -> OrganizeRoot {
        if state.isInPlace {
            if let current = directories.current { return .fixed(current) }
            return .eachFileFolder
        }
        if let url = state.rootURL { return .fixed(url) }
        return .eachFileFolder
    }

    /// 「就地整理」当前实际会用哪个根，给界面显示。
    func organizeInPlaceRootLabel() -> String {
        directories.current.map { "以工作目录「\($0.lastPathComponent)」为根" }
            ?? "以每个文件当前所在的目录为根"
    }

    // MARK: 执行

    func applyOrganize(_ state: OrganizeState) {
        guard state.validate() == nil else { return }
        guard !isBusy else {
            statusMessage = "正在处理其它任务，请稍后再试「按标签整理」"
            return
        }
        let plan = state.plan
        guard plan.readyCount > 0 else {
            alert = AlertBox(title: "按标签整理到文件夹",
                             message: "没有任何一行可以执行。请看预览里的原因。",
                             isError: true)
            return
        }

        // 跨卷是「复制」不是「移动」，磁盘占用会翻倍 —— 这件事必须让用户点头。
        if plan.crossVolumeCount > 0 {
            let tail = state.deleteSourceAfterCopy
                ? "复制并校验成功后会删除源文件。"
                : "将复制并校验，源文件保留（磁盘占用会增加）。"
            confirm = ConfirmBox(title: "跨卷整理",
                                 message: "其中 \(plan.crossVolumeCount) 个文件要跨到另一个卷，\(tail)\n\n"
                                        + plan.summaryLine,
                                 confirmTitle: "开始整理") { [weak self] in
                self?.performOrganize(state)
            }
            return
        }
        performOrganize(state)
    }

    private func performOrganize(_ state: OrganizeState) {
        let plan = state.plan
        let options = state.options

        isBusy = true
        progressTitle = "按标签整理到文件夹…"
        progress = BatchProgress(completed: 0, total: plan.items.count)
        var cancelled = false
        cancelHandler = { cancelled = true }

        let history = historyStore
        Task { @MainActor [weak self] in
            // 搬文件是同步 IO，扔到后台线程，别把主线程钉住。
            let outcome = await Task.detached(priority: .userInitiated) {
                LibraryOrganizer.execute(plan,
                                         options: options,
                                         journal: RenameJournal.shared,
                                         history: history,
                                         isCancelled: { cancelled },
                                         progress: { p in
                                             Task { @MainActor [weak self] in self?.progress = p }
                                         })
            }.value

            guard let self else { return }
            self.cancelHandler = nil
            self.finishOrganize(outcome, title: "按标签整理到文件夹")
        }
    }

    // MARK: 撤消整理

    func requestUndoOrganize() {
        guard let journal = RenameJournal.shared, let batch = journal.lastBatch() else {
            statusMessage = "没有可撤消的整理"
            return
        }
        guard batch.kind == .organize else {
            alert = AlertBox(title: "撤消整理",
                             message: "最近一批是「\(batch.kind.localizedName)」，不是整理。"
                                    + "请用「撤消重命名」。",
                             isError: true)
            return
        }
        var parts = ["共 \(batch.fileCount) 个文件"]
        if batch.companionCount > 0 { parts.append("另含 \(batch.companionCount) 个歌词 / 封面") }
        if batch.copyCount > 0 { parts.append("其中 \(batch.copyCount) 个是跨卷副本，撤消时会删掉副本") }
        let dirNote = batch.createdDirectories.isEmpty
            ? ""
            : "\n本批新建的 \(batch.createdDirectories.count) 个目录，撤消后若已空会一并删掉。"

        confirm = ConfirmBox(title: "撤消整理",
                             message: "确认要撤回最近一批整理？\(parts.joined(separator: "，"))，"
                                    + "将搬回原来的位置。\(dirNote)",
                             confirmTitle: "撤消整理") { [weak self] in
            self?.performUndoOrganize()
        }
    }

    private func performUndoOrganize() {
        guard let journal = RenameJournal.shared else { return }
        let outcome = journal.undoLastBatch(history: historyStore)
        guard outcome.summary.total > 0 else {
            statusMessage = "没有可撤消的整理"
            return
        }
        let audio = Set(ImportOptions.defaultExtensions.map { $0.lowercased() })
        let old = (outcome.restored.map(\.from) + outcome.deletedCopies)
            .filter { audio.contains($0.pathExtension.lowercased()) }
        let new = outcome.restored.map(\.to)
            .filter { audio.contains($0.pathExtension.lowercased()) }

        var note: [String] = []
        if !outcome.removedDirectories.isEmpty {
            note.append("删掉 \(outcome.removedDirectories.count) 个空目录")
        }
        if !outcome.deletedCopies.isEmpty {
            note.append("删掉 \(outcome.deletedCopies.count) 个跨卷副本")
        }
        refreshListAfterOrganize(outcome.summary,
                                 removed: old, added: new,
                                 title: "撤消整理",
                                 extraNote: note.isEmpty ? nil : "（" + note.joined(separator: "，") + "）")
    }

    // MARK: 列表刷新

    private func finishOrganize(_ outcome: LibraryOrganizer.OrganizeOutcome, title: String) {
        var note: [String] = []
        // 标签没读 / 读不出而没整理的文件：单独列出来，免得用户以为它们也搬好了。
        let unread = outcome.summary.ignoredItems
            .filter { AppModel.isUnreadTagsReason($0.reason) }
            .map { $0.url.lastPathComponent }
        if let n = AppModel.unreadableNote(unread) { note.append(n) }
        if !outcome.copied.isEmpty {
            note.append(OrganizeState.shared.deleteSourceAfterCopy
                        ? "跨卷复制 \(outcome.copied.count) 个（源已删）"
                        : "跨卷复制 \(outcome.copied.count) 个（源保留）")
        }
        if !outcome.movedCompanions.isEmpty { note.append("歌词 / 封面 \(outcome.movedCompanions.count) 个") }
        if !outcome.createdDirectories.isEmpty { note.append("新建 \(outcome.createdDirectories.count) 个目录") }
        if !outcome.removedEmptyDirectories.isEmpty {
            note.append("删掉 \(outcome.removedEmptyDirectories.count) 个空目录")
        }
        refreshListAfterOrganize(outcome.summary,
                                 removed: outcome.vanishedOldURLs,
                                 added: outcome.allNewURLs,
                                 title: title,
                                 extraNote: note.isEmpty ? nil : "（" + note.joined(separator: "，") + "）")
    }

    /// 整理 / 撤消整理之后把列表对上。
    ///
    /// 行的 id 就是 URL，换了位置等于换了身份，所以只能「移除旧行 + 重新导入新路径」。
    /// 这里只用 AppModel 的公开动作，不去碰它私有的 `allRows` 与索引 —— 与
    /// `AppModel+Rename.finishRename` 同一套做法。
    private func refreshListAfterOrganize(_ summary: BatchSummary,
                                          removed: [URL],
                                          added: [URL],
                                          title: String,
                                          extraNote: String?) {
        isBusy = false
        progress = nil

        let known = removed.filter { row(id: $0) != nil }
        if !known.isEmpty {
            selection = Set(known)
            removeSelectedItems()
        }
        if !added.isEmpty { importURLs(added) }

        if summary.failed > 0 {
            let detail = summary.failures.prefix(8)
                .map { "· \($0.url.lastPathComponent)：\($0.error.localizedDescription)" }
                .joined(separator: "\n")
            alert = AlertBox(title: "\(title)：\(summary.description)", message: detail, isError: true)
        }

        // importURLs 是异步的，`finishImport` 会把 statusMessage 改成「已添加 N 个文件」。
        // 等它落地后再把本次统计压回去，否则用户只看得到导入文案、看不到成功/失败数。
        let text = summary.description + (extraNote ?? "")
        Task { @MainActor [weak self] in
            for _ in 0..<400 {
                guard let self, self.isBusy else { break }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            self?.statusMessage = "\(title)：\(text)"
        }
    }
}
