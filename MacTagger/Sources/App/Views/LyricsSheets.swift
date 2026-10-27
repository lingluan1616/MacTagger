//
//  LyricsSheets.swift
//  MacTagger — 歌词的四个子窗口
//
//  对应原版：FormLyric（编辑 + 五个变换）、FormLyricAdjustTimetag（调整时间轴）、
//           FormFindReplace（查找替换）、FormLyricSearch（从网络搜索）、
//           以及批量下载复核与「另存为 Lrc」选项。
//
//  这些窗体此前只有模型层（AppModel+Lyrics 的四个 @Published 状态），
//  界面从未接上 —— 歌词菜单点了没有任何反应。本次一并补齐。
//
//  骨架与其余 sheet 一致：SheetTitleBar → 内容 → SheetButtonBar。
//

import SwiftUI
import AppKit

// MARK: - 1. 编辑歌词（FormLyric + FormLyricAdjustTimetag + FormFindReplace）

struct LyricsEditorSheet: View {

    let context: LyricsEditorContext

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var lyrics: LyricsSettings
    @Environment(\.dismiss) private var dismiss

    @StateObject private var controller = LyricsTextController()
    @State private var text: String = ""
    @State private var showFind = false
    @State private var showTimeAdjust = false
    @State private var shiftSeconds: Double = 0.5
    /// 「另存为文件…」菜单里的「歌词文件选项…」。挂在本 sheet **里面**：根上那张
    /// （`LyricsFileOptionsState.shared`）在编辑窗开着时会被 AppKit 排队，关窗后才弹（见 `LyricsFileSaveToggle`）。
    @State private var showFileOptionsSheet = false

    var body: some View {
        VStack(spacing: 0) {
            SheetTitleBar(systemImage: "text.quote",
                          title: "编辑歌词",
                          subtitle: subtitle) {
                HStack(spacing: Theme.Spacing.xs) {
                    Chip(text: "\(controller.lineCount) 行")
                    if controller.timestampCount > 0 {
                        Chip(text: "\(controller.timestampCount) 个时间轴", systemImage: "clock")
                    }
                }
            }

            transformBar

            if showTimeAdjust { timeAdjustBar }
            if showFind { findReplaceBar }

            LyricsSourceEditor(text: $text, controller: controller)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            SheetButtonBar {
                Text("第 \(controller.caretLine) 行 / 共 \(controller.lineCount) 行")
                    .font(Theme.Typo.digitsSmall)
                    .foregroundStyle(.secondary)
                Spacer()
                // 「另存为…」：四种格式直接点，位置/命名/编码走「歌词文件选项」。
                Menu {
                    ForEach(LyricsFileFormat.allCases) { f in
                        Button(f.localizedName) { saveAsFile(format: f) }
                    }
                    Divider()
                    Button("歌词文件选项…") { showFileOptionsSheet = true }
                } label: {
                    Label("另存为文件…", systemImage: "square.and.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || model.focusRow == nil)
                .help("把当前编辑框里的歌词按所选格式写成文件，不影响标签")
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(applyTitle) {
                    model.applyLyricsText(text, to: context.targets)
                    dismiss()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .help("把歌词写入工作副本（⌘⏎），之后按「保存标签」落盘")
            }
        }
        .frame(width: Theme.Size.sheetWide, height: 640)
        .onAppear { text = context.initialText }
        .lyricsFileOptionsSheet(isPresented: $showFileOptionsSheet)
    }

    private var subtitle: String {
        var parts: [String] = []
        let t = context.title.trimmingCharacters(in: .whitespaces)
        let a = context.artist.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { parts.append("《\(t)》") }
        if !a.isEmpty { parts.append(a) }
        let named = parts.joined(separator: " — ")
        guard context.isMultiple else { return named.isEmpty ? context.fileName : named }
        // 多选时这扇窗其实是「一份文本 → 覆盖 N 个文件」：文本取自焦点行
        // （`presentLyricsEditor` 在各行歌词不一致时的兜底），写回却覆盖全部选中项。
        // 「现在编的是谁」与「待会儿动谁」必须都写在脸上 —— 从前只说了后者，
        // 前者要靠用户自己猜标题属于哪一首。
        var s = "当前：\(context.fileName)"
        if !named.isEmpty { s += "（\(named)）" }
        s += " · 应用后会覆盖全部 \(context.targets.count) 个选中文件"
        return s
    }

    private var applyTitle: String {
        context.isMultiple ? "应用到 \(context.targets.count) 个文件" : "应用"
    }

    /// 把编辑框里的当前文本按指定格式另存成文件。落点归属行取焦点行。
    private func saveAsFile(format: LyricsFileFormat) {
        guard let row = model.focusRow else { return }
        model.saveLyricsFile(text: text, for: row, formatOverride: format)
    }

    // MARK: 变换条（原版 FormLyric 的五个变换）

    private var transformBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Spacing.xs) {
                transformButton("去掉时间轴", "clock.badge.xmark",
                                help: "删除每一行的 [mm:ss.xx]，只留纯文本") {
                    $0.removingTimestamps()
                }
                transformButton("格式化时间轴", "clock.badge.checkmark",
                                help: "把时间轴统一成 \(lyrics.millisecondDigits) 位毫秒的标准写法") {
                    $0.formattingTimestamps()
                }
                transformButton("去掉空行", "arrow.up.and.line.horizontal.and.arrow.down",
                                help: "删除没有文字的行") {
                    $0.removingBlankLines()
                }
                transformButton("去掉头部标签", "tag.slash",
                                help: "删除 [ti:] [ar:] [al:] 这类头部标签") {
                    $0.removingHeaderTags()
                }
                transformButton("按时间排序", "arrow.up.arrow.down",
                                help: "按时间轴重新排列所有行") {
                    $0.sortedByTime()
                }

                Divider().frame(height: 16)

                Toggle(isOn: $showTimeAdjust) {
                    Label("调整时间轴", systemImage: "timer")
                }
                .toggleStyle(.button)
                .help("整体提前或延后所有时间轴")

                Toggle(isOn: $showFind) {
                    Label("查找替换", systemImage: "magnifyingglass")
                }
                .toggleStyle(.button)
                .help("在歌词里查找与替换")

                Spacer()
            }
            .labelStyle(.titleAndIcon)
            .controlSize(.small)
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.vertical, Theme.Spacing.s)
            Divider()
        }
    }

    private func transformButton(_ title: String, _ symbol: String, help: String,
                                 _ body: @escaping (LrcDocument) -> LrcDocument) -> some View {
        Button {
            let doc = LrcDocument.parse(text)
            text = body(doc).render(millisecondDigits: lyrics.millisecondDigits)
        } label: {
            Label(title, systemImage: symbol)
        }
        .help(help)
    }

    // MARK: 调整时间轴（FormLyricAdjustTimetag）

    private var timeAdjustBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Spacing.m) {
                Text("整体偏移")
                    .font(Theme.Typo.fieldLabel)
                    .foregroundStyle(.secondary)

                Stepper(value: $shiftSeconds, in: 0.05...60, step: 0.05) {
                    Text(String(format: "%.2f 秒", shiftSeconds))
                        .font(Theme.Typo.digits)
                        .frame(width: 76, alignment: .leading)
                }
                .fixedSize()

                Button {
                    shift(by: -shiftSeconds)
                } label: {
                    Label("提前", systemImage: "backward.end")
                }
                .help("所有时间轴减去该秒数（歌词出现得更早）")

                Button {
                    shift(by: shiftSeconds)
                } label: {
                    Label("延后", systemImage: "forward.end")
                }
                .help("所有时间轴加上该秒数（歌词出现得更晚）")

                Divider().frame(height: 16)

                Text("毫秒位数")
                    .font(Theme.Typo.fieldLabel)
                    .foregroundStyle(.secondary)
                Picker("", selection: $lyrics.millisecondDigits) {
                    Text("2 位").tag(2)
                    Text("3 位").tag(3)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()

                Spacer()
            }
            .controlSize(.small)
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.vertical, Theme.Spacing.s)
            .background(Theme.Colors.chipFill)
            Divider()
        }
    }

    private func shift(by seconds: TimeInterval) {
        let doc = LrcDocument.parse(text)
        text = doc.shiftingTime(by: seconds).render(millisecondDigits: lyrics.millisecondDigits)
    }

    // MARK: 查找替换（FormFindReplace）

    private var findReplaceBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Spacing.s) {
                TextField("查找", text: $controller.findText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .onSubmit { controller.findNext() }

                Button { controller.findPrevious() } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(controller.findText.isEmpty)
                .help("上一个匹配")

                Button { controller.findNext() } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(controller.findText.isEmpty)
                .help("下一个匹配")

                Divider().frame(height: 16)

                TextField("替换为", text: $controller.replaceText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)

                Button("替换") { controller.replaceCurrentAndFindNext() }
                    .disabled(controller.findText.isEmpty)
                    .help("替换当前匹配并跳到下一个")

                Button("全部替换") { controller.replaceAll() }
                    .disabled(controller.findText.isEmpty)
                    .help("替换全部匹配")

                Toggle("区分大小写", isOn: $controller.matchCase)
                    .toggleStyle(.checkbox)

                Spacer()

                if !controller.findText.isEmpty {
                    Text(controller.findStatus.isEmpty
                         ? "\(controller.matchCount()) 处匹配"
                         : controller.findStatus)
                        .font(Theme.Typo.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .controlSize(.small)
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.vertical, Theme.Spacing.s)
            .background(Theme.Colors.chipFill)
            Divider()
        }
    }
}

// MARK: - 2. 从网络搜索歌词（FormLyricSearch）

@MainActor
final class LyricsSearchModel: ObservableObject {

    @Published var candidates: [LyricsCandidate] = []
    @Published var selectedID: UUID?
    @Published var isSearching = false
    @Published var statusText = "输入标题与艺术家后开始搜索"
    @Published var errorText: String?
    /// 逐源结果条：每个歌词源这一轮是「有 n 条 / 0 条 / 挂了」。
    /// 搜出 0 条时，它是唯一能回答「是没这首歌，还是源挂了」的东西。
    @Published var outcomes: [SourceOutcome] = []

    private var task: Task<Void, Never>?

    var selected: LyricsCandidate? {
        candidates.first { $0.id == selectedID } ?? candidates.first
    }

    func search(title: String, artist: String, filename: String, duration: TimeInterval,
                sourceIDs: [String], limit: Int, skipInstrumental: Bool) {
        task?.cancel()
        let query = TrackQuery(title: title.isEmpty ? nil : title,
                               artist: artist.isEmpty ? nil : artist,
                               filename: filename,
                               duration: duration)
        guard !query.isEmpty else {
            statusText = "请至少填写标题或艺术家"
            return
        }
        guard !sourceIDs.isEmpty else {
            errorText = "没有启用任何提供歌词的来源。"
            return
        }

        isSearching = true
        errorText = nil
        statusText = "正在搜索…"
        candidates = []
        selectedID = nil
        outcomes = []

        task = Task { [weak self] in
            let (_, outcome) = await LyricsService.bestLyrics(
                for: query, sourceIDs: sourceIDs,
                limitPerSource: limit, skipInstrumental: skipInstrumental)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.isSearching = false
                // 有词的排前面，其次比匹配分。
                self.candidates = outcome.candidates.sorted { a, b in
                    let ax = (a.bundle?.isEmpty == false) ? 1 : 0
                    let bx = (b.bundle?.isEmpty == false) ? 1 : 0
                    return ax != bx ? ax > bx : a.score > b.score
                }
                self.selectedID = self.candidates.first?.id
                self.outcomes = outcome.sourceOutcomes
                self.errorText = outcome.errorSummary
                self.statusText = self.candidates.isEmpty
                    ? "没有搜到候选"
                    : "找到 \(self.candidates.count) 条候选"
                    + (outcome.filteredInstrumental > 0
                       ? "，已滤掉 \(outcome.filteredInstrumental) 条伴奏版" : "")
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isSearching = false
        statusText = "已取消"
    }
}

struct LyricsSearchSheet: View {

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var lyrics: LyricsSettings
    @Environment(\.dismiss) private var dismiss

    @StateObject private var search = LyricsSearchModel()
    @State private var title = ""
    @State private var artist = ""
    /// 「保存为文件…」菜单里的「歌词文件选项…」。挂在本 sheet **里面**（理由同编辑窗，见 `LyricsFileSaveToggle`）。
    @State private var showFileOptionsSheet = false

    private var preview: String {
        guard let bundle = search.selected?.bundle else { return "" }
        return LyricsService.merge(bundle, options: lyrics.mergeOptions)
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetTitleBar(systemImage: "magnifyingglass",
                          title: "从网络搜索歌词",
                          subtitle: "选中的候选已把歌词一并取回。切换合并格式只是重新渲染，不会再联网。")

            multiSelectionNotice

            queryBar

            if !search.outcomes.isEmpty {
                SourceOutcomeBar(outcomes: search.outcomes,
                                 trailingNote: "共 \(search.candidates.count) 条候选")
                    .padding(.horizontal, Theme.Spacing.xl)
                    .padding(.bottom, Theme.Spacing.xs)
                    .overlay(alignment: .bottom) { Divider().opacity(0.4) }
            }

            HStack(spacing: 0) {
                candidateList
                Divider()
                previewPane
            }
            .frame(maxHeight: .infinity)

            mergeOptionsBar

            SheetButtonBar {
                Text(search.statusText)
                    .font(Theme.Typo.caption)
                    .foregroundStyle(search.errorText == nil ? Color.secondary : Theme.Colors.warning)
                    .lineLimit(1).truncationMode(.tail)
                    .help([search.statusText, search.errorText].compactMap { $0 }
                            .joined(separator: "\n"))
                Spacer()
                // 只保存文件、不碰标签：给「我只要一份 .lrc 放歌旁边」这种用法。
                Menu {
                    ForEach(LyricsFileFormat.allCases) { f in
                        Button(f.localizedName) { saveToFile(format: f) }
                    }
                    Divider()
                    Button("歌词文件选项…") { showFileOptionsSheet = true }
                } label: {
                    Label("保存为文件…", systemImage: "square.and.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || model.focusRow == nil)
                .help("按「歌词文件选项」把这条候选写成歌词文件，不改标签")
                Button("取消") { search.cancel(); dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("应用歌词") {
                    model.applyLyricsText(preview)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("写入当前选中文件的工作副本，之后按「保存标签」落盘")
            }
        }
        .frame(width: Theme.Size.sheetWide, height: 620)
        .onAppear(perform: prefill)
        .lyricsFileOptionsSheet(isPresented: $showFileOptionsSheet)
    }

    private func prefill() {
        guard let row = model.focusRow else { return }
        title = row.draft.title ?? ""
        artist = row.draft.artist ?? ""
        runSearch()
    }

    /// 把当前预览（含已合并的翻译）写成歌词文件。带上 bundle，增强 LRC 才有逐字可用。
    private func saveToFile(format: LyricsFileFormat) {
        guard let row = model.focusRow else { return }
        model.saveLyricsFile(text: preview,
                             bundle: search.selected?.bundle,
                             for: row,
                             formatOverride: format)
    }

    private func runSearch() {
        guard let row = model.focusRow else { return }
        search.search(title: title, artist: artist,
                      filename: row.file.url.deletingPathExtension().lastPathComponent,
                      duration: row.file.technical.duration,
                      sourceIDs: lyrics.activeSourceIDs,
                      limit: lyrics.limitPerSource,
                      skipInstrumental: lyrics.skipInstrumental)
    }

    // MARK: 多选提示条

    /// 这扇窗是**单曲**语义：一组查询条、一列候选、一版预览，天生只搜得了一首。
    /// 顶栏的「歌词」按钮已经按选中数分流（只有正好选中 1 首才开这扇窗），
    /// 但菜单「歌词 › 从网络搜索歌词…」与检查器歌词卡的「搜索歌词」保持单曲语义不变，
    /// 从那两处多选进来时，**必须在这里说清楚只搜了哪一首**，
    /// 并把「其实我想要 N 首都下」这条路摆在旁边一键可达 —— 不能让人以为 N 首都搜了。
    @ViewBuilder
    private var multiSelectionNotice: some View {
        if model.selection.count > 1 {
            HStack(spacing: Theme.Spacing.s) {
                Label {
                    Text("已选 \(model.selection.count) 首，这里只搜索当前这 1 首"
                         + "（\(model.focusRow?.fileName ?? "—")）。")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(Theme.Typo.caption)
                .foregroundStyle(Theme.Colors.warning)

                Spacer(minLength: Theme.Spacing.s)

                Button("改为批量下载这 \(model.selection.count) 首") {
                    // 先收掉在途请求再关窗：这扇窗一关，它的搜索结果就没人要了。
                    search.cancel()
                    dismiss()
                    model.startLyricsBatchDownload()
                }
                .controlSize(.small)
                .fixedSize()
                .help("关掉这扇窗，改为对选中的 \(model.selection.count) 首逐个联网搜索并下载歌词，"
                      + "完成后出一张复核清单，勾选后才写入")
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Colors.warning.opacity(0.10))
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    // MARK: 查询条

    private var queryBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Spacing.s) {
                Text("标题").font(Theme.Typo.fieldLabel).foregroundStyle(.secondary)
                TextField("", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { runSearch() }

                Text("艺术家").font(Theme.Typo.fieldLabel).foregroundStyle(.secondary)
                TextField("", text: $artist)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { runSearch() }

                if search.isSearching {
                    ProgressView().controlSize(.small)
                    Button("停止") { search.cancel() }
                } else {
                    Button {
                        runSearch()
                    } label: {
                        Label("搜索", systemImage: "magnifyingglass")
                    }
                    .help("联网搜索（回车同样可以）")
                }
            }
            .controlSize(.small)
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.vertical, Theme.Spacing.s)
            Divider()
        }
    }

    // MARK: 候选列表

    private var candidateList: some View {
        Group {
            if search.candidates.isEmpty {
                EmptyStateView(systemImage: "text.magnifyingglass",
                               title: search.isSearching ? "正在搜索…" : "没有候选",
                               message: search.isSearching ? nil : "换个标题或艺术家再试一次")
            } else {
                List(search.candidates, selection: $search.selectedID) { c in
                    candidateRow(c).tag(c.id)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .frame(width: 320)
    }

    private func candidateRow(_ c: LyricsCandidate) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            HStack(spacing: Theme.Spacing.xs) {
                StatusDot(color: (c.bundle?.isEmpty == false) ? Theme.Colors.matched : Theme.Colors.ignored)
                Text(c.title.isEmpty ? "未知标题" : c.title)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: Theme.Spacing.xs)
                Text(String(format: "%.2f", c.score))
                    .font(Theme.Typo.digitsSmall)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: Theme.Spacing.xs) {
                Text(c.artist.isEmpty ? "未知艺术家" : c.artist)
                    .font(Theme.Typo.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: Theme.Spacing.xs)
                Chip(text: SourceBootstrap.displayName(c.sourceID))
                if c.hasTranslation { Chip(text: "译词", tinted: true) }
            }
        }
        .padding(.vertical, Theme.Spacing.xxs)
        .contentShape(Rectangle())
        // 标题与艺术家两行都是尾截断，长的只剩个头；tooltip 给全。
        .help([c.title.isEmpty ? "未知标题" : c.title,
               c.artist.isEmpty ? "未知艺术家" : c.artist,
               c.album.isEmpty ? nil : "专辑：" + c.album,
               SourceBootstrap.displayName(c.sourceID)]
                .compactMap { $0 }.joined(separator: "\n"))
    }

    // MARK: 预览

    private var previewPane: some View {
        Group {
            if preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                EmptyStateView(systemImage: "doc.plaintext",
                               title: "这条候选没有歌词",
                               message: "左侧带绿点的候选才带歌词")
            } else {
                ScrollView {
                    Text(preview)
                        .font(Theme.Typo.monoSmall)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Theme.Spacing.m)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 合并选项

    private var mergeOptionsBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: Theme.Spacing.m) {
                Toggle("合并翻译", isOn: $lyrics.mergeTranslation)
                    .toggleStyle(.checkbox)

                Picker("", selection: Binding(
                    get: { lyrics.mergeFormat },
                    set: { lyrics.mergeFormat = $0 })) {
                    ForEach(TranslationMergeFormat.allCases) { f in
                        Text(f.localizedName).tag(f)
                    }
                }
                .labelsHidden()
                .frame(width: 240)
                .disabled(!lyrics.mergeTranslation)

                Toggle("只要翻译", isOn: $lyrics.translationOnly)
                    .toggleStyle(.checkbox)
                    .disabled(!lyrics.mergeTranslation)
                    .help("有翻译时丢掉原词，只保留翻译")

                Spacer()

                Toggle("过滤伴奏版", isOn: $lyrics.skipInstrumental)
                    .toggleStyle(.checkbox)
                    .help("下次搜索生效")
            }
            .controlSize(.small)
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.vertical, Theme.Spacing.s)
            .background(Theme.Colors.chipFill)
        }
    }
}

// MARK: - 3. 批量下载复核

struct LyricsBatchReviewSheet: View {

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @State private var expanded: Set<URL> = []
    /// 「选项…」打开的歌词文件选项。挂在本 sheet **里面**（见 `LyricsFileSaveToggle` 的说明）。
    @State private var showFileOptionsSheet = false

    private enum Col {
        static let check: CGFloat = 18
        static let status: CGFloat = 82
        static let file: CGFloat = 268
        static let source: CGFloat = 78
        static let score: CGFloat = 46
    }

    var body: some View {
        VStack(spacing: 0) {
            if let review = model.lyricsBatchReview {
                SheetTitleBar(systemImage: "quote.bubble",
                              title: "复核下载到的歌词",
                              subtitle: "勾选要采纳的项，在底部选「写入标签」「保存为歌词文件」后再应用。展开一行可比对原歌词与新歌词。") {
                    Chip(text: String(format: "耗时 %.1f 秒", review.elapsed))
                }

                // 逐源结果条：整批里每个歌词源搜到了多少条候选、哪个源整轮在报错。
                // 「一首都没下到」时，它是唯一能分开「这些歌线上没词」与「源挂了」的东西。
                // 数据来自 `review.sourceOutcomes`（每首的 `LyricsSearchOutcome.sourceOutcomes`
                // 经 `SourceOutcomeAggregator.merge` 聚合），不再由界面从复核行反推。
                if !review.sourceOutcomes.isEmpty {
                    SourceOutcomeBar(outcomes: review.sourceOutcomes,
                                     trailingNote: "下载成功 \(review.downloadedCount)/\(review.items.count)")
                        .padding(.horizontal, Theme.Spacing.xl)
                        .padding(.vertical, Theme.Spacing.xs)
                        .overlay(alignment: .bottom) { Divider().opacity(0.4) }
                }

                columnHeader
                list(review)

                LyricsBatchFooter(
                    counts: .init(downloaded: review.downloadedCount, total: review.items.count,
                                  selectable: review.writableCount, accepted: review.acceptedCount),
                    writeTags: Binding(get: { model.lyricsBatchReview?.writeTags ?? true },
                                       set: { model.setLyricsBatchWriteTags($0) }),
                    saveFiles: $settings.lyricsFile.enabled,
                    fileOptions: settings.lyricsFile,
                    phase: review.phase,
                    progress: model.progress.map { (completed: $0.completed, total: $0.total) },
                    actions: .init(
                        selectAll: { model.setAllLyricsAccepted(true) },
                        selectNone: { model.setAllLyricsAccepted(false) },
                        selectOnlyEmpty: { model.selectOnlyEmptyTargetLyrics() },
                        showOptions: { showFileOptionsSheet = true },
                        revealFile: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
                        discard: { model.discardLyricsBatchReview() },
                        apply: { model.applyLyricsBatchSelection() },
                        close: { model.closeLyricsBatchReview() }))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: Theme.Size.sheetWide, height: 620)
        .lyricsFileOptionsSheet(isPresented: $showFileOptionsSheet)
    }

    private var columnHeader: some View {
        HStack(spacing: Theme.Spacing.s) {
            // 高度必须限死：Color.clear 纵向可以无限伸展，
            // 只给宽度会让整条表头跟着下面的滚动区一起平分高度，撑出一大块空白。
            Color.clear.frame(width: Col.check, height: 1)
            Text("状态").frame(width: Col.status, alignment: .leading)
            Text("文件 / 匹配到的曲目").frame(width: Col.file, alignment: .leading)
            Text("来源").frame(width: Col.source, alignment: .leading)
            Text("匹配分").frame(width: Col.score, alignment: .trailing)
            Text("说明").frame(minWidth: 150, alignment: .leading)
            Spacer()
        }
        .font(Theme.Typo.sectionHeader)
        .foregroundStyle(.secondary)
        .tracking(0.4)
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.xs)
        .background(Theme.Colors.chipFill)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func list(_ review: LyricsBatchReview) -> some View {
        List {
            ForEach(review.items) { item in
                VStack(alignment: .leading, spacing: 0) {
                    row(item, review: review)
                    if expanded.contains(item.id) {
                        detail(item)
                            .padding(.leading, Col.check + Col.status)
                            .padding(.trailing, Theme.Spacing.m)
                            .padding(.vertical, Theme.Spacing.s)
                    }
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .frame(maxHeight: .infinity)
    }

    private func row(_ item: LyricsBatchItem, review: LyricsBatchReview) -> some View {
        // 完成态：已应用的行改报「已存文件 / 已写标签 / 标签+文件」与落点（BL 轮）。
        let outcome = review.outcomes[item.id]
        return HStack(spacing: Theme.Spacing.s) {
            Toggle("", isOn: Binding(
                // 当前写入方式下不可勾的行一律画成空勾（它本来也不会被应用，见 `acceptedItems`），
                // 免得在「仅存文件」里勾过、切回「写入标签」后留一个灰掉的对勾。
                get: { item.accepted && review.isSelectable(item) },
                set: { model.setLyricsAccepted(item.id, $0) }))
                .toggleStyle(.checkbox).labelsHidden()
                // 能不能勾随写入方式变：写标签要求新词与标签里的不同、且不是「标签已有歌词、未开覆盖」的行；
                // 仅存文件只要求有词（BL2 轮：标签已有词的行也能单独存文件）。
                .disabled(!review.isReviewing || !review.isSelectable(item))
                .frame(width: Col.check)

            HStack(spacing: Theme.Spacing.xs) {
                StatusDot(color: outcome.map { outcomeColor($0.tone) } ?? statusColor(item.status))
                Text(outcome?.label ?? item.status.label)
                    .font(Theme.Typo.caption)
                    .foregroundStyle(outcome == nil ? Color.secondary : Color.primary)
                    .lineLimit(1)
            }
            .frame(width: Col.status, alignment: .leading)

            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(item.fileName).lineLimit(1).truncationMode(.middle)
                Text(item.matchDescription)
                    .font(Theme.Typo.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            .frame(width: Col.file, alignment: .leading)
            .help(item.fileName + "\n" + item.matchDescription)

            Text(item.sourceName ?? "—")
                .font(Theme.Typo.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: Col.source, alignment: .leading)

            Text(item.score > 0 ? String(format: "%.2f", item.score) : "—")
                .font(Theme.Typo.digitsSmall)
                .foregroundStyle(item.score >= 0.85 ? Theme.Colors.matched : Color.secondary)
                .frame(width: Col.score, alignment: .trailing)

            HStack(spacing: Theme.Spacing.xs) {
                if item.hasTranslation {
                    Image(systemName: "character.book.closed")
                        .font(Theme.Typo.badge).foregroundStyle(.tertiary)
                        .help("含翻译")
                }
                Text(outcome?.note ?? review.note(for: item))
                    .font(Theme.Typo.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(outcome?.note ?? review.noteHelp(for: item))
            }
            .frame(minWidth: 150, alignment: .leading)

            Spacer(minLength: Theme.Spacing.xs)

            Button { toggleExpanded(item.id) } label: {
                Image(systemName: expanded.contains(item.id) ? "chevron.down" : "chevron.right")
                    .font(Theme.Typo.caption)
            }
            .buttonStyle(.borderless)
            .disabled(item.newLyrics.isEmpty && item.oldLyrics.isEmpty)
            .help("展开比对原歌词与新歌词")
        }
        .padding(.vertical, Theme.Spacing.xxs)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { toggleExpanded(item.id) }
    }

    private func toggleExpanded(_ id: URL) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    /// 展开：左「原歌词」右「新歌词」两列对照。
    private func detail(_ item: LyricsBatchItem) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            lyricsColumn("原歌词", item.oldLyrics, tinted: false)
            Image(systemName: "arrow.right")
                .font(Theme.Typo.badge)
                .foregroundStyle(.tertiary)
                .padding(.top, Theme.Spacing.xl)
            lyricsColumn("新歌词", item.newLyrics, tinted: true)
        }
        .padding(Theme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.chipFill,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
    }

    private func lyricsColumn(_ title: String, _ text: String, tinted: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(title).font(Theme.Typo.badge).foregroundStyle(.secondary)
            if text.isEmpty {
                Text("（空）")
                    .font(Theme.Typo.monoSmall)
                    .foregroundStyle(.tertiary)
            } else {
                ScrollView {
                    Text(text)
                        .font(Theme.Typo.monoSmall)
                        .foregroundStyle(tinted ? Color.accentColor : Color.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 132)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func outcomeColor(_ t: LyricsBatchItemOutcome.Tone) -> Color {
        switch t {
        case .ok:      return Theme.Colors.matched
        case .neutral: return Theme.Colors.ignored
        case .failed:  return Theme.Colors.failed
        }
    }

    private func statusColor(_ s: LyricsBatchItem.Status) -> Color {
        switch s {
        case .downloaded: return Theme.Colors.matched
        case .skipped:    return Theme.Colors.ignored
        case .notFound:   return Theme.Colors.ignored
        case .failed:     return Theme.Colors.failed
        case .noQuery:    return Theme.Colors.warning
        }
    }
}

// MARK: - 3b. 复核表脚注：写入方式（BL 轮）
//
// 用户反馈「批量获取歌词的时候好像没有单独下载歌词文件的选项」。原脚注只有一个折叠按钮
// 「歌词文件（格式）」，展开才看得到藏在里面的全局开关，而应用永远先写标签。现在：
//   ☑ 写入标签   ☑ 保存为歌词文件（LRC） [选项…]  LRC · 与音频同目录 · 同名 · UTF-8
// 按钮文案随组合变：「写入标签并保存文件（N）」/「仅保存文件（N）」/「仅写入标签（N）」。

/// 「保存为歌词文件」复选框 +「选项…」+ 设置摘要。批量下载、逐首自动匹配、专辑模式三张复核表共用。
///
/// 复选框直接绑 `settings.lyricsFile.enabled`：勾选/取消即写回偏好，下次记住。
///
/// 「选项…」**不走** `LyricsFileOptionsState.shared`：那张 sheet 挂在窗口根上，而复核表本身就是
/// 一张 sheet —— 根上再要一张会被 AppKit 排队，直到复核表关掉才弹出来（BL 轮离屏实验实测：
/// 请求后窗口仍只有复核表一张 sheet，复核表一关它才出现）。所以由各复核表在**自己里面**
/// 用 `.lyricsFileOptionsSheet(isPresented:)` 再挂一层，内容是同一个 `LyricsFileOptionsSheet`。
struct LyricsFileSaveToggle: View {
    @Binding var isOn: Bool
    let options: LyricsFileOptions
    /// 复选框旁那行小字「LRC · 与音频同目录 · 同名 · UTF-8」。
    var showsSummary = true
    let onOptions: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            Toggle("保存为歌词文件（\(options.format.shortName)）", isOn: $isOn)
                .toggleStyle(.checkbox)
                .help("勾选即记住：批量下载、自动匹配、专辑模式应用时各存一份歌词文件。\n"
                      + options.footerSummaryHelp)
            Button("选项…", action: onOptions)
                .help("格式 / 位置 / 命名 / 编码 / 覆盖")
            if showsSummary {
                Text(options.footerSummary)
                    .font(Theme.Typo.caption)
                    .foregroundStyle(isOn ? Color.secondary : Theme.Colors.placeholderText)
                    .lineLimit(1).truncationMode(.middle)
                    .help(options.footerSummaryHelp)
            }
        }
    }
}

extension View {
    /// 在复核表**里面**挂「歌词文件选项」sheet（为什么不用根上那张，见 `LyricsFileSaveToggle`）。
    func lyricsFileOptionsSheet(isPresented: Binding<Bool>) -> some View {
        sheet(isPresented: isPresented) { LyricsFileOptionsSheet() }
    }
}

/// 复核表按钮栏上方那条浅底横条。批量下载的「写入方式」条与自动匹配 / 专辑模式的
/// 「保存为歌词文件」条共用这一版式（上发丝线 + chipFill 底 + 与 `SheetButtonBar` 同宽的左右边距）。
struct ReviewFooterStrip<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: Theme.Spacing.m) { content }
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.vertical, Theme.Spacing.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Colors.chipFill)
        }
    }
}

/// 逐首自动匹配 / 专辑模式复核表脚注上的「保存为歌词文件」条（BL 轮）。
/// 只在这一轮会写歌词字段时由调用方挂出来；写标签逻辑一概不动，勾了就是 afterBatch 顺带存。
struct LyricsFileSaveStrip: View {
    @Binding var isOn: Bool
    let options: LyricsFileOptions
    let onOptions: () -> Void

    var body: some View {
        ReviewFooterStrip {
            LyricsFileSaveToggle(isOn: $isOn, options: options, onOptions: onOptions)
            Spacer(minLength: 0)
            Text(isOn ? "应用后按上述设置另存，状态栏列出保存数" : "只写标签，不另存歌词文件")
                .font(Theme.Typo.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

/// 批量复核表的脚注：写入方式条 + 按钮栏。
///
/// 拆成独立 View、只收纯值与回调，离屏渲染工装才能把它原样抽出来画三种状态（见 BL 报告）。
struct LyricsBatchFooter: View {

    struct Counts {
        var downloaded = 0
        var total = 0
        /// 当前写入方式下可勾的项数（写标签 = 新词与标签不同；仅存文件 = 有词）。
        var selectable = 0
        var accepted = 0
    }

    struct Actions {
        var selectAll: () -> Void = {}
        var selectNone: () -> Void = {}
        var selectOnlyEmpty: () -> Void = {}
        var showOptions: () -> Void = {}
        var revealFile: (URL) -> Void = { _ in }
        var discard: () -> Void = {}
        var apply: () -> Void = {}
        var close: () -> Void = {}
    }

    let counts: Counts
    @Binding var writeTags: Bool
    @Binding var saveFiles: Bool
    let fileOptions: LyricsFileOptions
    let phase: LyricsBatchPhase
    /// 应用中（写标签）时的进度。
    var progress: (completed: Int, total: Int)? = nil
    let actions: Actions

    private var mode: LyricsBatchApplyMode? {
        LyricsBatchApplyMode(writeTags: writeTags, saveFiles: saveFiles)
    }

    private var isReviewing: Bool {
        if case .reviewing = phase { return true }
        return false
    }

    private var applyTitle: String {
        "\(mode?.actionTitle ?? "应用选中项")（\(counts.accepted)）"
    }

    var body: some View {
        VStack(spacing: 0) {
            modeStrip
            SheetButtonBar {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text("下载成功 \(counts.downloaded) / 共 \(counts.total) 项")
                        .font(Theme.Typo.digitsSmall)
                    Text("\(writeTags ? "可写入" : "可存文件") \(counts.selectable) 项，已勾选 \(counts.accepted) 项")
                        .font(Theme.Typo.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                if case .done = phase {
                    Button("完成", action: actions.close)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                } else {
                    Group {
                        Button("全选", action: actions.selectAll)
                        Button("全不选", action: actions.selectNone)
                        Button("只选原本没词的", action: actions.selectOnlyEmpty)
                            .help("最保守的一键勾选：不覆盖任何已有歌词")
                    }
                    .disabled(!isReviewing)
                    Divider().frame(height: 18)
                    Button("放弃", action: actions.discard)
                        .keyboardShortcut(.cancelAction)
                        .disabled(!isReviewing)
                    Button(applyTitle, action: actions.apply)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(!isReviewing || mode == nil || counts.accepted == 0)
                        .help(mode == nil ? "「写入标签」与「保存为歌词文件」至少勾一项"
                                          : "按上面两个复选框的组合应用勾选项")
                }
            }
        }
    }

    /// 按钮栏上方那一条：复核中是两个复选框，应用中是进度，完成后是总账。
    private var modeStrip: some View {
        ReviewFooterStrip {
            switch phase {
            case .reviewing:
                Toggle("写入标签", isOn: $writeTags)
                    .toggleStyle(.checkbox)
                    .help("把勾选的歌词写进音频文件的歌词标签（写前记历史，可撤消）")
                LyricsFileSaveToggle(isOn: $saveFiles, options: fileOptions,
                                     onOptions: actions.showOptions)
                Spacer(minLength: 0)
                if mode == nil {
                    Label("至少勾一项", systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.Typo.caption)
                        .foregroundStyle(Theme.Colors.warning)
                }

            case .applying(let m):
                ProgressView().controlSize(.small)
                Text(m == .filesOnly
                     ? "正在保存歌词文件…"
                     : "正在写入标签…" + (progress.map { "（\($0.completed)/\($0.total)）" } ?? ""))
                    .font(Theme.Typo.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer(minLength: 0)

            case .done(let c):
                let bad = c.tagFailed + (c.files?.failed ?? 0) > 0
                Image(systemName: bad ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(bad ? Theme.Colors.warning : Theme.Colors.matched)
                Text(c.line)
                    .font(Theme.Typo.caption)
                    .monospacedDigit()
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let f = c.firstSavedFile {
                    Button("在访达中显示") { actions.revealFile(f) }
                        .buttonStyle(.link)
                        .font(Theme.Typo.caption)
                        .help(f.path)
                }
            }
        }
    }
}

// MARK: - 4. 另存为歌词文件的选项

struct LrcExportOptionsSheet: View {

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    private var count: Int { model.lrcExportCandidates.count }
    private var format: LyricsFileFormat { settings.lyricsFile.format }

    var body: some View {
        VStack(spacing: 0) {
            SheetTitleBar(systemImage: "square.and.arrow.down.on.square",
                          title: "另存为歌词文件",
                          subtitle: "将为 \(count) 个有歌词的文件各写出一份 \(format.shortName)。") {
                Chip(text: ".\(format.fileExtension)", tinted: true)
            }

            ScrollView {
                // 与「歌词文件选项」菜单、自动匹配窗、复核窗共用的同一份面板。
                LyricsFileOptionsView()
                    .padding(Theme.Spacing.l)
            }

            SheetButtonBar {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存 \(count) 个歌词文件") {
                    dismiss()
                    model.performExportLRC()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(count == 0)
            }
        }
        .frame(width: Theme.Size.sheetMedium, height: 620)
    }
}

// MARK: - 5. 歌词文件选项（四种格式 / 四种位置 / 命名 / 编码 / 覆盖）
//
// 唯一的一份选项界面。搜索窗、批量复核窗、另存窗、自动匹配窗、菜单里的独立小窗
// 全部复用这一个 View，绑的都是 `AppSettings.lyricsFile` —— 用户在哪儿改都一样。

struct LyricsFileOptionsView: View {

    /// 紧凑模式：去掉说明文字，塞进复核窗底部这类高度紧张的地方用。
    var compact: Bool = false
    /// 是否显示「保存歌词文件」总开关。菜单里的一次性「另存为…」用不到它。
    var showsEnableToggle: Bool = true

    @EnvironmentObject private var settings: AppSettings
    @State private var subfolder = ""

    private var options: LyricsFileOptions { settings.lyricsFile }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? Theme.Spacing.m : Theme.Spacing.l) {
            if showsEnableToggle {
                card("保存歌词文件") {
                    Toggle("下载或保存歌词时，同时保存一份歌词文件", isOn: $settings.lyricsFile.enabled)
                        .toggleStyle(.checkbox)
                    if !compact {
                        Text("与批量下载、自动匹配、专辑模式复核表脚注的「保存为歌词文件」复选框是同一个开关；"
                             + "保存标签时也按它顺带存一份。")
                            .font(Theme.Typo.caption)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            card("文件格式") {
                choicePicker {
                    Picker("", selection: $settings.lyricsFile.format) {
                        ForEach(LyricsFileFormat.allCases) { f in
                            Text(f.localizedName).tag(f)
                        }
                    }
                }

                if !compact {
                    Text(options.format.detail)
                        .font(Theme.Typo.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if options.format == .enhancedLrc {
                    Toggle("文件名加 .a2 后缀（写成 名字.a2.lrc）", isOn: $settings.lyricsFile.enhancedUsesA2Suffix)
                        .toggleStyle(.checkbox)
                        .help("默认不加：多数播放器只认 .lrc。加上可以和标准 LRC 并存")
                }
            }

            card("保存位置") {
                choicePicker {
                    Picker("", selection: locationKind) {
                        ForEach(LyricsSaveLocation.Kind.allCases) { k in
                            Text(k.localizedName).tag(k)
                        }
                    }
                }

                if options.location.kind == .songSubfolder {
                    HStack(spacing: Theme.Spacing.s) {
                        Text("子目录名").font(Theme.Typo.fieldLabel).foregroundStyle(.secondary)
                        TextField(LyricsSaveLocation.defaultSubfolderName, text: subfolderName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                    }
                    .controlSize(.small)
                }

                if options.location.kind == .fixedDirectory {
                    HStack(spacing: Theme.Spacing.s) {
                        Text(options.location.directoryURL?.path ?? "（未选择）")
                            .font(Theme.Typo.caption)
                            .foregroundStyle(options.location.directoryURL == nil ? .tertiary : .secondary)
                            .lineLimit(1).truncationMode(.middle)
                            .help(options.location.directoryURL?.path ?? "还没选目录")
                        Spacer()
                        Button("选择目录…") { pickDirectory() }
                            .controlSize(.small)
                    }
                }

                if !compact {
                    Text("「每次询问」只作用于手动的「保存为文件…／另存为…」；跟着保存标签自动落盘时按歌曲所在文件夹写，不会弹面板打断批量保存。")
                        .font(Theme.Typo.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            card("文件名与编码") {
                HStack(spacing: Theme.Spacing.m) {
                    Text("文件名").font(Theme.Typo.fieldLabel).foregroundStyle(.secondary)
                    Picker("", selection: $settings.lyricsFile.naming) {
                        ForEach(LyricsService.LrcFileNaming.allCases) { n in
                            Text(n.localizedName).tag(n)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
                HStack(spacing: Theme.Spacing.m) {
                    Text("编码").font(Theme.Typo.fieldLabel).foregroundStyle(.secondary)
                    Picker("", selection: $settings.lyricsFile.encoding) {
                        ForEach(LyricsFileEncoding.allCases) { e in
                            Text(e.localizedName).tag(e)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
                if !compact {
                    Text("标签缺失时文件名自动退回歌曲文件名，不会产出「 - 」这种残缺名；给旧播放器用就选 GB18030。")
                        .font(Theme.Typo.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            card("覆盖与翻译") {
                Toggle("目标文件已存在时覆盖", isOn: $settings.lyricsFile.overwriteExisting)
                    .toggleStyle(.checkbox)
                    .help("关闭时遇到同名文件直接跳过，不动已有的歌词文件")
                if !options.overwriteExisting {
                    Text("关闭时：本程序写出的无译文旧文件仍会升级为含译文版；用户改过的文件不动。")
                        .font(Theme.Typo.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("把翻译一起写进文件", isOn: $settings.lyricsFile.includeTranslation)
                    .toggleStyle(.checkbox)
                HStack(spacing: Theme.Spacing.m) {
                    Text("合并格式").font(Theme.Typo.fieldLabel).foregroundStyle(.secondary)
                    Picker("", selection: $settings.lyricsFile.mergeFormat) {
                        ForEach(TranslationMergeFormat.allCases) { f in
                            Text(f.localizedName).tag(f)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 240)
                    .disabled(!options.includeTranslation)
                }
                if !compact {
                    Text("只影响「从歌词源直接存文件」的情形；已经在编辑器里合好的文本原样写出。")
                        .font(Theme.Typo.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear { subfolder = options.location.subfolderName }
    }

    /// 单选组：宽松模式用 radioGroup（一眼看全四个选项），
    /// 紧凑模式换成弹出菜单省高度。两种 pickerStyle 类型不同，只能分支写。
    @ViewBuilder
    private func choicePicker<C: View>(@ViewBuilder _ picker: () -> C) -> some View {
        if compact {
            picker().labelsHidden().pickerStyle(.menu).frame(width: 240, alignment: .leading)
        } else {
            picker().labelsHidden().pickerStyle(.radioGroup)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: 绑定

    private var locationKind: Binding<LyricsSaveLocation.Kind> {
        Binding(
            get: { settings.lyricsFile.location.kind },
            set: { kind in
                // 选「自定义目录」但还没选过目录时，直接把面板端上来；
                // 取消就保持原样，免得单选钮停在一个写不出东西的状态上。
                if kind == .fixedDirectory, settings.lyricsFile.location.directoryURL == nil {
                    pickDirectory()
                    return
                }
                settings.lyricsFile.location =
                    settings.lyricsFile.location.changingKind(kind, subfolderName: subfolder)
            })
    }

    private var subfolderName: Binding<String> {
        Binding(
            get: { subfolder },
            set: { v in
                subfolder = v
                let t = v.trimmingCharacters(in: .whitespaces)
                settings.lyricsFile.location =
                    .songSubfolder(name: t.isEmpty ? LyricsSaveLocation.defaultSubfolderName : t)
            })
    }

    private func pickDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "选择歌词文件的保存目录"
        panel.prompt = "选择"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.lyricsFile.location = .fixedDirectory(url)
    }

    @ViewBuilder
    private func card<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: compact ? Theme.Spacing.s : Theme.Spacing.m) {
            SectionHeader(title)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

// MARK: - 歌词文件选项的独立小窗

/// 「歌词」菜单里的「歌词文件选项…」。
///
/// ContentView 已定稿不可改，所以挂载点自带 —— 与 `FilenameRelationSheetsModifier` 同一套路：
/// 在 `MacTaggerApp` 里以 `.modifier(LyricsFileOptionsSheetModifier())` 套在环境注入**里面**。
@MainActor
final class LyricsFileOptionsState: ObservableObject {
    static let shared = LyricsFileOptionsState()
    @Published var isPresented = false
}

struct LyricsFileOptionsSheetModifier: ViewModifier {
    @ObservedObject private var state = LyricsFileOptionsState.shared
    func body(content: Content) -> some View {
        content.sheet(isPresented: $state.isPresented) { LyricsFileOptionsSheet() }
    }
}

struct LyricsFileOptionsSheet: View {

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            SheetTitleBar(systemImage: "doc.badge.gearshape",
                          title: "歌词文件选项",
                          subtitle: "自动匹配、批量下载、搜索、编辑器另存、保存标签顺带存，五条路径共用这一份设置。") {
                Chip(text: settings.lyricsFile.format.shortName, tinted: true)
            }

            // BL 轮：说清这份设置管什么、不管什么 —— 「存不存」不在这里定。
            Label("此处设置对批量下载、自动匹配、专辑模式共用；是否保存由各复核表脚注的复选框决定",
                  systemImage: "info.circle")
                .font(Theme.Typo.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.vertical, Theme.Spacing.s)
                .background(Theme.Colors.chipFill)
                .overlay(alignment: .bottom) { Divider() }

            ScrollView {
                LyricsFileOptionsView()
                    .padding(Theme.Spacing.l)
            }

            SheetButtonBar {
                Text(previewHint)
                    .font(Theme.Typo.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(previewHint)
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(width: Theme.Size.sheetMedium, height: 620)
    }

    /// 底栏回显一条示意路径，省得用户靠猜。
    private var previewHint: String {
        let o = settings.lyricsFile
        let ext = o.format == .enhancedLrc && o.enhancedUsesA2Suffix ? "a2." + o.format.fileExtension
                                                                    : o.format.fileExtension
        switch o.location.kind {
        case .songFolder:     return "示例：歌曲所在文件夹/歌名.\(ext)"
        case .songSubfolder:  return "示例：歌曲所在文件夹/\(o.location.subfolderName)/歌名.\(ext)"
        case .fixedDirectory: return "示例：\(o.location.directoryURL?.path ?? "（未选择目录）")/歌名.\(ext)"
        case .askEachTime:    return "手动另存时弹面板选位置；自动落盘时按歌曲所在文件夹"
        }
    }
}
