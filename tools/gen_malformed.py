#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成畸形 / 异常音频文件，验证桥接层的健壮性。

背景：B 报告风险点 6 指出原版 MusicTag 开启了 legacyCorruptedStateExceptionsPolicy，
说明其原生引擎在畸形文件上会抛 AccessViolation。macOS 版必须在 C++ 侧兜住，
向 Swift 返回错误而不是崩溃。这个脚本就是用来打这一环的。

全部样本从 testdata/ 里自己生成的正常文件派生，不涉及任何用户私人文件。

用法：python3 gen_malformed.py <正常样本目录> <输出目录>
"""

import os
import random
import shutil
import sys


def write(path: str, data: bytes) -> None:
    with open(path, 'wb') as f:
        f.write(data)
    print(f'  {os.path.basename(path):<34} {len(data):>9,} 字节')


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 1
    src_dir, out_dir = sys.argv[1], sys.argv[2]
    os.makedirs(out_dir, exist_ok=True)
    random.seed(20260901)

    def src(name: str) -> bytes:
        with open(os.path.join(src_dir, name), 'rb') as f:
            return f.read()

    mp3 = src('sample.mp3')
    flac = src('sample.flac')
    m4a = src('sample.m4a')
    wav = src('sample.wav')
    ogg = src('sample.ogg')

    # 1. 空文件
    write(os.path.join(out_dir, 'empty.mp3'), b'')

    # 2. 只有几个字节
    write(os.path.join(out_dir, 'tiny.flac'), b'fLaC')

    # 3. 扩展名与内容不符：FLAC 内容顶着 .mp3 的名字
    write(os.path.join(out_dir, 'flac_content_named.mp3'), flac)

    # 4. 纯文本冒充音频
    write(os.path.join(out_dir, 'plaintext.mp3'),
          ('这不是音频文件。' * 500).encode('utf-8'))

    # 5. 全 0 字节
    write(os.path.join(out_dir, 'allzero.wav'), b'\x00' * 200_000)

    # 6. 全随机字节
    write(os.path.join(out_dir, 'random.m4a'),
          bytes(random.getrandbits(8) for _ in range(120_000)))

    # 7. 头部正确但被拦腰截断
    write(os.path.join(out_dir, 'truncated.flac'), flac[:len(flac) // 3])
    write(os.path.join(out_dir, 'truncated.mp3'), mp3[:200])
    write(os.path.join(out_dir, 'truncated.m4a'), m4a[:len(m4a) // 4])
    write(os.path.join(out_dir, 'truncated.ogg'), ogg[:60])

    # 8. ID3v2 头声称长度巨大（经典的整数溢出/越界读诱因）
    bad_id3 = bytearray(b'ID3\x04\x00\x00')
    bad_id3 += bytes([0x7F, 0x7F, 0x7F, 0x7F])        # syncsafe ≈ 268 MB
    bad_id3 += mp3[:4000]
    write(os.path.join(out_dir, 'huge_id3_size.mp3'), bytes(bad_id3))

    # 9. ID3v2 帧长度撒谎
    frame = bytearray(b'ID3\x04\x00\x00\x00\x00\x10\x00')
    frame += b'TIT2' + bytes([0x00, 0x0F, 0xFF, 0xFF]) + b'\x00\x00' + b'\x03hello'
    frame += mp3[:3000]
    write(os.path.join(out_dir, 'lying_frame_size.mp3'), bytes(frame))

    # 10. FLAC METADATA_BLOCK 长度撒谎
    bad_flac = bytearray(flac)
    if len(bad_flac) > 8:
        bad_flac[5:8] = b'\x7F\xFF\xFF'
    write(os.path.join(out_dir, 'bad_block_size.flac'), bytes(bad_flac))

    # 11. MP4 atom 尺寸为 0（易导致死循环）
    bad_mp4 = bytearray(m4a)
    if len(bad_mp4) > 8:
        bad_mp4[0:4] = b'\x00\x00\x00\x00'
    write(os.path.join(out_dir, 'zero_atom.m4a'), bytes(bad_mp4))

    # 12. RIFF 声明的长度远超实际
    bad_wav = bytearray(wav[:5000])
    bad_wav[4:8] = (0xFFFFFF00).to_bytes(4, 'little')
    write(os.path.join(out_dir, 'oversize_riff.wav'), bytes(bad_wav))

    # 13. 中段被随机涂抹
    scribbled = bytearray(flac)
    for i in range(len(scribbled) // 3, len(scribbled) // 3 + 4000):
        scribbled[i] = random.getrandbits(8)
    write(os.path.join(out_dir, 'scribbled.flac'), bytes(scribbled))

    # 14. 双重 ID3v2 头
    write(os.path.join(out_dir, 'double_id3.mp3'),
          b'ID3\x03\x00\x00\x00\x00\x00\x0A' + b'\x00' * 10 + mp3)

    # 15. 目录伪装成文件名（读取时应报错而非崩溃）
    fake_dir = os.path.join(out_dir, 'a_directory.mp3')
    os.makedirs(fake_dir, exist_ok=True)
    print(f'  {"a_directory.mp3":<34} （目录）')

    # 16. 只读文件（验证写入路径的权限判断）
    ro = os.path.join(out_dir, 'readonly.mp3')
    shutil.copyfile(os.path.join(src_dir, 'sample.mp3'), ro)
    os.chmod(ro, 0o444)
    print(f'  {"readonly.mp3":<34} {os.path.getsize(ro):>9,} 字节（0444 只读）')

    return 0


if __name__ == '__main__':
    sys.exit(main())
