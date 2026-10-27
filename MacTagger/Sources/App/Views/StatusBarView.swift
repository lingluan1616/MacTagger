//
//  StatusBarView.swift
//  MacTagger — 底部状态栏（原版 statusStrip：总数 / 已选 / 过滤 / 进度）
//
//  一行、小字、次要色。计数走胶囊，进度时左侧换成细进度条。
//
//  尺寸逐值抄自设计稿 build_directions.py 的 statusbar 块：
//  height 26、padding 0 12、gap 10、font-size 11 次要色、顶部一条发丝线、
//  胶囊 11px + padding 1 8 + 圆角 9（等价胶囊形）+ 等宽数字。
//

import SwiftUI

struct StatusBarView: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: Theme.Spacing.s2) {
            leading
            Spacer(minLength: Theme.Spacing.s2)
            counters
        }
        .font(Theme.Typo.small)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Theme.Spacing.m)
        .frame(height: Theme.Size.statusBarHeight)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: 左：状态文案 / 进度

    @ViewBuilder
    private var leading: some View {
        HStack(spacing: Theme.Spacing.s2) {
            if let p = model.progress {
                HStack(spacing: Theme.Spacing.s) {
                    ProgressView(value: p.total > 0 ? p.fraction : nil)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .frame(width: 120)
                    Text(progressText(p))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .monospacedDigit()
                        .help(progressText(p))
                }
            } else {
                Text(model.statusMessage)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    // 收尾结果常常是「保存 12 个文件成功，2 个失败（…）」这种长句，
                    // 状态栏一行装不下，全文挂 tooltip。
                    .help(model.statusMessage)
            }
            pendingHint
        }
    }

    /// 「有 N 首未读取标签 · 点此读取」。
    ///
    /// 待读行躺了 5 秒还没人读才出现（见 `AppModel.showPendingHint`）：正在读的时候
    /// 进度浮层已经在说这件事，再挂一句只会重复。**整枚就是按钮** ——
    /// 同样的动作在右键菜单里藏得太深，这里是它的明面入口。
    @ViewBuilder
    private var pendingHint: some View {
        if model.showPendingHint {
            Button {
                model.resumeTagRead()
            } label: {
                Chip(text: model.pendingHintText,
                     tinted: true,
                     systemImage: "arrow.down.circle")
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("这些行只列出了文件名，标签还没读。点一下把它们全部读出来"
                + "（也可以在列表里右键「继续读取标签」）。")
            .accessibilityIdentifier("继续读取标签")
            .fixedSize()
        }
    }

    // MARK: 右：计数胶囊

    private var counters: some View {
        HStack(spacing: Theme.Spacing.s2) {
            Chip(text: "总共 \(model.totalCount)")
            quickFilterChip
            if model.visibleCount != model.totalCount {
                Chip(text: "过滤 \(model.visibleCount)", systemImage: "line.3.horizontal.decrease")
            }
            if model.selectedCount > 0 {
                Chip(text: "已选 \(model.selectedCount)")
            }
            if dirtyCount > 0 {
                Chip(text: "已改 \(dirtyCount)", tinted: true)
            } else if model.artworkDirty {
                Chip(text: "封面已改", tinted: true)
            }
        }
        .fixedSize()
    }

    /// 快捷筛选胶囊。**整枚就是清除按钮** —— 筛选是唯一会让「文件好像不见了」的
    /// 状态，它必须一眼看得见、一下点得掉，不能只藏在顶栏菜单里。
    @ViewBuilder
    private var quickFilterChip: some View {
        if !model.quickFilters.isEmpty {
            Button {
                model.clearQuickFilters()
            } label: {
                HStack(spacing: Theme.Spacing.xs) {
                    Chip(text: "筛选：" + model.quickFilterSummary,
                         tinted: true,
                         systemImage: "line.3.horizontal.decrease.circle.fill")
                    Image(systemName: "xmark.circle.fill")
                        .font(Theme.Typo.badge)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("当前只显示同时满足「\(model.quickFilterSummary)」的文件"
                + "（\(model.visibleCount)/\(model.totalCount)）。点一下清除全部筛选。")
            .accessibilityIdentifier("清除筛选")
        }
    }

    private var dirtyCount: Int { model.dirtyRows.count }

    private func progressText(_ p: BatchProgress) -> String {
        var s = model.progressTitle
        if p.total > 0 { s += " \(p.completed)/\(p.total)" }
        if let path = p.currentPath { s += " · " + (path as NSString).lastPathComponent }
        return s
    }
}
