//
//  MTTagModels.h
//  MacTagger — TagLib bridging layer (public model types)
//
//  纯 Objective-C 头文件：不含任何 C++ 声明，可安全导入 Swift bridging header。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 错误域

/// 桥接层错误域。
FOUNDATION_EXPORT NSErrorDomain const MTTagLibErrorDomain;

typedef NS_ENUM(NSInteger, MTTagLibErrorCode) {
    /// 文件不存在 / 不可读。
    MTTagLibErrorFileNotFound        = 1,
    /// 文件存在但 TagLib 无法识别（格式不支持或文件头损坏）。
    MTTagLibErrorUnsupportedFormat   = 2,
    /// 文件被识别但内部结构损坏，读取中止。
    MTTagLibErrorCorruptedFile       = 3,
    /// 只读文件 / 无写权限。
    MTTagLibErrorNotWritable         = 4,
    /// TagLib save() 返回 false。
    MTTagLibErrorWriteFailed         = 5,
    /// 原生层抛出 C++ 异常（已被兜住，未崩溃）。
    MTTagLibErrorNativeException     = 6,
    /// 传入参数非法。
    MTTagLibErrorInvalidArgument     = 7,
    /// 该格式不支持所请求的能力（例如封面写入）。
    MTTagLibErrorCapabilityMissing   = 8,
    /// 单张封面超出该容器的硬上限（FLAC 的 METADATA_BLOCK 长度字段只有 24 bit）。
    /// 这一条**在动文件之前**就返回，原有封面保持原样。
    MTTagLibErrorArtworkTooLarge     = 9,
    /// 兜底：操作失败但没能给出更具体的原因。
    MTTagLibErrorUnknown             = 99,
};

/// `MTTagLibErrorArtworkTooLarge` 的 userInfo：容器名（NSString，如 @"FLAC"）。
FOUNDATION_EXPORT NSErrorUserInfoKey const MTArtworkLimitFormatKey;
/// `MTTagLibErrorArtworkTooLarge` 的 userInfo：该容器允许的**图片数据**上限字节数（NSNumber）。
FOUNDATION_EXPORT NSErrorUserInfoKey const MTArtworkLimitBytesKey;
/// `MTTagLibErrorArtworkTooLarge` 的 userInfo：这次要写的图片数据字节数（NSNumber）。
FOUNDATION_EXPORT NSErrorUserInfoKey const MTArtworkActualBytesKey;

#pragma mark - 封面

/// 封面图类型，取值对齐 ID3v2 APIC 帧的 picture type。
typedef NS_ENUM(NSInteger, MTPictureType) {
    MTPictureTypeOther               = 0,
    MTPictureTypeFileIcon            = 1,
    MTPictureTypeOtherFileIcon       = 2,
    MTPictureTypeFrontCover          = 3,
    MTPictureTypeBackCover           = 4,
    MTPictureTypeLeafletPage         = 5,
    MTPictureTypeMedia               = 6,
    MTPictureTypeLeadArtist          = 7,
    MTPictureTypeArtist              = 8,
    MTPictureTypeConductor           = 9,
    MTPictureTypeBand                = 10,
    MTPictureTypeComposer            = 11,
    MTPictureTypeLyricist            = 12,
    MTPictureTypeRecordingLocation   = 13,
    MTPictureTypeDuringRecording     = 14,
    MTPictureTypeDuringPerformance   = 15,
    MTPictureTypeMovieScreenCapture  = 16,
    MTPictureTypeColouredFish        = 17,
    MTPictureTypeIllustration        = 18,
    MTPictureTypeBandLogo            = 19,
    MTPictureTypePublisherLogo       = 20,
};

/// 一张内嵌封面图。
@interface MTArtwork : NSObject

/// 图片二进制数据（原样，未解码）。
@property (nonatomic, copy) NSData *data;
/// MIME 类型，例如 `image/jpeg`。可能为 nil（部分格式不存储）。
@property (nonatomic, copy, nullable) NSString *mimeType;
/// 图片描述文字。
@property (nonatomic, copy, nullable) NSString *artworkDescription;
/// 图片类型。
@property (nonatomic, assign) MTPictureType type;
/// 标签中记录的像素宽（仅 FLAC METADATA_BLOCK_PICTURE 等格式提供），未知为 0。
@property (nonatomic, assign) NSInteger declaredWidth;
/// 标签中记录的像素高，未知为 0。
@property (nonatomic, assign) NSInteger declaredHeight;
/// 标签中记录的色深，未知为 0。
@property (nonatomic, assign) NSInteger declaredColorDepth;

- (instancetype)initWithData:(NSData *)data
                    mimeType:(nullable NSString *)mimeType
                 description:(nullable NSString *)description
                        type:(MTPictureType)type NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// 依据数据头猜测 MIME（jpeg/png/gif/bmp/webp），失败返回 nil。
+ (nullable NSString *)sniffMIMETypeForData:(NSData *)data;

@end

#pragma mark - 技术参数

/// 音频技术参数（来自 TagLib AudioProperties）。
@interface MTAudioProperties : NSObject

/// 时长（毫秒）。未知为 0。
@property (nonatomic, assign) NSInteger durationMilliseconds;
/// 平均比特率（kbps）。未知为 0。
@property (nonatomic, assign) NSInteger bitrateKbps;
/// 采样率（Hz）。未知为 0。
@property (nonatomic, assign) NSInteger sampleRate;
/// 声道数。未知为 0。
@property (nonatomic, assign) NSInteger channels;
/// 位深（bit）。不适用/未知为 0。
@property (nonatomic, assign) NSInteger bitsPerSample;
/// 编码格式名，例如 `FLAC` / `MPEG Layer III` / `AAC`。
@property (nonatomic, copy) NSString *codecName;
/// 容器名，例如 `FLAC` / `MPEG` / `MP4` / `Ogg`。
@property (nonatomic, copy) NSString *containerName;
/// 是否无损。
@property (nonatomic, assign) BOOL isLossless;
/// 文件字节数。
@property (nonatomic, assign) long long fileSizeBytes;

@end

#pragma mark - 标签

/// 从文件读到的完整标签快照。所有字段均可为 nil，表示该字段不存在。
@interface MTTags : NSObject

@property (nonatomic, copy, nullable) NSString *title;
@property (nonatomic, copy, nullable) NSString *artist;
@property (nonatomic, copy, nullable) NSString *albumArtist;
@property (nonatomic, copy, nullable) NSString *album;
/// 年份原文（可能是 `2023` 或完整日期 `2023-05-01`）。
@property (nonatomic, copy, nullable) NSString *year;
/// 音轨号，nil 表示未设置。
@property (nonatomic, strong, nullable) NSNumber *trackNumber;
/// 音轨总数，nil 表示未设置。
@property (nonatomic, strong, nullable) NSNumber *trackTotal;
/// 碟号。
@property (nonatomic, strong, nullable) NSNumber *discNumber;
/// 碟总数。
@property (nonatomic, strong, nullable) NSNumber *discTotal;
@property (nonatomic, copy, nullable) NSString *genre;
@property (nonatomic, copy, nullable) NSString *comment;
@property (nonatomic, copy, nullable) NSString *composer;
/// 作词者（PropertyMap 键 LYRICIST）。
@property (nonatomic, copy, nullable) NSString *lyricist;
/// 非同步歌词全文（ID3v2 USLT / Vorbis LYRICS 等）。
@property (nonatomic, copy, nullable) NSString *lyrics;

/// 全部封面图。
@property (nonatomic, copy) NSArray<MTArtwork *> *artworks;

/// TagLib PropertyMap 全量原始键值（大写键 → 值数组），用于展示未映射字段。
@property (nonatomic, copy) NSDictionary<NSString *, NSArray<NSString *> *> *rawProperties;

/// 该格式无法用 PropertyMap 表达、被 TagLib 判定为 unsupported 的键。
@property (nonatomic, copy) NSArray<NSString *> *unsupportedProperties;

@end

#pragma mark - 文件信息

/// 一个音频文件的完整读取结果。
@interface MTAudioFileInfo : NSObject

@property (nonatomic, copy) NSString *path;
@property (nonatomic, strong) MTTags *tags;
@property (nonatomic, strong) MTAudioProperties *audioProperties;
/// 文件内实际存在的标签容器，例如 `["ID3v2.4", "ID3v1", "APEv2"]`。
@property (nonatomic, copy) NSArray<NSString *> *tagContainers;
/// TagLib 以只读方式打开（文件本身不可写）。
@property (nonatomic, assign) BOOL isReadOnly;
/// 读取过程中 TagLib 输出的诊断信息（畸形文件排查用）。
@property (nonatomic, copy) NSArray<NSString *> *diagnostics;

@end

#pragma mark - 写入编辑集

/// 标签字段标识。取值就是 TagLib PropertyMap 的标准键（大写）。
/// 故意用裸 NSString 而非 NS_STRING_ENUM，避免 Swift 导入时产生歧义类型。
FOUNDATION_EXPORT NSString * const MTTagFieldTitle;        // TITLE
FOUNDATION_EXPORT NSString * const MTTagFieldArtist;       // ARTIST
FOUNDATION_EXPORT NSString * const MTTagFieldAlbumArtist;  // ALBUMARTIST
FOUNDATION_EXPORT NSString * const MTTagFieldAlbum;        // ALBUM
FOUNDATION_EXPORT NSString * const MTTagFieldYear;         // DATE
FOUNDATION_EXPORT NSString * const MTTagFieldTrack;        // TRACKNUMBER (可为 "3/12")
FOUNDATION_EXPORT NSString * const MTTagFieldDisc;         // DISCNUMBER  (可为 "1/2")
FOUNDATION_EXPORT NSString * const MTTagFieldGenre;        // GENRE
FOUNDATION_EXPORT NSString * const MTTagFieldComment;      // COMMENT
FOUNDATION_EXPORT NSString * const MTTagFieldComposer;     // COMPOSER
FOUNDATION_EXPORT NSString * const MTTagFieldLyricist;     // LYRICIST
FOUNDATION_EXPORT NSString * const MTTagFieldLyrics;       // LYRICS

/// 封面写入策略。
typedef NS_ENUM(NSInteger, MTArtworkWriteMode) {
    /// 不动封面。
    MTArtworkWriteModeKeep    = 0,
    /// 用 `artworks` 整体替换。
    MTArtworkWriteModeReplace = 1,
    /// 删除全部封面。
    MTArtworkWriteModeRemoveAll = 2,
};

/// 一次写入操作的描述。只有被显式 set 过的字段才会写回，实现「只写部分字段」。
@interface MTTagEdit : NSObject

/// 设置字段值。传 nil 表示「删除该字段」。
- (void)setValue:(nullable NSString *)value forField:(NSString *)field;
/// 该字段本次是否参与写入。
- (BOOL)hasField:(NSString *)field;
/// 取回本次要写的值（可能是 NSNull 表示删除）。
- (nullable id)valueForField:(NSString *)field;
/// 已排定的全部字段，按 set 顺序。
@property (nonatomic, readonly, copy) NSArray<NSString *> *touchedFields;

/// 写入非标准键（直接落到 PropertyMap）。键需大写。
- (void)setRawValues:(nullable NSArray<NSString *> *)values forKey:(NSString *)key;

/// 封面写入策略，默认 Keep。
@property (nonatomic, assign) MTArtworkWriteMode artworkMode;
/// 当 artworkMode == Replace 时使用。
@property (nonatomic, copy) NSArray<MTArtwork *> *artworks;

/// 写入时是否顺带同步 ID3v1（MP3 等格式）。默认 YES。
@property (nonatomic, assign) BOOL syncID3v1;

/// 是否为空操作。
@property (nonatomic, readonly) BOOL isEmpty;

@end

#pragma mark - 写入结果

/// 一次写入的结果。
/// 不用 `BOOL + NSError**`，是为了让「写成功但部分字段被格式拒绝」这种
/// 半成功状态能干净地传到 Swift（Swift 会把 BOOL+NSError** 自动转成 throws，
/// 成功路径上的 error 会被丢弃）。
@interface MTWriteResult : NSObject

@property (nonatomic, assign) BOOL success;
/// 失败原因；success == YES 时为 nil。
@property (nonatomic, strong, nullable) NSError *error;
/// 写入成功、但该格式不支持因而没落盘的键。
@property (nonatomic, copy) NSArray<NSString *> *rejectedKeys;
/// TagLib 在本次写入中输出的告警。
@property (nonatomic, copy) NSArray<NSString *> *diagnostics;

/// success && rejectedKeys.count == 0
@property (nonatomic, readonly) BOOL isComplete;

@end

#pragma mark - 格式能力

/// 单一格式在当前 TagLib 版本下的能力描述。
@interface MTFormatCapability : NSObject
/// 扩展名（小写，不含点）。
@property (nonatomic, copy) NSString *fileExtension;
/// TagLib 是否声明支持该扩展名。
@property (nonatomic, assign) BOOL recognizedByTagLib;
/// 该格式使用的标签容器名。
@property (nonatomic, copy) NSString *tagContainer;
@end

#pragma mark - 文本编码策略

/// 老旧中文文件（ID3v1 / ID3v2 Latin-1 帧）的兼容读取策略。
typedef NS_ENUM(NSInteger, MTLegacyEncoding) {
    /// 严格按规范：ID3v1 当 Latin-1，ID3v2 按帧内编码字节。
    MTLegacyEncodingStrict = 0,
    /// 把 Latin-1 字节流按 GB18030（兼容 GBK/GB2312）重新解释。
    MTLegacyEncodingGB18030 = 1,
    /// 按 Big5 重新解释。
    MTLegacyEncodingBig5 = 2,
    /// 按 Shift-JIS 重新解释。
    MTLegacyEncodingShiftJIS = 3,
    /// 按 UTF-8 重新解释（有些写标签软件把 UTF-8 直接塞进 Latin-1 帧）。
    MTLegacyEncodingUTF8 = 4,
    /// 预留：自动猜测。当前实现回退为 Strict，待编码猜测算法接入。
    MTLegacyEncodingAutoDetect = 100,
};

NS_ASSUME_NONNULL_END
