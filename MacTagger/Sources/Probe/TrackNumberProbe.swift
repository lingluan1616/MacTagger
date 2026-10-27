//
//  TrackNumberProbe.swift
//  mactagger-probe — 音轨号/碟号「写入值」离线自检
//
//  子命令：
//    tracknum      纯离线，不联网、不碰任何文件
//
//  为什么要单独一条：`albumdisc` 验证的是**对齐**（谁对到哪首），
//  这里验证的是**写进标签的字符串**。两者曾经不一致——界面显示 `2-07/21`，
//  写进 TRACKNUMBER 的却是 `7/45`（全辑总数）。
//
//  标签规范：TRACKNUMBER = 该碟内序号/该碟曲目数，碟别信息一律交给 DISCNUMBER。
//

import Foundation

func cmdTrackNumberWrite() {
    var fail = 0

    func check(_ label: String, _ got: String?, _ want: String) {
        let ok = got == want
        if !ok { fail += 1 }
        let g = got ?? "(nil)"
        print("  \(ok ? "✔" : "⛔") \(label)  →  \(g)"
              + (ok ? "" : "   期望 \(want)"))
    }

    // MARK: 双碟：碟1 24 首、碟2 21 首，全辑声明 45 首
    hr("双碟专辑的写入值（tracknum）")
    var tracks: [AlbumTrack] = []
    for n in 1...24 { tracks.append(AlbumTrack(number: n, disc: 1, title: "D1-\(n)")) }
    for n in 1...21 { tracks.append(AlbumTrack(number: n, disc: 2, title: "D2-\(n)")) }
    let two = AlbumDetail(sourceID: "probe", albumID: "2disc",
                          title: "千と千尋の神隠し サウンドトラック", artist: "久石譲",
                          year: "2001", trackCount: 45, discCount: 2, tracks: tracks)
    print("  合成专辑 : \(two.summary)  碟数 \(two.effectiveDiscCount)"
          + "（碟1 \(two.trackCount(inDisc: 1)) 首 / 碟2 \(two.trackCount(inDisc: 2)) 首）")
    print("  全辑声明 \(two.trackCount) 首 —— 旧行为就是把这个 45 写进了 TRACKNUMBER")
    print("")
    let d1t7 = two.candidate(for: tracks[6])                 // 碟1 第 7 首
    check("碟1 第7首 TRACKNUMBER", d1t7.trackNumber, "7/24")
    check("碟1 第7首 DISCNUMBER ", d1t7.discNumber, "1/2")
    let d2t7 = two.candidate(for: tracks[24 + 6])            // 碟2 第 7 首
    check("碟2 第7首 TRACKNUMBER", d2t7.trackNumber, "7/21")
    check("碟2 第7首 DISCNUMBER ", d2t7.discNumber, "2/2")
    let d2last = two.candidate(for: tracks[24 + 20])         // 碟2 末首
    check("碟2 第21首 TRACKNUMBER", d2last.trackNumber, "21/21")

    // MARK: 单碟：维持原样 n/11
    hr("单碟专辑的写入值（tracknum）")
    let one = AlbumDetail(sourceID: "probe", albumID: "1disc",
                          title: "魔杰座", artist: "周杰伦", year: "2008",
                          trackCount: 11, discCount: 1,
                          tracks: (1...11).map { AlbumTrack(number: $0, disc: 1, title: "T\($0)") })
    let o7 = one.candidate(for: one.tracks[6])
    check("第7首 TRACKNUMBER", o7.trackNumber, "7/11")
    check("第7首 DISCNUMBER ", o7.discNumber, "1/1")

    // 源少给了曲目（网易云版权下架那种）：声明值仍是 11，写入也应保持 n/11
    let short = AlbumDetail(sourceID: "probe", albumID: "1disc-short",
                            title: "魔杰座（缺 2 首）", artist: "周杰伦",
                            trackCount: 11, discCount: 1,
                            tracks: (1...9).map { AlbumTrack(number: $0, disc: 1, title: "T\($0)") })
    let s3 = short.candidate(for: short.tracks[2])
    check("缺曲单碟 第3首 TRACKNUMBER", s3.trackNumber, "3/11")
    check("缺曲单碟 第3首 DISCNUMBER ", s3.discNumber, "1/1")

    // MARK: 源没声明碟数，但曲目表里带了碟号 —— 以曲目表为准
    hr("源少声明碟数时以曲目表为准（tracknum）")
    let sloppy = AlbumDetail(sourceID: "probe", albumID: "sloppy",
                             title: "碟数没声明", trackCount: 0, discCount: 1,
                             tracks: (1...5).map { AlbumTrack(number: $0, disc: 1, title: "A\($0)") }
                                   + (1...3).map { AlbumTrack(number: $0, disc: 2, title: "B\($0)") })
    let sl = sloppy.candidate(for: sloppy.tracks[5])         // 碟2 第 1 首
    check("碟2 第1首 TRACKNUMBER", sl.trackNumber, "1/3")
    check("碟2 第1首 DISCNUMBER ", sl.discNumber, "2/2")

    print("")
    print(fail == 0 ? "  ✔ 全部通过" : "  ⛔ \(fail) 项不符")
}
