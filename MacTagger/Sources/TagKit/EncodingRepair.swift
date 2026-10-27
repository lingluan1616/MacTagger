//
//  EncodingRepair.swift
//  MacTagger — 遗留文本编码修正
//
//  对应原版 FormCharacterSet「修复乱码标签」。
//
//  问题背景：ID3v1 没有编码标识；ID3v2 的 Latin-1 文本帧也常被早年的中文软件
//  直接塞进 GBK / Big5 字节。按规范（Latin-1）读出来就是「ÔÂÁÁ´ú±íÎÒµÄÐÄ」这类乱码，
//  必须用对应编码重新解释同一串字节才能还原。
//
//  自动识别策略：对每个候选编码各解一遍，给解出的文本打分，取最高分。
//  评分完全基于「解出来的字符像不像人写的」，不依赖任何外部检测库。
//

import Foundation

public enum EncodingRepair {

    // MARK: - 候选编码

    /// 参与自动识别的候选编码。顺序即同分时的优先顺序。
    public static let candidates: [LegacyTextEncoding] = [
        .utf8, .gb18030, .big5, .shiftJIS, .strict
    ]

    // MARK: - 预览

    /// 一个候选编码的解码结果。
    public struct Candidate: Sendable {
        public var encoding: LegacyTextEncoding
        public var tags: Tags
        public var score: Double
        /// 供界面展示的代表性文本（标题/艺术家/专辑拼接）。
        public var sample: String
    }

    /// 用全部候选编码各解一遍，按分数从高到低返回。
    /// 界面可直接拿这个列表做「编码修正」对话框的预览表。
    public static func preview(_ url: URL) -> [Candidate] {
        let saved = TagService.legacyEncoding
        defer { TagService.legacyEncoding = saved }

        var results: [Candidate] = []
        for enc in candidates {
            TagService.legacyEncoding = enc
            guard let file = try? TagService.read(url) else { continue }
            let tags = file.tags
            let sample = [tags.title, tags.artist, tags.album]
                .compactMap { $0 }
                .joined(separator: " / ")
            results.append(Candidate(encoding: enc,
                                     tags: tags,
                                     score: score(tags),
                                     sample: sample))
        }
        return results.sorted { $0.score > $1.score }
    }

    /// 自动识别该文件最可能的原始编码。无法判断时返回 `.strict`。
    public static func detect(_ url: URL) -> LegacyTextEncoding {
        preview(url).first?.encoding ?? .strict
    }

    /// 自动识别并把修正后的文本字段写回文件。
    ///
    /// - Returns: 实际采用的编码与写入结果；若识别为 `.strict`（即本来就没乱码）
    ///            则不写入，`outcome` 为 nil。
    @discardableResult
    public static func repair(_ url: URL) throws -> (encoding: LegacyTextEncoding, outcome: WriteOutcome?) {
        let ranked = preview(url)
        guard let best = ranked.first, best.encoding != .strict else {
            return (.strict, nil)
        }
        // 与「按规范」解出的结果一致时说明没有乱码，不必写
        if let strict = ranked.first(where: { $0.encoding == .strict }),
           strict.tags.title == best.tags.title,
           strict.tags.artist == best.tags.artist,
           strict.tags.album == best.tags.album {
            return (.strict, nil)
        }

        var edit = TagEdit()
        if let v = best.tags.title       { edit.set(.title, v) }
        if let v = best.tags.artist      { edit.set(.artist, v) }
        if let v = best.tags.album       { edit.set(.album, v) }
        if let v = best.tags.albumArtist { edit.set(.albumArtist, v) }
        if let v = best.tags.genre       { edit.set(.genre, v) }
        if let v = best.tags.comment     { edit.set(.comment, v) }
        if let v = best.tags.composer    { edit.set(.composer, v) }

        // 修正后的文本一律以 UTF-8 写回，从此不再有编码歧义
        let saved = TagService.legacyEncoding
        TagService.legacyEncoding = .strict
        defer { TagService.legacyEncoding = saved }
        let outcome = try TagService.write(edit, to: url)
        return (best.encoding, outcome)
    }

    // MARK: - 评分

    /// 给一组标签的可读性打分。分数越高越像「人写的文本」。
    public static func score(_ tags: Tags) -> Double {
        let text = [tags.title, tags.artist, tags.album, tags.albumArtist, tags.genre]
            .compactMap { $0 }
            .joined(separator: " ")
        return score(text: text)
    }

    /// 给一段文本打分。
    ///
    /// 评分维度（逐字符累计，最后按字符数归一化）：
    /// - CJK 汉字 / 假名 / 谚文：**强正分**——乱码几乎不会大量落在这些区间
    /// - ASCII 字母数字与常见标点：**弱正分**——中性，英文标签也应得分
    /// - Latin-1 补充区的重音符号（À-ÿ）：**强负分**——GBK 被当 Latin-1 读的典型特征
    /// - 替换字符 U+FFFD、控制字符、私用区：**重罚**——解码明确失败
    /// - 罕用 CJK 扩展区、注音符号：**轻罚**——Big5 误解 GBK 时常落在这里
    public static func score(text: String) -> Double {
        guard !text.isEmpty else { return 0 }

        var total = 0.0
        var count = 0

        for scalar in text.unicodeScalars {
            count += 1
            let v = scalar.value
            switch v {
            case 0xFFFD:                            // 替换字符：解码失败
                total -= 12
            case 0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F:  // 控制字符
                total -= 10
            case 0xE000...0xF8FF:                   // 私用区
                total -= 8
            case 0x4E00...0x9FFF:                   // CJK 统一汉字（常用）
                total += 6
            case 0x3040...0x30FF:                   // 平假名 / 片假名
                total += 5
            case 0xAC00...0xD7AF:                   // 谚文音节
                total += 5
            case 0x3000...0x303F,                   // CJK 标点（、。《》）
                 0xFF01...0xFF60:                   // 全角字符
                total += 3
            case 0x20...0x7E:                       // 可打印 ASCII
                total += 1
            case 0xC0...0xFF:                       // Latin-1 重音字母：GBK 误读特征
                total -= 4
            case 0x80...0xBF:                       // Latin-1 补充区符号
                total -= 3
            case 0x3400...0x4DBF,                   // CJK 扩展 A（罕用字）
                 0x20000...0x2FFFF:                 // CJK 扩展 B+
                total -= 2
            case 0x02C0...0x02FF,                   // 修饰字母
                 0x0370...0x1FFF:                   // 希腊/西里尔/其它字母表
                total -= 1
            default:
                break                               // 其余中性
            }
        }

        var normalized = total / Double(count)

        // 连续三个以上罕用扩展区汉字，通常是"用错了中文编码"（如 Big5 解 GBK）
        var run = 0, maxRun = 0
        for s in text.unicodeScalars {
            if (0x3400...0x4DBF).contains(s.value) { run += 1; maxRun = max(maxRun, run) }
            else { run = 0 }
        }
        if maxRun >= 3 { normalized -= 2 }

        // 常用字比例：这是区分「正确的中文」与「另一种中文编码误解出的合法但生僻的汉字」
        // 的关键信号。两者都落在 CJK 统一汉字区、都能拿到基础汉字分，
        // 差别在于前者几乎全是常用字，后者几乎全是生僻字。
        let cjk = text.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }
        if !cjk.isEmpty {
            let common = cjk.filter { Self.commonHanzi.contains(Character($0)) }.count
            let ratio = Double(common) / Double(cjk.count)
            // 全常用字 +4，全生僻字 -4，线性过渡
            normalized += (ratio * 2 - 1) * 4
        }

        return normalized
    }

    // MARK: - 常用汉字表

    /// 简繁通用的高频汉字（约 1200 字，覆盖日常文本 90% 以上的字次）。
    /// 用途只有一个：判断「解出来的汉字是不是人常写的字」。
    /// 不追求完备，只要能把常用字与生僻字拉开差距即可。
    static let commonHanzi: Set<Character> = Set(
        "的一是了我不人在他有这个上们来到时大地为子中你说生国年着就那和要她出也得里后自以会家可下而过天去能对小多然于心学么之都好看起发当没成只如事把还用第样道想作种开美总从无情己面最女但现前些所同日手又行意动方期它头经长儿回位分爱老因很给名法间斯知世什两次使身者被高已亲其进此话常与活正感"
        + "见明问力理尔点文几定本公特做外孩相西果走将月十实向声车全信重三机工物气每并别真打太新比才便夫再书部水像眼等体却加电主界门利海受听表德少克代员许稜先口由死安写性马光白或住难望教命花结乐色更拉东神记处让母父应直字场平报友关放至张认接告入笑内英军候民岁往何度山觉路带万男边风解叫任金快原吃妈变通师立象数四失满战远格士音轻目条呢病始达深完今提求清王化空业思切怎非找片罗钱紶吗语元喜曾离飞科言干流欢约各即指合反题必该论交终林请医晚制球决窢传画保读运及则房早院量苦火布品近坐产答星精视五连司巴奇管类未朋且婚台夜青北队久乎越观落尽形影红爸百令周吧识步希亚术留市半热送兴造谈容极随演收首根讲整式取照办强石古华諣拿计您装似足双妻尼转诉米称丽客南领节衣站黑刻统断福城故历惊脸选包紧争另建维绝树系伤示愿持千史谁准联妇纪基买志静阿诗独复痛消社算义竟确酒需单治卡幸兰念举仅钟怕共毛句息功官待究跟穿室易游程号居考突皮哪费倒价图具刚脑永歌响商礼细专黄块脚味灵改据般破引食仍存众注笔甚某沉血备习校默务土微娘须试怀料调广蜖苏显赛查密议底列富梦错座参八除跑亮假印设线温虽掉京初养香停际致阳纸李纳验助激够严证帝饭忘趣支春集丈木研班普导顿睡展跳获艺六波察群皇段急庭创区奥器谢弟店否害草排背止组州朝封睛板角况曲馆育忙质河续哥呼若推境遇雨标姐充围案伦护冷警贝著雪索剧啊船险烟依斗值帮汉慢佛肯闻唱沙局伯族低玩资屋击速顾泪洲团圣旁堂兵七露园牛哭旅街劳型烈姑陈莫鱼异抱宝权鲁简态级票怪寻杀律胜份汽右洋范床舞秘午登楼贵吸责例追较职属渐左录丝牙党继托赶章智冲叶胡吉卖坚喝肉遗救修松临藉灯泥试迅曼宁哈鲜梅蒋营洗奶脱赵幽微舒抗虎努归啦谓乃鼓丁贫蓝胸夏亦孙秋亡添稳氏训莱狗宗污泉伸巨疑寒残纯戏惠亭乱毫谷罪虚宜妹兽绿铁潮拥腰仙倍冠恐辈厂粗宣召尚郑荣绍替毁忍宫脏昨顶怒欠恶劲塔铺镇圆凡罚敏胆凝喊贴挥赏遍绕暗炮迎堪抢仿刀奖穷贯甲祖凤咬涌菜厚翻臂宾岛陆惑柔浪桥辆熟牌孤铜奇栽剑蜂杜幕仰甘赞抽茶乡碗蛋衡拍宽舍蜡岗浮扬肩慧丹爬伙晓奔燕谋盘匆邓丽君岛国情歌"
    )
}
