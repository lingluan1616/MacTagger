//
//  ContentView.swift
//  MacTagger — 主窗口三栏布局
//
//  对应原版 FormMain：左=工作目录、中=文件列表、右=标签编辑面板。
//  顶栏不用原生 NSToolbar，改用自绘的 TopBarView（按设计稿「方向 A」逐值重画）。
//

import SwiftUI
import AppKit

struct ContentView: View {

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var columns: ColumnStore
    @EnvironmentObject private var directories: DirectoryStore
    @EnvironmentObject private var settings: AppSettings

    @State private var showManageDirs = false
    @State private var showHistory = false
    @State private var showColumns = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// 放行过的根级确认框 / 提示框（BO#14）。新请求先过 `admitRootDialogs()` 这一关，
    /// 过了才真的弹；已经弹出来的不会因为后来又开了一张 sheet 被收回去。
    @State private var admittedConfirmID: UUID?
    @State private var admittedAlertID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            // 设计稿（build_directions.py 的窗口装配）把标题栏与 50px 工具栏画在窗口内、
            // 横跨整窗（含侧栏之上），所以顶栏挂在 NavigationSplitView 外层，不是 detail 区里。
            // 配合 .windowStyle(.hiddenTitleBar)：标题栏那 38px 也由 TopBarView 自己画。
            TopBarView(showManageDirs: $showManageDirs,
                       showHistory: $showHistory,
                       showColumns: $showColumns,
                       drawsTitleRow: true,
                       subtitle: navigationSubtitle)

            splitView
        }
        // hiddenTitleBar 下 SwiftUI 仍会保留一条标题栏高度的顶部安全区（实测 32pt），
        // 不让开顶栏就会被压到下面、上方空出一条窗口底色。
        .ignoresSafeArea(.container, edges: .top)
        .sheet(isPresented: $showManageDirs) { ManageDirsSheet() }
        .sheet(isPresented: $showHistory) { TagsHistorySheet() }
        .sheet(isPresented: $showColumns) { CustomColumnsSheet() }
        .sheet(isPresented: $model.showAutoMatchOptions) { AutoMatchOptionsSheet() }
        .sheet(isPresented: Binding(get: { model.autoMatchReview != nil },
                                    set: { if !$0 { model.autoMatchReview = nil } })) {
            AutoMatchReviewSheet()
        }
        // 根级提示框 / 确认框：只弹放行过的那个（见 `admitRootDialogs()`）。
        .alert(item: Binding(get: { model.alert.flatMap { $0.id == admittedAlertID ? $0 : nil } },
                             set: { model.alert = $0 })) { box in
            Alert(title: Text(box.title), message: Text(box.message), dismissButton: .default(Text("好")))
        }
        .confirmationDialog(
            model.confirm?.title ?? "",
            isPresented: Binding(get: { model.confirm != nil && model.confirm?.id == admittedConfirmID },
                                 set: { if !$0 { model.confirm = nil } }),
            presenting: model.confirm
        ) { box in
            Button(box.confirmTitle, role: box.destructive ? .destructive : nil) {
                box.action(); model.confirm = nil
            }
            Button("取消", role: .cancel) { model.confirm = nil }
        } message: { box in
            Text(box.message)
        }
        .onChange(of: model.confirm?.id) { _, id in if id != nil { scheduleAdmission() } }
        .onChange(of: model.alert?.id) { _, id in if id != nil { scheduleAdmission() } }
        // 窗口出现前就已经挂上的（启动时模型自检的提示、关窗期间到的结果）也要过一遍，
        // 否则 onChange 不会为它们触发，永远弹不出来。
        .onAppear { scheduleAdmission() }
        .overlay(alignment: .bottom) { progressOverlay }
        // 接着上次：把持久化的工作目录重新载入。窗口出现时跑一次，
        // 方法自己带幂等判断（列表非空 / 正忙 就直接返回），不会和手动点击撞车。
        .task { model.restoreLastDirectoryIfNeeded() }
    }

    // MARK: 根级确认框 / 提示框的放行（BO#14）

    /// 当前开着的内容 sheet（含本视图自己的三个 `@State` sheet）。
    private var openSheetName: String? {
        if showManageDirs { return "管理目录" }
        if showHistory { return "标签历史" }
        if showColumns { return "自定义显示列" }
        return model.openSheetName
    }

    /// 推到下一拍再判：按钮里「先 dismiss() 再发请求」时，sheet 的开关到那时一定已经落下，
    /// 请求不会被误当成「sheet 还开着」。
    private func scheduleAdmission() {
        DispatchQueue.main.async { admitRootDialogs() }
    }

    /// 根级 `confirm` / `alert` 在别的 sheet 开着时**不排队**（BO#14）：
    /// SwiftUI 会把它们排到那张 sheet 关掉之后才弹 —— 点了没反应、关窗后突然冒出来，
    /// 确认框还带着请求那一刻的旧快照去执行。所以：
    ///   * 没有 sheet 开着 → 放行，照常弹；
    ///   * 有 sheet 开着 → 确认框当场作废（不执行），状态栏说明；提示框改写到状态栏（全文在悬停提示里）。
    private func admitRootDialogs() {
        let sheet = openSheetName
        if let box = model.confirm, box.id != admittedConfirmID {
            if let sheet {
                model.confirm = nil
                model.statusMessage = "「\(sheet)」还开着，没有执行「\(box.title)」：请先关掉它再操作"
            } else {
                admittedConfirmID = box.id
            }
        }
        if let box = model.alert, box.id != admittedAlertID {
            if let sheet {
                model.alert = nil
                let text = box.message.split(whereSeparator: \.isNewline).joined(separator: " · ")
                model.statusMessage = "\(box.title)：\(text)（「\(sheet)」开着，未弹窗）"
            } else {
                admittedAlertID = box.id
            }
        }
    }

    /// 三栏主体。单拿出来是为了把自绘顶栏套在它外层时不动原有缩排。
    private var splitView: some View {
        // columnVisibility 这个绑定是「显示 › 隐藏边栏 ⌃⌘S」（SidebarCommands）工作的前提，
        // 不能去掉。
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(showManageDirs: $showManageDirs)
                // 设计稿顶栏没有折叠按钮，去掉原生的那一个。
                // 菜单项与 ⌃⌘S 由 `SidebarCommands()` 提供，不受影响。
                .toolbar(removing: .sidebarToggle)
                // 侧栏宽度的唯一真相源（SidebarView 里那句重复的 .frame 已删）。
                .navigationSplitViewColumnWidth(min: Theme.Size.sidebarMinWidth,
                                                ideal: Theme.Size.sidebarIdealWidth,
                                                max: Theme.Size.sidebarMaxWidth)
        } detail: {
            HSplitView {
                VStack(spacing: 0) {
                    FileTableView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    StatusBarView()
                }
                .modifier(LyricsSheetsModifier())
                // 不给 maxHeight 时 HSplitView 会按内容固有高度排版，
                // 空列表被压成中间一条、上下留白（实测截图即此现象）。
                .frame(minWidth: Theme.Size.contentMinWidth, maxWidth: .infinity, maxHeight: .infinity)

                InspectorView()
                    .frame(minWidth: Theme.Size.inspectorMinWidth,
                           idealWidth: Theme.Size.inspectorIdealWidth,
                           maxWidth: Theme.Size.inspectorMaxWidth,
                           maxHeight: .infinity)
                    // HSplitView 首帧只会把尾栏摊到它的 maxWidth，idealWidth 从不参与
                    //（实测：max=336→量到 336、max=460→量到 460；layoutPriority 给哪一栏都无效）。
                    // 所以首帧的分隔位置由下面这个一次性 seeder 按 idealWidth 摆好，之后交还用户拖动。
                    .background(SplitDividerSeeder(width: Theme.Size.inspectorIdealWidth))
            }
        }
        .navigationTitle("MacTagger")
        .navigationSubtitle(navigationSubtitle)
    }

    /// 标题栏副标题：当前工作目录。没有就不显示。
    private var navigationSubtitle: String {
        directories.current?.lastPathComponent ?? ""
    }

    // MARK: 进度浮层

    /// 「平均 3.7 秒/首」。**只在没有字节口径可算时才出现** ——
    /// 写入类批量已经有 MB/s 与 ETA 了，再加一个「秒/首」纯属噪音；
    /// 而自动匹配这类纯网络等待的批量压根没有字节可算，「秒/首」是它唯一的速度尺。
    private static func secondsPerItemText(_ p: BatchProgress) -> String? {
        guard p.throughputText == nil, p.completed > 0, p.total > 0 else { return nil }
        let e = p.elapsed
        guard e > 0.5 else { return nil }
        return String(format: "平均 %.1f 秒/首", e / Double(p.completed))
    }

    @ViewBuilder
    private var progressOverlay: some View {
        if let progress = model.progress {
            VStack(spacing: Theme.Spacing.s) {
                Text(model.progressTitle).font(Theme.Typo.value)

                // 导入的阶段一还不知道总数（目录没走完），`total == 0` 即「不定量」，
                // 这时给一条循环滚动的条，而不是一条永远停在 0 的进度条。
                if progress.total > 0 {
                    ProgressView(value: Double(progress.completed),
                                 total: Double(progress.total))
                        .progressViewStyle(.linear)
                        .frame(width: 260)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .frame(width: 260)
                }

                Text((progress.total > 0 ? "\(progress.completed)/\(progress.total)"
                                         : "已列出 \(progress.completed) 首")
                     + (progress.currentPath.map { " · " + ($0 as NSString).lastPathComponent } ?? ""))
                    .font(Theme.Typo.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 260)
                    // 正在处理的那一条路径会被中截断，全路径挂 tooltip
                    .help(progress.currentPath ?? "")

                // 速率 + 剩余时间。只有本批真会「整文件重写」时才有字节口径可算
                // （原地改写的耗时跟字节数无关，算出来是噪声），所以两者都可能为 nil，
                // 都没有时整行不占位。
                // 自动匹配没有「字节」可算，只有「每首几秒」。那恰恰是用户嫌慢时
                // 唯一想看的数字 —— 有了它，「是不是卡住了」当场就能自己判断。
                if progress.throughputText != nil || progress.etaText != nil
                    || Self.secondsPerItemText(progress) != nil {
                    Text([progress.throughputText,
                          Self.secondsPerItemText(progress),
                          progress.etaText]
                            .compactMap { $0 }.joined(separator: " · "))
                        .font(Theme.Typo.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .frame(maxWidth: 260)
                }

                // 可移动存储降速时 WritePacer 推上来的提示（「暂停 N 秒等待恢复…」）。
                // 没有提示时整行不占位。
                if let note = progress.note {
                    Text(note)
                        .font(Theme.Typo.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: 260)
                        .help(note)
                }

                if let cancel = model.cancelHandler {
                    Button("取消") { cancel() }
                        .controlSize(.small)
                        .padding(.top, Theme.Spacing.xxs)
                }
            }
            .padding(Theme.Spacing.l)
            .background(.regularMaterial,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                        .strokeBorder(Theme.Colors.hairline))
            .shadow(color: Theme.Colors.artworkShadow, radius: 14, y: 6)
            .padding(.bottom, Theme.Spacing.xxl + Theme.Spacing.s)
        }
    }
}

// MARK: - 歌词四个子窗口的挂载点

/// 歌词的编辑 / 搜索 / 批量复核 / 另存 Lrc 四个 sheet。
/// 单独挂在中栏而不是最外层：SwiftUI 在同一个视图上叠过多 `.sheet` 时行为不稳。
struct LyricsSheetsModifier: ViewModifier {

    @EnvironmentObject private var model: AppModel

    func body(content: Content) -> some View {
        content
            .sheet(item: $model.lyricsEditorContext) { ctx in
                LyricsEditorSheet(context: ctx)
            }
            .sheet(isPresented: $model.showLyricsSearch) {
                LyricsSearchSheet()
            }
            .sheet(isPresented: Binding(get: { model.lyricsBatchReview != nil },
                                        set: { if !$0 { model.lyricsBatchReview = nil } })) {
                LyricsBatchReviewSheet()
            }
            .sheet(isPresented: $model.showLrcExportOptions) {
                LrcExportOptionsSheet()
            }
    }
}

// MARK: - 首帧把检查器摆到 idealWidth

/// `HSplitView` 首帧会把尾栏直接摊到 `maxWidth`（`idealWidth` 不参与首帧布局），
/// 于是检查器一启动就是 460，而不是设计稿的 336。
/// 这里在检查器背后贴一张零尺寸的 NSView，顺着父链找到外层 `NSSplitView`，
/// **只摆一次**分隔位置，之后完全不再插手 —— 用户拖动照常，
/// 可拖范围仍由 SwiftUI 那句 `.frame(minWidth:maxWidth:)`（300…460）约束。
/// 找不到 NSSplitView 就什么都不做，退回原行为，不会崩。
private struct SplitDividerSeeder: NSViewRepresentable {

    /// 检查器的目标首帧宽度。
    let width: CGFloat

    final class Coordinator { var seeded = false }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard !context.coordinator.seeded else { return }
        // 挂上去这一帧 NSSplitView 还没定宽，推到下一轮 runloop 再摆。
        DispatchQueue.main.async {
            guard !context.coordinator.seeded else { return }
            var node: NSView? = nsView.superview
            while let current = node, !(current is NSSplitView) { node = current.superview }
            guard let split = node as? NSSplitView,
                  split.isVertical,
                  split.arrangedSubviews.count == 2,
                  split.bounds.width > width + split.dividerThickness else { return }
            context.coordinator.seeded = true
            split.setPosition(split.bounds.width - width - split.dividerThickness, ofDividerAt: 0)
        }
    }
}

