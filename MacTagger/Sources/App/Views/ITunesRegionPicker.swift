//
//  ITunesRegionPicker.swift
//  MacTagger — iTunes 曲库地区选择器
//
//  原版支持 16 个地区码，MacTagger 之前把它写死在 `AutoMatchStore` 里（`countryCode: "CN"`），
//  全应用没有任何入口。而中区商店当前**整个是空的**（见 `ITunesSource` 文件头的实测记录），
//  用户既看不出「iTunes 那一格为什么总是 0」，也没办法自己换个地区试试。
//
//  这个选择器刻意做成**自带状态的独立构件**：
//  · 用 `@AppStorage` 直接读写 `MacTagger.itunes.country`，不依赖任何 environmentObject ——
//    它要能塞进「数据源状态」那个**独立 NSWindow**（那里没有环境注入，用
//    `@EnvironmentObject` 会当场崩），也要能被自动匹配选项 sheet 直接嵌进去；
//  · 换地区后立刻调 `SourceBootstrap.registerITunes()` 覆盖注册表里的实例，
//    下一次搜索就是新地区，不必重启 App。
//

import SwiftUI

struct ITunesRegionPicker: View {

    /// 与 `SourceBootstrap.itunesCountry` / `AppSettings.itunesCountry` 同一个键。
    @AppStorage(SourceBootstrap.itunesCountryKey)
    private var country: String = SourceBootstrap.itunesCountryDefault

    /// 紧凑版：只有一个下拉，不带标题与说明。嵌进已有表单行时用。
    var compact: Bool = false
    /// 是否显示那行「中区当前常返回 0 条」的说明。
    var showsNote: Bool = true

    var body: some View {
        if compact {
            picker.labelsHidden().frame(width: 168)
        } else {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                picker.frame(maxWidth: 260)
                if showsNote {
                    Text(Self.note)
                        .font(Theme.Typo.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var picker: some View {
        Picker("曲库地区", selection: binding) {
            // 「自动」排在最上面，但**出厂默认是港区 HK**（见
            // `SourceBootstrap.itunesCountryDefault`）：中区商店实测整个是空的。
            // 自动档与固定港区的实际链条一样（`JP/KR?` → HK → US），
            // 区别只在健康台账单独分一格、且不把「所选地区」排进链里。
            Text("自动（按曲名语言）").tag(ITunesSource.Region.automatic)
            Divider()
            ForEach(ITunesSource.Region.allCases, id: \.rawValue) { region in
                // 界面上英国写「英国」，值仍是 iTunes 认的 GB（见 Region 注释）。
                Text("\(region.localizedName)（\(region.rawValue)）").tag(region.rawValue)
            }
        }
        .pickerStyle(.menu)
        .help(Self.note)
        .accessibilityIdentifier("iTunes 曲库地区")
    }

    /// 写入前先规范化（老配置里可能存着 "UK" 或小写），再让注册表换实例。
    /// `"AUTO"` 是哨兵值，不能拿去 `Region.parse`（会被折成 CN）。
    private var binding: Binding<String> {
        Binding(
            get: {
                ITunesSource.Region.isAutomatic(country)
                    ? ITunesSource.Region.automatic
                    : ITunesSource.Region.parse(country).rawValue
            },
            set: { raw in
                let code = ITunesSource.Region.isAutomatic(raw)
                    ? ITunesSource.Region.automatic
                    : ITunesSource.Region.parse(raw).rawValue
                guard code != country else { return }
                country = code
                SourceBootstrap.registerITunes()
            }
        )
    }

    /// 说明文案。写清楚「0 条不等于源挂了」，这正是数据源状态面板存在的理由。
    static let note = "默认港区：中区目前对所有搜索返回 0 条；"
        + "繁体元数据会按「在线结果统一转为」设置自动转换。"
}

// MARK: - 预览用的一行

/// 「数据源状态」面板里 iTunes 那一行右侧挂的紧凑版。
/// 单独抽出来是为了让面板那边只加一行代码。
struct ITunesRegionInlineRow: View {
    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text("地区")
                .font(Theme.Typo.caption)
                .foregroundStyle(.secondary)
            ITunesRegionPicker(compact: true)
                .controlSize(.small)
        }
        .help(ITunesRegionPicker.note)
    }
}
