//
//  Sheets.swift
//  MacTagger — 管理目录 / 标签历史两个子窗口
//
//  对应原版 FormManageDirs 与 FormTagsHistory。
//  骨架统一：SheetTitleBar（标题 + 副标题）→ 内容 → SheetButtonBar（次要操作左、主操作右）。
//

import SwiftUI

// MARK: - 管理目录（FormManageDirs）

struct ManageDirsSheet: View {

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var directories: DirectoryStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<URL> = []

    var body: some View {
        VStack(spacing: 0) {
            SheetTitleBar(systemImage: "folder",
                          title: "管理目录",
                          subtitle: "工作目录会常驻在侧栏。移出列表只是不再显示，磁盘上的文件不受影响。")

            content

            autoReadTagsBar

            SheetButtonBar {
                Button("添加…") { model.presentAddDirectory() }
                Button("移除") {
                    directories.remove(Array(selection))
                    selection = []
                }
                .disabled(selection.isEmpty)
                // 与侧栏点目录同一入口（BO#11）：忙时拒绝、目录不在时列表不动、
                // 有未保存的改动先问「保存 / 放弃 / 取消」；`directories.current` 由它在真正切过去时才改。
                Button("设为当前") {
                    if let first = selection.first { model.switchDirectory(to: first) }
                }
                .disabled(selection.count != 1)

                Spacer()

                Button("全部清除", role: .destructive) { directories.removeAll() }
                    .disabled(directories.directories.isEmpty)
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(width: Theme.Size.sheetMedium, height: 470)
    }

    @ViewBuilder
    private var content: some View {
        if directories.directories.isEmpty {
            EmptyStateView(systemImage: "folder.badge.plus",
                           title: "还没有工作目录",
                           message: "添加一个目录后，它会出现在侧栏并被记住") {
                Button("添加目录…") { model.presentAddDirectory() }
            }
        } else {
            List(directories.directories, id: \.self, selection: $selection) { url in
                HStack(spacing: Theme.Spacing.m) {
                    Image(systemName: directories.current == url ? "folder.fill" : "folder")
                        .foregroundStyle(directories.current == url ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Text(url.lastPathComponent)
                        Text(url.path)
                            .font(Theme.Typo.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                            .help(url.path)   // 中间截断，深路径只能靠悬停看全
                    }
                    Spacer(minLength: Theme.Spacing.s)
                    if directories.current == url {
                        Chip(text: "当前", tinted: true)
                    }
                }
                .padding(.vertical, Theme.Spacing.xxs)
                .contentShape(Rectangle())
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .frame(maxHeight: .infinity)
        }
    }

    // MARK: 读取标签的时机

    /// `AppSettings.autoReadTags` 的界面开关。
    ///
    /// 落在「管理目录」而不是「更多 ▾」：这个选项只在**添加/切换目录那一刻**起作用，
    /// 用户会想起它、也只可能来这里改它。三档的差别就是用户当初的痛点 ——
    /// TF 卡上 3 万首全读要好几分钟，而多数时候他只想看看目录里有什么。
    private var autoReadTagsBar: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.m) {
                Text("读取标签")
                    .font(Theme.Typo.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: $settings.autoReadTags) {
                    Text("自动").tag(AppSettings.AutoReadTagsMode.auto)
                    Text("总是").tag(AppSettings.AutoReadTagsMode.always)
                    Text("从不").tag(AppSettings.AutoReadTagsMode.never)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help(settings.autoReadTags.label)
                Spacer(minLength: 0)
            }
            Text(autoReadTagsExplanation)
                .font(Theme.Typo.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            lazyThresholdRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.s)
        .overlay(alignment: .top) { Divider().opacity(0.4) }
    }

    /// 两段式导入的起用门槛。
    ///
    /// 和上面那三档是**配套**的：三档管「读不读」，这一行管「什么时候才值得先列文件」。
    /// 小目录先闪一片「读取中…」再一格格填，主观上比直接等出全表更慢 ——
    /// 这一行就是用户那句「小库反而更慢」的出口。
    private var lazyThresholdRow: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.xs) {
                Text("超过")
                    .font(Theme.Typo.caption)
                    .foregroundStyle(.secondary)
                TextField("", value: $settings.lazyThreshold, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 68)
                    .labelsHidden()
                Stepper("", value: $settings.lazyThreshold, in: 0...100_000, step: 100)
                    .labelsHidden()
                Text("首时，先列文件再补标签")
                    .font(Theme.Typo.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            Text(lazyThresholdExplanation)
                .font(Theme.Typo.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, Theme.Spacing.xs)
    }

    private var lazyThresholdExplanation: String {
        settings.lazyThreshold == 0
            ? "填 0 = 任何目录都先列文件再补标签。文件名立刻可见，标签随后一格格填上。"
            : "不超过 \(settings.lazyThreshold) 首的目录「一次读完再显示」—— 列表出现时标签就是齐的，"
            + "不会先闪一片「读取中…」。**外置卡 / U 盘上也一样**（这道阈值比卷类型优先）。"
            + "更大的目录才拆成两段，好让几万首的库几秒内可见、可滚、可取消。"
    }

    private var autoReadTagsExplanation: String {
        switch settings.autoReadTags {
        case .auto:
            return "不超过上面那个数的目录，在任何盘上都一次读完再显示；更大的目录列完接着后台读，"
                 + "外置卡 / U 盘 / 网络盘上会放慢（并发 2、每 200 首让一次），"
                 + "免得把卡的主控打满。屏幕上看得到的行始终排在最前面先读。"
        case .always:
            return "任何盘都列完即刻全读，而且不放慢。标签最全，代价是大目录（尤其是外置卡）"
                 + "要等上一阵，期间可以随时点进度条上的「取消」。"
        case .never:
            return "不自动读任何标签 —— 连小目录也不读，列表里会先显示一片「读取中…」，"
                 + "只有你正看着的那一屏会按需补上，其余要点状态栏的「有 N 首未读取标签」"
                 + "或右键「继续读取标签」才读。批量操作（保存 / 清除 / 匹配 / 下载歌词）"
                 + "开工前仍会自动补读用得到的那些行。"
        }
    }
}

// MARK: - 标签历史（FormTagsHistory）

struct TagsHistorySheet: View {

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    /// 「清除全部历史」的确认框。**挂在本窗自己身上**（BO #15）：原来走根视图的 `model.confirm`，
    /// 历史窗开着时根上的确认框只能排队 —— 点了没反应，关窗后才突然冒出来。
    @State private var confirmClearAll = false
    /// 清除失败的原因，同样就地弹在本窗上。
    @State private var clearError: String?

    var body: some View {
        VStack(spacing: 0) {
            SheetTitleBar(systemImage: "clock.arrow.circlepath",
                          title: "标签历史",
                          subtitle: "每次写入前的原始标签都会存档。选一条「回滚」即可把该文件恢复到写入前。") {
                Picker("", selection: $model.historyScopeIsAll) {
                    Text("当前文件").tag(false)
                    Text("全部").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .onChange(of: model.historyScopeIsAll) { _, _ in model.loadHistoryForFocus() }
            }

            if let error = model.historyError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.Colors.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Spacing.xl)
                    .padding(.vertical, Theme.Spacing.s)
            }

            content

            SheetButtonBar {
                Text("共 \(model.historyEntries.count) 条")
                    .font(Theme.Typo.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button("清除全部历史", role: .destructive) { confirmClearAll = true }
                    .disabled(model.historyEntries.isEmpty || model.isBusy)
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(width: Theme.Size.sheetWide, height: 520)
        .onAppear { model.loadHistoryForFocus() }
        .confirmationDialog("清除所有标签历史", isPresented: $confirmClearAll, titleVisibility: .visible) {
            Button("清除", role: .destructive) {
                Task { @MainActor in clearError = await model.clearAllHistory() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("确认要清除所有标签历史？撤消用的封面 / 歌词旁存也会一并删除，此后已保存的改动都无法再撤消。")
        }
        .alert("清除失败",
               isPresented: Binding(get: { clearError != nil }, set: { if !$0 { clearError = nil } })) {
            Button("好", role: .cancel) { clearError = nil }
        } message: {
            Text(clearError ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.historyEntries.isEmpty {
            EmptyStateView(systemImage: "clock.arrow.circlepath",
                           title: "暂无历史记录",
                           message: model.historyScopeIsAll
                               ? "还没有任何一次标签写入被存档"
                               : "当前文件还没有被写入过标签")
        } else {
            Table(model.historyEntries) {
                TableColumn("时间") { e in
                    Text(Formatters.dateTime(e.createdAt))
                        .font(Theme.Typo.digitsSmall)
                        .foregroundStyle(.secondary)
                }
                .width(132)
                TableColumn("标题") { e in cell(e.title) }
                TableColumn("艺术家") { e in cell(e.artist) }
                TableColumn("专辑") { e in cell(e.album) }
                TableColumn("文件") { e in
                    Text((e.filePath as NSString).lastPathComponent)
                        .font(Theme.Typo.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        // 列窄，长文件名一定被截；顺手把完整路径也给出来，
                        // 同名文件分散在多个目录时这一条才分得清是哪一个。
                        .help(e.filePath)
                }
                TableColumn("") { e in
                    Button("回滚") { model.undo(to: e) }
                        .buttonStyle(.link)
                        .font(Theme.Typo.caption)
                        .disabled(model.isBusy)   // 批量任务 / 收尾回读进行中不许单条回滚（模型层同样会拒绝）
                        .help("把该文件恢复到这次写入之前的标签")
                }
                .width(44)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .frame(maxHeight: .infinity)
        }
    }

    private func cell(_ value: String?) -> some View {
        Text(value?.isEmpty == false ? value! : "—")
            .font(Theme.Typo.caption)
            .foregroundStyle(value?.isEmpty == false ? Color.primary : Theme.Colors.placeholderText)
            .lineLimit(1).truncationMode(.tail)
            .help(value ?? "")   // 标题/艺术家/专辑列都窄，长值只能靠悬停看全
    }
}
