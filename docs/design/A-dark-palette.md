# 方向 A · 深色模式配色（定稿令牌，设计稿与 App 共用）

原则不变：Apple 原生克制。深色不是"把浅色反转"，而是跟随 macOS 深色的层次：窗口底最深、侧栏材质、卡片略浮起、发丝线靠透明白。

| 令牌 | 浅色（现状） | 深色（本次定稿） | 说明 |
|---|---|---|---|
| 画布/桌面底 | #e9e7e3 | #101010 | 画板外框，仅设计稿用 |
| 窗口底 windowBg | #f6f5f3 | #1e1e1e | 对应 NSColor.windowBackgroundColor 深色 |
| 侧栏 sidebarBg | 材质 | #1a1a1a（+ 材质感） | source-list 深色 |
| 表格底 tableBg | #ffffff | #1e1e1e | |
| 表格斑马纹 rowAlt | #f7f6f3 | rgba(255,255,255,0.035) | |
| 选中行 rowSelected | #2f6fed 实心 + 白字 | #0a84ff 实心 + 白字 | macOS 深色系统蓝 |
| 表头底 headerBg | #fbfaf8 | #232323 | |
| 卡片底 cardFill | #ffffff | #262626 | 比窗口底浮起一级 |
| 卡片描边 cardStroke | rgba(0,0,0,0.08) | rgba(255,255,255,0.09) | |
| 发丝线 hairline | rgba(0,0,0,0.10) | rgba(255,255,255,0.10) | |
| 正文 textPrimary | #1d1d1f | #f2f2f2 | |
| 次要 textSecondary | #6e6e73 | #9a9a9f | |
| 三级 textTertiary | #a1a1a6 | #6b6b70 | |
| 强调 accent | #2f6fed | #0a84ff | 跟随系统强调色，设计稿取默认蓝 |
| 未保存点 dirty | accent | accent | |
| 已匹配 matched | #34c759 | #30d158 | 系统绿深色值 |
| 警告 warning | #ff9500 | #ff9f0a | |
| 失败 failed | #ff3b30 | #ff453a | |
| 封面占位 artworkPlaceholder | rgba(0,0,0,0.06) | rgba(255,255,255,0.07) | |
| 输入框底 fieldBg | #ffffff | #1c1c1e | |
| 输入框描边 fieldStroke | rgba(0,0,0,0.12) | rgba(255,255,255,0.14) | |
| 大封面投影 heroShadow | 0 8px 24px rgba(0,0,0,0.18) | 0 8px 28px rgba(0,0,0,0.55) | 深色下投影更重才看得见浮起 |
| 工具栏底 toolbarBg | #f6f5f3 | #232323 | |
| 状态栏底 statusBg | #f6f5f3 | #1a1a1a | |

App 侧映射：能用系统语义色的一律用系统色（windowBackgroundColor / controlBackgroundColor / labelColor / secondaryLabelColor / separatorColor / systemBlue 等），它们在深色下的取值与上表一致；只有透明白/黑这类系统没有的（rowAlt / cardStroke / hairline / artworkPlaceholder / fieldStroke / heroShadow）在 Theme.swift 里按明暗各写一值。
