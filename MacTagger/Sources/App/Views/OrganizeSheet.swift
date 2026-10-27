//
//  OrganizeSheet.swift
//  MacTagger — 「按标签整理到文件夹」
//
//  骨架与其它 sheet 一致：SheetTitleBar → 选项区 → 预览 → SheetButtonBar。
//  预览是**两栏**：左边一棵目录树（用户真正要确认的是「结构长这样对不对」），
//  右边逐文件「原路径 → 新路径」（复用复核表的原 → 新样式）。
//  所有间距 / 字级 / 颜色一律取 Theme 令牌，不写魔法数字。
//

import SwiftUI

// MARK: - 挂载点

/// 「按标签整理到文件夹」这一个 sheet 的挂载点。
///
/// ContentView 已定稿不可改，所以挂载点自带 —— 与 `FilenameRelationSheetsModifier` 同一套做法：
/// 在 `MacTaggerApp` 里排在 `environmentObject` **之前**，sheet 内容才拿得到 `AppModel`。
struct OrganizeSheetModifier: ViewModifier {

    @ObservedObject private var state = OrganizeState.shared

    func body(content: Content) -> some View {
        content.sheet(isPresented: $state.isPresented) {
            OrganizeSheet()
        }
    }
}

// MARK: - 主体

struct OrganizeSheet: View {

    @EnvironmentObject private var model: AppModel
    @ObservedObject private var state = OrganizeState.shared
    @Environment(\.dismiss) private var dismiss
    /// 预览树里被**手动折叠**的目录 id。默认全展开 —— 见 `treeColumn` 的注释。
    @State private var collapsed: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            SheetTitleBar(systemImage: "folder.badge.gearshape",
                          title: "按标签整理到文件夹",
                          subtitle: subtitle)

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.s2) {
                    templateCard
                    policyCard
                }
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.top, Theme.Spacing.m)
                .padding(.bottom, Theme.Spacing.s2)
            }
            .frame(maxHeight: 244)

            Divider()
            previewSection

            SheetButtonBar {
                summaryLine
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("取消")
                Button("整理") {
                    model.applyOrganize(state)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canApply)
                .accessibilityIdentifier("整理")
            }
        }
        .frame(width: Theme.Size.sheetExtraWide, height: 760)
        // 显式垫一层窗口底色。真窗口下 sheet 由系统材质垫底，看不出差别；
        // 但没有它的话，任何「视图自己没画过」的区域都是透明的 ——
        // 离屏渲染实测整块预览区透出黑底、黑字直接消失。用系统语义色，深浅自动。
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.refreshOrganizePreview(state) }
        .onChange(of: state.previewKey) { _, _ in model.refreshOrganizePreview(state) }
    }

    private var subtitle: String {
        let n = model.organizeTargets.count
        let scope = model.selection.isEmpty ? "列表里全部 \(n) 个文件" : "选中的 \(n) 个文件"
        return "按标签把\(scope)搬进目录结构。只搬文件、不改标签，"
             + "整理后可用「撤消整理」原样撤回。"
    }

    // MARK: 模板卡

    private var templateCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s2) {
            HStack(spacing: Theme.Spacing.s2) {
                Text("结构")
                    .font(Theme.Typo.fieldLabel)
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .leading)

                Picker("", selection: $state.preset) {
                    ForEach(OrganizeTemplatePreset.allCases) { p in
                        if let ex = p.example {
                            Text("\(p.localizedName)   —   \(ex)").tag(p)
                        } else {
                            Text(p.localizedName).tag(p)
                        }
                    }
                }
                .labelsHidden()
                .frame(width: 380)
                .accessibilityIdentifier("目录结构预设")

                TextField("", text: $state.templateText, prompt: Text("例如 @2/@3/@5 - @1"))
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.Typo.valueMono)
                    .accessibilityIdentifier("模板")

                customTemplateMenu
            }

            if let error = state.ruleError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.Colors.failed)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("「/」是层级分隔符：前面每一段是一级目录，最后一段是文件名。"
                     + "音轨号自动补两位；碟号只在多碟专辑上出现。")
                    .font(Theme.Typo.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            FieldGroupLabel(title: "参数（点一下追加到模板末尾）")

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: Theme.Spacing.xs2)],
                      alignment: .leading,
                      spacing: Theme.Spacing.xs2) {
                Button("／ 新一级目录") { state.appendSeparator() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .font(Theme.Typo.small)
                    .help("插入层级分隔符「/」：它左边的内容成为一级目录")
                    .accessibilityIdentifier("分隔符")
                ForEach(FilenameField.assignable) { field in
                    Button(field.buttonLabel) { state.appendParameter(field) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .font(Theme.Typo.small)
                        .help("在模板中插入 \(field.token)（\(field.localizedName)）")
                        .accessibilityIdentifier(field.token)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var customTemplateMenu: some View {
        Menu {
            if state.customTemplates.isEmpty {
                Text("还没有保存过自定义结构")
            } else {
                Section("套用") {
                    ForEach(state.customTemplates, id: \.self) { t in
                        Button(t) { state.templateText = t }
                    }
                }
            }
            Section {
                Button("保存当前结构") { state.saveCurrentTemplate() }
                    .disabled(state.validate() != nil
                              || state.customTemplates.contains(state.templateText))
                Button("删除当前结构", role: .destructive) { state.deleteTemplate(state.templateText) }
                    .disabled(!state.customTemplates.contains(state.templateText))
            }
        } label: {
            Label("自定义", systemImage: "chevron.down").font(Theme.Typo.small)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("套用 / 保存 / 删除自定义目录结构")
        .accessibilityIdentifier("自定义结构")
    }

    // MARK: 策略卡

    private var policyCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s2) {
            // 一排摆下「目标 / 缺字段 / 重名」，第二排是四个勾选。
            // 早先版本把它们摞成两大行，离屏渲染实测被选项区的滚动高度切掉了半排 ——
            // 最要紧的三个策略必须**默认可见**，不该藏在滚动条后面。
            HStack(alignment: .bottom, spacing: Theme.Spacing.m) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("目标").font(Theme.Typo.sectionHeader).foregroundStyle(.secondary)
                    Picker("", selection: $state.isInPlace) {
                        Text("就地整理").tag(true)
                        Text("指定目录").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 170)
                }

                if state.isInPlace {
                    Label(model.organizeInPlaceRootLabel(), systemImage: "folder")
                        .font(Theme.Typo.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(model.organizeInPlaceRootLabel())
                } else {
                    HStack(spacing: Theme.Spacing.s) {
                        Button("指定目录…") { model.chooseOrganizeRoot(state) }
                            .controlSize(.small)
                            .accessibilityIdentifier("指定目录")
                        Text(state.rootPath.isEmpty ? "还没选目录" : state.rootPath)
                            .font(Theme.Typo.caption)
                            .foregroundStyle(state.rootPath.isEmpty
                                             ? Theme.Colors.failed : Color.secondary)
                            .lineLimit(1).truncationMode(.middle)
                            .help(state.rootPath)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("缺字段").font(Theme.Typo.sectionHeader).foregroundStyle(.secondary)
                    Picker("", selection: $state.missing) {
                        ForEach(OrganizeMissingPolicy.allCases) { p in
                            Text(p.localizedName).tag(p)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 216)
                    .help("模板用到的艺术家 / 专辑为空时怎么办。标题为空一律回落到当前文件名")
                    .accessibilityIdentifier("缺字段策略")
                }

                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("重名").font(Theme.Typo.sectionHeader).foregroundStyle(.secondary)
                    Picker("", selection: $state.conflict) {
                        ForEach(OrganizeConflictPolicy.allCases) { p in
                            Text(p.localizedName).tag(p)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 132)
                    .help("目标已存在同名文件，或同批内两个文件算到了同一个目标时怎么办")
                    .accessibilityIdentifier("重名策略")
                }
            }

            Divider()

            HStack(spacing: Theme.Spacing.l) {
                Toggle("同名歌词 / 字幕跟着走", isOn: $state.moveCompanions)
                    .font(Theme.Typo.fieldLabel)
                    .toggleStyle(.checkbox)
                    .help("同目录下与歌曲同名的 .lrc / .txt / .srt 一起搬")
                Toggle("整组搬走时带上文件夹封面", isOn: $state.moveFolderArtwork)
                    .font(Theme.Typo.fieldLabel)
                    .toggleStyle(.checkbox)
                    .help("源目录里的音频全部搬走、且都落到同一个目标目录时，"
                          + "cover.jpg / folder.jpg 跟着走；否则留在原地")
                Toggle("整理后删除空文件夹", isOn: $state.deleteEmptyFolders)
                    .font(Theme.Typo.fieldLabel)
                    .toggleStyle(.checkbox)
                    .help("只删真正空的目录；里面还剩任何一项（含 .DS_Store）都保留")
                Toggle("跨卷复制后删除源文件", isOn: $state.deleteSourceAfterCopy)
                    .font(Theme.Typo.fieldLabel)
                    .toggleStyle(.checkbox)
                    .help("跨到另一个卷时走「复制 + 校验」。默认复制后保留源文件，"
                          + "勾选后校验通过才删源")
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    // MARK: 预览

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("预览").font(Theme.Typo.sectionHeader).foregroundStyle(.secondary)
                Spacer()
                Chip(text: "可整理 \(state.plan.readyCount)", tinted: state.plan.readyCount > 0)
                if state.plan.crossVolumeCount > 0 {
                    Text("跨卷 \(state.plan.crossVolumeCount)")
                        .font(Theme.Typo.badge)
                        .foregroundStyle(Theme.Colors.warning)
                }
                if state.plan.skippedCount > 0 {
                    Text("跳过 \(state.plan.skippedCount)")
                        .font(Theme.Typo.badge)
                        .foregroundStyle(.secondary)
                }
                if state.plan.invalidCount > 0 {
                    Text("失败 \(state.plan.invalidCount)")
                        .font(Theme.Typo.badge)
                        .foregroundStyle(Theme.Colors.failed)
                }
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.s)

            Divider()

            if state.plan.items.isEmpty {
                EmptyStateView(systemImage: "folder.badge.questionmark",
                               title: state.ruleError == nil ? "没有可预览的文件" : "结构还不完整",
                               message: state.ruleError ?? "先在列表里选中文件，或把文件添加进来")
            } else {
                HStack(spacing: 0) {
                    treeColumn
                    Divider()
                    pathColumn
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: 左：目录树

    private var treeColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("整理后的目录结构")
                .font(Theme.Typo.badge)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.vertical, Theme.Spacing.xs2)

            // 自己摊平 + 自己管折叠，**不用 `OutlineGroup`**：
            // 它默认全折叠，而这棵树的全部价值就在于「一眼看见结构对不对」，
            // 默认只给一行 `> flat 15` 等于没给（离屏渲染实测）。
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(flattenedTree, id: \.node.id) { row in
                        treeRow(row.node, depth: row.depth)
                            .padding(.horizontal, Theme.Spacing.l)
                            .padding(.vertical, 3)
                    }
                }
                .padding(.vertical, Theme.Spacing.xs)
            }
            .accessibilityIdentifier("目录树")
        }
        .frame(width: 452)
        .background(Theme.Colors.cardFill)
    }

    /// 摊平成 (节点, 层深)。折叠起来的目录不吐子节点。
    private var flattenedTree: [(node: OrganizeTreeNode, depth: Int)] {
        var out: [(OrganizeTreeNode, Int)] = []
        func walk(_ nodes: [OrganizeTreeNode], _ depth: Int) {
            for n in nodes {
                out.append((n, depth))
                guard let kids = n.children, !kids.isEmpty, !collapsed.contains(n.id) else { continue }
                walk(kids, depth + 1)
            }
        }
        walk(state.plan.tree, 0)
        return out
    }

    @ViewBuilder
    private func treeRow(_ node: OrganizeTreeNode, depth: Int) -> some View {
        let hasChildren = !(node.children?.isEmpty ?? true)
        HStack(spacing: Theme.Spacing.xs2) {
            Color.clear.frame(width: CGFloat(depth) * 14, height: 1)

            if hasChildren {
                Button {
                    if collapsed.contains(node.id) { collapsed.remove(node.id) }
                    else { collapsed.insert(node.id) }
                } label: {
                    Image(systemName: collapsed.contains(node.id) ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
                .help(collapsed.contains(node.id) ? "展开" : "折叠")
            } else {
                Color.clear.frame(width: 12, height: 1)
            }

            if node.isFile {
                StatusDot(color: dotColor(node.status), size: Theme.Size.statusDot)
            } else {
                Image(systemName: node.isNewFolder ? "folder.badge.plus" : "folder")
                    .font(Theme.Typo.badge)
                    .foregroundStyle(node.isNewFolder ? Color.accentColor : Color.secondary)
            }

            Text(node.name)
                .font(node.isFile ? Theme.Typo.tableCell : Theme.Typo.tableCell.weight(.medium))
                .foregroundStyle(node.isFile ? Color.primary : Color.primary)
                .lineLimit(1).truncationMode(.middle)
                .help(helpText(node))

            if node.isCrossVolume {
                Text("跨卷")
                    .font(Theme.Typo.badge)
                    .foregroundStyle(Theme.Colors.warning)
                    .padding(.horizontal, Theme.Spacing.xs2)
                    .background(Theme.Colors.chipFill, in: Capsule())
            }

            Spacer(minLength: Theme.Spacing.xs)

            if !node.isFile {
                Text("\(node.fileCount)")
                    .font(Theme.Typo.badge)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .help("这个目录下共 \(node.fileCount) 个文件")
            }
        }
    }

    private func helpText(_ node: OrganizeTreeNode) -> String {
        var lines = [node.name]
        if let r = node.status?.reason { lines.append(r) }
        lines.append(contentsOf: node.notes)
        if node.isNewFolder { lines.append("本次新建的目录") }
        return lines.joined(separator: "\n")
    }

    // MARK: 右：原 → 新

    private var pathColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("原路径 → 新路径")
                .font(Theme.Typo.badge)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.vertical, Theme.Spacing.xs2)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(state.plan.items.enumerated()), id: \.element.id) { index, item in
                        pathRow(item)
                            .padding(.horizontal, Theme.Spacing.l)
                            .padding(.vertical, Theme.Spacing.xs2)
                            .background(index.isMultiple(of: 2) ? Color.clear : Theme.Colors.rowAlt)
                    }
                }
            }
            .accessibilityIdentifier("原新路径列表")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.cardFill)
    }

    @ViewBuilder
    private func pathRow(_ item: OrganizePlanItem) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            HStack(spacing: Theme.Spacing.s) {
                StatusDot(color: dotColor(item.status), size: Theme.Size.statusDot)

                Text(item.currentName)
                    .font(Theme.Typo.tableCell)
                    .foregroundStyle(item.status.isReady ? Color.secondary : Color.primary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(width: 208, alignment: .leading)
                    .help(item.sourceURL.path)

                Image(systemName: item.isCrossVolume ? "arrow.right.doc.on.clipboard" : "arrow.right")
                    .font(Theme.Typo.badge)
                    .foregroundStyle(item.isCrossVolume ? Theme.Colors.warning : Color.secondary)
                    .help(item.isCrossVolume ? "跨卷：复制 + 校验" : "同卷：移动")

                Text(item.status.isReady ? item.relativePath : "—")
                    .font(Theme.Typo.tableCell)
                    .foregroundStyle(valueColor(item.status))
                    .lineLimit(1).truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(item.status.isReady
                          ? "原：\(item.sourceURL.path)\n新：\(item.targetURL.path)"
                          : (item.status.reason ?? ""))
            }

            if let reason = item.status.reason {
                Text(reason)
                    .font(Theme.Typo.caption)
                    .foregroundStyle(isFailed(item.status) ? Theme.Colors.failed : Color.secondary)
                    .padding(.leading, Theme.Size.statusDot + Theme.Spacing.s)
                    .lineLimit(2)
            }

            ForEach(item.notes, id: \.self) { note in
                Text("⚠︎ " + note)
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.Colors.warning)
                    .padding(.leading, Theme.Size.statusDot + Theme.Spacing.s)
                    .lineLimit(1).truncationMode(.middle)
                    .help(note)
            }

            ForEach(item.companions, id: \.to) { c in
                Text("＋ " + c.to.lastPathComponent)
                    .font(Theme.Typo.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, Theme.Size.statusDot + Theme.Spacing.s)
                    .lineLimit(1).truncationMode(.middle)
                    .help("伴随文件：\(c.from.path)\n→ \(c.to.path)")
            }
        }
    }

    // MARK: 配色与统计

    private func dotColor(_ status: OrganizePlanItem.Status?) -> Color {
        switch status {
        case .ready:        return Theme.Colors.matched
        case .unchanged:    return Theme.Colors.ignored
        case .skipped:      return Theme.Colors.warning
        case .invalid:      return Theme.Colors.failed
        case nil:           return Theme.Colors.ignored
        }
    }

    private func valueColor(_ status: OrganizePlanItem.Status) -> Color {
        switch status {
        case .ready:     return Color.accentColor
        case .unchanged: return Theme.Colors.placeholderText
        case .skipped:   return Theme.Colors.warning
        case .invalid:   return Theme.Colors.failed
        }
    }

    private func isFailed(_ status: OrganizePlanItem.Status) -> Bool {
        if case .invalid = status { return true }
        return false
    }

    private var canApply: Bool {
        state.ruleError == nil && state.plan.readyCount > 0 && !model.isBusy
            && (state.isInPlace || !state.rootPath.isEmpty)
    }

    private var summaryLine: some View {
        Text(state.plan.summaryLine)
            .font(Theme.Typo.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1).truncationMode(.middle)
            .help(state.plan.summaryLine)
    }
}
