//
//  InspectorView.swift
//  MacTagger — 右栏检查器：封面 Hero + 标签 / 歌词 / 技术参数三张卡片 + 底部操作条
//
//  对应原版 FormMain 右侧 panel1。视觉方向参照 Meta(Nightbirds)：
//  大幅封面置顶、标签字段成组对齐、操作只在需要时出现，不堆按钮。
//
//  尺寸逐值抄自设计稿 build_directions.py 的 `hero`(heroStyle="big") / `card()` /
//  `field()` / `minifield()` / inspector 装配块：
//  检查器宽 336、内边距 16、Hero 与卡片区间隔 12、卡片之间 10；
//  大封面 176 / 圆角 12 / 投影 0 10px 26px；曲名 18px·600 + 7px 强调色圆点、
//  副标题 13px 次要色、封面计数行 11px；卡片圆角 10 内边距 12 标题 11px·600；
//  字段栅格 62pt + 弹性列 gap 10，输入框高 24 圆角 6 内边距 0 9 字号 13，数字字段等宽。
//

import SwiftUI
import AppKit
import ImageIO

struct InspectorView: View {

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Group {
            if model.selection.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                        InspectorHero()
                        // 设计稿：三张卡片自成一叠，卡片之间 10，与 Hero 之间 12。
                        VStack(alignment: .leading, spacing: Theme.Spacing.s2) {
                            TagsCard()
                            LyricsCard()
                            TechnicalInfoSection()
                        }
                    }
                    .padding(Theme.Spacing.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { actionBar }
            }
        }
        // 空态曾经把整个面板压塌，必须撑满。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 空态

    private var emptyState: some View {
        EmptyStateView(systemImage: "music.note.list",
                       title: "未选择文件",
                       message: "在列表中选择一个或多个文件，即可在这里编辑标签与封面")
    }

    // MARK: 底部操作条

    private var actionBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Spacing.s) {
                Button {
                    model.requestSave()
                } label: {
                    // 设计稿：主按钮占满剩余宽度（flex:1）。
                    Label("保存标签", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy || !model.hasPendingChanges)
                .help("把改动写入所选文件（⌘S）")

                Button {
                    model.requestUndo()
                } label: {
                    Label("撤消", systemImage: "arrow.uturn.backward")
                        .labelStyle(.iconOnly)
                }
                .disabled(model.isBusy)
                .help("撤消上一次保存，回滚到写入前的标签")

                // 多选态才出现：同一张碟里几首缺专辑/年份/封面时，这里一步到位。
                // 只是**备好选择并打开预览**，不静默写盘（见 AppModel+Propagate.swift）。
                if model.selectedCount > 1 {
                    Button {
                        model.presentPropagationFillFromMajority()
                    } label: {
                        Label("用组内多数值填空字段", systemImage: "square.stack.3d.up")
                            .labelStyle(.iconOnly)
                    }
                    .disabled(model.isBusy)
                    .help("用这几个文件里出现最多的值补齐空字段——先看预览表，确认后才写")
                }

                Spacer(minLength: Theme.Spacing.xs)

                Menu {
                    Button("清除标签", role: .destructive) { model.requestClearTags() }
                    Button("提取封面到文件夹") { model.requestExtractCovers() }
                    Button("从标签取图…") { model.presentArtworkFromTags() }
                    Divider()
                    Button("放弃未保存的改动") { model.revertSelected() }
                    Divider()
                    Toggle("保存时不改变文件修改时间", isOn: $settings.preserveModificationDate)
                    Toggle("添加封面时覆盖已有封面", isOn: $settings.overwriteArtworkOnAdd)
                } label: {
                    Label("更多", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("更多标签操作")
            }
            .controlSize(.large)
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.vertical, Theme.Spacing.m)
            // 设计稿这一条和检查器同底色，不做材质、不加发丝线。
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }
}

// MARK: - Hero：封面 + 曲名

struct InspectorHero: View {

    @EnvironmentObject private var model: AppModel
    @State private var isTargeted = false
    @State private var isHovering = false

    private var current: Artwork? {
        guard model.artworkIndex >= 0, model.artworkIndex < model.focusArtworks.count else { return nil }
        return model.focusArtworks[model.artworkIndex]
    }

    private var count: Int { model.focusArtworks.count }

    var body: some View {
        // 设计稿 hero：flex column、gap 10、padding 4px 0 0。
        VStack(spacing: Theme.Spacing.s2) {
            artwork
            if count > 1 { pageDots }
            titleBlock
        }
        .padding(.top, Theme.Spacing.xs)
        .frame(maxWidth: .infinity)
    }

    // MARK: 封面

    private var artwork: some View {
        ZStack {
            if let art = current, let image = NSImage(data: art.data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ArtworkPlaceholder(corner: Theme.Radius.l)
                if !isHovering {
                    Text("拖入图片添加封面")
                        .font(Theme.Typo.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, Theme.Size.inspectorHero * 0.34)
                }
            }
        }
        .frame(width: Theme.Size.inspectorHero, height: Theme.Size.inspectorHero)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous)
                .strokeBorder(isTargeted ? Theme.Colors.dropTarget : Theme.Colors.artworkStroke,
                              lineWidth: isTargeted ? 2 : 1)
        }
        .overlay(alignment: .bottom) { hoverBar }
        .overlay(alignment: .leading) { pageArrow(back: true) }
        .overlay(alignment: .trailing) { pageArrow(back: false) }
        // 设计稿 heroShadow：0 10px 26px（CSS 的 blur 半径约等于 SwiftUI radius 的两倍）。
        .shadow(color: Theme.Colors.artworkShadow, radius: 13, x: 0, y: 10)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) { isHovering = hovering }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $isTargeted) { providers in
            model.handleArtworkDrop(providers)
        }
        .help("拖入图片可直接添加封面")
    }

    /// 悬停才浮现的操作条：平时封面是干净的。
    @ViewBuilder
    private var hoverBar: some View {
        if isHovering {
            HStack(spacing: Theme.Spacing.xs) {
                iconButton("plus", "添加封面") { model.presentAddArtwork() }
                iconButton("trash", "删除当前封面", enabled: current != nil) { model.removeCurrentArtwork() }
                iconButton("square.and.arrow.up", "导出当前封面", enabled: current != nil) {
                    model.exportCurrentArtwork()
                }
                iconButton("arrow.up.forward.square", "用预览打开", enabled: current != nil) {
                    model.openCurrentArtwork()
                }
                // 本轮补齐的两项：从网络搜索封面 / 调整分辨率与压缩。
                iconButton("magnifyingglass", "从网络搜索封面") { model.presentArtworkSearch() }
                iconButton("slider.horizontal.3", "调整分辨率 / 压缩", enabled: current != nil) {
                    model.presentArtworkAdjust()
                }
                if let art = current {
                    Divider().frame(height: 14)
                    Menu {
                        Picker("封面类型", selection: Binding(
                            get: { art.type },
                            set: { model.setCurrentArtworkType($0) })) {
                            ForEach(PictureType.allCases, id: \.self) { type in
                                Text(type.localizedName).tag(type)
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Text(art.type.localizedName)
                            .font(Theme.Typo.badge)
                            .lineLimit(1)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("封面类型")
                }
            }
            .padding(.horizontal, Theme.Spacing.s)
            .padding(.vertical, Theme.Spacing.xs)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.Colors.hairline))
            .padding(.bottom, Theme.Spacing.s)
            .transition(.opacity)
        }
    }

    private func iconButton(_ symbol: String, _ help: String,
                            enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }

    @ViewBuilder
    private func pageArrow(back: Bool) -> some View {
        if count > 1 && isHovering {
            Button {
                let next = back ? model.artworkIndex - 1 : model.artworkIndex + 1
                model.artworkIndex = (next + count) % count
            } label: {
                Image(systemName: back ? "chevron.left" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .background(.regularMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(Theme.Colors.hairline))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Theme.Spacing.s)
            .transition(.opacity)
            .help(back ? "上一张封面" : "下一张封面")
        }
    }

    private var pageDots: some View {
        HStack(spacing: Theme.Spacing.xs) {
            ForEach(0..<count, id: \.self) { i in
                Circle()
                    .fill(i == model.artworkIndex ? Color.accentColor : Theme.Colors.hairline)
                    .frame(width: Theme.Size.heroDot, height: Theme.Size.heroDot)
                    .onTapGesture { model.artworkIndex = i }
            }
        }
        .help("共 \(count) 张封面")
    }

    // MARK: 曲名区

    private var titleBlock: some View {
        // 设计稿：曲名行 / 副标题(margin-top 3) / 封面计数行(margin-top 6)，整体居中。
        VStack(spacing: 0) {
            HStack(spacing: Theme.Spacing.s) {
                Text(heroTitle)
                    .font(Theme.Typo.heroTitle)
                    .tracking(-0.2)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                // 设计稿把「有未保存改动」的 7px 圆点放在曲名之后。
                if model.hasPendingChanges {
                    StatusDot(color: Theme.Colors.dirty)
                        .help("有未保存的改动")
                }
            }

            if !heroSubtitle.isEmpty {
                Text(heroSubtitle)
                    .font(Theme.Typo.heroSubtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.top, 3)
            }

            if let coverInfo {
                HStack(spacing: Theme.Spacing.xs2) {
                    Image(systemName: "photo")
                    Text(coverInfo)
                }
                .font(Theme.Typo.small)
                .foregroundStyle(.secondary)
                .padding(.top, Theme.Spacing.xs2)
            }

            if model.selection.count > 1 {
                Chip(text: "已选 \(model.selection.count) 个文件", tinted: true)
                    .padding(.top, Theme.Spacing.xs2)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// 设计稿的「1 张封面 · 1200×1200」一行。像素尺寸优先用标签里声明的，
    /// 没声明就问 ImageIO 要图头（只读元数据，不解码整张图）。
    private var coverInfo: String? {
        guard count > 0 else { return nil }
        var text = "\(count) 张封面"
        if let art = current {
            let size = Self.pixelSize(art)
            if size.width > 0, size.height > 0 {
                text += " · \(size.width)×\(size.height)"
            }
        }
        return text
    }

    private static func pixelSize(_ art: Artwork) -> (width: Int, height: Int) {
        if art.declaredWidth > 0, art.declaredHeight > 0 {
            return (art.declaredWidth, art.declaredHeight)
        }
        guard let source = CGImageSourceCreateWithData(art.data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return (0, 0) }
        return (w, h)
    }

    private var heroTitle: String {
        if model.selection.count > 1 {
            if model.isMixed(.title) { return "多个文件" }
            let t = model.mergedValue(.title) ?? ""
            return t.isEmpty ? "多个文件" : t
        }
        guard let row = model.focusRow else { return "—" }
        let t = (row.draft.title ?? "").trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? row.fileName : t
    }

    private var heroSubtitle: String {
        let artist = model.isMixed(.artist) ? "多个艺术家" : (model.mergedValue(.artist) ?? "")
        let album = model.isMixed(.album) ? "多张专辑" : (model.mergedValue(.album) ?? "")
        return [artist, album].filter { !$0.isEmpty }.joined(separator: "  —  ")
    }
}

// MARK: - 标签卡片

struct TagsCard: View {

    @EnvironmentObject private var model: AppModel

    private static let basic: [EditorField] = [.title, .artist, .album, .albumArtist]
    private static let numbers: [EditorField] = [.year, .track, .disc]
    private static let more: [EditorField] = [.genre, .composer, .lyricist, .comment]

    /// 自绘输入框没有系统的聚焦环，用它把描边换成强调色。
    @FocusState private var focused: EditorField?

    var body: some View {
        // 设计稿 card()：内部 gap 8、标题 11/600 次要色。
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            SectionHeader("标签") {
                if model.selection.count > 1 {
                    Chip(text: "\(model.selection.count) 项", tinted: true)
                }
            }

            ForEach(Self.basic) { fieldRow($0) }

            // 设计稿：四个基本字段与三个数字字段之间一条发丝线（margin:2px 0）。
            Rectangle()
                .fill(Theme.Colors.hairline)
                .frame(height: 1)
                .padding(.vertical, Theme.Spacing.xxs)

            // 设计稿：年份 / 音轨 / 碟号是三等分栅格（gap 8），标签在框上方。
            HStack(alignment: .top, spacing: Theme.Spacing.s) {
                ForEach(Self.numbers) { miniField($0) }
            }

            ForEach(Self.more) { fieldRow($0) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    /// 设计稿 field()：62pt 右对齐标签 + 弹性输入框，中间 gap 10。
    private func fieldRow(_ field: EditorField) -> some View {
        HStack(spacing: Theme.Spacing.s2) {
            Text(field.label)
                .font(Theme.Typo.fieldLabel)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: Theme.Size.fieldLabelWidth, alignment: .trailing)

            fieldBox(field)
        }
    }

    /// 设计稿 minifield()：11px 标签在上、gap 4、输入框等宽字体。
    private func miniField(_ field: EditorField) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(field.label)
                .font(Theme.Typo.small)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            fieldBox(field, mono: true)
        }
        .frame(maxWidth: .infinity)
    }

    /// 设计稿的输入框：高 24、圆角 6、内边距 0 9、字号 13、1px 描边。
    /// 原生 `.roundedBorder` 的高度、圆角、内边距都对不上，这里自绘外框，
    /// 行为仍是标准 `TextField`（多选时占位「多个值」、编辑即写回 draft）。
    private func fieldBox(_ field: EditorField, mono: Bool = false) -> some View {
        TextField(
            model.isMixed(field) ? "多个值" : "",
            text: Binding(
                get: { model.mergedValue(field) ?? "" },
                set: { model.apply(field, $0) })
        )
        .textFieldStyle(.plain)
        .font(mono ? Theme.Typo.valueMono : Theme.Typo.value)
        .focused($focused, equals: field)
        .padding(.horizontal, Theme.Size.fieldPadding)
        .frame(height: Theme.Size.fieldHeight)
        .background(Color(nsColor: .textBackgroundColor),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous)
                .strokeBorder(focused == field ? Color.accentColor : Theme.Colors.fieldStroke,
                              lineWidth: focused == field ? 2 : 1)
        )
    }
}

// MARK: - 歌词卡片

struct LyricsCard: View {

    @EnvironmentObject private var model: AppModel

    private var text: String { model.mergedValue(.lyrics) ?? "" }
    private var isMixed: Bool { model.isMixed(.lyrics) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            SectionHeader("歌词") {
                HStack(spacing: Theme.Spacing.xs) {
                    if isMixed {
                        Chip(text: "多个值")
                    } else if !text.isEmpty {
                        Chip(text: "\(LyricsGlance.lineCount(text)) 行")
                        if LyricsGlance.hasTimestamps(text) {
                            Chip(text: "时间轴", systemImage: "clock")
                        }
                        Chip(text: LyricsGlance.hasTranslation(text) ? "含翻译" : "无翻译")
                    }
                }
            }

            if isMixed {
                Text("所选文件的歌词不一致，打开编辑器会以第一个文件为准并覆盖全部选中项。")
                    .font(Theme.Typo.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if text.isEmpty {
                Text("暂无歌词")
                    .font(Theme.Typo.caption)
                    .foregroundStyle(.tertiary)
            } else {
                // 设计稿 lyric_inner：12px 等宽、line-height 1.5（12 × 1.5 - 12 = 6 的行距）。
                VStack(alignment: .leading, spacing: Theme.Spacing.xs2) {
                    ForEach(Array(LyricsGlance.preview(text).enumerated()), id: \.offset) { pair in
                        Text(pair.element)
                            .font(Theme.Typo.techValue)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: Theme.Spacing.s) {
                Button {
                    model.presentLyricsEditor()
                } label: {
                    Label("打开编辑器", systemImage: "square.and.pencil")
                }
                .help("打开歌词编辑器（⇧⌘L）")

                Button {
                    model.presentLyricsSearch()
                } label: {
                    Label("搜索歌词", systemImage: "magnifyingglass")
                }
                .disabled(model.isBusy)
                .help("联网搜索这首歌的歌词（⌥⌘L）")

                Spacer()
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// 歌词卡片用的轻量判读：只看形状，不解析语义。
enum LyricsGlance {

    static func lineCount(_ text: String) -> Int {
        text.isEmpty ? 0 : text.components(separatedBy: "\n").count
    }

    static func hasTimestamps(_ text: String) -> Bool {
        !LyricsHighlighter.timestampRanges(in: text as NSString).isEmpty
    }

    /// 同一个时间戳出现两次以上，基本可以断定是「原词 + 翻译」合并过的。
    static func hasTranslation(_ text: String) -> Bool {
        let doc = LrcDocument.parse(text)
        var seen = Set<Int>()
        for line in doc.lines {
            guard let t = line.firstTimestamp, !line.isBlankText else { continue }
            let key = Int((t * 100).rounded())
            if seen.contains(key) { return true }
            seen.insert(key)
        }
        return false
    }

    /// 预览前若干行（跳过头部标签行，去掉时间戳）。
    static func preview(_ text: String, limit: Int = 3) -> [String] {
        let doc = LrcDocument.parse(text)
        var out: [String] = []
        for line in doc.lines where !line.isBlankText {
            out.append(line.text.trimmingCharacters(in: .whitespaces))
            if out.count >= limit { break }
        }
        if out.isEmpty {
            out = text.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .prefix(limit)
                .map { $0 }
        }
        return out
    }
}

// MARK: - 技术参数卡片

struct TechnicalInfoSection: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            SectionHeader("技术参数") {
                if let row = model.focusRow {
                    Chip(text: row.file.technical.isLossless ? "无损" : "有损")
                }
            }

            if model.selection.count > 1 {
                Text("已选择多个文件，这里只显示第一个文件的参数。")
                    .font(Theme.Typo.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let row = model.focusRow {
                // 设计稿 tech_inner：两列栅格，gap 6px（行） / 14px（列）。
                Grid(alignment: .leading,
                     horizontalSpacing: 14,
                     verticalSpacing: Theme.Spacing.xs2) {
                    KeyValueRow(label: "时长", value: row.file.technical.formattedDuration, mono: true)
                    KeyValueRow(label: "比特率",
                                value: row.file.technical.bitrateKbps > 0
                                    ? "\(row.file.technical.bitrateKbps) kbps" : "",
                                mono: true)
                    KeyValueRow(label: "采样率",
                                value: row.file.technical.sampleRate > 0
                                    ? "\(row.file.technical.sampleRate) Hz" : "",
                                mono: true)
                    KeyValueRow(label: "声道", value: "\(row.file.technical.channels)", mono: true)
                    KeyValueRow(label: "位深",
                                value: row.file.technical.bitsPerSample > 0
                                    ? "\(row.file.technical.bitsPerSample) bit" : "",
                                mono: true)
                    KeyValueRow(label: "容器", value: row.file.technical.containerName)
                    KeyValueRow(label: "编码", value: row.file.technical.codecName)
                    KeyValueRow(label: "标签格式", value: row.file.tagContainers.joined(separator: ", "))
                    KeyValueRow(label: "大小", value: Formatters.fileSize(row.fileSize), mono: true)
                    KeyValueRow(label: "修改时间",
                                value: row.modifiedAt.map(Formatters.dateTime) ?? "", mono: true)
                    KeyValueRow(label: "目录", value: row.directory)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
