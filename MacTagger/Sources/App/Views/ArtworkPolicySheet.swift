//
//  ArtworkPolicySheet.swift
//  MacTagger — 「封面与写入选项」
//
//  两件事、一套控件：
//    * **封面存到哪** —— 嵌进音频标签 / 存成专辑目录里的图片 / 两者都写；
//    * **写完要不要预留填充** —— 在那次「反正要整文件重写」的保存之后把文件头填充
//      一次扩到位，之后换封面、改标题都能原地完成。
//
//  为什么值得单开一个窗：用户的无损库在 TF 卡上，一张 1 MB 的封面塞不进 FLAC 头部
//  那几 KB 的 PADDING，TagLib 就要把整段音频（几十 MB）后移一遍。这两个开关是绕开
//  这件事的全部手段，藏在偏好设置深处等于没有。
//
//  `ArtworkPolicyOptionsView` 是可复用主体：这里铺开用，自动匹配选项 sheet 里
//  `compact: true` 嵌一份（同一份设置，用户在哪改都一样）—— 与 `LyricsFileOptionsView`
//  的做法一致。
//

import SwiftUI

// MARK: - 可复用主体

struct ArtworkPolicyOptionsView: View {

    /// 紧凑模式：去掉长说明只留控件，塞进高度紧张的地方用。
    var compact: Bool = false

    /// 单例，不走 `@EnvironmentObject` —— 这份视图会被嵌到自动匹配选项 sheet 里，
    /// 那条路径上的环境里没有注入 `ArtworkStore`。
    @ObservedObject private var store = ArtworkStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? Theme.Spacing.m : Theme.Spacing.l) {

            card("封面保存方式") {
                choicePicker {
                    Picker("", selection: $store.artworkEmbedMode) {
                        ForEach(ArtworkEmbedMode.allCases, id: \.self) { m in
                            Text(m.localizedName).tag(m)
                        }
                    }
                }
                if !compact {
                    Text(modeDetail)
                        .font(Theme.Typo.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("FLAC 的单张封面不能超过 16 MB（元数据块长度字段只有 24 bit）。"
                         + "超限的图会在保存前自动压到 15 MB 以内；压不下去才拒写，"
                         + "原有封面不会被动。")
                        .font(Theme.Typo.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if store.artworkEmbedMode.writesFolderFile {
                card("文件夹图片") {
                    HStack(spacing: Theme.Spacing.m) {
                        Text("文件名").font(Theme.Typo.fieldLabel).foregroundStyle(.secondary)
                        Picker("", selection: $store.folderArtworkNaming) {
                            ForEach(FolderArtworkNaming.allCases, id: \.self) { n in
                                Text(n.localizedName).tag(n)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                    }
                    Toggle("目录里已有同名图片时覆盖", isOn: $store.folderArtworkOverwrite)
                        .toggleStyle(.checkbox)
                        .help("关闭时遇到已有封面直接跳过，不动用户自己放的图")
                    if !compact {
                        Text("扩展名按图片的**实际字节**定（写进 cover.jpg 的却是 PNG 会让一半播放器瞎掉）。"
                             + "同一个文件夹只写一次：选中整张专辑 12 首歌，目标目录也只有一个。")
                            .font(Theme.Typo.caption)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            card("预留填充") {
                Toggle("整文件重写之后顺手把文件头填充扩到位", isOn: $store.reservePaddingEnabled)
                    .toggleStyle(.checkbox)
                Text("按文件大小自动取 1% 以内，M4A 不支持。")
                    .font(Theme.Typo.caption)
                    .foregroundStyle(.secondary)
                if !compact {
                    Text("只在这次保存**本来就要**整文件重写时才补——文件反正刚被搬过一遍，"
                         + "这时再搬一次换来的是以后换封面、改标题全部原地完成（毫秒级）。"
                         + "预留量不是固定值：TagLib 会把超过「文件长度 1%、且不超过 1 MB」的填充砸回 4096，"
                         + "所以实际值按每个文件的大小算，再打 95 折。")
                        .font(Theme.Typo.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if store.reservePaddingEnabled {
                    HStack(spacing: Theme.Spacing.m) {
                        Text("预留上限").font(Theme.Typo.fieldLabel).foregroundStyle(.secondary)
                        Slider(value: reserveKB, in: 64...Double(PaddingReserver.maxSafeReserveBytes / 1024), step: 32)
                            .frame(maxWidth: 220)
                        Text(String(format: "%.0f KB", Double(store.reservePaddingBytes) / 1024))
                            .font(Theme.Typo.digits)
                            .foregroundStyle(.secondary)
                            .frame(width: 64, alignment: .trailing)
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private var modeDetail: String {
        switch store.artworkEmbedMode {
        case .embed:
            return "原版行为。封面写进音频标签，播放器一定认，代价是塞不进头部空闲位时要把整段音频后移一遍。"
        case .folderFile:
            return "封面只写成专辑目录里的图片文件，**音频一个字节都不动**（保存瞬间完成，也不多写一遍闪存）。"
                 + "foobar2000 / MusicBee / Plex / Navidrome / Apple Music 导入都认这套约定。"
        case .both:
            return "两边都写。播放器怎么找都能找到，代价是仍要按嵌入方式重写音频。"
        }
    }

    private var reserveKB: Binding<Double> {
        Binding(get: { Double(store.reservePaddingBytes) / 1024 },
                set: { store.reservePaddingBytes = Int($0) * 1024 })
    }

    /// 与 `LyricsFileOptionsView` 同样的取舍：宽松模式单选钮一眼看全，紧凑模式换弹出菜单省高度。
    @ViewBuilder
    private func choicePicker<C: View>(@ViewBuilder _ picker: () -> C) -> some View {
        if compact {
            picker().labelsHidden().pickerStyle(.menu).frame(width: 240, alignment: .leading)
        } else {
            picker().labelsHidden().pickerStyle(.radioGroup)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
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

// MARK: - 独立小窗（「标签 › 封面与写入选项…」）

struct ArtworkPolicySheet: View {

    @ObservedObject private var store = ArtworkStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            SheetTitleBar(systemImage: "photo.badge.checkmark",
                          title: "封面与写入选项",
                          subtitle: "保存标签、自动匹配、按专辑匹配三条写入路径共用这一份设置。") {
                Chip(text: store.artworkEmbedMode.localizedName, tinted: true)
            }

            ScrollView {
                ArtworkPolicyOptionsView()
                    .padding(Theme.Spacing.l)
            }

            SheetButtonBar {
                Text(hint)
                    .font(Theme.Typo.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(hint)
                Spacer()
                Button("完成") { ArtworkSheetPresenter.shared.dismiss(); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(width: Theme.Size.sheetMedium, height: 600)
    }

    /// 底栏回显一条示意，省得用户靠猜。
    private var hint: String {
        switch store.artworkEmbedMode {
        case .embed:
            return "示例：封面写进音频标签"
        case .folderFile, .both:
            let name = store.folderArtworkNaming.baseName(album: "专辑名") + ".jpg"
            return "示例：歌曲所在文件夹/\(name)"
                + (store.artworkEmbedMode == .both ? "，同时嵌入音频标签" : "，音频不改动")
        }
    }
}
