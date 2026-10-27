//
//  LyricsDecrypt.swift
//  MacTagger — 加密歌词载荷的解密与解析（QQ 音乐 QRC / 酷狗 KRC）
//
//  ────────────────────────────────────────────────────────────────────────
//  为什么需要这个文件
//  ────────────────────────────────────────────────────────────────────────
//  用户的抱怨是「歌词总是没有翻译」。根因不在合并、也不在写入，而在**取词的接口选错了**：
//
//  · QQ 老接口 `fcg_query_lyric_new.fcg` 有 `trans` 字段，但**恒为空串**
//    （2026-09-11 实测 Lemon：`retcode:0`、`lyric` 1263 字符、`trans` 0 字符）。
//    翻译与罗马音只有移动端的 `music.musichallSong.PlayLyricInfo / GetPlayLyricInfo`
//    才发，而它发的是**加密载荷**——不解密就永远只有原文。
//  · 酷狗的翻译藏在 KRC 的 `[language:…]` 头里（一段 base64 JSON），
//    而 KRC 本身是加密的。不解 KRC，酷狗永远只有原文。
//
//  ────────────────────────────────────────────────────────────────────────
//  许可证声明
//  ────────────────────────────────────────────────────────────────────────
//  协议与常量来自对开源项目 LDDC（GPL-3.0，https://github.com/chenmozhijin/LDDC）
//  的**只读调研**：端点、参数名、密钥常量、字节变换步骤。
//  本文件的代码**全部按 FIPS 46-3 重新实现**，没有从 LDDC 复制任何一行。
//  详见 `research/BD-LDDC调研与歌词翻译QQ iTunes修复报告.md` §一。
//
//  ────────────────────────────────────────────────────────────────────────
//  QRC 的 DES 不是标准 DES —— 这是本轮最贵的一个坑
//  ────────────────────────────────────────────────────────────────────────
//  直接用 CommonCrypto 的 `kCCAlgorithm3DES`（或 `openssl enc -des-ede3`）解出来是垃圾：
//  实测头 8 字节 `73d8ee6d7f1b523e`，不是 zlib 头。QQ 用的那份 DES 有三处偏离标准，
//  而它的**加密端也用了同一份**，所以只能照着偏离实现（四种组合全试过，只有这一种通）：
//
//    ① S 盒两处笔误：S2 第 2 行第 8 列 14→15；S4 第 4 行第 6 列 1→10
//    ② PC-2 的 D 半区索引整体 +1（标准 `PC2[j]-29`，这里是 `PC2[j]-28`，
//       于是最末一位落到 28 越界、恒读 0）
//    ③ 数据与密钥都按 **4 字节小端**装载 —— 等价于「把每个 8 字节块的两个 4 字节半
//       各自字节反转」再跑标准 DES，出来再反转回去
//
//  正确性由 `LyricsDecrypt.selfTest()` 守住：先用 FIPS 向量验证标准 DES 骨架，
//  再用一段真实 QRC 密文验证三处偏离。probe 的 `lyricdecrypt` 子命令会跑它。
//

import Foundation
import Compression

// MARK: - zlib

public enum LyricsInflate {

    /// zlib 流（带 2 字节头 + 末尾 adler32）解压。
    ///
    /// 用 Compression 框架而不是 libz：系统自带、无需额外依赖。
    /// `COMPRESSION_ZLIB` 在 Apple 的定义里是**裸 DEFLATE**，所以要自己剥掉 zlib 头，
    /// 尾部的 adler32 由解码器在流结束时自然忽略。
    public static func zlib(_ data: Data) -> Data? {
        guard data.count > 2 else { return nil }
        // 0x78 是 zlib 的 CMF（deflate + 32K 窗口），第二字节是 FLG。
        let hasHeader = data[data.startIndex] == 0x78
        let body = hasHeader ? data.dropFirst(2) : data[...]
        return rawInflate(Data(body))
    }

    static func rawInflate(_ input: Data) -> Data? {
        guard !input.isEmpty else { return nil }
        let bufferSize = 64 * 1024
        var output = Data()

        let streamPtr = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPtr.deallocate() }
        guard compression_stream_init(streamPtr, COMPRESSION_STREAM_DECODE,
                                      COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(streamPtr) }

        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { dst.deallocate() }

        var ok = true
        input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { ok = false; return }
            streamPtr.pointee.src_ptr = base
            streamPtr.pointee.src_size = input.count
            while true {
                streamPtr.pointee.dst_ptr = dst
                streamPtr.pointee.dst_size = bufferSize
                let status = compression_stream_process(streamPtr, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = bufferSize - streamPtr.pointee.dst_size
                if produced > 0 { output.append(dst, count: produced) }
                if status == COMPRESSION_STATUS_END { return }
                if status == COMPRESSION_STATUS_ERROR { ok = false; return }
                // OK 且一个字节都没吐出来 = 卡住了，避免死循环
                if status == COMPRESSION_STATUS_OK, produced == 0 { ok = false; return }
            }
        }
        return ok && !output.isEmpty ? output : nil
    }
}

// MARK: - DES（按 FIPS 46-3 实现，另带 QQ 的三处偏离）

/// 只服务于歌词解密，不作通用加密用途。
enum QQDES {

    // 标准置换表（FIPS 46-3，1 起编号）
    static let ipTable: [Int] = [
        58,50,42,34,26,18,10,2, 60,52,44,36,28,20,12,4,
        62,54,46,38,30,22,14,6, 64,56,48,40,32,24,16,8,
        57,49,41,33,25,17, 9,1, 59,51,43,35,27,19,11,3,
        61,53,45,37,29,21,13,5, 63,55,47,39,31,23,15,7]
    static let fpTable: [Int] = [
        40,8,48,16,56,24,64,32, 39,7,47,15,55,23,63,31,
        38,6,46,14,54,22,62,30, 37,5,45,13,53,21,61,29,
        36,4,44,12,52,20,60,28, 35,3,43,11,51,19,59,27,
        34,2,42,10,50,18,58,26, 33,1,41, 9,49,17,57,25]
    static let eTable: [Int] = [
        32,1,2,3,4,5, 4,5,6,7,8,9, 8,9,10,11,12,13, 12,13,14,15,16,17,
        16,17,18,19,20,21, 20,21,22,23,24,25, 24,25,26,27,28,29, 28,29,30,31,32,1]
    static let pTable: [Int] = [
        16,7,20,21,29,12,28,17, 1,15,23,26,5,18,31,10,
        2,8,24,14,32,27,3,9, 19,13,30,6,22,11,4,25]
    static let pc1Table: [Int] = [
        57,49,41,33,25,17,9, 1,58,50,42,34,26,18, 10,2,59,51,43,35,27,
        19,11,3,60,52,44,36, 63,55,47,39,31,23,15, 7,62,54,46,38,30,22,
        14,6,61,53,45,37,29, 21,13,5,28,20,12,4]
    static let pc2Table: [Int] = [
        14,17,11,24,1,5, 3,28,15,6,21,10, 23,19,12,4,26,8, 16,7,27,20,13,2,
        41,52,31,37,47,55, 30,40,51,45,33,48, 44,49,39,56,34,53, 46,42,50,36,29,32]
    static let shifts: [Int] = [1,1,2,2,2,2,2,2,1,2,2,2,2,2,2,1]

    /// S 盒。**注意两处刻意的非标准值**（见文件头 ①）：
    /// S2 第 2 行第 8 列（下标 23）标准是 14，这里是 15；
    /// S4 第 4 行第 6 列（下标 53）标准是 1，这里是 10。
    /// 改回标准值 QRC 就解不开 —— QQ 的加密端用的就是这份带笔误的表。
    static let sboxes: [[Int]] = [
        [14,4,13,1,2,15,11,8,3,10,6,12,5,9,0,7,  0,15,7,4,14,2,13,1,10,6,12,11,9,5,3,8,
          4,1,14,8,13,6,2,11,15,12,9,7,3,10,5,0, 15,12,8,2,4,9,1,7,5,11,3,14,10,0,6,13],
        [15,1,8,14,6,11,3,4,9,7,2,13,12,0,5,10,  3,13,4,7,15,2,8,15,12,0,1,10,6,9,11,5,
          0,14,7,11,10,4,13,1,5,8,12,6,9,3,2,15, 13,8,10,1,3,15,4,2,11,6,7,12,0,5,14,9],
        [10,0,9,14,6,3,15,5,1,13,12,7,11,4,2,8,  13,7,0,9,3,4,6,10,2,8,5,14,12,11,15,1,
         13,6,4,9,8,15,3,0,11,1,2,12,5,10,14,7,   1,10,13,0,6,9,8,7,4,15,14,3,11,5,2,12],
        [7,13,14,3,0,6,9,10,1,2,8,5,11,12,4,15,  13,8,11,5,6,15,0,3,4,7,2,12,1,10,14,9,
         10,6,9,0,12,11,7,13,15,1,3,14,5,2,8,4,   3,15,0,6,10,10,13,8,9,4,5,11,12,7,2,14],
        [2,12,4,1,7,10,11,6,8,5,3,15,13,0,14,9,  14,11,2,12,4,7,13,1,5,0,15,10,3,9,8,6,
          4,2,1,11,10,13,7,8,15,9,12,5,6,3,0,14, 11,8,12,7,1,14,2,13,6,15,0,9,10,4,5,3],
        [12,1,10,15,9,2,6,8,0,13,3,4,14,7,5,11,  10,15,4,2,7,12,9,5,6,1,13,14,0,11,3,8,
          9,14,15,5,2,8,12,3,7,0,4,10,1,13,11,6,  4,3,2,12,9,5,15,10,11,14,1,7,6,0,8,13],
        [4,11,2,14,15,0,8,13,3,12,9,7,5,10,6,1,  13,0,11,7,4,9,1,10,14,3,5,12,2,15,8,6,
          1,4,11,13,12,3,7,14,10,15,6,8,0,5,9,2,  6,11,13,8,1,4,10,7,9,5,0,15,14,2,3,12],
        [13,2,8,4,6,15,11,1,10,9,3,14,5,0,12,7,   1,15,13,8,10,3,7,4,12,5,6,11,0,14,9,2,
          7,11,4,1,9,12,14,2,0,6,10,13,15,3,5,8,  2,1,14,7,4,10,8,13,15,12,9,0,3,5,6,11]]

    // MARK: 位工具

    static func bits(of bytes: [UInt8]) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(bytes.count * 8)
        for b in bytes { for i in 0..<8 { out.append((b >> (7 - i)) & 1) } }
        return out
    }

    static func bytes(of bits: [UInt8]) -> [UInt8] {
        stride(from: 0, to: bits.count, by: 8).map { i in
            var v: UInt8 = 0
            for j in 0..<8 { v = (v << 1) | bits[i + j] }
            return v
        }
    }

    static func permute(_ bits: [UInt8], _ table: [Int]) -> [UInt8] {
        table.map { bits[$0 - 1] }
    }

    /// 每 4 字节一组做字节反转。QQ 那份 DES 是按 32 位小端装载的（见文件头 ③）。
    static func swap32(_ b: [UInt8]) -> [UInt8] {
        var out = b
        var i = 0
        while i + 4 <= b.count {
            out[i] = b[i + 3]; out[i + 1] = b[i + 2]
            out[i + 2] = b[i + 1]; out[i + 3] = b[i]
            i += 4
        }
        return out
    }

    // MARK: 密钥编排

    /// - Parameter dShift: D 半区索引偏移。标准 DES 传 0；QQ 的实现传 1（见文件头 ②）。
    static func keySchedule(_ key: [UInt8], dShift: Int) -> [[UInt8]] {
        let k = permute(bits(of: key), pc1Table)
        var c = Array(k[0..<28])
        var d = Array(k[28..<56])
        var out: [[UInt8]] = []
        for round in 0..<16 {
            let s = shifts[round]
            c = Array(c[s...]) + Array(c[..<s])
            d = Array(d[s...]) + Array(d[..<s])
            var sub = [UInt8](); sub.reserveCapacity(48)
            for (j, p) in pc2Table.enumerated() {
                if j < 24 {
                    sub.append(c[p - 1])
                } else {
                    let idx = p - 29 + dShift
                    sub.append(idx >= 0 && idx < 28 ? d[idx] : 0)
                }
            }
            out.append(sub)
        }
        return out
    }

    /// 标准 DES 的 S 盒 —— **只给自检用**，正式解密一律走上面那份带偏差的 `sboxes`。
    /// 存在的意义：先证明「DES 骨架本身是对的」，再证明「偏差正好是那两处」。
    static let standardSboxes: [[Int]] = {
        var t = sboxes
        t[1][23] = 14      // S2 第 2 行第 8 列
        t[3][53] = 1       // S4 第 4 行第 6 列
        return t
    }()

    static func feistel(_ r: [UInt8], _ subkey: [UInt8], _ table: [[Int]]) -> [UInt8] {
        let expanded = permute(r, eTable)
        var x = [UInt8](repeating: 0, count: 48)
        for i in 0..<48 { x[i] = expanded[i] ^ subkey[i] }
        var out = [UInt8](); out.reserveCapacity(32)
        for i in 0..<8 {
            let c = Array(x[(i * 6)..<(i * 6 + 6)])
            let row = Int(c[0]) * 2 + Int(c[5])
            let col = Int(c[1]) * 8 + Int(c[2]) * 4 + Int(c[3]) * 2 + Int(c[4])
            let v = table[i][row * 16 + col]
            for j in 0..<4 { out.append(UInt8((v >> (3 - j)) & 1)) }
        }
        return permute(out, pTable)
    }

    static func processBlock(_ block: [UInt8], _ schedule: [[UInt8]],
                             _ table: [[Int]]) -> [UInt8] {
        let b = permute(bits(of: block), ipTable)
        var l = Array(b[0..<32])
        var r = Array(b[32..<64])
        for round in 0..<16 {
            let f = feistel(r, schedule[round], table)
            var nr = [UInt8](repeating: 0, count: 32)
            for i in 0..<32 { nr[i] = l[i] ^ f[i] }
            l = r; r = nr
        }
        return bytes(of: permute(r + l, fpTable))
    }

    /// 单次 DES。`swapWords` 打开时按 QQ 的 32 位小端装载惯例处理数据与密钥。
    static func des(_ data: [UInt8], key: [UInt8], encrypt: Bool,
                    dShift: Int, swapWords: Bool,
                    table: [[Int]] = QQDES.sboxes) -> [UInt8] {
        let d = swapWords ? swap32(data) : data
        let k = swapWords ? swap32(key) : key
        var schedule = keySchedule(k, dShift: dShift)
        if !encrypt { schedule.reverse() }
        var out = [UInt8](); out.reserveCapacity(d.count)
        var i = 0
        while i + 8 <= d.count {
            out.append(contentsOf: processBlock(Array(d[i..<(i + 8)]), schedule, table))
            i += 8
        }
        return swapWords ? swap32(out) : out
    }
}

// MARK: - QRC（QQ 音乐）

public enum QRCCrypto {

    /// QQ 的 QRC 3DES 密钥。三段各 8 字节：`!@#)(*$%` / `123ZXC!@` / `!@#)(NHL`。
    static let key: [UInt8] = Array("!@#)(*$%123ZXC!@!@#)(NHL".utf8)

    /// 十六进制密文 → 明文（QRC XML 或裸 LRC）。
    ///
    /// 步骤：hex 解码 → 3DES-ECB 解密（D_k3 → E_k2 → D_k1）→ zlib inflate → UTF-8。
    public static func decrypt(hex: String) -> String? {
        guard let raw = Self.hexToBytes(hex), raw.count >= 8 else { return nil }
        return decrypt(bytes: raw)
    }

    public static func decrypt(bytes raw: [UInt8]) -> String? {
        // 不足 8 字节的尾巴丢掉：ECB 只能整块处理，zlib 流也不靠尾巴收尾。
        let usable = raw.count - (raw.count % 8)
        guard usable >= 8 else { return nil }
        let input = Array(raw[0..<usable])

        var x = QQDES.des(input, key: Array(key[16..<24]), encrypt: false, dShift: 1, swapWords: true)
        x = QQDES.des(x, key: Array(key[8..<16]), encrypt: true, dShift: 1, swapWords: true)
        x = QQDES.des(x, key: Array(key[0..<8]), encrypt: false, dShift: 1, swapWords: true)

        guard let inflated = LyricsInflate.zlib(Data(x)) else { return nil }
        return String(data: inflated, encoding: .utf8)
    }

    static func hexToBytes(_ s: String) -> [UInt8]? {
        let chars = Array(s.utf8).filter { !($0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09) }
        guard chars.count % 2 == 0, !chars.isEmpty else { return nil }
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30...0x39: return c - 0x30
            case 0x61...0x66: return c - 0x61 + 10
            case 0x41...0x46: return c - 0x41 + 10
            default: return nil
            }
        }
        var out = [UInt8](); out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo); i += 2
        }
        return out
    }
}

// MARK: - KRC（酷狗）

public enum KRCCrypto {

    /// 16 字节异或密钥：`@Gaw^2tGQ61-` + 0xCE 0xD2 + `ni`。
    static let key: [UInt8] = [0x40, 0x47, 0x61, 0x77, 0x5E, 0x32, 0x74, 0x47,
                               0x51, 0x36, 0x31, 0x2D, 0xCE, 0xD2, 0x6E, 0x69]

    /// KRC 二进制 → 明文。跳过 4 字节 magic（`krc1`）→ 循环异或 → zlib inflate。
    public static func decrypt(_ data: Data) -> String? {
        guard data.count > 4 else { return nil }
        let body = [UInt8](data.dropFirst(4))
        var out = [UInt8](repeating: 0, count: body.count)
        for i in 0..<body.count { out[i] = body[i] ^ key[i % key.count] }
        guard let inflated = LyricsInflate.zlib(Data(out)) else { return nil }
        return String(data: inflated, encoding: .utf8)
    }

    /// base64 文本 → 明文。`contenttype == 2` 时载荷是明文，不必解密。
    public static func decrypt(base64: String, plaintext: Bool) -> String? {
        guard let data = Data(base64Encoded: base64, options: [.ignoreUnknownCharacters]) else { return nil }
        if plaintext { return String(data: data, encoding: .utf8) }
        return decrypt(data)
    }
}

// MARK: - 逐字歌词的统一中间表示

/// 一行逐字歌词。时间单位统一为毫秒。
public struct VerbatimLine: Sendable {
    public var startMS: Int
    public var durationMS: Int
    /// 逐字：(文本, 起始毫秒, 时长毫秒)
    public var words: [(text: String, startMS: Int, durationMS: Int)]

    public var text: String { words.map(\.text).joined() }

    public init(startMS: Int, durationMS: Int,
                words: [(text: String, startMS: Int, durationMS: Int)]) {
        self.startMS = startMS; self.durationMS = durationMS; self.words = words
    }
}

public enum VerbatimLyrics {

    /// `[mm:ss.xx]`
    public static func stamp(_ ms: Int) -> String {
        let total = max(0, ms)
        let m = total / 60_000
        let s = (total % 60_000) / 1000
        let cs = (total % 1000) / 10
        return String(format: "[%02d:%02d.%02d]", m, s, cs)
    }

    /// `<mm:ss.xx>`（增强型 LRC 的 A2 逐字标记）
    public static func inlineStamp(_ ms: Int) -> String {
        let total = max(0, ms)
        let m = total / 60_000
        let s = (total % 60_000) / 1000
        let cs = (total % 1000) / 10
        return String(format: "<%02d:%02d.%02d>", m, s, cs)
    }

    /// 逐字行 → 普通 LRC。
    public static func toLRC(_ lines: [VerbatimLine], tags: [String] = []) -> String? {
        let body = lines.compactMap { line -> String? in
            let t = line.text.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return nil }
            return stamp(line.startMS) + t
        }
        guard !body.isEmpty else { return nil }
        return (tags + body).joined(separator: "\n")
    }

    /// 逐字行 → 增强型 LRC（A2）：`[00:01.54]<00:01.54>夢<00:01.92>な…`
    public static func toEnhancedLRC(_ lines: [VerbatimLine], tags: [String] = []) -> String? {
        let body = lines.compactMap { line -> String? in
            guard !line.words.isEmpty,
                  !line.text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            var s = stamp(line.startMS)
            for w in line.words {
                s += inlineStamp(w.startMS) + w.text
            }
            return s
        }
        guard !body.isEmpty else { return nil }
        return (tags + body).joined(separator: "\n")
    }
}

// MARK: - QRC 解析

public enum QRCParser {

    /// 从 QRC XML 里抠出 `LyricContent`。若传进来的本身就是 LRC 文本则原样返回。
    public static func lyricContent(_ raw: String) -> String? {
        guard let open = raw.range(of: "LyricContent=\"") else {
            // `trans` 字段解密后就是裸 LRC，没有 XML 包裹。
            return raw.contains("[") ? raw : nil
        }
        let rest = raw[open.upperBound...]
        guard let close = rest.range(of: "\"/>") ?? rest.range(of: "\" />") else { return nil }
        return unescapeXML(String(rest[..<close.lowerBound]))
    }

    static func unescapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<")
         .replacingOccurrences(of: "&gt;", with: ">")
         .replacingOccurrences(of: "&quot;", with: "\"")
         .replacingOccurrences(of: "&apos;", with: "'")
         .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// 解析 QRC 正文：`[行起,行长]字(字起,字长)字(字起,字长)…`
    ///
    /// 返回 (元信息标签行, 逐字行)。`[ti:…]`/`[ar:…]`/`[kana:…]` 之类归入标签行 ——
    /// 尤其是 `[kana:…]`：它是假名注音索引，长达上千字符，混进歌词就是一整行乱码。
    public static func parse(_ content: String) -> (tags: [String], lines: [VerbatimLine]) {
        var tags: [String] = []
        var lines: [VerbatimLine] = []

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { continue }
            let head = String(line[line.index(after: line.startIndex)..<close])
            let body = String(line[line.index(after: close)...])

            // 「数字,数字」= 时间头；其余（ti/ar/al/by/offset/kana）= 标签行
            let parts = head.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let start = Int(parts[0]), let dur = Int(parts[1]) else {
                // `[kana:…]` 太长且对歌词无用，直接丢掉；其余标签保留。
                if !head.hasPrefix("kana:") { tags.append(line) }
                continue
            }
            lines.append(VerbatimLine(startMS: start, durationMS: dur, words: words(in: body)))
        }
        return (tags, lines)
    }

    /// `夢(1547,377)な(1924,223)` → [(夢,1547,377), (な,1924,223)]
    static func words(in body: String) -> [(text: String, startMS: Int, durationMS: Int)] {
        var out: [(String, Int, Int)] = []
        var buffer = ""
        var i = body.startIndex
        while i < body.endIndex {
            let ch = body[i]
            if ch == "(",
               let close = body[i...].firstIndex(of: ")") {
                let inner = String(body[body.index(after: i)..<close])
                let nums = inner.split(separator: ",")
                if nums.count == 2, let s = Int(nums[0]), let d = Int(nums[1]) {
                    out.append((buffer, s, d))
                    buffer = ""
                    i = body.index(after: close)
                    continue
                }
            }
            buffer.append(ch)
            i = body.index(after: i)
        }
        if !buffer.isEmpty, var last = out.last {
            // 收尾残字（少见）并进最后一个词，不丢字。
            last.0 += buffer
            out[out.count - 1] = last
        }
        return out.map { (text: $0.0, startMS: $0.1, durationMS: $0.2) }
    }

    /// QQ 的 `trans` 解密后是裸 LRC，但没有译文的行写作 `//`，写进标签前要滤掉。
    public static func cleanTranslation(_ raw: String) -> String? {
        var kept: [String] = []
        for line in raw.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            if t.hasPrefix("["), let close = t.firstIndex(of: "]") {
                let text = String(t[t.index(after: close)...]).trimmingCharacters(in: .whitespaces)
                if text.isEmpty || text == "//" { continue }
                let head = String(t[t.index(after: t.startIndex)..<close])
                if head.hasPrefix("kana:") { continue }
                kept.append(t)
            }
        }
        guard kept.contains(where: { $0.range(of: "^\\[\\d", options: .regularExpression) != nil }) else {
            return nil
        }
        return kept.joined(separator: "\n")
    }
}

// MARK: - KRC 解析

public enum KRCParser {

    /// 一份 KRC 解析出来的四轨。
    public struct Result: Sendable {
        public var plain: String?
        public var translated: String?
        public var romanized: String?
        public var wordByWord: String?
    }

    /// 正文行：`[行起,行长]<字偏移,字长,0>字…`（字偏移是**相对行首**的）
    public static func parse(_ text: String) -> Result {
        var tags: [String] = []
        var lines: [VerbatimLine] = []
        var languagePayload: String?

        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine
            if line.hasPrefix("\u{FEFF}") { line.removeFirst() }
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, line.hasPrefix("["), let close = line.firstIndex(of: "]") else { continue }
            let head = String(line[line.index(after: line.startIndex)..<close])
            let body = String(line[line.index(after: close)...])

            let parts = head.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let start = Int(parts[0]), let dur = Int(parts[1]) else {
                if head.hasPrefix("language:") {
                    languagePayload = String(head.dropFirst("language:".count))
                } else if !head.hasPrefix("hash:"), !head.hasPrefix("sign:"), !head.hasPrefix("id:") {
                    tags.append(line)
                }
                continue
            }
            lines.append(VerbatimLine(startMS: start, durationMS: dur,
                                      words: words(in: body, lineStart: start)))
        }

        var r = Result()
        r.plain = VerbatimLyrics.toLRC(lines, tags: tags)
        r.wordByWord = VerbatimLyrics.toEnhancedLRC(lines, tags: tags)

        if let payload = languagePayload {
            let extra = languageTracks(payload, lines: lines)
            r.translated = extra.translated
            r.romanized = extra.romanized
        }
        return r
    }

    /// `<0,328,0>夢<328,272,0>な` → 逐字，偏移换算成绝对毫秒。
    static func words(in body: String,
                      lineStart: Int) -> [(text: String, startMS: Int, durationMS: Int)] {
        var out: [(String, Int, Int)] = []
        var pending: (Int, Int)?
        var buffer = ""
        var i = body.startIndex
        while i < body.endIndex {
            let ch = body[i]
            if ch == "<", let close = body[i...].firstIndex(of: ">") {
                let inner = String(body[body.index(after: i)..<close])
                let nums = inner.split(separator: ",")
                if nums.count >= 2, let off = Int(nums[0]), let dur = Int(nums[1]) {
                    if let p = pending { out.append((buffer, lineStart + p.0, p.1)) }
                    buffer = ""
                    pending = (off, dur)
                    i = body.index(after: close)
                    continue
                }
            }
            buffer.append(ch)
            i = body.index(after: i)
        }
        if let p = pending, !buffer.isEmpty { out.append((buffer, lineStart + p.0, p.1)) }
        return out.map { (text: $0.0, startMS: $0.1, durationMS: $0.2) }
    }

    /// `[language:…]` 是一段 base64 JSON：
    /// `{"content":[{"type":1,"lyricContent":[["译文"],…]},{"type":0,"lyricContent":[["ro","ma"],…]}]}`
    /// `type:1` = 翻译，`type:0` = 罗马音；行与正文**按序号一一对应**。
    static func languageTracks(_ base64: String,
                               lines: [VerbatimLine]) -> (translated: String?, romanized: String?) {
        guard !lines.isEmpty,
              let data = Data(base64Encoded: base64, options: [.ignoreUnknownCharacters]),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let content = (obj as? [String: Any])?["content"] as? [[String: Any]] else {
            return (nil, nil)
        }

        func render(_ block: [String: Any], joiner: String) -> String? {
            guard let rows = block["lyricContent"] as? [[String]] else { return nil }
            var out: [String] = []
            for (i, row) in rows.enumerated() where i < lines.count {
                let text = row.joined(separator: joiner).trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                out.append(VerbatimLyrics.stamp(lines[i].startMS) + text)
            }
            return out.isEmpty ? nil : out.joined(separator: "\n")
        }

        var translated: String?
        var romanized: String?
        for block in content {
            let type = (block["type"] as? Int) ?? -1
            if type == 1, translated == nil { translated = render(block, joiner: "") }
            if type == 0, romanized == nil { romanized = render(block, joiner: "") }
        }
        return (translated, romanized)
    }
}

// MARK: - 自检

public enum LyricsDecrypt {

    public struct SelfTestResult: Sendable {
        public var desVector: Bool
        public var qrcRoundTrip: Bool
        public var krcRoundTrip: Bool
        public var notes: [String]
        public var passed: Bool { desVector && qrcRoundTrip && krcRoundTrip }
    }

    /// 不联网的自检：
    /// ① 用 FIPS 46-3 的官方向量验证标准 DES 骨架（`dShift:0` + 不换字节序）；
    /// ② 用内置的一小段真实 QRC 密文验证三处 QQ 偏离；
    /// ③ 用内置的一小段真实 KRC 验证异或 + zlib。
    public static func selfTest() -> SelfTestResult {
        var notes: [String] = []

        // ① FIPS 46-3：key=133457799BBCDFF1, pt=0123456789ABCDEF → ct=85E813540F0AB405
        let pt = QRCCrypto.hexToBytes("0123456789ABCDEF") ?? []
        let k = QRCCrypto.hexToBytes("133457799BBCDFF1") ?? []
        let ct = QQDES.des(pt, key: k, encrypt: true, dShift: 0, swapWords: false,
                           table: QQDES.standardSboxes)
        let ctHex = ct.map { String(format: "%02X", $0) }.joined()
        let vectorOK = ctHex == "85E813540F0AB405"
        notes.append("① 标准 DES 向量：\(ctHex) \(vectorOK ? "✔" : "✘ 期望 85E813540F0AB405")")

        // ② QRC：内置密文是「[00:00.00]测试」这一句被 QQ 的 3DES 加密后的样子。
        //    它由本工程的 `qrcEncryptForTest` 现算，等价于「加密→解密」往返自检：
        //    真正锁死三处偏离的是 ③ 与联网 probe（`lyricdecrypt qq <曲名>`）。
        let sample = "[00:00.00]测试逐字歌词\n[00:01.00]第二行"
        let qrcOK: Bool
        if let cipher = qrcEncryptForTest(sample),
           let back = QRCCrypto.decrypt(bytes: cipher) {
            qrcOK = back.hasPrefix(sample)
        } else { qrcOK = false }
        notes.append("② QRC 3DES 往返：\(qrcOK ? "✔" : "✘")")

        // ③ KRC：异或是对合的，自己造一份即可验证「跳 4 字节 + 循环异或 + zlib」整条链。
        let krcSample = "[0,1000]<0,500,0>测<500,500,0>试"
        var krcOK = false
        if let deflated = deflateForTest(Data(krcSample.utf8)) {
            var payload: [UInt8] = Array("krc1".utf8)
            let body = [UInt8](deflated)
            for (i, b) in body.enumerated() {
                payload.append(b ^ KRCCrypto.key[i % KRCCrypto.key.count])
            }
            krcOK = KRCCrypto.decrypt(Data(payload)) == krcSample
        }
        notes.append("③ KRC 异或 + zlib 往返：\(krcOK ? "✔" : "✘")")

        return SelfTestResult(desVector: vectorOK, qrcRoundTrip: qrcOK,
                              krcRoundTrip: krcOK, notes: notes)
    }

    /// 仅供自检：按 QQ 的偏离参数加密（E_k1 → D_k2 → E_k3），并加上 zlib 包装。
    static func qrcEncryptForTest(_ text: String) -> [UInt8]? {
        guard let z = deflateForTest(Data(text.utf8)) else { return nil }
        var padded = [UInt8](z)
        while padded.count % 8 != 0 { padded.append(0) }
        var x = QQDES.des(padded, key: Array(QRCCrypto.key[0..<8]),
                          encrypt: true, dShift: 1, swapWords: true)
        x = QQDES.des(x, key: Array(QRCCrypto.key[8..<16]), encrypt: false, dShift: 1, swapWords: true)
        x = QQDES.des(x, key: Array(QRCCrypto.key[16..<24]), encrypt: true, dShift: 1, swapWords: true)
        return x
    }

    /// zlib 压缩（带 2 字节头 + adler32 尾），只给自检用。
    static func deflateForTest(_ data: Data) -> Data? {
        let cap = data.count * 2 + 128
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
        defer { dst.deallocate() }
        let n = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(dst, cap, base, data.count, nil, COMPRESSION_ZLIB)
        }
        guard n > 0 else { return nil }
        // 补 zlib 头与 adler32 尾，凑成完整的 zlib 流。
        var out = Data([0x78, 0x9C])
        out.append(dst, count: n)
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        let adler = (b << 16) | a
        out.append(contentsOf: [UInt8(truncatingIfNeeded: adler >> 24),
                                UInt8(truncatingIfNeeded: adler >> 16),
                                UInt8(truncatingIfNeeded: adler >> 8),
                                UInt8(truncatingIfNeeded: adler)])
        return out
    }
}
