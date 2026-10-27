//
//  FilenameRelationSheet.swift
//  MacTagger — 「文件名 ↔ 标签」互转（原版 FormFilenameRel）
//
//  骨架与其它 sheet 一致：SheetTitleBar → 规则区 → 实时预览表 → SheetButtonBar。
//  所有间距 / 字级 / 颜色一律取 Theme 令牌，不写魔法数字。
//

import SwiftUI

// MARK: - 挂载点

/// 「文件名 ↔ 标签」这一个 sheet 的挂载点。
///
/// ContentView 已定稿不可改，所以挂载点自带：在 `MacTaggerApp` 里以
/// `ContentView().modifier(FilenameRelationSheetsModifier()).environmentObject(...)` 的顺序套上去
/// —— 修饰器在环境注入**里面**，sheet 内容才拿得到 `AppModel`。
struct FilenameRelationSheetsModifier: ViewModifier {

    @ObservedObject private var state = RenameState.shared

    func body(content: Content) -> some View {
        content.sheet(isPresented: $state.isPresented) {
            FilenameRelationSheet()
        }
    }
}

// MARK: - 主体

struct FilenameRelationSheet: View {

    @EnvironmentObject private var model: AppModel
    @ObservedObject private var state = RenameState.shared
    @Environment(\.dismiss) private var dismiss

    /// 预览重算的触发键：任一项变了就重算（不在 body 里算，避免每帧跑磁盘检查）。
    private var previewKey: String {
        [state.mode.rawValue,
         state.method.rawValue,
         state.templateText,
         state.regexText,
         state.renameCompanions ? "1" : "0",
         state.groupFields.keys.sorted().map { "\($0):\(state.groupFields[$0]?.rawValue ?? -1)" }.joined(separator: ",")
        ].joined(separator: "|")
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetTitleBar(systemImage: "arrow.left.arrow.right",
                          title: "文件名 ↔ 标签",
                          subtitle: subtitle)

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.s2) {
                    modeCard
                    ruleCard
                }
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.top, Theme.Spacing.m)
                .padding(.bottom, Theme.Spacing.s2)
            }
            .frame(maxHeight: 258)

            Divider()
            previewSection

            SheetButtonBar {
                summaryLine
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    // SwiftUI 只把按钮文字放进 AXAttributedDescription，UI 脚本取不到，
                    // 所以照 TopBarView 的做法补一个 AXIdentifier。
                    .accessibilityIdentifier("取消")
                Button(state.mode == .rename ? "重命名" : "更改标签") {
                    model.applyFilenameRelation(state)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canApply)
                .accessibilityIdentifier("应用")
            }
        }
        .frame(width: Theme.Size.sheetWide, height: 640)
        .onAppear { model.refreshRenamePreview(state) }
        .onChange(of: previewKey) { _, _ in model.refreshRenamePreview(state) }
    }

    private var subtitle: String {
        let n = model.renameTargets.count
        let scope = model.selection.isEmpty ? "列表里全部 \(n) 个文件" : "选中的 \(n) 个文件"
        return state.mode == .rename
            ? "按标签给 \(scope) 重命名。改名后可用「撤消重命名」原样撤回。"
            : "从 \(scope) 的文件名里解析出标签并写入。写入前会记快照，可用「撤消标签保存」回滚。"
    }

    // MARK: 模式 / 方式

    private var modeCard: some View {
        HStack(spacing: Theme.Spacing.l) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("操作模式").font(Theme.Typo.sectionHeader).foregroundStyle(.secondary)
                Picker("", selection: $state.mode) {
                    ForEach(FilenameRelationMode.allCases) { m in
                        Text(m.shortName).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 300)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("匹配方式").font(Theme.Typo.sectionHeader).foregroundStyle(.secondary)
                Picker("", selection: $state.method) {
                    ForEach(FilenameMatchMethod.allCases) { m in
                        Text(m.localizedName).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 190)
            }

            Spacer(minLength: Theme.Spacing.s)

            if state.mode == .rename {
                Toggle("同步重命名 Lrc / 图片", isOn: $state.renameCompanions)
                    .font(Theme.Typo.fieldLabel)
                    .toggleStyle(.checkbox)
                    .help("同目录下与歌曲同名的 .lrc 与 .jpg/.png 等图片跟着一起改名")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    // MARK: 规则区

    @ViewBuilder
    private var ruleCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s2) {
            if state.method == .template { templateEditor } else { regexEditor }

            if let error = state.ruleError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.Colors.failed)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    // MARK: 模板

    private var templateEditor: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s2) {
            HStack(spacing: Theme.Spacing.s2) {
                Text("模板")
                    .font(Theme.Typo.fieldLabel)
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .leading)
                TextField("", text: $state.templateText, prompt: Text("例如 @5 - @2 - @1"))
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.Typo.valueMono)
                    .accessibilityIdentifier("模板")
                customTemplateMenu
            }

            FieldGroupLabel(title: "参数（点一下追加到模板末尾）")

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: Theme.Spacing.xs2)],
                      alignment: .leading,
                      spacing: Theme.Spacing.xs2) {
                ForEach(parameterButtons) { field in
                    Button(field.buttonLabel) { state.appendParameter(field) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .font(Theme.Typo.small)
                        .help(field == .discard
                              ? "@0：匹配任意内容并丢弃，只在「从文件名更改标签」模式下可用"
                              : "在模板中插入 \(field.token)（\(field.localizedName)）")
                        .accessibilityIdentifier(field.token)
                }
            }
        }
    }

    /// 重命名模式下 `@0` 不可用（原版校验规则），按钮条里直接不显示。
    private var parameterButtons: [FilenameField] {
        state.mode == .rename
            ? FilenameField.assignable
            : ([.discard] + FilenameField.assignable)
    }

    private var customTemplateMenu: some View {
        Menu {
            Section("套用") {
                ForEach(state.customTemplates, id: \.self) { t in
                    Button(t) { state.templateText = t }
                }
            }
            Section {
                Button("保存当前模板") { state.saveCurrentTemplate() }
                    .disabled(state.templateText.trimmingCharacters(in: .whitespaces).isEmpty
                              || state.customTemplates.contains(state.templateText))
                Button("删除当前模板", role: .destructive) { state.deleteTemplate(state.templateText) }
                    .disabled(!state.customTemplates.contains(state.templateText))
            }
        } label: {
            Label("自定义模板", systemImage: "chevron.down")
                .font(Theme.Typo.small)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("套用 / 保存 / 删除自定义模板")
        .accessibilityIdentifier("自定义模板")
    }

    // MARK: 正则

    private var regexEditor: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s2) {
            HStack(spacing: Theme.Spacing.s2) {
                Text("正则")
                    .font(Theme.Typo.fieldLabel)
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .leading)
                TextField("", text: $state.regexText,
                          prompt: Text(#"例如 ^(\d+) - (.+) - (.+)$"#))
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.Typo.valueMono)
                    .accessibilityIdentifier("正则")
                Button("清空捕获组") { state.clearGroupFields() }
                    .controlSize(.small)
                    .disabled(state.groupFields.isEmpty)
            }

            FieldGroupLabel(title: "捕获组 → 字段")

            if state.captureGroupCount == 0 {
                Text("正则里还没有捕获组（用小括号把要提取的部分括起来）")
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.Colors.placeholderText)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: Theme.Spacing.s2)],
                          alignment: .leading,
                          spacing: Theme.Spacing.xs2) {
                    ForEach(1...state.captureGroupCount, id: \.self) { group in
                        HStack(spacing: Theme.Spacing.s) {
                            Text("第 \(group) 组")
                                .font(Theme.Typo.small)
                                .foregroundStyle(.secondary)
                                .frame(width: 52, alignment: .leading)
                            Picker("", selection: groupBinding(group)) {
                                Text("（不使用）").tag(-1)
                                ForEach(FilenameField.assignable) { f in
                                    Text(f.buttonLabel).tag(f.rawValue)
                                }
                            }
                            .labelsHidden()
                            .font(Theme.Typo.small)
                            .accessibilityIdentifier("第 \(group) 组")
                        }
                    }
                }
            }
        }
    }

    private func groupBinding(_ group: Int) -> Binding<Int> {
        Binding(get: { state.groupFields[group]?.rawValue ?? -1 },
                set: { raw in
                    if let f = FilenameField(rawValue: raw), raw >= 0 {
                        state.groupFields[group] = f
                    } else {
                        state.groupFields[group] = nil
                    }
                })
    }

    // MARK: 预览

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("预览").font(Theme.Typo.sectionHeader).foregroundStyle(.secondary)
                Spacer()
                Chip(text: "可执行 \(readyCount)", tinted: readyCount > 0)
                if failedCount > 0 {
                    Text("失败 \(failedCount)")
                        .font(Theme.Typo.badge)
                        .foregroundStyle(Theme.Colors.failed)
                }
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.s)

            Divider()

            if state.preview.isEmpty {
                EmptyStateView(systemImage: "text.magnifyingglass",
                               title: state.ruleError == nil ? "没有可预览的文件" : "规则还不完整",
                               message: state.ruleError ?? "先在列表里选中文件，或把文件添加进来")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(state.preview.enumerated()), id: \.element.id) { index, row in
                            previewRow(row)
                                .padding(.horizontal, Theme.Spacing.xl)
                                .padding(.vertical, Theme.Spacing.xs2)
                                .background(index.isMultiple(of: 2) ? Color.clear : Theme.Colors.rowAlt)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func previewRow(_ row: RenamePreviewRow) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            HStack(spacing: Theme.Spacing.s) {
                StatusDot(color: dotColor(row), size: Theme.Size.statusDot)

                Text(row.currentName)
                    .font(Theme.Typo.tableCell)
                    .foregroundStyle(row.isReady ? Color.secondary : Color.primary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(width: 268, alignment: .leading)
                    .help(row.currentName)

                Image(systemName: "arrow.right")
                    .font(Theme.Typo.badge)
                    .foregroundStyle(.tertiary)

                if state.mode == .rename {
                    Text(row.newName.isEmpty ? "—" : row.newName)
                        .font(Theme.Typo.tableCell)
                        .foregroundStyle(valueColor(row))
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(row.newName.isEmpty ? "这一行不会改名"
                                                  : "原：\(row.currentName)\n新：\(row.newName)")
                } else {
                    parsedFields(row)
                }
            }

            if let reason = row.reason {
                Text(reason)
                    .font(Theme.Typo.caption)
                    .foregroundStyle(row.isFailed ? Theme.Colors.failed : Color.secondary)
                    .padding(.leading, Theme.Size.statusDot + Theme.Spacing.s)
                    .lineLimit(2)
            }

            ForEach(row.companionNames, id: \.self) { name in
                Text("＋ " + name)
                    .font(Theme.Typo.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, Theme.Size.statusDot + Theme.Spacing.s)
                    .lineLimit(1).truncationMode(.middle)
                    .help("伴随文件：" + name)
            }
        }
    }

    @ViewBuilder
    private func parsedFields(_ row: RenamePreviewRow) -> some View {
        if row.parsed.isEmpty {
            Text("—")
                .font(Theme.Typo.tableCell)
                .foregroundStyle(valueColor(row))
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: Theme.Spacing.xs2) {
                ForEach(row.parsed, id: \.field) { item in
                    HStack(spacing: Theme.Spacing.xs) {
                        Text(item.field.localizedName)
                            .font(Theme.Typo.badge)
                            .foregroundStyle(.secondary)
                        Text(item.value)
                            .font(Theme.Typo.badge)
                            .foregroundStyle(Color.accentColor)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .help("\(item.field.localizedName)：\(item.value)")
                    .padding(.horizontal, Theme.Spacing.xs2)
                    .padding(.vertical, 1)
                    .background(Theme.Colors.chipFill, in: Capsule())
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func dotColor(_ row: RenamePreviewRow) -> Color {
        switch row.kind {
        case .ready:   return Theme.Colors.matched
        case .ignored: return Theme.Colors.ignored
        case .failed:  return Theme.Colors.failed
        }
    }

    private func valueColor(_ row: RenamePreviewRow) -> Color {
        switch row.kind {
        case .ready:   return Color.accentColor
        case .ignored: return Theme.Colors.placeholderText
        case .failed:  return Theme.Colors.failed
        }
    }

    // MARK: 统计与可用性

    private var readyCount: Int { state.preview.filter(\.isReady).count }
    private var failedCount: Int { state.preview.filter(\.isFailed).count }

    private var canApply: Bool {
        state.ruleError == nil && readyCount > 0 && !model.isBusy
    }

    private var summaryLine: some View {
        Text(state.preview.isEmpty
             ? "共 0 项"
             : "共 \(state.preview.count) 项 · 可执行 \(readyCount) · 失败 \(failedCount) · 忽略 \(state.preview.count - readyCount - failedCount)")
            .font(Theme.Typo.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }
}
