//
//  MTTagLibBridge.h
//  MacTagger — TagLib bridging layer (facade)
//
//  设计约定（对应 B 报告风险点 6：原版因原生层抛 AccessViolation 才开
//  legacyCorruptedStateExceptionsPolicy）：
//
//  * 本层所有入口都用 C++ try/catch(...) 兜底，**绝不把异常传播到 Swift**；
//  * 所有指针在解引用前判空；
//  * 任何失败都通过 NSError 返回，返回值为 nil / NO；
//  * TagLib 的调试输出被重定向到 diagnostics 数组，不打到 stderr。
//

#import <Foundation/Foundation.h>
#import "MTTagModels.h"

NS_ASSUME_NONNULL_BEGIN

@interface MTTagLibBridge : NSObject

#pragma mark - 环境

/// 链接到的 TagLib 版本，例如 `2.3.1`。
@property (class, nonatomic, readonly) NSString *taglibVersion;

/// TagLib 自称支持的全部扩展名（小写，无点）。
@property (class, nonatomic, readonly) NSArray<NSString *> *supportedFileExtensions;

/// 判断某扩展名是否在 TagLib 的支持列表内。
+ (BOOL)isExtensionSupported:(NSString *)ext;

#pragma mark - 全局文本编码策略

/// 老旧中文标签的兼容读取策略。默认 `MTLegacyEncodingStrict`。
///
/// 说明：ID3v1 无编码标识，ID3v2 的 Latin-1 帧同样常被中文软件塞入 GBK 字节。
/// 设为 GB18030 后，桥接层会安装自定义 StringHandler，把这些字节按对应编码解释。
/// UTF-8 / UTF-16 的规范路径不受影响。
/// `MTLegacyEncodingAutoDetect` 当前等价于 Strict，编码猜测算法后续接入。
@property (class, nonatomic, assign) MTLegacyEncoding legacyEncoding;

#pragma mark - 读

/// 读取一个音频文件的标签与技术参数。
/// @param path       绝对路径。
/// @param error      失败原因。
/// @return 失败返回 nil。**任何情况下都不会崩溃或抛异常。**
+ (nullable MTAudioFileInfo *)readFileAtPath:(NSString *)path
                                       error:(NSError * _Nullable * _Nullable)error;

/// 只读技术参数，跳过标签解析（批量扫描时更快）。
+ (nullable MTAudioProperties *)readAudioPropertiesAtPath:(NSString *)path
                                                    error:(NSError * _Nullable * _Nullable)error;

/// 只读封面（避免为了取图把整份标签解出来）。
+ (nullable NSArray<MTArtwork *> *)readArtworksAtPath:(NSString *)path
                                                error:(NSError * _Nullable * _Nullable)error;

#pragma mark - 写

/// 按 `edit` 描述写回标签。只有 edit 中出现过的字段会被改动，其余保持原样。
/// **绝不抛异常**：失败信息在返回的 `MTWriteResult.error` 中。
+ (MTWriteResult *)writeEdit:(MTTagEdit *)edit toFileAtPath:(NSString *)path;

/// 删除文件中的全部标签容器（ID3v1/ID3v2/APE/Xiph…）。
+ (BOOL)stripAllTagsAtPath:(NSString *)path error:(NSError * _Nullable * _Nullable)error;

#pragma mark - 写入代价预估（只读）

/// **只读**预估：这次保存会不会触发 TagLib 的「整文件重写」。
///
/// 背景：TagLib 保存标签时先渲染新的标签区，再调 `File::insert(data, offset, oldLength)`。
/// 新标签区**不超过**原标签区时是原地覆盖（只写那几 KB）；一旦超出，`insert()` 必须把
/// 标签区后面的**全部音频数据**整体后移 —— 耗时由「要搬动的字节数」决定，
/// 跟图片本身多大基本无关。
///
/// 本方法只解析文件头部的标签区结构（FLAC 元数据块表 / ID3v2 头与帧表 / MP4 atom 树），
/// **不打开 TagLib 的写入路径，一个字节都不修改**。
///
/// @param path             绝对路径。
/// @param payloadBytes     本次要新写进标签区的负载字节（封面原始字节 + 文本增量的粗估）。
/// @param reclaimsArtwork  YES = 本次会覆盖 / 删除文件里现有的封面（那部分空间可回收）。
/// @return 字典，键：
///   `fullRewrite`  (NSNumber BOOL)      是否会整文件重写
///   `confident`    (NSNumber BOOL)      该格式的判定是否可信（flac/mp3/mp4/m4a 为 YES）
///   `fileBytes`    (NSNumber longlong)  文件总字节
///   `slackBytes`   (NSNumber longlong)  标签区里可原地复用的空闲字节（PADDING / free / ID3v2 空隙 + 可回收的旧封面）
///   `needBytes`    (NSNumber longlong)  本次负载实际需要的字节（含容器包头开销）
///   `rewriteBytes` (NSNumber longlong)  会被物理搬动的字节（= 标签区之后的数据量；不重写时为 0）
///   `container`    (NSString)           判定用的容器名
///   `note`         (NSString)           判定依据的说明
+ (NSDictionary<NSString *, id> *)estimateWriteCostAtPath:(NSString *)path
                                            payloadBytes:(long long)payloadBytes
                                         reclaimsArtwork:(BOOL)reclaimsArtwork;

#pragma mark - 文件头填充（PADDING / ID3v2 padding）

/// **只读**：解析文件头部的元数据区，报告当前预留了多少填充。
///
/// 背景与 `estimateWriteCostAtPath:` 同一件事的另一面：TagLib 保存标签时，
/// 只要新标签区塞得进原标签区就原地覆盖（写几 KB，毫秒级）；塞不进就得把
/// **整段音频后移**（几十 MB，秒级，还多写一遍闪存）。填充越大，越多次保存
/// 能走原地那条路。
///
/// 支持 flac / mp3 / mp4 / m4a；其余格式返回 `supported = NO`。
/// **一个字节都不修改。**
///
/// @return 字典，键：
///   `supported`      (NSNumber BOOL)      该格式是否做了结构解析
///   `container`      (NSString)           容器名
///   `fileBytes`      (NSNumber longlong)  文件总字节
///   `currentPadding` (NSNumber longlong)  当前可原地复用的填充字节
///                                         （FLAC = PADDING 块数据长度合计；
///                                          MP3 = ID3v2 区尾部的零字节；
///                                          MP4 = ilst / moov 之后的 free atom）
///   `metadataBytes`  (NSNumber longlong)  整个元数据区的字节数（含填充）
///   `audioOffset`    (NSNumber longlong)  音频数据的起始偏移
///   `blocks`         (NSArray<NSDictionary *>)  FLAC 专有：逐块表
///                                         （`type` `name` `length` `isLast`）
///   `note`           (NSString)           说明
+ (NSDictionary<NSString *, id> *)inspectPaddingAtPath:(NSString *)path;

/// 把文件头部的填充**扩大**到 `targetBytes`。当前填充已经够大时原样不动。
///
/// 代价说明：扩填充必然要把音频整体后移一次，所以只应该在「TagLib 刚刚已经
/// 整文件重写过」的同一批操作里顺手做 —— 那时候文件反正刚被搬过一遍，
/// 多搬这一次换来的是之后每次换封面 / 改标签都能原地完成。
///
/// 上限提醒：TagLib 的 FLAC `MaxPaddingLength` 与 ID3v2 `MaxPaddingSize` 都是 1 MB，
/// 预留超过它，下一次保存反而会把填充**收缩**回去（又是一次整文件重写）。
/// 调用方应把 `targetBytes` 控制在 1 MB 以内（建议 ≤ 960 KB）。
///
/// 实现：写同目录临时文件 → `rename()` 原子替换。任何环节失败都会删掉临时文件，
/// 原文件保持不变，**绝不留半截文件**。
///
/// 当前支持 flac 与 mp3（ID3v2）。mp4 / m4a 只做 inspect：往 moov 前插 free atom
/// 会让 stco / co64 里的绝对块偏移全部失效，必须同步改写偏移表，风险不划算。
///
/// @return 失败返回 nil 并填 `error`；成功返回字典，键：
///   `changed`          (NSNumber BOOL)      是否真的改写了文件
///   `paddingBefore`    (NSNumber longlong)
///   `paddingAfter`     (NSNumber longlong)
///   `fileBytesBefore`  (NSNumber longlong)
///   `fileBytesAfter`   (NSNumber longlong)
///   `movedBytes`       (NSNumber longlong)  实际被搬动的音频字节
///   `note`             (NSString)
+ (nullable NSDictionary<NSString *, id> *)reservePaddingAtPath:(NSString *)path
                                                    targetBytes:(long long)targetBytes
                                                          error:(NSError * _Nullable * _Nullable)error;

#pragma mark - 能力探测

/// 对给定扩展名返回 TagLib 侧的静态能力判断（不碰真实文件）。
+ (MTFormatCapability *)capabilityForExtension:(NSString *)ext;

/// 对**真实文件**做一次读—写—复核的活体探测，用于生成能力矩阵。
/// 会在同目录创建临时副本进行写测试，测完删除，不改动原文件。
/// 返回一个描述性字典，键：
/// `canRead`(NSNumber BOOL) `canWrite` `canWriteArtwork` `container` `codec`
/// `duration` `note`。
+ (NSDictionary<NSString *, id> *)probeFileAtPath:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
