//
//  ChineseConvertSheet.swift
//  MacTagger — 批量简繁转换面板
//
//  一屏四件事：作用对象（标签 / 文件名）· 方向（简→繁 / 繁→简）· 逐行「原 → 新」预览 · 应用。
//
//  预览表是这个面板的全部价值：简繁转换会一次改掉整库的标题与艺术家，
//  用户必须先看见「哪几行会变成什么样」，再决定要不要点那个按钮。
//  因此没有任何一条路径可以跳过预览直接写盘（菜单四项也是先开这张表）。
//

import SwiftUI

// MARK: - 挂载点

/// 与 `FilenameRelationSheetsModifier` 同样的挂法：
/// `ContentView().modifier(ChineseConvertSheetModifier()).environmentObject(...)`
/// —— 修饰器必须在环境注入**里面**，sheet 内容才拿得到 `AppModel`。
struct ChineseConvertSheetModifier: ViewModifier {

    @ObservedObject private var state = ChineseConvertState.shared

    func body(content: Content) -> some View {
        content.sheet(isPresented: $state.isPresented) {
            ChineseConvertSheet()
        }
    }
}

// MARK: - 主体

struct ChineseConvertSheet: View {

    @EnvironmentObject private var model: AppModel
    @ObservedObject private var state = ChineseConvertState.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            SheetTitleBar(systemImage: "character.book.closed.fill.zh",
                          title: "简繁转换",
                          subtitle: subtitle)

            optionsCard

            Divider()

            if !ChineseVariant.isAvailable {
                EmptyStateView(systemImage: "exclamationmark.triangle",
                               title: "OpenCC 引擎不可用",
                               message: ChineseVariant.unavailableReason
                                        ?? "找不到 OpenCC 转换配置。请执行 brew install opencc 后重开 MacTagger。")
            } else if isPreviewEmpty {
                EmptyStateView(systemImage: "text.badge.checkmark",
                               title: "没有需要转换的内容",
                               message: emptyMessage)
            } else {
                previewList
            }

            SheetButtonBar {
                Text(state.summary)
                    .font(Theme.Typo.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("应用") { model.applyChineseConvert(state) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!state.isRunnable || model.isBusy)
            }
        }
        .frame(width: Theme.Size.sheetWide, height: 620)
        .onAppear { model.refreshChineseConvertPreview(state) }
        .onChange(of: state.previewKey) { _, _ in
            model.refreshChineseConvertPreview(state)
        }
    }

    private var subtitle: String {
        "把选中文件的\(state.scope.label)整批转成另一种字形。"
        + "先看预览表再应用；\(state.scope.undoHint)。"
    }

    // MARK: 选项卡片

    private var optionsCard: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.xl) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("作用对象").font(Theme.Typo.sectionHeader).foregroundStyle(.secondary)
                Picker("", selection: $state.scope) {
                    ForEach(ChineseConversionScope.allCases) { s in
                        Text(s.label).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("方向").font(Theme.Typo.sectionHeader).foregroundStyle(.secondary)
                Picker("", selection: $state.policy) {
                    Text("繁 → 简").tag(ChineseVariantPolicy.simplified)
                    Text("简 → 繁").tag(ChineseVariantPolicy.traditional)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("范围").font(Theme.Typo.sectionHeader).foregroundStyle(.secondary)
                Text(scopeNote)
                    .font(Theme.Typo.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.m)
    }

    private var scopeNote: String {
        let n = model.selection.isEmpty ? model.displayRows.count : model.selection.count
        return model.selection.isEmpty
            ? "未选中任何文件，将处理列表里全部 \(n) 个"
            : "已选中 \(n) 个文件"
    }

    // MARK: 预览

    private var isPreviewEmpty: Bool {
        state.scope == .tags
            ? state.tagPlan.changes.isEmpty
            : state.filePlans.allSatisfy { if case .unchanged = $0.status { return true }; return false }
    }

    private var emptyMessage: String {
        state.scope == .tags
            ? "这批文件的标签里没有需要转成\(state.policy == .simplified ? "简体" : "繁体")的字。"
            : "这批文件名里没有需要转成\(state.policy == .simplified ? "简体" : "繁体")的字。"
    }

    @ViewBuilder
    private var previewList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                switch state.scope {
                case .tags:      tagRows
                case .filenames: fileRows
                }
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.s)
        }
        .frame(maxHeight: .infinity)
    }

    /// 标签：按文件分组，组内逐字段一行「字段：原 → 新」。
    @ViewBuilder
    private var tagRows: some View {
        ForEach(groupedTagChanges, id: \.file) { group in
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "music.note")
                    .font(Theme.Typo.badge)
                    .foregroundStyle(.tertiary)
                Text(group.file)
                    .font(Theme.Typo.tableCell)
                    .lineLimit(1).truncationMode(.middle)
                    .help(group.file)
                Text("\(group.changes.count) 处")
                    .font(Theme.Typo.badge)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                Spacer(minLength: 0)
            }
            .padding(.top, Theme.Spacing.s)
            .padding(.bottom, Theme.Spacing.xxs)

            Grid(alignment: .leading,
                 horizontalSpacing: Theme.Spacing.s,
                 verticalSpacing: Theme.Spacing.xxs) {
                ForEach(group.changes) { c in
                    DiffRow(field: c.field.localizedName,
                            oldValue: c.old,
                            newValue: c.new)
                }
            }
            .padding(.leading, Theme.Spacing.l)
            .padding(.bottom, Theme.Spacing.xs)

            Divider().opacity(0.35)
        }
    }

    /// 文件名：一行一个文件，`原 → 新`；不可执行的行标灰/标红并写明原因。
    @ViewBuilder
    private var fileRows: some View {
        ForEach(state.filePlans) { p in
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                StatusDot(color: dotColor(p.status), size: 6)
                Text(p.currentName)
                    .font(Theme.Typo.tableCell)
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 300, alignment: .leading)
                    .help(p.currentName)
                Image(systemName: "arrow.right")
                    .font(Theme.Typo.badge)
                    .foregroundStyle(.tertiary)
                Text(p.status.isReady ? p.newName : (p.status.reason ?? "—"))
                    .font(Theme.Typo.tableCell)
                    .foregroundStyle(textColor(p.status))
                    .lineLimit(1).truncationMode(.middle)
                    .help(p.status.isReady ? "新文件名：" + p.newName
                                           : (p.status.reason ?? "不改名"))
                Spacer(minLength: 0)
            }
            .padding(.vertical, Theme.Spacing.xxs)

            ForEach(p.companions, id: \.to) { c in
                Text("伴随：\(c.from.lastPathComponent) → \(c.to.lastPathComponent)")
                    .font(Theme.Typo.badge)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
                    .help("伴随文件\n原：\(c.from.lastPathComponent)\n新：\(c.to.lastPathComponent)")
                    .padding(.leading, Theme.Spacing.l)
                    .padding(.bottom, Theme.Spacing.xxs)
            }
        }
    }

    private func dotColor(_ s: RenamePlanItem.Status) -> Color {
        switch s {
        case .ready:     return Theme.Colors.matched
        case .unchanged: return Theme.Colors.ignored
        case .invalid:   return Theme.Colors.failed
        }
    }

    private func textColor(_ s: RenamePlanItem.Status) -> Color {
        switch s {
        case .ready:     return .primary
        case .unchanged: return Theme.Colors.placeholderText
        case .invalid:   return Theme.Colors.failed
        }
    }

    // MARK: 分组

    private struct TagGroup {
        var file: String
        var changes: [ChineseTagChange]
    }

    /// 逐字段改动按文件归拢。`planTags` 已按文件顺序产出，这里只做相邻归组，不重排。
    private var groupedTagChanges: [TagGroup] {
        var out: [TagGroup] = []
        for c in state.tagPlan.changes {
            if var last = out.last, last.file == c.fileName {
                last.changes.append(c)
                out[out.count - 1] = last
            } else {
                out.append(TagGroup(file: c.fileName, changes: [c]))
            }
        }
        return out
    }
}
