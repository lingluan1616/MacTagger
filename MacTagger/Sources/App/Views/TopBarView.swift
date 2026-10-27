//
//  TopBarView.swift
//  MacTagger — 自绘顶栏（标题栏行 + 工具栏行）
//
//  为什么不用原生 NSToolbar：
//  设计稿「方向 A」的顶栏是画在窗口内的一条 50px 工具栏 —— 图标＋文字并排、按功能分组
//  用 1×18 发丝竖线隔开、「保存标签」用强调色、右端一个 230×26 的圆角搜索框。
//  `.toolbar { ToolbarItemGroup(placement: .primaryAction) }` 会被系统渲染成一排纯图标
//  挤在标题栏右侧、Divider 退化成空隙，结构不同，怎么调都不会像。所以整条自绘。
//
//  所有数值直接抄自设计稿生成器 design/build_directions.py：
//    · toolbar 块（L131–137）· tb() 按钮（L123–129）· sep 分隔线（L130）· 标题栏（L248–251）
//  没有凑整、没有按 4/8 网格取整。
//

import SwiftUI
import AppKit

// MARK: - 尺寸

/// 顶栏的尺寸常量，逐个对应设计稿生成器里的取值。
/// 颜色（工具栏底 / 搜索框底 / 悬停底）已统一收在 `Theme.Colors` 里。
private enum TopBarMetric {
    static let titleRowHeight: CGFloat = 38     // titleH
    static let toolbarRowHeight: CGFloat = 50   // tbH
    static let rowLeading: CGFloat = 12         // padding: 0 14 0 12
    static let rowTrailing: CGFloat = 14
    static let itemGap: CGFloat = 4             // gap:4px
    static let buttonHeight: CGFloat = 28
    static let buttonHPadding: CGFloat = 9      // padding:0 9
    static let buttonRadius: CGFloat = 7        // border-radius:7px
    static let iconLabelGap: CGFloat = 6        // gap:6px
    static let labelSize: CGFloat = 12          // font-size:12px
    static let iconSize: CGFloat = 14           // 设计稿 svg 16×16 ≈ SF Symbol 14pt/.medium
    static let sepWidth: CGFloat = 1            // 1×18
    static let sepHeight: CGFloat = 18
    static let sepMargin: CGFloat = 4           // margin:0 4px
    static let searchWidth: CGFloat = 230       // searchW
    static let searchHeight: CGFloat = 26
    static let searchHPadding: CGFloat = 10     // padding:0 10
    static let searchRadius: CGFloat = 8        // border-radius:8px
    static let searchIconSize: CGFloat = 13
    static let disabledOpacity: CGFloat = 0.4
    /// 自绘标题栏左侧要给红绿灯让出的位置（设计稿三灯右边缘 66 + gap 8 = 74）
    static let trafficLightsInset: CGFloat = 78
    static let titleSize: CGFloat = 13          // font-size:13px font-weight:600
    static let titleTrailingOffset: CGFloat = 44 // margin-right:44px
}

// MARK: - 顶栏

struct TopBarView: View {

    @EnvironmentObject private var model: AppModel

    /// 「更多」菜单里三个 sheet 的开关，仍由 ContentView 持有。
    @Binding var showManageDirs: Bool
    @Binding var showHistory: Bool
    @Binding var showColumns: Bool

    // 侧栏显隐不在顶栏里做：设计稿顶栏没有折叠按钮，原生的那个也被
    // `.toolbar(removing: .sidebarToggle)` 去掉了，开关统一由 `SidebarCommands()` 装进
    // 系统「显示」菜单（隐藏边栏/显示边栏 ⌃⌘S）。这里再放一份会与系统项重复、快捷键打架。

    /// 是否自绘标题栏行。
    /// `false` = 保留系统标题栏（红绿灯、标题、副标题、拖拽、双击缩放全归系统管），
    /// `true`  = 配合 `.windowStyle(.hiddenTitleBar)` 自己画那条 38px。
    var drawsTitleRow: Bool = false

    /// 自绘标题栏时显示的副标题（当前工作目录），为空则只显示标题。
    var subtitle: String = ""

    var body: some View {
        VStack(spacing: 0) {
            if drawsTitleRow { titleRow }
            toolbarRow
        }
    }

    // MARK: 标题栏行（38）

    private var titleRow: some View {
        HStack(spacing: 8) {
            // 红绿灯由系统画在这块区域上，这里只是让位。
            Color.clear
                .frame(width: TopBarMetric.trafficLightsInset - TopBarMetric.rowTrailing, height: 1)

            HStack(spacing: 6) {
                Text("MacTagger")
                    .font(.system(size: TopBarMetric.titleSize, weight: .semibold))
                if !subtitle.isEmpty {
                    Text("—").font(.system(size: TopBarMetric.titleSize))
                    Text(subtitle)
                        .font(.system(size: TopBarMetric.titleSize))
                        .lineLimit(1).truncationMode(.middle)
                        .help(subtitle)
                }
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.trailing, TopBarMetric.titleTrailingOffset)
        }
        .padding(.horizontal, TopBarMetric.rowTrailing)
        .frame(height: TopBarMetric.titleRowHeight)
        .frame(maxWidth: .infinity)
        .background(Theme.Colors.toolbarBg)
    }

    // MARK: 工具栏行（50）

    private var toolbarRow: some View {
        HStack(spacing: TopBarMetric.itemGap) {

            // —— 组 1：导入 ——
            TopBarButton(symbol: "doc.badge.plus", label: "添加文件",
                         help: "添加音频文件（⌘O）") { model.presentAddFiles() }

            TopBarButton(symbol: "folder.badge.plus", label: "添加目录",
                         help: "添加整个目录（⇧⌘O）") { model.presentAddDirectory() }

            TopBarSeparator()

            // —— 组 2：落盘 ——
            TopBarButton(symbol: "square.and.arrow.down", label: "保存标签",
                         primary: true,
                         enabled: !(model.isBusy || !model.hasPendingChanges),
                         help: model.hasPendingChanges
                               ? "把未保存的改动写入文件（⌘S）"
                               : "没有未保存的改动") { model.requestSave() }

            TopBarButton(symbol: "arrow.uturn.backward", label: "撤消",
                         enabled: !(model.selection.isEmpty || model.isBusy),
                         help: "撤消上一次保存，回滚到写入前的标签") { model.requestUndo() }

            TopBarSeparator()

            // —— 组 3：联网 ——
            // 无选中时对全部文件执行，有选中时只对选中项执行（原版行为）。
            TopBarButton(symbol: "wand.and.stars", label: "自动匹配",
                         enabled: !(model.isBusy || model.displayRows.isEmpty),
                         help: model.selection.isEmpty
                               ? "自动匹配标签：联网为全部 \(model.displayRows.count) 个文件匹配（⇧⌘M）"
                               : "自动匹配标签：联网为选中的 \(model.selection.count) 个文件匹配（⇧⌘M）") {
                model.presentAutoMatch()
            }

            // 顶栏没有「歌词」按钮（BH 轮删除，用户实测「慢且不实用」）：
            // 单曲搜索窗要联网搜一轮才出候选、批量下载一按就是整库，两件事都不该在
            // 一个「随手会点到」的位置上。两个入口都还在，只是退回菜单：
            // 菜单栏「歌词」下那一整组（编辑歌词… / 从网络搜索歌词… / 批量下载歌词… /
            // 导入 Lrc… / 另存为歌词文件… / 歌词文件选项… / 重置歌词）。
            TopBarSeparator()

            // —— 组 4：更多 ——
            moreMenu

            Spacer(minLength: TopBarMetric.itemGap)   // <div style="flex:1">

            quickFilterMenu
            searchField
        }
        .padding(.leading, TopBarMetric.rowLeading)
        .padding(.trailing, TopBarMetric.rowTrailing)
        .frame(height: TopBarMetric.toolbarRowHeight)
        .frame(maxWidth: .infinity)
        .background(Theme.Colors.toolbarBg)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Colors.hairline).frame(height: 1)
        }
    }

    // MARK: 「更多」菜单

    private var moreMenu: some View {
        Menu {
            Section {
                Button("全选") { model.selectAll() }
                Button("反选") { model.invertSelection() }
                Button("取消选定") { model.clearSelection() }
            }
            // 会读写文件 / 动列表的项：忙时灰，与菜单栏、文件表右键同一条件（BO#5/#6）。
            Section {
                Button("刷新选中项") { model.refreshSelected() }
                    .disabled(model.isBusy)
                Button("在访达中显示") { model.revealInFinder() }
                // 选中行里有未保存的改动先问「保存 / 放弃 / 取消」（BO#11）。
                Button("从列表移除选中项") { model.requestRemoveSelectedItems() }
                    .disabled(model.isBusy)
            }
            Section {
                Button("文件名 ↔ 标签…") { model.presentFilenameRelation() }
                    .disabled(model.isBusy)
                Button("按文件夹统一标签…") { model.presentTagPropagation(grouping: .folder) }
                    .disabled(model.isBusy)
                Button("按标签整理到文件夹…") { model.presentOrganize() }
                    .disabled(model.isBusy)
                // 沿用上次选的作用对象与方向；四个具体方向在「标签 › 简繁转换 ▸」下。
                Button("简繁转换…") { model.presentChineseConvert() }
                    .disabled(model.isBusy)
                Button("撤消重命名") { model.requestUndoRename() }
                    .disabled(model.isBusy)
            }
            Section {
                Button("自定义显示列…") { showColumns = true }
                Button("标签历史…") { showHistory = true }
                Button("管理目录…") { showManageDirs = true }
            }
        } label: {
            TopBarLabel(symbol: "ellipsis.circle", label: "更多", primary: false)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("列表与窗口相关的其余操作")
        .accessibilityIdentifier("更多")
    }

    // MARK: 快捷筛选（搜索框左侧的漏斗，26×26）

    /// 「哪些文件还没有封面」是整理曲库时最常问的一句话。
    /// 原先只能点表头把它们排到一头再手动圈选 —— 这个菜单把它变成一次点击。
    ///
    /// 与搜索框**并列而不是塞进框里**：过滤词是自由文本，筛选是有限选项，
    /// 两者会叠加生效（先筛后搜），摆成两个控件才看得出是两件事。
    /// 勾中任意一条时图标变实心 + 强调色 —— 列表被挡住时必须一眼看得见是谁挡的。
    private var quickFilterMenu: some View {
        Menu {
            Button("全部") { model.clearQuickFilters() }
                .disabled(model.quickFilters.isEmpty)
            // 菜单里明说是交集：勾两条得到的是「同时缺这两样」的那一批，
            // 不写清楚的话用户会按并集去理解，然后觉得筛选「漏了文件」。
            Section("同时满足以下条件（交集）") {
                ForEach(QuickFilter.allCases) { f in
                    Toggle(isOn: Binding(get: { model.quickFilters.contains(f) },
                                         set: { model.setQuickFilter(f, $0) })) {
                        Label(f.localizedName, systemImage: f.systemImage)
                    }
                    .help(f.help)
                }
            }
        } label: {
            Image(systemName: model.quickFilters.isEmpty
                  ? "line.3.horizontal.decrease.circle"
                  : "line.3.horizontal.decrease.circle.fill")
                .font(.system(size: TopBarMetric.iconSize, weight: .regular))
                .foregroundStyle(model.quickFilters.isEmpty ? Color.secondary : Color.accentColor)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(height: TopBarMetric.searchHeight)
        .padding(.trailing, TopBarMetric.itemGap)
        .help(quickFilterHelp)
        .accessibilityLabel("快捷筛选")
        .accessibilityIdentifier("快捷筛选")
    }

    private var quickFilterHelp: String {
        guard !model.quickFilters.isEmpty else {
            return "快捷筛选：只看无封面 / 无标题 / 无专辑 / 无歌词 / 待读取标签的文件。\n"
                 + "可多选，取交集（同时满足），并与右侧的过滤词叠加。"
        }
        return "当前筛选：\(model.quickFilterSummary)（同时满足）\n"
             + "只剩 \(model.visibleCount)/\(model.totalCount) 个文件。菜单里选「全部」清除。"
    }

    // MARK: 搜索框（230×26）

    private var searchField: some View {
        HStack(spacing: TopBarMetric.iconLabelGap) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: TopBarMetric.searchIconSize, weight: .regular))
                .foregroundStyle(.secondary)

            TextField("", text: $model.filterText, prompt: Text("过滤文件"))
                .textFieldStyle(.plain)
                .font(.system(size: TopBarMetric.labelSize))
                .accessibilityLabel("过滤文件")
                .accessibilityIdentifier("过滤文件")
        }
        .padding(.horizontal, TopBarMetric.searchHPadding)
        .frame(width: TopBarMetric.searchWidth, height: TopBarMetric.searchHeight)
        .background(Theme.Colors.searchFieldBg,
                    in: RoundedRectangle(cornerRadius: TopBarMetric.searchRadius, style: .continuous))
    }
}

// MARK: - 构件

/// 分组分隔线：1×18 发丝，左右各留 4（与 HStack 的 gap 4 相加 = 设计稿的 8）。
private struct TopBarSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Theme.Colors.hairline)
            .frame(width: TopBarMetric.sepWidth, height: TopBarMetric.sepHeight)
            .padding(.horizontal, TopBarMetric.sepMargin)
    }
}

/// 图标 + 文字水平排列（设计稿 tb()：gap 6、图标 16px 线性、文字 12px）。
private struct TopBarLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: TopBarMetric.iconLabelGap) {
            configuration.icon
                .font(.system(size: TopBarMetric.iconSize, weight: .regular))
                .imageScale(.medium)
            configuration.title
                .font(.system(size: TopBarMetric.labelSize))
                .fixedSize()
        }
    }
}

/// 按钮/菜单共用的内容。
/// 用 `Label` 而不是手搭 HStack：手搭的话按钮在辅助功能树里 AXTitle 是空的（实测），
/// VoiceOver 与 UI 脚本都读不到按钮文字；`Label` 会把标题带进去。
private struct TopBarLabel: View {
    let symbol: String
    let label: String
    let primary: Bool

    var body: some View {
        Label(label, systemImage: symbol)
            .labelStyle(TopBarLabelStyle())
            .foregroundStyle(primary ? Color.accentColor : Color.secondary)
            .frame(height: TopBarMetric.buttonHeight)
            .padding(.horizontal, TopBarMetric.buttonHPadding)
    }
}

/// 顶栏按钮：无边框、悬停才出底。`primary` 只把图标与文字换成强调色，不加填充底（照设计稿）。
private struct TopBarButton: View {

    let symbol: String
    let label: String
    var primary: Bool = false
    var enabled: Bool = true
    var help: String = ""
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            TopBarLabel(symbol: symbol, label: label, primary: primary)
                .background(
                    RoundedRectangle(cornerRadius: TopBarMetric.buttonRadius, style: .continuous)
                        .fill(hovering && enabled ? Theme.Colors.hoverFill : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: TopBarMetric.buttonRadius,
                                               style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : TopBarMetric.disabledOpacity)
        .onHover { hovering = $0 }
        .help(help)
        // 按钮文字 SwiftUI 只放进 AXAttributedDescription（VoiceOver 读得到，
        // 但 System Events / JXA 取不出富文本）。补一个 AXIdentifier 给 UI 脚本用。
        .accessibilityIdentifier(label)
    }
}
