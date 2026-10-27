# 生成设计画板。改样稿只改这里，然后重新组装画布。
# 定稿 = 方向 A：Main（浅色）+ MainDark（深色，配色见 A-dark-palette.md）；B / C 备选留档。
import json, os

DIR = os.path.dirname(os.path.abspath(__file__))
def out(name):
    return os.path.join(DIR, name)

BASE_ROWS = [
 ("稻香 - 周杰伦.flac","稻香","周杰伦","魔杰座","2008","11/11","3:43","FLAC · 44.1k/16","dirty"),
 ("晴天 - 周杰伦.m4a","晴天","周杰伦","叶惠美","2003","3/11","4:29","AAC · 256k",""),
 ("月亮代表我的心 - 邓丽君.mp3","月亮代表我的心","邓丽君","岛国之情歌 第四集","1977","3/12","3:29","MP3 · 320k",""),
 ("Blank Space - Taylor Swift.m4a","Blank Space","Taylor Swift","1989","2014","2/13","3:51","AAC · 256k",""),
 ("Lemon - 米津玄師.flac","Lemon","米津玄師","BOOTLEG","2017","6/14","4:16","FLAC · 96k/24",""),
 ("zzz-无法识别的文件名 12345.ogg","","","","","","0:02","Vorbis · 未知","warn"),
 ("七里香 - 周杰伦.flac","七里香","周杰伦","七里香","2004","2/10","4:59","FLAC · 44.1k/16",""),
 ("以父之名 - 周杰伦.flac","以父之名","周杰伦","叶惠美","2003","2/11","5:42","FLAC · 44.1k/16",""),
 ("夜曲 - 周杰伦.flac","夜曲","周杰伦","十一月的萧邦","2005","1/12","3:46","FLAC · 44.1k/16",""),
 ("青花瓷 - 周杰伦.flac","青花瓷","周杰伦","我很忙","2007","3/10","3:58","FLAC · 44.1k/16",""),
 ("甜蜜蜜 - 邓丽君.mp3","甜蜜蜜","邓丽君","难忘的一天","1979","1/12","3:32","MP3 · 320k",""),
 ("小城故事 - 邓丽君.mp3","小城故事","邓丽君","小城故事","1979","1/12","2:47","MP3 · 320k",""),
 ("Style - Taylor Swift.m4a","Style","Taylor Swift","1989","2014","3/13","3:51","AAC · 256k",""),
 ("Shake It Off - Taylor Swift.m4a","Shake It Off","Taylor Swift","1989","2014","6/13","3:39","AAC · 256k",""),
 ("灰色軌跡 - 米津玄師.flac","灰色軌跡","米津玄師","BOOTLEG","2017","3/14","4:03","FLAC · 96k/24",""),
 ("双截棍 - 周杰伦.flac","双截棍","周杰伦","范特西","2001","6/10","3:22","FLAC · 44.1k/16",""),
 ("安静 - 周杰伦.flac","安静","周杰伦","范特西","2001","10/10","5:34","FLAC · 44.1k/16",""),
 ("龙卷风 - 周杰伦.flac","龙卷风","周杰伦","Jay","2000","5/10","3:59","FLAC · 44.1k/16",""),
 ("星晴 - 周杰伦.flac","星晴","周杰伦","Jay","2000","4/10","4:19","FLAC · 44.1k/16",""),
 ("我只在乎你 - 邓丽君.mp3","我只在乎你","邓丽君","我只在乎你","1987","1/10","3:50","MP3 · 320k",""),
 ("漫步人生路 - 邓丽君.mp3","漫步人生路","邓丽君","漫步人生路","1983","2/12","3:47","MP3 · 320k",""),
 ("Wildest Dreams - Taylor Swift.m4a","Wildest Dreams","Taylor Swift","1989","2014","9/13","3:40","AAC · 256k",""),
 ("打上花火 - 米津玄師.flac","打上花火","米津玄師","BOOTLEG","2017","12/14","4:49","FLAC · 96k/24",""),
 ("东风破 - 周杰伦.flac","东风破","周杰伦","叶惠美","2003","6/11","5:14","FLAC · 44.1k/16",""),
 ("简单爱 - 周杰伦.flac","简单爱","周杰伦","范特西","2001","2/10","4:30","FLAC · 44.1k/16",""),
]

ART = {
 "稻香":"linear-gradient(135deg,#c9a227,#6b4f1d)", "晴天":"linear-gradient(135deg,#7fb3d5,#2c5d8a)",
 "月亮代表我的心":"linear-gradient(135deg,#e8c1c5,#8b3a4a)", "Blank Space":"linear-gradient(135deg,#d9d2c5,#5a5245)",
 "Lemon":"linear-gradient(135deg,#f2e394,#b8a12c)", "七里香":"linear-gradient(135deg,#a3c9a8,#3c6e47)",
 "以父之名":"linear-gradient(135deg,#8c8c8c,#2a2a2a)", "夜曲":"linear-gradient(135deg,#5b6b8c,#1d2438)",
 "青花瓷":"linear-gradient(135deg,#cfe3ee,#3a6f8f)", "甜蜜蜜":"linear-gradient(135deg,#f3c6a5,#b0603a)",
 "小城故事":"linear-gradient(135deg,#d8c9a3,#7a6a3f)", "Style":"linear-gradient(135deg,#d9d2c5,#5a5245)",
 "Shake It Off":"linear-gradient(135deg,#d9d2c5,#5a5245)", "灰色軌跡":"linear-gradient(135deg,#f2e394,#b8a12c)",
 "双截棍":"linear-gradient(135deg,#8f6ad1,#3b2a6b)", "安静":"linear-gradient(135deg,#8f6ad1,#3b2a6b)",
 "龙卷风":"linear-gradient(135deg,#7ec4b6,#2b6b60)", "星晴":"linear-gradient(135deg,#7ec4b6,#2b6b60)",
 "我只在乎你":"linear-gradient(135deg,#e5a5b8,#7d2f4f)", "漫步人生路":"linear-gradient(135deg,#c7d3a2,#5f7a2e)",
 "Wildest Dreams":"linear-gradient(135deg,#d9d2c5,#5a5245)", "打上花火":"linear-gradient(135deg,#f2e394,#b8a12c)",
 "东风破":"linear-gradient(135deg,#7fb3d5,#2c5d8a)", "简单爱":"linear-gradient(135deg,#8f6ad1,#3b2a6b)",
}

def icon(inner, s=16):
    return f'<svg width="{s}" height="{s}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">{inner}</svg>'
NOTE = icon('<path d="M9 18V5l12-2v13"></path><circle cx="6" cy="18" r="3"></circle><circle cx="18" cy="16" r="3"></circle>', 14)
FOLDER = icon('<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"></path>')
I_ADD = icon('<path d="M12 5v14M5 12h14"></path>')
I_FOLDERPLUS = icon('<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"></path><path d="M12 11v6M9 14h6"></path>')
I_SAVE = icon('<path d="M4 4h12l4 4v12H4z"></path><path d="M8 4v5h7V4M8 20v-6h8v6"></path>')
I_UNDO = icon('<path d="M9 14 4 9l5-5"></path><path d="M4 9h10a6 6 0 0 1 0 12h-3"></path>')
I_WAND = icon('<path d="m4 20 10-10M13 4l1 3 3 1-3 1-1 3-1-3-3-1 3-1z"></path><path d="m18 12 .5 1.5L20 14l-1.5.5L18 16l-.5-1.5L16 14l1.5-.5z"></path>')
I_LYRIC = icon('<path d="M4 5h16v11H9l-5 4z"></path><path d="M8 9h8M8 12h5"></path>')
I_MORE = icon('<circle cx="12" cy="12" r="9"></circle><path d="M8 12h.01M12 12h.01M16 12h.01"></path>')
I_SEARCH = icon('<circle cx="11" cy="11" r="7"></circle><path d="m20 20-3.5-3.5"></path>')
I_IMG = icon('<rect x="3" y="4" width="18" height="16" rx="2"></rect><path d="m3 16 5-5 4 4 3-3 6 6"></path><circle cx="16" cy="9" r="1.5"></circle>')
SORT_UP = icon('<path d="m6 14 6-6 6 6"></path>', 11)

MONO = "ui-monospace, SFMono-Regular, Menlo, monospace"   # 无空格族名，不需要引号

def art(title, size, radius, extra="", T=None):
    g = ART.get(title)
    if g:
        return f'<div style="width:{size}px;height:{size}px;border-radius:{radius}px;background:{g};flex:none;{extra}"></div>'
    T = T or {}
    ph = T.get("artPh", "rgba(127,127,127,0.14)")
    phfg = T.get("artPhFg", "rgba(127,127,127,0.7)")
    return f'<div style="width:{size}px;height:{size}px;border-radius:{radius}px;background:{ph};display:flex;align-items:center;justify-content:center;color:{phfg};flex:none;{extra}">{NOTE}</div>'

def build(name, T):
    # 派生令牌：深色下卡片描边/输入框描边/状态栏底与发丝线不同值，浅色与 B/C 回落原值
    cstroke = T.get("cardStroke", T["hair"])
    fstroke = T.get("fieldStroke", T["hair"])
    statusBg = T.get("statusBg", T["tbBg"])
    winStroke = T.get("winStroke", "rgba(0,0,0,0.18)")
    rows = BASE_ROWS[:T["rows"]]
    rows_html = []
    for i,(fn,ti,ar,al,yr,tr,du,fmt,st) in enumerate(rows):
        sel = i == 0
        bg = T["selRow"] if sel else (T["rowAlt"] if (i%2==1 and T["alternate"]) else "transparent")
        inv = sel and T["selInvert"]
        fg = "#ffffff" if inv else T["fg"]
        fg2 = "rgba(255,255,255,0.78)" if inv else T["fg2"]
        if st == "dirty":
            dotc = "#ffffff" if inv else T["accent"]
            dot = f'<span style="width:7px;height:7px;border-radius:50%;background:{dotc};flex:none;"></span>'
        elif st == "warn":
            warnc = "#ffffff" if inv else T.get("warn", "#e39a2d")
            dot = f'<span style="width:7px;height:7px;border-radius:50%;background:{warnc};flex:none;"></span>'
        else:
            dot = '<span style="width:7px;height:7px;flex:none;"></span>'
        thumb = art(ti, T["thumb"], 4, T=T) if T["thumb"] else ""
        num = f"font-family:{MONO};font-variant-numeric:tabular-nums;"
        border = f'border-bottom:1px solid {T["hair"]};' if T["hairRows"] else ""
        rows_html.append(f'''
        <div style="display:grid;grid-template-columns:{T["cols"]};align-items:center;height:{T["row"]}px;padding:0 12px;background:{bg};{border}font-size:{T["cell"]}px;color:{fg};flex:none;">
          <div style="display:flex;align-items:center;gap:8px;min-width:0;">{dot}{thumb}<span style="white-space:nowrap;overflow:hidden;text-overflow:ellipsis;">{fn}</span></div>
          <div style="white-space:nowrap;overflow:hidden;text-overflow:ellipsis;">{ti}</div>
          <div style="white-space:nowrap;overflow:hidden;text-overflow:ellipsis;">{ar}</div>
          <div style="white-space:nowrap;overflow:hidden;text-overflow:ellipsis;">{al}</div>
          <div style="text-align:right;{num}">{yr}</div>
          <div style="text-align:right;{num}">{tr}</div>
          <div style="text-align:right;color:{fg2};{num}">{du}</div>
          <div style="white-space:nowrap;overflow:hidden;text-overflow:ellipsis;color:{fg2};font-size:{T["cell"]-1}px;">{fmt}</div>
        </div>''')
    rows_html = "".join(rows_html)

    def hcell(k):
        align = "text-align:right;" if k in ("年份","音轨","时长") else ""
        if k == "文件名":
            return f'<div style="display:flex;align-items:center;gap:4px;white-space:nowrap;">文件名{SORT_UP}</div>'
        return f'<div style="{align}white-space:nowrap;">{k}</div>'
    hdr = "".join(hcell(k) for k in ["文件名","标题","艺术家","专辑","年份","音轨","时长","格式"])

    def tb(svg, label, primary=False):
        col = T["accent"] if primary else T["fg2"]
        if T["tbIconOnly"]:
            return f'<div title="{label}" style="display:flex;align-items:center;justify-content:center;width:28px;height:26px;border-radius:6px;color:{col};"></div>'.replace("></div>", f">{svg}</div>")
        return f'<div title="{label}" style="display:flex;align-items:center;gap:6px;height:28px;padding:0 9px;border-radius:7px;color:{col};">{svg}<span style="font-size:12px;">{label}</span></div>'
    sep = f'<div style="width:1px;height:18px;background:{T["hair"]};margin:0 4px;"></div>'
    toolbar = f'''
    <div style="display:flex;align-items:center;gap:4px;height:{T["tbH"]}px;padding:0 14px 0 12px;background:{T["tbBg"]};border-bottom:1px solid {T["hair"]};flex:none;">
      {tb(I_ADD,"添加文件")}{tb(I_FOLDERPLUS,"添加目录")}{sep}
      {tb(I_SAVE,"保存标签",primary=True)}{tb(I_UNDO,"撤消")}{sep}
      {tb(I_WAND,"自动匹配")}{tb(I_LYRIC,"歌词")}{sep}
      {tb(I_MORE,"更多")}
      <div style="flex:1;"></div>
      <div style="display:flex;align-items:center;gap:6px;width:{T["searchW"]}px;height:26px;padding:0 10px;border-radius:8px;background:{T["search"]};color:{T["fg2"]};font-size:12px;">{I_SEARCH}<span>过滤文件</span></div>
    </div>'''

    def sbrow(name, count, selected=False):
        bg = T["sbSel"] if selected else "transparent"
        return f'<div style="display:flex;align-items:center;gap:8px;height:30px;padding:0 8px;border-radius:7px;background:{bg};color:{T["fg"]};font-size:13px;">{FOLDER}<span style="flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;">{name}</span><span style="font-size:11px;padding:1px 7px;border-radius:9px;background:{T["pill"]};color:{T["fg2"]};font-family:{MONO};">{count}</span></div>'
    sidebar = f'''
    <div style="display:flex;flex-direction:column;width:{T["sidebar"]}px;flex:none;background:{T["sbBg"]};border-right:1px solid {T["hair"]};padding:10px 10px;gap:4px;">
      <div style="font-size:11px;font-weight:600;color:{T["fg2"]};padding:0 8px 6px;">工作目录</div>
      {sbrow("Music · 2024 整理","1,284",True)}{sbrow("周杰伦 全集","186")}{sbrow("待整理","43")}
      <div style="flex:1;"></div>
      <div style="display:flex;gap:6px;color:{T["fg2"]};padding:0 4px;">{I_ADD}</div>
    </div>'''

    def field(label, value, mono=False):
        fam = f"font-family:{MONO};" if mono else ""
        return f'''<div style="display:grid;grid-template-columns:{T["labelW"]}px minmax(0,1fr);gap:10px;align-items:center;">
          <div style="font-size:12px;color:{T["fg2"]};text-align:right;">{label}</div>
          <div style="height:{T["fieldH"]}px;display:flex;align-items:center;padding:0 9px;border-radius:6px;background:{T["field"]};border:1px solid {fstroke};font-size:13px;color:{T["fg"]};{fam}white-space:nowrap;overflow:hidden;text-overflow:ellipsis;">{value}</div>
        </div>'''
    def minifield(label, value):
        return f'<div style="display:flex;flex-direction:column;gap:4px;"><div style="font-size:11px;color:{T["fg2"]};">{label}</div><div style="height:{T["fieldH"]}px;display:flex;align-items:center;padding:0 9px;border-radius:6px;background:{T["field"]};border:1px solid {fstroke};font-size:13px;color:{T["fg"]};font-family:{MONO};">{value}</div></div>'
    def card(title, inner):
        return f'''<div style="display:flex;flex-direction:column;gap:8px;padding:{T["cardPad"]}px;border-radius:{T["cardR"]}px;background:{T["card"]};border:1px solid {cstroke};flex:none;">
          <div style="font-size:11px;font-weight:600;color:{T["fg2"]};">{title}</div>
          {inner}
        </div>'''

    title_line = f'<div style="display:flex;align-items:center;justify-content:center;gap:8px;font-size:{T["heroTitle"]}px;font-weight:600;color:{T["fg"]};letter-spacing:-0.2px;">稻香<span style="width:7px;height:7px;border-radius:50%;background:{T["accent"]};"></span></div>'
    sub_line = f'<div style="font-size:13px;color:{T["fg2"]};margin-top:3px;">周杰伦 — 魔杰座 · 2008</div>'
    cover_line = f'<div style="display:flex;justify-content:center;align-items:center;gap:6px;color:{T["fg2"]};font-size:11px;margin-top:6px;">{I_IMG}<span>1 张封面 · 1200×1200</span></div>'

    if T["heroStyle"] == "big":
        hero = f'''<div style="display:flex;flex-direction:column;align-items:center;gap:10px;padding:4px 0 0;flex:none;">
          {art("稻香", T["hero"], T["heroR"], f"box-shadow:{T['heroShadow']};", T=T)}
          <div style="text-align:center;">{title_line}{sub_line}{cover_line}</div>
        </div>'''
    elif T["heroStyle"] == "backdrop":
        hero = f'''<div style="margin:-{T["inspPad"]}px -{T["inspPad"]}px 0;padding:18px {T["inspPad"]}px 12px;background:linear-gradient(180deg,rgba(201,162,39,0.35),rgba(201,162,39,0) 92%);flex:none;">
          <div style="display:flex;flex-direction:column;align-items:center;gap:12px;">
            {art("稻香", T["hero"], T["heroR"], f"box-shadow:{T['heroShadow']};", T=T)}
            <div style="text-align:center;">{title_line}{sub_line}{cover_line}</div>
          </div>
        </div>'''
    else:
        hero = f'''<div style="display:flex;gap:12px;align-items:center;flex:none;">
          {art("稻香", T["hero"], T["heroR"], f"box-shadow:{T['heroShadow']};", T=T)}
          <div style="min-width:0;">
            <div style="display:flex;align-items:center;gap:8px;font-size:{T["heroTitle"]}px;font-weight:600;color:{T["fg"]};white-space:nowrap;overflow:hidden;text-overflow:ellipsis;">稻香<span style="width:7px;height:7px;border-radius:50%;background:{T["accent"]};flex:none;"></span></div>
            <div style="font-size:12px;color:{T["fg2"]};margin-top:2px;">周杰伦 — 魔杰座 · 2008</div>
            <div style="display:flex;align-items:center;gap:6px;margin-top:8px;color:{T["fg2"]};font-size:11px;">{I_IMG}<span>1 张封面 · 1200×1200</span></div>
          </div>
        </div>'''

    tags_inner = "".join([
        field("标题","稻香"), field("艺术家","周杰伦"), field("专辑","魔杰座"), field("专辑艺术家","周杰伦"),
        f'<div style="height:1px;background:{T["hair"]};margin:2px 0;"></div>',
        f'<div style="display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:8px;">{minifield("年份","2008")}{minifield("音轨","11 / 11")}{minifield("碟号","1")}</div>',
        field("风格","国语流行"), field("作曲","周杰伦"), field("作词","周杰伦"),
    ])
    lyric_inner = f'''<div style="white-space:pre-line;font-family:{MONO};font-size:12px;line-height:1.5;color:{T["fg"]};">[00:30.80]对这个世界如果
[00:32.63]你有太多的抱怨
[00:34.26]跌倒了就不敢继续往前走</div>
    <div style="display:flex;justify-content:space-between;align-items:center;"><span style="font-size:11px;color:{T["fg2"]};">54 行 · 无翻译</span><span style="font-size:12px;color:{T["accent"]};">打开编辑器</span></div>'''
    tech_inner = f'''<div style="display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:6px 14px;font-size:12px;font-family:{MONO};font-variant-numeric:tabular-nums;">
      <div style="color:{T["fg2"]};">时长</div><div style="color:{T["fg"]};">3:43</div>
      <div style="color:{T["fg2"]};">比特率</div><div style="color:{T["fg"]};">1 007 kbps</div>
      <div style="color:{T["fg2"]};">采样率</div><div style="color:{T["fg"]};">44 100 Hz · 16 bit</div>
      <div style="color:{T["fg2"]};">标签格式</div><div style="color:{T["fg"]};">Xiph Comment</div>
    </div>'''

    # 卡片区可滚动（静态稿用 overflow:hidden + 底部渐隐表示"还有内容"），按钮行永远吸底。
    inspector = f'''
    <div style="display:flex;flex-direction:column;width:{T["insp"]}px;flex:none;background:{T["inspBg"]};border-left:1px solid {T["hair"]};padding:{T["inspPad"]}px;gap:12px;min-height:0;">
      {hero}
      <div style="position:relative;flex:1;min-height:0;overflow:hidden;">
        <div style="display:flex;flex-direction:column;gap:10px;">
          {card("标签", tags_inner)}
          {card("歌词", lyric_inner)}
          {card("技术参数", tech_inner)}
        </div>
        <div style="position:absolute;left:0;right:0;bottom:0;height:28px;background:linear-gradient(180deg,rgba(0,0,0,0),{T["inspBg"]});"></div>
      </div>
      <div style="display:flex;gap:8px;align-items:center;flex:none;">
        <div style="flex:1;height:30px;display:flex;align-items:center;justify-content:center;border-radius:7px;background:{T["accent"]};color:#ffffff;font-size:13px;font-weight:600;">保存标签</div>
        <div style="height:30px;display:flex;align-items:center;padding:0 12px;border-radius:7px;background:{T["btn2"]};border:1px solid {fstroke};color:{T["fg"]};font-size:13px;">撤消</div>
        <div style="height:30px;display:flex;align-items:center;padding:0 10px;border-radius:7px;background:{T["btn2"]};border:1px solid {fstroke};color:{T["fg2"]};">{I_MORE}</div>
      </div>
    </div>'''

    statusbar = f'''
    <div style="display:flex;align-items:center;gap:10px;height:26px;padding:0 12px;background:{statusBg};border-top:1px solid {T["hair"]};font-size:11px;color:{T["fg2"]};flex:none;">
      <span>已选 1 个文件 · 1 项未保存改动 · 1 个文件有警告</span><div style="flex:1;"></div>
      <span style="padding:1px 8px;border-radius:9px;background:{T["pill"]};font-family:{MONO};">总共 1,284</span><span style="padding:1px 8px;border-radius:9px;background:{T["pill"]};font-family:{MONO};">已选 1</span><span style="padding:1px 8px;border-radius:9px;background:{T["pill"]};color:{T["accent"]};font-family:{MONO};">已改 1</span>
    </div>'''

    html = f'''<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <script src="./support.js"></script>
</head>
<body>
<x-dc>
<helmet>
  <style>
    body {{ margin: 0; font-family: -apple-system, "SF Pro Text", "PingFang SC", "Helvetica Neue", system-ui, sans-serif; -webkit-font-smoothing: antialiased; }}
    a {{ color: {T["accent"]}; }} a:hover {{ color: {T["accent"]}; opacity: .8; }}
  </style>
</helmet>
<div style="width:1440px;height:900px;background:{T["desk"]};display:flex;align-items:center;justify-content:center;">
  <div style="width:1300px;height:790px;border-radius:12px;overflow:hidden;background:{T["win"]};box-shadow:0 14px 34px rgba(0,0,0,{T["winShadow"]}),0 0 0 1px {winStroke};display:flex;flex-direction:column;color:{T["fg"]};">
    <div style="display:flex;align-items:center;height:{T["titleH"]}px;padding:0 14px;background:{T["tbBg"]};gap:8px;flex:none;">
      <span style="width:12px;height:12px;border-radius:50%;background:#ff5f57;"></span><span style="width:12px;height:12px;border-radius:50%;background:#febc2e;"></span><span style="width:12px;height:12px;border-radius:50%;background:#28c840;"></span>
      <div style="flex:1;text-align:center;font-size:13px;font-weight:600;color:{T["fg2"]};margin-right:44px;">MacTagger</div>
    </div>
    {toolbar}
    <div style="display:flex;flex:1;min-height:0;">
      {sidebar}
      <div style="display:flex;flex-direction:column;flex:1;min-width:0;background:{T["tableBg"]};">
        <div style="display:grid;grid-template-columns:{T["cols"]};align-items:center;height:{T["hdrH"]}px;padding:0 12px;font-size:11px;font-weight:600;color:{T["fg2"]};border-bottom:1px solid {T["hair"]};{T["hdrExtra"]}flex:none;">{hdr}</div>
        <div style="display:flex;flex-direction:column;flex:1;min-height:0;overflow:hidden;">{rows_html}</div>
        {statusbar}
      </div>
      {inspector}
    </div>
  </div>
</div>
</x-dc>
</body>
</html>'''
    open(out(f"{name}.dc.html"),"w",encoding="utf-8").write(html)
    print("wrote", name, len(html), "rows", T["rows"])

COLS = "minmax(190px,1.5fr) 1fr 0.9fr 1.5fr 54px 62px 58px 118px"

# ── 方向 A（定稿）· 浅色 ─────────────────────────────────────────────
A_LIGHT = dict(
  desk="#e9e7e3", win="#f6f5f3", winShadow="0.26", titleH=38, tbH=50, tbIconOnly=False, searchW=230,
  fg="#1d1d1f", fg2="#6e6e73", accent="#2f6fed",
  hair="rgba(0,0,0,0.08)", tbBg="rgba(246,245,243,0.96)", btn2="#ffffff", search="rgba(0,0,0,0.05)",
  sidebar=206, sbBg="#ece9e4", sbSel="rgba(0,0,0,0.07)", pill="rgba(0,0,0,0.06)",
  tableBg="#ffffff", rowAlt="#f7f6f3", alternate=True, hairRows=False, selRow="#2f6fed", selInvert=True,
  row=30, rows=21, cell=12.5, thumb=22, cols=COLS, hdrH=28, hdrExtra="",
  insp=336, inspBg="#f6f5f3", inspPad=16, heroStyle="big", hero=176, heroR=12, heroShadow="0 10px 26px rgba(0,0,0,0.18)", heroTitle=18,
  card="#ffffff", cardR=10, cardPad=12, field="#fbfaf8", fieldH=24, labelW=62,
)

# ── 方向 A（定稿）· 深色 ─────────────────────────────────────────────
# 同一方向的两种外观：布局 / 行数 / 文案 / 图标与 A_LIGHT 逐项相同，只覆盖颜色类键。
# 取值全部来自 design/A-dark-palette.md；无对应令牌的几项（search / sbSel / pill /
# btn2 / winShadow / winStroke / artPhFg）按同一层级关系推导，见 Q 报告。
A_DARK = dict(A_LIGHT,
  desk="#101010",                       # 画布/桌面底
  win="#1e1e1e",                        # 窗口底
  winShadow="0.55", winStroke="rgba(255,255,255,0.10)",   # 深色下黑描边不可见，改用发丝白
  fg="#f2f2f2", fg2="#9a9a9f",          # 正文 / 次要
  accent="#0a84ff",                     # 系统蓝（深色）
  warn="#ff9f0a",                       # 警告
  hair="rgba(255,255,255,0.10)",        # 发丝线
  cardStroke="rgba(255,255,255,0.09)",  # 卡片描边
  fieldStroke="rgba(255,255,255,0.14)", # 输入框/控件描边
  tbBg="#232323",                       # 工具栏底（标题栏共用）
  statusBg="#1a1a1a",                   # 状态栏底
  btn2="#262626",                       # 次级按钮 = 卡片底（浅色下二者同为 #ffffff）
  search="#1c1c1e",                     # 搜索框 = 输入框底
  sbBg="#1a1a1a", sbSel="rgba(255,255,255,0.09)", pill="rgba(255,255,255,0.08)",
  tableBg="#1e1e1e", rowAlt="rgba(255,255,255,0.035)",
  selRow="#0a84ff",                     # 选中行实心蓝 + 白字（selInvert 继承 True，状态圆点随之转白）
  inspBg="#1e1e1e",                     # 检查器底 = 窗口底
  heroShadow="0 8px 28px rgba(0,0,0,0.55)",
  card="#262626", field="#1c1c1e",
  artPh="rgba(255,255,255,0.07)", artPhFg="#6b6b70",   # 封面占位底 / 占位图标（三级文字色）
)

build("Main", A_LIGHT)      # 定稿 · A 浅色
build("MainDark", A_DARK)   # 定稿 · A 深色

build("DirectionB_Record", dict(
  desk="#141311", win="#1f1d1a", winShadow="0.55", titleH=38, tbH=50, tbIconOnly=False, searchW=230,
  fg="#ece7df", fg2="#9b9489", accent="#e0a458",
  hair="rgba(255,255,255,0.08)", tbBg="#23211d", btn2="rgba(255,255,255,0.06)", search="rgba(255,255,255,0.07)",
  sidebar=206, sbBg="#1a1816", sbSel="rgba(255,255,255,0.08)", pill="rgba(255,255,255,0.08)",
  tableBg="#1f1d1a", rowAlt="#242220", alternate=True, hairRows=False, selRow="rgba(224,164,88,0.22)", selInvert=False,
  row=36, rows=17, cell=13, thumb=28, cols=COLS, hdrH=30, hdrExtra="",
  insp=350, inspBg="#1b1917", inspPad=18, heroStyle="backdrop", hero=196, heroR=12, heroShadow="0 16px 40px rgba(0,0,0,0.6)", heroTitle=20,
  card="#242220", cardR=12, cardPad=12, field="#1b1917", fieldH=26, labelW=62,
))
build("DirectionC_Dense", dict(
  desk="#e6e8eb", win="#f3f4f6", winShadow="0.24", titleH=34, tbH=36, tbIconOnly=True, searchW=200,
  fg="#15181c", fg2="#5f6670", accent="#2b8aa5",
  hair="rgba(0,0,0,0.10)", tbBg="#f3f4f6", btn2="#ffffff", search="#ffffff",
  sidebar=186, sbBg="#eceef1", sbSel="rgba(43,138,165,0.14)", pill="rgba(0,0,0,0.06)",
  tableBg="#ffffff", rowAlt="#ffffff", alternate=False, hairRows=True, selRow="rgba(43,138,165,0.14)", selInvert=False,
  row=26, rows=25, cell=12, thumb=0, cols=COLS, hdrH=24, hdrExtra="letter-spacing:0.3px;background:#f8f9fa;",
  insp=320, inspBg="#f3f4f6", inspPad=12, heroStyle="compact", hero=96, heroR=8, heroShadow="0 6px 16px rgba(0,0,0,0.14)", heroTitle=15,
  card="#ffffff", cardR=8, cardPad=10, field="#f8f9fa", fieldH=22, labelW=58,
))

# 画布：第一页放定稿 A 的浅/深两版，第二页留档备选 B / C。横向间距 100。
canvas = {
  "pages": [
    {"id":"page-1","name":"定稿 · A"},
    {"id":"page-2","name":"备选 · B / C"},
  ],
  "artboards": [
    {"file":"Main.dc.html","title":"A · 原生克制 · 浅色（定稿）","x":0,"y":0,"w":1440,"h":900,"page":"page-1"},
    {"file":"MainDark.dc.html","title":"A · 原生克制 · 深色（定稿）","x":1540,"y":0,"w":1440,"h":900,"page":"page-1"},
    {"file":"DirectionB_Record.dc.html","title":"B · 深色唱片行（备选）","x":0,"y":0,"w":1440,"h":900,"page":"page-2"},
    {"file":"DirectionC_Dense.dc.html","title":"C · 数据优先编辑台（备选）","x":1540,"y":0,"w":1440,"h":900,"page":"page-2"},
  ],
  "annotations": [
    {"id":"note-main-light","x":0,"y":-210,"w":440,"page":"page-1","text":"定稿 · A 浅色\n参照 Apple Music / 访达：系统蓝、侧栏 source-list、大封面 + 三张卡片、行高 30、缩略图 22。\nApp 端浅色以此稿为准。"},
    {"id":"note-main-dark","x":1540,"y":-210,"w":440,"page":"page-1","text":"定稿 · A 深色，配色见 A-dark-palette.md\n与左侧浅色稿布局、行数、文案、图标完全一致，只换颜色：窗口底 #1e1e1e、侧栏 #1a1a1a、卡片 #262626、强调 #0a84ff、发丝线为透明白。\n选中行仍是实心蓝 + 白字，未保存圆点在选中行转白才看得见。"},
    {"id":"note-b","x":0,"y":-210,"w":440,"page":"page-2","text":"B · 深色唱片行\n参照 Roon / Plex：暖炭底、琥珀强调、封面更大带色彩晕染、行高 36、缩略图 28。\n动机：唱片收藏的氛围感，和 Spinbox / Cratebox 一脉相承。\n代价：深色优先，浅色模式要再做一版；长时间批量编辑略显厚重。"},
    {"id":"note-c","x":1540,"y":-210,"w":440,"page":"page-2","text":"C · 数据优先编辑台\n行高 26、发丝分隔、无缩略图、工具栏收成 36px 纯图标、字段密排、冷青强调。\n动机：一屏看更多、改更快，重度整理者最顺手。\n代价：观感偏工具、少了「唱片」的温度。"},
  ],
  "launch": {"view":"canvas","page":"page-1"}
}
json.dump(canvas, open(out("canvas.json"),"w",encoding="utf-8"), ensure_ascii=False, indent=2)
print("canvas.json written:", len(canvas["artboards"]), "artboards /", len(canvas["pages"]), "pages")
