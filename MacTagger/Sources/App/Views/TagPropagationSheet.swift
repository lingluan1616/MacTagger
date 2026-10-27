//
//  TagPropagationSheet.swift
//  MacTagger — 「统一 / 补齐标签」窗口
//
//  一屏四段，自上而下就是用户的思路：
//    ① 范围 —— 按文件夹 / 按专辑标签 / 当前选中作为一组，再从下拉里挑具体哪一组；
//    ② 字段 —— 逐字段看到组内出现过的值与各自的份数，勾要统一的、选统一到哪个值；
//    ③ 模式 —— 只填空的（默认）还是连写错的一起纠正；
//    ④ 预览 —— 哪个文件的哪个字段「原 → 新」，确认无误再应用。
//
//  骨架与用词与其余 sheet 一致：`SheetTitleBar` → 内容 → `SheetButtonBar`，
//  「原 → 新」直接复用复核表那块砖（`OldNewCell`），行首状态点复用 `StatusDot`。
//  宽度 `Theme.Size.sheetWide`（860）—— 字段行要同时摆下「值下拉 + 空值数 + 一致性」，
//  再窄下拉就会把值截成省略号，那正是这个功能最该让人看清的一列。
//

import SwiftUI
import AppKit

struct TagPropagationSheet: View {

    @EnvironmentObject private var model: AppModel
    @ObservedObject private var store = TagPropagationStore.shared

    // 字段表的列宽（与预览表各自独立，两张表的语义不同，不强行对齐）
    private enum Col {
        static let check: CGFloat = 20
        static let name: CGFloat = 76
        static let empty: CGFloat = 62
        static let status: CGFloat = 104
        // 预览表
        static let file: CGFloat = 208
        static let field: CGFloat = 72
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetTitleBar(systemImage: "square.stack.3d.up",
                          title: "统一 / 补齐标签",
                          subtitle: "同一张碟里多数文件写着一样的专辑、年份、艺术家与封面，只有几首是空的。这里逐字段看组内出现过的值，挑一个统一过去。") {
                Chip(text: store.status, tinted: false)
            }

            scopeBar
            Divider()
            fieldTable
            Divider()
            modeBar
            Divider()
            previewTable

            SheetButtonBar {
                footerText
                Spacer(minLength: Theme.Spacing.m)
                Button("关闭") {
                    // 表内补读还在跑就一并作废（已读完的块照常落了行，不会白读）。
                    model.cancelPropagationPendingLoad(silently: true)
                    ArtworkSheetPresenter.shared.dismiss()
                }
                    .keyboardShortcut(.cancelAction)
                Button(applyTitle) { apply() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(store.plan.isEmpty || model.isBusy
                              || store.isLoadingGroup || store.pendingLoad != nil)
                    .help("按预览表批量写入。写入前会自动记录撤消快照，可用「撤消标签保存」整批回滚。")
            }
        }
        .frame(width: Theme.Size.sheetWide, height: 660)
        // 排队弹出（请求时主窗口上还挂着别的 sheet）的那一次，等本表**真正挂上**主窗口时按最新数据
        // 重建分组、重算计划；平时打开前已经算好，这里什么也不做（BO #42）。
        // 不用 `.onAppear`：离屏工装实测，排队中的 sheet 窗口一建好 SwiftUI 就报了 onAppear，
        // 那时前一张 sheet 还开着、文件还没被它改写，刷了等于没刷。
        .background(PropagationWindowProbe { model.propagationSheetWindowReady($0) })
    }

    // MARK: ① 范围

    private var scopeBar: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack(spacing: Theme.Spacing.m) {
                Picker("", selection: groupingBinding) {
                    ForEach(PropagationGrouping.allCases) { g in
                        Text(g.localizedName).tag(g)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 340)
                .help(store.grouping.hint)

                Picker("", selection: groupBinding) {
                    ForEach(store.groups) { g in
                        Text(g.count > 0 ? "\(g.title)  （\(g.count) 个文件）" : g.title).tag(g.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .disabled(store.groups.count <= 1)
                // 组名是专辑名或文件夹名，长起来没边；下拉本身会截，这里挂全文。
                .help(store.selectedGroup.map { "\($0.title)（\($0.count) 个文件）" }
                        ?? "没有可用的分组")

                if store.isLoadingGroup { ProgressView().controlSize(.small) }
                // 正在补读待读行（组内还有没读标签的文件）：给一个就地取消的口子。
                if store.pendingLoad != nil {
                    Button("取消读取") { model.cancelPropagationPendingLoad() }
                        .controlSize(.small)
                        .help("停止读取本组待读文件的标签。标签没读出来的文件不能参与统一。")
                }
            }

            HStack(spacing: Theme.Spacing.s) {
                if let g = store.selectedGroup, !g.subtitle.isEmpty {
                    Text(g.subtitle)
                        .font(Theme.Typo.badge)
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .help(g.subtitle)
                }
                Spacer(minLength: 0)
                if store.dirtyInGroup > 0 {
                    Label("组内 \(store.dirtyInGroup) 个文件有未保存改动，应用后会以磁盘现状为准",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.Typo.badge)
                        .foregroundStyle(Theme.Colors.warning)
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.m)
    }

    // MARK: ② 字段表

    private var fieldTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Spacing.s) {
                // 必须给定高：`Color` 在两个轴上都是可无限拉伸的，只写 width 的话
                // 这一格会把表头撑到「剩下多少吃多少」，把下面的表挤成一条缝。
                Color.clear.frame(width: Col.check, height: 1)
                Text("字段").frame(width: Col.name, alignment: .leading)
                Text("统一为（组内出现过的值 × 份数）").frame(maxWidth: .infinity, alignment: .leading)
                Text("空值").frame(width: Col.empty, alignment: .trailing)
                Text("一致性").frame(width: Col.status, alignment: .leading)
            }
            .font(Theme.Typo.tableHeader)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.xs)

            Divider()

            if store.surveys.isEmpty {
                EmptyStateView(systemImage: "square.stack.3d.up.slash",
                               title: store.isLoadingGroup ? "正在统计…" : "没有可统计的字段",
                               message: store.isLoadingGroup ? nil : "先在主窗口载入文件，再回到这里")
                    .frame(height: 232)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(store.surveys.enumerated()), id: \.element.id) { i, s in
                            fieldRow(s)
                                .background(i.isMultiple(of: 2) ? Color.clear : Theme.Colors.rowAlt)
                        }
                    }
                }
                .frame(height: 240)
            }
        }
    }

    @ViewBuilder
    private func fieldRow(_ s: FieldSurvey) -> some View {
        let on = store.enabledFields.contains(s.field.id)
        HStack(spacing: Theme.Spacing.s) {
            Toggle("", isOn: enableBinding(s))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .frame(width: Col.check)
                .disabled(s.isAllEmpty)

            Text(s.field.localizedName)
                .font(Theme.Typo.tableCell)
                .foregroundStyle(s.field.isGroupLevel ? Color.primary : Color.secondary)
                .frame(width: Col.name, alignment: .leading)
                .help(s.field.isGroupLevel ? "整组通常一致的字段"
                                           : "逐首各不相同的字段，一般不该统一 —— 确实要统一请自行勾选")

            valueChooser(s, enabled: on)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(s.emptyCount > 0 ? "\(s.emptyCount)" : "—")
                .font(Theme.Typo.tableCell)
                .monospacedDigit()
                .foregroundStyle(s.emptyCount > 0 ? Color.accentColor : Theme.Colors.placeholderText)
                .frame(width: Col.empty, alignment: .trailing)

            HStack(spacing: Theme.Spacing.xs) {
                StatusDot(color: statusColor(s))
                Text(s.statusText)
                    .font(Theme.Typo.badge)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: Col.status, alignment: .leading)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.xs2)
    }

    private func statusColor(_ s: FieldSurvey) -> Color {
        if s.isAllEmpty { return Theme.Colors.readOnly }
        if s.isUniform { return Theme.Colors.matched }
        if !s.isConsistent { return Theme.Colors.warning }
        return Color.accentColor
    }

    /// 值选择：封面行画缩略图，其余画下拉 +（选了「自定义…」时）一个输入框。
    @ViewBuilder
    private func valueChooser(_ s: FieldSurvey, enabled: Bool) -> some View {
        if case .artwork = s.field {
            artworkChooser(s, enabled: enabled)
        } else {
            HStack(spacing: Theme.Spacing.s) {
                Picker("", selection: choiceBinding(s)) {
                    // 「多数值」直接标在选项文字里，而不是在下拉外面另挂一个标签 ——
                    // 挂在外面时它会随下拉宽度浮动，行与行对不齐，反而看不出哪个是默认。
                    ForEach(Array(s.buckets.enumerated()), id: \.element.id) { i, b in
                        Text("\(b.display)　×\(b.count)" + (i == 0 ? "（多数值）" : "")).tag(b.id)
                    }
                    Divider()
                    Text("自定义…").tag(TagPropagationStore.customChoiceID)
                }
                .labelsHidden()
                // 300：下拉 300 + 间距 8 + 自定义输入框 190 = 498，仍窄于这一列的 ~518 pt，
                // 「自定义…」展开时不会把输入框挤出去。
                .frame(width: 300)
                .disabled(!enabled)
                // 下拉宽度有限，长值一定会截成省略号 —— 全文挂在这里，
                // 且**跟着当前选中项走**，不是只报多数值。
                .help(choiceHelp(s))

                if store.choiceByField[s.field.id] == TagPropagationStore.customChoiceID {
                    TextField("手输一个值", text: customBinding(s))
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.Typo.tableCell)
                        .frame(maxWidth: 190)
                        .disabled(!enabled)
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// 封面候选条。**候选数量没有上限**（一组最多 400 个文件，理论上就有 400 张不同的图），
    /// 所以这一条必须能横向滚，且要让人一眼看出「还有」：
    ///
    /// * 旧版把「×份数 + 尺寸 + 字节」摆在缩略图右边，一格 154 pt，
    ///   这一列只有 ~518 pt，**三张半就到头**，第四张起直接被右边的「空值 / 一致性」
    ///   两列压掉；滚动条又是 `showsIndicators: false`，于是屏幕上没有任何东西
    ///   暗示后面还有候选 —— 用户的原话是「超过 4 个就看不到了」。
    /// * 新版一格只留 44 pt 缩略图（份数压在图角上），尺寸/字节/示例文件全部挪进
    ///   **悬停预览**（`ArtworkHoverPreview`，停 300 ms 弹 320 pt 大图，点一下 640 pt）——
    ///   挑封面本来就要看图，不是看数字。一格 56 pt，同样的宽度能摆下 9 张；
    ///   再多就横向滚，且滚动条常驻（`.scrollIndicators(.visible)`）。
    /// * `LazyHStack`：400 张候选时不会一次性把 400 个 `NSImage` 建出来。
    @ViewBuilder
    private func artworkChooser(_ s: FieldSurvey, enabled: Bool) -> some View {
        if s.buckets.isEmpty {
            Text(store.artworkReady ? "组内没有任何封面" : "封面未统计")
                .font(Theme.Typo.badge)
                .foregroundStyle(Theme.Colors.placeholderText)
        } else {
            let chosen = store.choiceByField[s.field.id] ?? s.majority?.id
            HStack(spacing: Theme.Spacing.xs2) {
                // 张数常驻在滚动区**外面**：macOS 默认是覆盖式滚动条，不滚的时候
                // 根本不画，`.scrollIndicators(.visible)` 也救不回来。所以「一共几张」
                // 必须有一个不依赖滚动条的说法，否则又回到「看不出后面还有」。
                Text("\(s.buckets.count) 张")
                    .font(Theme.Typo.badge)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .help("组内共有 \(s.buckets.count) 张不同的封面。"
                          + "悬停缩略图看 \(Int(Theme.Size.reviewPreview)) pt 大图，点一下选中；"
                          + "候选多时这一条可以横向滚动。")

                ScrollView(.horizontal) {
                    LazyHStack(spacing: Theme.Spacing.xs2) {
                        ForEach(s.buckets) { b in
                            artworkCell(b, selected: b.id == chosen, enabled: enabled) {
                                store.choiceByField[s.field.id] = b.id
                                model.recomputePropagationPlan()
                            }
                        }
                    }
                    .padding(.vertical, 1)
                    // 选中框有 1.5 pt 描边，末尾留一点余量免得被滚动区裁掉半条
                    .padding(.trailing, 2)
                }
                .scrollIndicators(.visible)
            }
            .frame(height: Self.artworkStripHeight)
        }
    }

    /// 缩略图 44 + cell padding 3×2 + 常驻滚动条留白。
    ///
    /// 「共几张」不另起一行说 —— 右边「一致性」列已经写着「N 种值」，
    /// 再加一行只会把这一行顶出字段表的 240 pt 视口（份数、提示语一起看不见）。
    private static let artworkThumb: CGFloat = 44
    private static let artworkStripHeight: CGFloat = 62

    private func artworkCell(_ b: FieldValueBucket, selected: Bool, enabled: Bool,
                             action: @escaping () -> Void) -> some View {
        ArtworkHoverPreview(image: b.artwork.flatMap { NSImage(data: $0.data) },
                            meta: artworkMeta(b),
                            size: Self.artworkThumb,
                            corner: Theme.Radius.xs,
                            help: artworkHelp(b))
            // 份数压在图角上而不是另起一行：一行 13 pt 的代价是整行高出 20 pt，
            // 而这一行本来就快顶到字段表视口的底了。`.regularMaterial` 保证
            // 压在亮图与暗图上都读得出来。
            .overlay(alignment: .bottomLeading) {
                Text("×\(b.count)")
                    .font(Theme.Typo.badge)
                    .monospacedDigit()
                    .foregroundStyle(selected ? Color.accentColor : Color.primary)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 0.5)
                    .background(.regularMaterial,
                                in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .padding(2)
            }
            .padding(3)
            .background(selected ? Theme.Colors.accentSoft : Color.clear,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 1.5))
            .contentShape(Rectangle())
            .onTapGesture { if enabled { action() } }
            .opacity(enabled ? 1 : 0.45)
            .accessibilityLabel(artworkHelp(b))
    }

    /// 悬停预览面板里那行元信息。
    /// 标签里声明的尺寸常常是 0（多数写入方不填），所以这里从图片头部实读一次；
    /// `pixelSize` 只解 header，不解码像素。
    private func artworkMeta(_ b: FieldValueBucket) -> ArtworkMeta? {
        guard let d = b.artwork?.data else { return nil }
        let px = ArtworkProcessor.pixelSize(d)
        return ArtworkMeta(pixelWidth: px.width, pixelHeight: px.height,
                           byteCount: d.count,
                           mime: b.artwork?.mimeType ?? ArtworkMeta.mime(of: d),
                           source: "组内 \(b.count) 个文件用这张",
                           role: "候选封面 · 例如 " + b.exampleFile.lastPathComponent)
    }

    private func artworkHelp(_ b: FieldValueBucket) -> String {
        var parts = ["组内 \(b.count) 个文件用这张"]
        if let d = b.artwork?.data {
            let px = ArtworkProcessor.pixelSize(d)
            if px.width > 0 { parts.append("\(px.width)×\(px.height)") }
            parts.append(TagService.humanBytes(Int64(d.count)))
        }
        parts.append("例如 " + b.exampleFile.lastPathComponent)
        return parts.joined(separator: " · ")
    }

    // MARK: ③ 模式

    private var modeBar: some View {
        HStack(spacing: Theme.Spacing.m) {
            Picker("", selection: modeBinding) {
                ForEach(PropagationMode.allCases) { m in
                    Text(m.localizedName).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)

            Text(store.mode.hint)
                .font(Theme.Typo.badge)
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
                .help(store.mode.hint)

            Spacer(minLength: 0)

            Button("按多数值全勾") {
                store.preselect()
                store.choiceByField.removeAll()
                model.recomputePropagationPlan()
            }
            .buttonStyle(.link)
            .font(Theme.Typo.badge)
            .help("把有空缺或不一致的整组级字段全部勾上，值取组内多数值")

            Button("全不勾") {
                store.enabledFields.removeAll()
                model.recomputePropagationPlan()
            }
            .buttonStyle(.link)
            .font(Theme.Typo.badge)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.s)
    }

    // MARK: ④ 预览

    private var previewTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Spacing.s) {
                Color.clear.frame(width: Theme.Size.statusDot, height: 1)   // 同上：Color 必须给定高
                Text("文件").frame(width: Col.file, alignment: .leading)
                Text("字段").frame(width: Col.field, alignment: .leading)
                Text("原 → 新").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(Theme.Typo.tableHeader)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.xs)

            Divider()

            // GeometryReader 给滚动区一个**确定**高度，而不是让它自己去要
            // `maxHeight: .infinity`。ScrollView 会把「内容的理想高度」（几百行加起来
            // 几千 pt）往上报，父容器据此排版就会算歪；GeometryReader 不向上传递子视图的
            // 理想尺寸，`geo.size.height` 就是这一段真正剩下的空间，且不必写死任何数字。
            // （本轮离屏渲染图上表头下方那条空带另有其因 —— 见上面表头里 `Color.clear`
            //   必须给定高的注释 —— 两处一起改掉才彻底。）
            GeometryReader { geo in
                previewBody
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var previewBody: some View {
        Group {
            if store.plan.changes.isEmpty {
                EmptyStateView(systemImage: "checkmark.seal",
                               title: "0 个文件需要修改",
                               message: store.enabledFields.isEmpty
                                   ? "在上面勾选要统一的字段"
                                   : "勾选的字段在这一组里已经对齐了；想连写着别的值的一起纠正，把模式切到「覆盖不一致的值」")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // 只画前 `previewLimit` 行，且用普通 VStack 而不是 LazyVStack：
                // 一次统一动辄改几千处（3000 个文件 × 6 个字段），没人会去滚第 400 行以后
                // —— 预览是用来抽查「有没有改错」的，不是逐条审计。行数一封顶，
                // 普通 VStack 又快又稳，也省掉懒加载在离屏渲染下的那些不确定性。
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(previewShown.enumerated()), id: \.element.id) { i, c in
                            previewRow(c)
                                .background(i.isMultiple(of: 2) ? Color.clear : Theme.Colors.rowAlt)
                        }
                        if store.plan.changeCount > previewShown.count {
                            Text("…以及另外 \(store.plan.changeCount - previewShown.count) 处改动"
                                 + "（共 \(store.plan.changeCount) 处，全部都会写入）")
                                .font(Theme.Typo.badge)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, Theme.Spacing.xl)
                                .padding(.vertical, Theme.Spacing.s)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
    }

    /// 预览表最多画这么多行，其余折成一句「另有 N 处」。全部改动仍然照写。
    private static let previewLimit = 400

    private var previewShown: [PropagationChange] {
        Array(store.plan.changes.prefix(Self.previewLimit))
    }

    private func previewRow(_ c: PropagationChange) -> some View {
        HStack(spacing: Theme.Spacing.s) {
            // 补空 = 强调色（本功能的主业），纠正已有值 = 橙色（动到了原有数据，值得多看一眼）
            StatusDot(color: c.wasEmpty ? Color.accentColor : Theme.Colors.warning)
            Text(c.fileName)
                .font(Theme.Typo.tableCellSmall)
                .lineLimit(1).truncationMode(.middle)
                .frame(width: Col.file, alignment: .leading)
                .help(c.url.path)
            Text(c.field.localizedName)
                .font(Theme.Typo.tableCellSmall)
                .foregroundStyle(.secondary)
                .frame(width: Col.field, alignment: .leading)
            OldNewCell(old: c.oldValue, new: c.newValue,
                       font: Theme.Typo.tableCellSmall,
                       help: "\(c.fileName) · \(c.field.localizedName)")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.xs)
    }

    // MARK: 底部

    @ViewBuilder
    private var footerText: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(store.plan.summary)
                .font(Theme.Typo.caption)
                .foregroundStyle(store.plan.isEmpty ? Color.secondary : Color.primary)
            if let cost = store.costText {
                Text(cost)
                    .font(Theme.Typo.badge)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(cost)
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
    }

    private var applyTitle: String {
        store.plan.isEmpty ? "应用" : "应用到 \(store.plan.fileCount) 个文件"
    }

    private func apply() {
        let edits = store.plan.edits
        guard !edits.isEmpty else { return }
        ArtworkSheetPresenter.shared.dismiss()
        model.performTagPropagation(edits)
    }

    // MARK: 绑定

    private var groupingBinding: Binding<PropagationGrouping> {
        Binding(get: { store.grouping },
                set: { g in
                    // 换分组方式：按专辑分组要先把池里的待读行读回来，交给 model 统一处理。
                    model.changePropagationGrouping(g)
                })
    }

    private var groupBinding: Binding<String> {
        Binding(get: { store.selectedGroupID ?? store.groups.first?.id ?? "" },
                set: { id in
                    store.selectedGroupID = id
                    store.resetChoices()
                    model.loadPropagationGroup()
                })
    }

    private var modeBinding: Binding<PropagationMode> {
        Binding(get: { store.mode },
                set: { store.mode = $0; model.recomputePropagationPlan() })
    }

    private func enableBinding(_ s: FieldSurvey) -> Binding<Bool> {
        Binding(get: { store.enabledFields.contains(s.field.id) },
                set: { on in
                    if on { store.enabledFields.insert(s.field.id) }
                    else { store.enabledFields.remove(s.field.id) }
                    model.recomputePropagationPlan()
                })
    }

    private func choiceBinding(_ s: FieldSurvey) -> Binding<String> {
        Binding(get: {
                    store.choiceByField[s.field.id]
                        ?? s.majority?.id
                        ?? TagPropagationStore.customChoiceID
                },
                set: { store.choiceByField[s.field.id] = $0; model.recomputePropagationPlan() })
    }

    /// 值下拉的 tooltip：当前选中的那一项的**完整**取值 + 多数值 + 示例文件。
    private func choiceHelp(_ s: FieldSurvey) -> String {
        guard !s.buckets.isEmpty else { return "组内没有任何取值，只能自己输一个" }
        let id = store.choiceByField[s.field.id]
        if id == TagPropagationStore.customChoiceID {
            let v = store.customByField[s.field.id] ?? ""
            return v.isEmpty ? "自定义：还没输入" : "自定义：" + v
        }
        let picked = id.flatMap { pid in s.buckets.first { $0.id == pid } } ?? s.majority
        guard let b = picked else { return "组内没有任何取值，只能自己输一个" }
        var line = "\(b.display)　—— 组内 \(b.count) 个文件，例如 \(b.exampleFile.lastPathComponent)"
        if let m = s.majority, m.id != b.id { line += "\n（多数值是 \(m.display)）" }
        return line
    }

    private func customBinding(_ s: FieldSurvey) -> Binding<String> {
        Binding(get: { store.customByField[s.field.id] ?? "" },
                set: { store.customByField[s.field.id] = $0; model.recomputePropagationPlan() })
    }
}

// MARK: - 窗口探针

/// 把本表所在的 `NSWindow` 交给 model：排队弹出时靠它判断「真的挂到主窗口上了」。
private struct PropagationWindowProbe: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> ProbeView {
        let v = ProbeView()
        v.onWindow = onWindow
        return v
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.onWindow = onWindow
    }

    final class ProbeView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let w = window { onWindow?(w) }
        }
    }
}
