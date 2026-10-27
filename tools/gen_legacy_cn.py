#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成「老式中文标签」样本，验证 GBK / Big5 兼容读取路径。

这类文件在国内非常常见：2000 年代的播放器把 GBK 字节直接塞进
ID3v1（无编码标识）与 ID3v2 的 Latin-1 文本帧里。按规范读会得到乱码，
必须用对应的 StringHandler 重新解释字节才能读出中文。

用法：python3 gen_legacy_cn.py <干净的 mp3> <输出目录>
"""

import os
import sys


def id3v1(title: str, artist: str, album: str, year: str,
          comment: str, track: int, encoding: str) -> bytes:
    """拼一个 128 字节 ID3v1.1 标签，文本按 `encoding` 编码。"""
    def fld(s: str, n: int) -> bytes:
        b = s.encode(encoding, errors='replace')[:n]
        return b + b'\x00' * (n - len(b))

    tag = b'TAG'
    tag += fld(title, 30)
    tag += fld(artist, 30)
    tag += fld(album, 30)
    tag += fld(year, 4)
    tag += fld(comment, 28) + b'\x00' + bytes([track])   # v1.1
    tag += bytes([17])                                    # genre 17 = Rock
    assert len(tag) == 128, len(tag)
    return tag


def syncsafe(n: int) -> bytes:
    return bytes([(n >> 21) & 0x7F, (n >> 14) & 0x7F, (n >> 7) & 0x7F, n & 0x7F])


def id3v2_latin1_frames(fields: dict, encoding: str) -> bytes:
    """
    构造 ID3v2.3 标签，文本帧标记为 encoding byte 0x00（ISO-8859-1），
    但实际写入的是 GBK/Big5 字节 —— 这正是老中文软件干的事。
    """
    body = b''
    for frame_id, text in fields.items():
        payload = b'\x00' + text.encode(encoding, errors='replace') + b'\x00'
        body += frame_id.encode('ascii')
        body += len(payload).to_bytes(4, 'big')     # v2.3 用普通 32 位长度
        body += b'\x00\x00'                          # flags
        body += payload
    header = b'ID3' + bytes([3, 0]) + b'\x00' + syncsafe(len(body))
    return header + body


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 1
    src, out_dir = sys.argv[1], sys.argv[2]
    os.makedirs(out_dir, exist_ok=True)

    with open(src, 'rb') as f:
        audio = f.read()
    # 去掉源文件自带的 ID3v2，只留裸音频帧
    if audio[:3] == b'ID3':
        size = ((audio[6] & 0x7F) << 21) | ((audio[7] & 0x7F) << 14) | \
               ((audio[8] & 0x7F) << 7) | (audio[9] & 0x7F)
        audio = audio[10 + size:]

    cases = [
        ('legacy_gbk.mp3', 'gbk',
         {'TIT2': '月亮代表我的心', 'TPE1': '邓丽君', 'TALB': '岛国之情歌',
          'TCON': '流行', 'TCOM': '翁清溪'}),
        ('legacy_big5.mp3', 'big5',
         {'TIT2': '月亮代表我的心', 'TPE1': '鄧麗君', 'TALB': '島國之情歌',
          'TCON': '流行', 'TCOM': '翁清溪'}),
    ]

    for name, enc, fields in cases:
        v2 = id3v2_latin1_frames(fields, enc)
        v1 = id3v1(fields['TIT2'], fields['TPE1'], fields['TALB'],
                   '1977', '老式中文标签', 3, enc)
        path = os.path.join(out_dir, name)
        with open(path, 'wb') as f:
            f.write(v2 + audio + v1)
        print(f'  {name:<20} {os.path.getsize(path):>8,} 字节  '
              f'(ID3v2.3 Latin-1 帧 + ID3v1，实际字节为 {enc.upper()})')

    # 对照组：规范的 UTF-16 ID3v2
    utf16_body = b''
    for fid, text in [('TIT2', '规范的UTF-16标题'), ('TPE1', '规范艺术家')]:
        payload = b'\x01' + '﻿'.encode('utf-16-le') + text.encode('utf-16-le') + b'\x00\x00'
        utf16_body += fid.encode('ascii') + len(payload).to_bytes(4, 'big') + b'\x00\x00' + payload
    utf16 = b'ID3' + bytes([3, 0]) + b'\x00' + syncsafe(len(utf16_body)) + utf16_body
    path = os.path.join(out_dir, 'modern_utf16.mp3')
    with open(path, 'wb') as f:
        f.write(utf16 + audio)
    print(f'  {"modern_utf16.mp3":<20} {os.path.getsize(path):>8,} 字节  (对照组：规范 UTF-16)')

    return 0


if __name__ == '__main__':
    sys.exit(main())
