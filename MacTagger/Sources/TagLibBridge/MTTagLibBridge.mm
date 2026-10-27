//
//  MTTagLibBridge.mm
//  MacTagger — TagLib bridging layer (implementation)
//
//  编译要求：Objective-C++ (-x objective-c++)，C++17，链接 -ltag -lz。
//

#import "MTTagLibBridge.h"

#include <string>
#include <vector>
#include <memory>
#include <map>
#include <mutex>
#include <exception>
#include <cstring>
#include <cstdio>
#include <cmath>
#include <algorithm>
#include <sys/stat.h>
#include <unistd.h>
#include <cerrno>

#include <taglib/taglib.h>
#include <taglib/tstring.h>
#include <taglib/tstringlist.h>
#include <taglib/tbytevector.h>
#include <taglib/tvariant.h>
#include <taglib/tpropertymap.h>
#include <taglib/tdebuglistener.h>
#include <taglib/fileref.h>
#include <taglib/tfile.h>
#include <taglib/tag.h>
#include <taglib/audioproperties.h>

#include <taglib/id3v1tag.h>
#include <taglib/id3v2tag.h>

#include <taglib/mpegfile.h>
#include <taglib/mpegheader.h>
#include <taglib/mpegproperties.h>
#include <taglib/flacfile.h>
#include <taglib/flacproperties.h>
#include <taglib/oggflacfile.h>
#include <taglib/vorbisfile.h>
#include <taglib/vorbisproperties.h>
#include <taglib/opusfile.h>
#include <taglib/opusproperties.h>
#include <taglib/speexfile.h>
#include <taglib/mp4file.h>
#include <taglib/mp4properties.h>
#include <taglib/asffile.h>
#include <taglib/asfproperties.h>
#include <taglib/apefile.h>
#include <taglib/apeproperties.h>
#include <taglib/mpcfile.h>
#include <taglib/mpcproperties.h>
#include <taglib/wavpackfile.h>
#include <taglib/wavpackproperties.h>
#include <taglib/trueaudiofile.h>
#include <taglib/trueaudioproperties.h>
#include <taglib/wavfile.h>
#include <taglib/wavproperties.h>
#include <taglib/aifffile.h>
#include <taglib/aiffproperties.h>
#include <taglib/dsffile.h>
#include <taglib/dsfproperties.h>
#include <taglib/dsdifffile.h>
#include <taglib/dsdiffproperties.h>

using namespace TagLib;

/// MTTagEdit 的内部访问接口（实现在 MTTagModels.mm，未公开到头文件）。
@interface MTTagEdit (MTInternal)
- (NSDictionary<NSString *, id> *)mt_rawFields;
@end

#pragma mark - 内部工具

namespace {

// ---------------------------------------------------------------- 字符串转换

inline NSString *ns(const String &s)
{
    if (s.isEmpty()) { return @""; }
    const std::string u8 = s.to8Bit(true);
    NSString *out = [[NSString alloc] initWithBytes:u8.data()
                                             length:u8.size()
                                           encoding:NSUTF8StringEncoding];
    return out ?: @"";
}

/// nil-安全：空串返回 nil，方便区分「字段不存在」。
inline NSString *nsOrNil(const String &s)
{
    NSString *v = ns(s);
    return v.length > 0 ? v : nil;
}

inline String tl(NSString *s)
{
    if (s.length == 0) { return String(); }
    const char *utf8 = s.UTF8String;
    return String(utf8 ? utf8 : "", String::UTF8);
}

inline NSData *nsdata(const ByteVector &bv)
{
    if (bv.isEmpty()) { return [NSData data]; }
    return [NSData dataWithBytes:bv.data() length:bv.size()];
}

inline ByteVector bytevector(NSData *d)
{
    if (d.length == 0) { return ByteVector(); }
    return ByteVector(static_cast<const char *>(d.bytes), static_cast<unsigned int>(d.length));
}

// ---------------------------------------------------------------- 诊断收集
//
// TagLib 默认把畸形文件的告警打到 stderr。这里改成收进线程局部数组，
// 既不污染控制台，又能把「文件哪里坏了」回传给上层。

thread_local std::vector<std::string> *tls_diagSink = nullptr;

class MTDebugListener : public DebugListener {
public:
    void printMessage(const String &msg) override
    {
        if (tls_diagSink) {
            try { tls_diagSink->push_back(msg.to8Bit(true)); } catch (...) {}
        }
    }
};

struct DiagScope {
    std::vector<std::string> messages;
    std::vector<std::string> *previous;

    DiagScope() : previous(tls_diagSink) { tls_diagSink = &messages; }
    ~DiagScope() { tls_diagSink = previous; }

    NSArray<NSString *> *toArray() const
    {
        NSMutableArray<NSString *> *a = [NSMutableArray arrayWithCapacity:messages.size()];
        for (const auto &m : messages) {
            NSString *s = [[NSString alloc] initWithBytes:m.data()
                                                   length:m.size()
                                                 encoding:NSUTF8StringEncoding];
            if (s.length) {
                // TagLib 的消息常带换行
                s = [s stringByTrimmingCharactersInSet:
                     [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (s.length) { [a addObject:s]; }
            }
        }
        return [a copy];
    }
};

void installDebugListenerOnce()
{
    static std::once_flag once;
    std::call_once(once, []{
        static MTDebugListener listener;
        setDebugListener(&listener);
    });
}

// ---------------------------------------------------------------- 遗留编码

NSStringEncoding cocoaEncodingFor(MTLegacyEncoding e)
{
    switch (e) {
        case MTLegacyEncodingGB18030:
            return CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGB_18030_2000);
        case MTLegacyEncodingBig5:
            return CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingBig5_HKSCS_1999);
        case MTLegacyEncodingShiftJIS:
            return CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingShiftJIS);
        case MTLegacyEncodingUTF8:
            return NSUTF8StringEncoding;
        case MTLegacyEncodingStrict:
        case MTLegacyEncodingAutoDetect:
        default:
            return NSISOLatin1StringEncoding;
    }
}

/// 把「本应是 Latin-1」的原始字节按 legacy 编码重新解释。失败回退 Latin-1。
String reinterpretBytes(const ByteVector &data, MTLegacyEncoding enc)
{
    if (data.isEmpty()) { return String(); }

    // 去掉尾部填充 0
    unsigned int len = data.size();
    while (len > 0 && data[static_cast<int>(len) - 1] == '\0') { --len; }
    if (len == 0) { return String(); }

    @autoreleasepool {
        NSData *raw = [NSData dataWithBytes:data.data() length:len];
        NSStringEncoding cocoa = cocoaEncodingFor(enc);
        NSString *decoded = [[NSString alloc] initWithData:raw encoding:cocoa];
        if (!decoded) {
            decoded = [[NSString alloc] initWithData:raw encoding:NSISOLatin1StringEncoding];
        }
        if (!decoded) { return String(); }
        const char *utf8 = decoded.UTF8String;
        return String(utf8 ? utf8 : "", String::UTF8);
    }
}

std::mutex &encodingMutex()
{
    static std::mutex m;
    return m;
}

MTLegacyEncoding g_legacyEncoding = MTLegacyEncodingStrict;

class MTLegacyID3v1Handler : public ID3v1::StringHandler {
public:
    explicit MTLegacyID3v1Handler(MTLegacyEncoding e) : encoding(e) {}

    String parse(const ByteVector &data) const override
    {
        return reinterpretBytes(data, encoding);
    }

    ByteVector render(const String &s) const override
    {
        if (s.isEmpty()) { return ByteVector(); }
        @autoreleasepool {
            NSString *str = ns(s);
            NSStringEncoding cocoa = cocoaEncodingFor(encoding);
            // ID3v1 字段最长 30 字节；在字符边界处截断，避免半个汉字。
            uint8_t buf[64] = {0};
            NSUInteger used = 0;
            [str getBytes:buf
                maxLength:30
               usedLength:&used
                 encoding:cocoa
                  options:0
                    range:NSMakeRange(0, str.length)
           remainingRange:NULL];
            if (used == 0) { return ID3v1::StringHandler::render(s); }
            return ByteVector(reinterpret_cast<const char *>(buf),
                              static_cast<unsigned int>(used));
        }
    }

private:
    MTLegacyEncoding encoding;
};

class MTLegacyLatin1Handler : public ID3v2::Latin1StringHandler {
public:
    explicit MTLegacyLatin1Handler(MTLegacyEncoding e) : encoding(e) {}

    String parse(const ByteVector &data) const override
    {
        return reinterpretBytes(data, encoding);
    }

private:
    MTLegacyEncoding encoding;
};

/// 安装/卸载与 `enc` 对应的全局 StringHandler。handler 实例常驻，不释放。
void applyLegacyEncoding(MTLegacyEncoding enc)
{
    std::lock_guard<std::mutex> guard(encodingMutex());
    if (g_legacyEncoding == enc) { return; }
    g_legacyEncoding = enc;

    static std::map<int, std::unique_ptr<MTLegacyID3v1Handler>> v1Handlers;
    static std::map<int, std::unique_ptr<MTLegacyLatin1Handler>> v2Handlers;

    if (enc == MTLegacyEncodingStrict || enc == MTLegacyEncodingAutoDetect) {
        // AutoDetect 尚未实现启发式，先退回规范行为。
        ID3v1::Tag::setStringHandler(nullptr);
        ID3v2::Tag::setLatin1StringHandler(nullptr);
        return;
    }

    const int key = static_cast<int>(enc);
    if (v1Handlers.find(key) == v1Handlers.end()) {
        v1Handlers[key] = std::make_unique<MTLegacyID3v1Handler>(enc);
        v2Handlers[key] = std::make_unique<MTLegacyLatin1Handler>(enc);
    }
    ID3v1::Tag::setStringHandler(v1Handlers[key].get());
    ID3v2::Tag::setLatin1StringHandler(v2Handlers[key].get());
}

// ---------------------------------------------------------------- 错误构造

NSError *mkError(MTTagLibErrorCode code, NSString *path, NSString *reason)
{
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[NSLocalizedDescriptionKey] = reason ?: @"未知错误";
    if (path.length) { info[NSFilePathErrorKey] = path; }
    return [NSError errorWithDomain:MTTagLibErrorDomain code:code userInfo:info];
}

inline void assignError(NSError **out, NSError *err)
{
    if (out) { *out = err; }
}

// ---------------------------------------------------------------- 封面体积上限
//
// 容器对「单张封面」能装下多少字节各有各的硬上限，超了不会报错，只会被静默丢弃。
// FLAC 尤其致命：METADATA_BLOCK 的长度字段只有 24 bit，TagLib 渲染时发现块太大就
// 整块跳过，save() 照样返回 true —— 于是「新图没写进去、旧图也一并没了」，
// 上层还以为成功。所以写之前先把编码后的块体积量出来，超限就在**动文件之前**
// 整笔拒写。

/// FLAC METADATA_BLOCK 长度字段 = 24 bit。
constexpr unsigned long long kFLACBlockMaxPayload  = 0xFFFFFFULL;     // 16,777,215
/// ID3v2.4 帧长度 = syncsafe 28 bit。（2.3 是裸 32 bit，按更严的 2.4 卡。）
constexpr unsigned long long kID3v2FrameMaxPayload = 0x0FFFFFFFULL;   // 268,435,455

struct ArtworkCapacity {
    unsigned long long limit;      ///< 单张封面「块体积」上限；0 = 没有会踩到的硬上限。
    NSString *container;           ///< 报错文案里用的容器名。
};

/// 该文件的封面落到哪种容器里、那种容器的硬上限是多少。
///
/// `Ogg::FLAC::File` 与 `FLAC::File` 是两个互不继承的类，dynamic_cast 不会误命中；
/// Ogg 侧封面走 Xiph 注释的 METADATA_BLOCK_PICTURE（字段长度 32 bit），不受 24 bit 约束。
/// MP4 / APE / ASF 的长度字段都是 32 bit，实际用不到上限，一律返回 0（不设限）。
ArtworkCapacity artworkCapacityFor(File *f)
{
    if (dynamic_cast<FLAC::File *>(f))       { return { kFLACBlockMaxPayload,  @"FLAC" }; }
    if (dynamic_cast<MPEG::File *>(f))       { return { kID3v2FrameMaxPayload, @"MP3" };  }
    if (dynamic_cast<RIFF::WAV::File *>(f))  { return { kID3v2FrameMaxPayload, @"WAV" };  }
    if (dynamic_cast<RIFF::AIFF::File *>(f)) { return { kID3v2FrameMaxPayload, @"AIFF" }; }
    if (dynamic_cast<DSF::File *>(f))        { return { kID3v2FrameMaxPayload, @"DSF" };  }
    if (dynamic_cast<DSDIFF::File *>(f))     { return { kID3v2FrameMaxPayload, @"DFF" };  }
    return { 0, @"" };
}

/// 除图片数据本身之外，一张封面在该容器里还要占掉多少字节。
///
/// FLAC PICTURE 块体：类型(4) + MIME 长度(4) + MIME + 描述长度(4) + 描述
///                    + 宽/高/色深/颜色数(16) + 数据长度(4) = 32 + MIME + 描述。
/// ID3v2 APIC 帧体：编码(1) + MIME + 终止符(1) + 图片类型(1) + 描述 + 终止符(≤2)。
unsigned long long artworkOverheadBytes(File *f, NSString *mime, NSString *desc)
{
    const unsigned long long mimeLen =
        (unsigned long long)[(mime ?: @"") lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    const unsigned long long descLen =
        (unsigned long long)[(desc ?: @"") lengthOfBytesUsingEncoding:NSUTF8StringEncoding];

    if (dynamic_cast<FLAC::File *>(f)) { return 32ULL + mimeLen + descLen; }
    return 5ULL + mimeLen + descLen;
}

/// 把字节数说成人话。刚好落在整 MiB 附近就不带小数（16 MB 比 16.0 MB 好读）。
NSString *humanMB(unsigned long long bytes)
{
    const double mb = (double)bytes / (1024.0 * 1024.0);
    if (fabs(mb - round(mb)) < 0.05) {
        return [NSString stringWithFormat:@"%.0f MB", round(mb)];
    }
    return [NSString stringWithFormat:@"%.1f MB", mb];
}

/// 造一条「封面太大」错误。`allowance` 是**纯图片数据**能占的上限（已扣掉块头开销），
/// 上层拿它当自动压缩的目标值。
NSError *mkArtworkTooLargeError(NSString *path, NSString *container,
                                unsigned long long allowance, unsigned long long actual)
{
    // 只超出几十字节时两边会印成同一个数（「不能超过 16 MB，当前 16 MB」，看着像 bug）。
    // 这种紧贴上限的情况改印字节数。
    NSString *limitText = humanMB(allowance);
    NSString *actualText = humanMB(actual);
    if ([limitText isEqualToString:actualText]) {
        limitText  = [NSString stringWithFormat:@"%llu 字节", allowance];
        actualText = [NSString stringWithFormat:@"%llu 字节", actual];
    }
    NSString *reason =
        [NSString stringWithFormat:@"%@ 单张封面不能超过 %@（当前 %@），请先在『调整分辨率 / 压缩』里缩小",
         container, limitText, actualText];
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[NSLocalizedDescriptionKey] = reason;
    if (path.length) { info[NSFilePathErrorKey] = path; }
    info[MTArtworkLimitFormatKey] = container ?: @"";
    info[MTArtworkLimitBytesKey]  = @((long long)allowance);
    info[MTArtworkActualBytesKey] = @((long long)actual);
    return [NSError errorWithDomain:MTTagLibErrorDomain
                               code:MTTagLibErrorArtworkTooLarge
                           userInfo:info];
}

// ---------------------------------------------------------------- 封面类型

struct PictureTypeEntry { MTPictureType type; const char *canonical; };

const PictureTypeEntry kPictureTypes[] = {
    { MTPictureTypeOther,              "Other" },
    { MTPictureTypeFileIcon,           "File Icon" },
    { MTPictureTypeOtherFileIcon,      "Other File Icon" },
    { MTPictureTypeFrontCover,         "Front Cover" },
    { MTPictureTypeBackCover,          "Back Cover" },
    { MTPictureTypeLeafletPage,        "Leaflet Page" },
    { MTPictureTypeMedia,              "Media" },
    { MTPictureTypeLeadArtist,         "Lead Artist" },
    { MTPictureTypeArtist,             "Artist" },
    { MTPictureTypeConductor,          "Conductor" },
    { MTPictureTypeBand,               "Band" },
    { MTPictureTypeComposer,           "Composer" },
    { MTPictureTypeLyricist,           "Lyricist" },
    { MTPictureTypeRecordingLocation,  "Recording Location" },
    { MTPictureTypeDuringRecording,    "During Recording" },
    { MTPictureTypeDuringPerformance,  "During Performance" },
    { MTPictureTypeMovieScreenCapture, "Movie Screen Capture" },
    { MTPictureTypeColouredFish,       "Coloured Fish" },
    { MTPictureTypeIllustration,       "Illustration" },
    { MTPictureTypeBandLogo,           "Band Logo" },
    { MTPictureTypePublisherLogo,      "Publisher Logo" },
};

NSString *normalizeKey(NSString *s)
{
    NSString *lower = s.lowercaseString;
    return [[lower componentsSeparatedByCharactersInSet:
             [NSCharacterSet characterSetWithCharactersInString:@" _-"]]
            componentsJoinedByString:@""];
}

MTPictureType pictureTypeFromName(NSString *name)
{
    if (name.length == 0) { return MTPictureTypeFrontCover; }
    NSString *want = normalizeKey(name);
    if ([want isEqualToString:@"coloredfish"]) { want = @"colouredfish"; }
    for (const auto &e : kPictureTypes) {
        if ([normalizeKey(@(e.canonical)) isEqualToString:want]) { return e.type; }
    }
    // 有些实现直接存数字
    NSScanner *sc = [NSScanner scannerWithString:name];
    NSInteger n = 0;
    if ([sc scanInteger:&n] && n >= 0 && n <= 20) { return (MTPictureType)n; }
    return MTPictureTypeOther;
}

NSString *pictureTypeName(MTPictureType t)
{
    for (const auto &e : kPictureTypes) {
        if (e.type == t) { return @(e.canonical); }
    }
    return @"Other";
}

// ---------------------------------------------------------------- 格式识别

struct FormatDescriptor {
    NSString *container;
    NSString *codec;
    BOOL lossless;
    NSInteger bitsPerSample;
};

FormatDescriptor describeFile(File *f, AudioProperties *ap)
{
    FormatDescriptor d = { @"未知", @"未知", NO, 0 };
    if (!f) { return d; }

    if (auto *mpeg = dynamic_cast<MPEG::File *>(f)) {
        (void)mpeg;
        // 注意：TagLib 2.x 把裸 ADTS 的 .aac 也交给 MPEG::File 处理
        // （ADTS 帧头与 MPEG 帧头同族），标签走「ID3v2 前置于 ADTS」这一
        // 业界通行约定。所以这里必须先判 ADTS，否则会把 AAC 误标成 Layer III。
        d.container = @"MPEG";
        d.codec = @"MPEG Layer III";
        d.lossless = NO;
        if (auto *p = dynamic_cast<MPEG::Properties *>(ap)) {
            if (p->isADTS()) {
                d.container = @"ADTS";
                d.codec = @"AAC";
            } else {
                const int layer = p->layer();
                const char *ver = "1";
                switch (p->version()) {
                    case MPEG::Header::Version1:   ver = "1";   break;
                    case MPEG::Header::Version2:   ver = "2";   break;
                    case MPEG::Header::Version2_5: ver = "2.5"; break;
                    default: break;
                }
                d.codec = [NSString stringWithFormat:@"MPEG-%s Layer %s", ver,
                           layer == 1 ? "I" : layer == 2 ? "II" : "III"];
            }
        }
    }
    else if (dynamic_cast<Ogg::FLAC::File *>(f)) {
        d.container = @"Ogg";  d.codec = @"FLAC";  d.lossless = YES;
    }
    else if (dynamic_cast<FLAC::File *>(f)) {
        d.container = @"FLAC"; d.codec = @"FLAC";  d.lossless = YES;
        if (auto *p = dynamic_cast<FLAC::Properties *>(ap)) { d.bitsPerSample = p->bitsPerSample(); }
    }
    else if (dynamic_cast<Ogg::Vorbis::File *>(f)) {
        d.container = @"Ogg";  d.codec = @"Vorbis"; d.lossless = NO;
    }
    else if (dynamic_cast<Ogg::Opus::File *>(f)) {
        d.container = @"Ogg";  d.codec = @"Opus";   d.lossless = NO;
    }
    else if (dynamic_cast<Ogg::Speex::File *>(f)) {
        d.container = @"Ogg";  d.codec = @"Speex";  d.lossless = NO;
    }
    else if (dynamic_cast<MP4::File *>(f)) {
        d.container = @"MP4";
        d.codec = @"AAC";
        if (auto *p = dynamic_cast<MP4::Properties *>(ap)) {
            d.bitsPerSample = p->bitsPerSample();
            switch (p->codec()) {
                case MP4::Properties::AAC:  d.codec = @"AAC";  d.lossless = NO;  break;
                case MP4::Properties::ALAC: d.codec = @"ALAC"; d.lossless = YES; break;
                default:                    d.codec = @"未知(MP4)"; break;
            }
        }
    }
    else if (dynamic_cast<ASF::File *>(f)) {
        d.container = @"ASF";
        d.codec = @"WMA";
        if (auto *p = dynamic_cast<ASF::Properties *>(ap)) {
            d.bitsPerSample = p->bitsPerSample();
            NSString *cn = ns(p->codecName());
            if (cn.length) { d.codec = cn; }
            d.lossless = (p->codec() == ASF::Properties::WMA9Lossless);
        }
    }
    else if (dynamic_cast<APE::File *>(f)) {
        d.container = @"APE"; d.codec = @"Monkey's Audio"; d.lossless = YES;
        if (auto *p = dynamic_cast<APE::Properties *>(ap)) { d.bitsPerSample = p->bitsPerSample(); }
    }
    else if (dynamic_cast<MPC::File *>(f)) {
        d.container = @"Musepack"; d.codec = @"Musepack"; d.lossless = NO;
    }
    else if (dynamic_cast<WavPack::File *>(f)) {
        d.container = @"WavPack"; d.codec = @"WavPack";
        if (auto *p = dynamic_cast<WavPack::Properties *>(ap)) {
            d.bitsPerSample = p->bitsPerSample();
            d.lossless = p->isLossless();
        }
    }
    else if (dynamic_cast<TrueAudio::File *>(f)) {
        d.container = @"TTA"; d.codec = @"True Audio"; d.lossless = YES;
        if (auto *p = dynamic_cast<TrueAudio::Properties *>(ap)) { d.bitsPerSample = p->bitsPerSample(); }
    }
    else if (dynamic_cast<RIFF::WAV::File *>(f)) {
        d.container = @"RIFF/WAVE"; d.codec = @"PCM"; d.lossless = YES;
        if (auto *p = dynamic_cast<RIFF::WAV::Properties *>(ap)) { d.bitsPerSample = p->bitsPerSample(); }
    }
    else if (dynamic_cast<RIFF::AIFF::File *>(f)) {
        d.container = @"AIFF"; d.codec = @"PCM"; d.lossless = YES;
        if (auto *p = dynamic_cast<RIFF::AIFF::Properties *>(ap)) { d.bitsPerSample = p->bitsPerSample(); }
    }
    else if (dynamic_cast<DSF::File *>(f)) {
        d.container = @"DSF"; d.codec = @"DSD"; d.lossless = YES;
        if (auto *p = dynamic_cast<DSF::Properties *>(ap)) { d.bitsPerSample = p->bitsPerSample(); }
    }
    else if (dynamic_cast<DSDIFF::File *>(f)) {
        d.container = @"DSDIFF"; d.codec = @"DSD"; d.lossless = YES;
        if (auto *p = dynamic_cast<DSDIFF::Properties *>(ap)) { d.bitsPerSample = p->bitsPerSample(); }
    }
    return d;
}

NSArray<NSString *> *detectTagContainers(File *f)
{
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    if (!f) { return out; }

    auto addID3v2 = [&](ID3v2::Tag *t, NSString *fallback) {
        if (!t) { return; }
        NSString *label = fallback;
        if (t->header()) {
            label = [NSString stringWithFormat:@"ID3v2.%u", t->header()->majorVersion()];
        }
        [out addObject:label];
    };

    if (auto *mpeg = dynamic_cast<MPEG::File *>(f)) {
        if (mpeg->hasID3v2Tag()) { addID3v2(mpeg->ID3v2Tag(false), @"ID3v2"); }
        if (mpeg->hasAPETag())   { [out addObject:@"APEv2"]; }
        if (mpeg->hasID3v1Tag()) { [out addObject:@"ID3v1"]; }
    }
    else if (auto *flac = dynamic_cast<FLAC::File *>(f)) {
        if (flac->hasXiphComment()) { [out addObject:@"Xiph Comment"]; }
        if (flac->hasID3v2Tag())    { addID3v2(flac->ID3v2Tag(), @"ID3v2"); }
        if (flac->hasID3v1Tag())    { [out addObject:@"ID3v1"]; }
        if (!flac->pictureList().isEmpty()) { [out addObject:@"FLAC PICTURE block"]; }
    }
    else if (dynamic_cast<Ogg::File *>(f)) {
        [out addObject:@"Xiph Comment"];
    }
    else if (dynamic_cast<MP4::File *>(f)) {
        [out addObject:@"MP4 (iTunes) atoms"];
    }
    else if (dynamic_cast<ASF::File *>(f)) {
        [out addObject:@"ASF Content Description"];
    }
    else if (auto *ape = dynamic_cast<APE::File *>(f)) {
        if (ape->hasAPETag())   { [out addObject:@"APEv2"]; }
        if (ape->hasID3v1Tag()) { [out addObject:@"ID3v1"]; }
    }
    else if (auto *mpc = dynamic_cast<MPC::File *>(f)) {
        if (mpc->hasAPETag())   { [out addObject:@"APEv2"]; }
        if (mpc->hasID3v1Tag()) { [out addObject:@"ID3v1"]; }
    }
    else if (auto *wv = dynamic_cast<WavPack::File *>(f)) {
        if (wv->hasAPETag())   { [out addObject:@"APEv2"]; }
        if (wv->hasID3v1Tag()) { [out addObject:@"ID3v1"]; }
    }
    else if (auto *tta = dynamic_cast<TrueAudio::File *>(f)) {
        if (tta->hasID3v2Tag()) { addID3v2(tta->ID3v2Tag(), @"ID3v2"); }
        if (tta->hasID3v1Tag()) { [out addObject:@"ID3v1"]; }
    }
    else if (auto *wav = dynamic_cast<RIFF::WAV::File *>(f)) {
        if (wav->hasID3v2Tag()) { addID3v2(wav->ID3v2Tag(), @"ID3v2"); }
        if (wav->hasInfoTag())  { [out addObject:@"RIFF INFO"]; }
    }
    else if (auto *aiff = dynamic_cast<RIFF::AIFF::File *>(f)) {
        if (aiff->hasID3v2Tag()) { [out addObject:@"ID3v2"]; }
    }
    else if (auto *dsf = dynamic_cast<DSF::File *>(f)) {
        if (dsf->tag() && !dsf->tag()->isEmpty()) { [out addObject:@"ID3v2"]; }
    }
    else if (auto *dff = dynamic_cast<DSDIFF::File *>(f)) {
        if (dff->hasID3v2Tag()) { [out addObject:@"ID3v2"]; }
        if (dff->hasDIINTag())  { [out addObject:@"DIIN"]; }
    }
    return out;
}

// ---------------------------------------------------------------- 属性映射

NSString *joinValues(const StringList &list)
{
    if (list.isEmpty()) { return nil; }
    if (list.size() == 1) { return nsOrNil(list.front()); }
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (const auto &v : list) {
        NSString *s = ns(v);
        if (s.length) { [parts addObject:s]; }
    }
    if (parts.count == 0) { return nil; }
    return [parts componentsJoinedByString:@"; "];
}

/// 解析 "3/12" 形式，返回 {number, total}，缺失为 nil。
void parseNumberPair(NSString *raw, NSNumber **number, NSNumber **total)
{
    *number = nil;
    *total = nil;
    if (raw.length == 0) { return; }
    NSArray<NSString *> *parts = [raw componentsSeparatedByString:@"/"];
    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    if (parts.count >= 1) {
        NSString *a = [parts[0] stringByTrimmingCharactersInSet:ws];
        if (a.length) {
            NSInteger v = a.integerValue;
            if (v > 0 || [a hasPrefix:@"0"]) { *number = @(v); }
        }
    }
    if (parts.count >= 2) {
        NSString *b = [parts[1] stringByTrimmingCharactersInSet:ws];
        if (b.length) {
            NSInteger v = b.integerValue;
            if (v > 0) { *total = @(v); }
        }
    }
}

NSArray<MTArtwork *> *artworksFromFile(File *f)
{
    NSMutableArray<MTArtwork *> *out = [NSMutableArray array];
    if (!f) { return out; }

    List<VariantMap> pics;
    try {
        pics = f->complexProperties("PICTURE");
    } catch (...) {
        return out;
    }

    for (const auto &pic : pics) {
        try {
            ByteVector data = pic.value("data").toByteVector();
            if (data.isEmpty()) { continue; }
            NSString *mime = nsOrNil(pic.value("mimeType").toString());
            NSString *desc = nsOrNil(pic.value("description").toString());
            NSString *typeName = ns(pic.value("pictureType").toString());

            MTArtwork *art = [[MTArtwork alloc] initWithData:nsdata(data)
                                                    mimeType:mime
                                                 description:desc
                                                        type:pictureTypeFromName(typeName)];
            bool ok = false;
            int w = pic.value("width").toInt(&ok);   if (ok) { art.declaredWidth = w; }
            int h = pic.value("height").toInt(&ok);  if (ok) { art.declaredHeight = h; }
            int cd = pic.value("colorDepth").toInt(&ok); if (ok) { art.declaredColorDepth = cd; }
            [out addObject:art];
        } catch (...) {
            continue;   // 单张图坏掉不影响其它
        }
    }
    return out;
}

MTTags *tagsFromFile(File *f)
{
    MTTags *tags = [[MTTags alloc] init];
    if (!f) { return tags; }

    PropertyMap props;
    try { props = f->properties(); } catch (...) { props = PropertyMap(); }

    NSMutableDictionary<NSString *, NSArray<NSString *> *> *raw = [NSMutableDictionary dictionary];
    for (auto it = props.begin(); it != props.end(); ++it) {
        NSMutableArray<NSString *> *vals = [NSMutableArray array];
        for (const auto &v : it->second) { [vals addObject:ns(v)]; }
        raw[ns(it->first)] = [vals copy];
    }
    tags.rawProperties = [raw copy];

    NSMutableArray<NSString *> *unsupported = [NSMutableArray array];
    for (const auto &u : props.unsupportedData()) { [unsupported addObject:ns(u)]; }
    tags.unsupportedProperties = [unsupported copy];

    auto get = [&](const char *key) -> NSString * {
        if (!props.contains(key)) { return nil; }
        return joinValues(props[key]);
    };

    tags.title       = get("TITLE");
    tags.artist      = get("ARTIST");
    tags.albumArtist = get("ALBUMARTIST");
    tags.album       = get("ALBUM");
    tags.year        = get("DATE");
    tags.genre       = get("GENRE");
    tags.comment     = get("COMMENT");
    tags.composer    = get("COMPOSER");
    tags.lyricist    = get("LYRICIST");
    tags.lyrics      = get("LYRICS");

    NSNumber *n = nil, *t = nil;
    parseNumberPair(get("TRACKNUMBER"), &n, &t);
    tags.trackNumber = n;
    tags.trackTotal  = t;
    if (!t) {
        NSString *tt = get("TRACKTOTAL") ?: get("TOTALTRACKS");
        if (tt.length) { tags.trackTotal = @(tt.integerValue); }
    }

    parseNumberPair(get("DISCNUMBER"), &n, &t);
    tags.discNumber = n;
    tags.discTotal  = t;
    if (!t) {
        NSString *dt = get("DISCTOTAL") ?: get("TOTALDISCS");
        if (dt.length) { tags.discTotal = @(dt.integerValue); }
    }

    // 兜底：PropertyMap 为空但基础 Tag 有内容（极少见的畸形 tag）
    Tag *basic = f->tag();
    if (basic && !basic->isEmpty()) {
        if (!tags.title)  { tags.title  = nsOrNil(basic->title());  }
        if (!tags.artist) { tags.artist = nsOrNil(basic->artist()); }
        if (!tags.album)  { tags.album  = nsOrNil(basic->album());  }
        if (!tags.genre)  { tags.genre  = nsOrNil(basic->genre());  }
        if (!tags.comment){ tags.comment= nsOrNil(basic->comment());}
        if (!tags.year && basic->year() > 0) {
            tags.year = [NSString stringWithFormat:@"%u", basic->year()];
        }
        if (!tags.trackNumber && basic->track() > 0) {
            tags.trackNumber = @(basic->track());
        }
    }

    tags.artworks = artworksFromFile(f);
    return tags;
}

MTAudioProperties *propsFromFile(File *f, AudioProperties *ap, long long fileSize)
{
    MTAudioProperties *out = [[MTAudioProperties alloc] init];
    out.fileSizeBytes = fileSize;
    FormatDescriptor d = describeFile(f, ap);
    out.containerName = d.container;
    out.codecName = d.codec;
    out.isLossless = d.lossless;
    out.bitsPerSample = d.bitsPerSample;

    if (ap) {
        out.durationMilliseconds = ap->lengthInMilliseconds();
        out.bitrateKbps = ap->bitrate();
        out.sampleRate = ap->sampleRate();
        out.channels = ap->channels();
    }
    return out;
}

// ---------------------------------------------------------------- 前置检查

BOOL preflight(NSString *path, BOOL needWrite, NSError **error)
{
    if (path.length == 0) {
        assignError(error, mkError(MTTagLibErrorInvalidArgument, path, @"路径为空"));
        return NO;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir]) {
        assignError(error, mkError(MTTagLibErrorFileNotFound, path, @"文件不存在"));
        return NO;
    }
    if (isDir) {
        assignError(error, mkError(MTTagLibErrorInvalidArgument, path, @"路径指向目录"));
        return NO;
    }
    if (![fm isReadableFileAtPath:path]) {
        assignError(error, mkError(MTTagLibErrorFileNotFound, path, @"文件不可读（权限不足）"));
        return NO;
    }
    NSError *attrErr = nil;
    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:&attrErr];
    if (attrs) {
        unsigned long long size = [attrs[NSFileSize] unsignedLongLongValue];
        if (size == 0) {
            assignError(error, mkError(MTTagLibErrorCorruptedFile, path, @"文件长度为 0"));
            return NO;
        }
        if (size < 16) {
            assignError(error, mkError(MTTagLibErrorCorruptedFile, path,
                                       [NSString stringWithFormat:@"文件过小（%llu 字节），不可能是有效音频", size]));
            return NO;
        }
    }
    if (needWrite) {
        if (![fm isWritableFileAtPath:path]) {
            assignError(error, mkError(MTTagLibErrorNotWritable, path, @"文件不可写（只读或权限不足）"));
            return NO;
        }
        NSNumber *immutable = attrs[NSFileImmutable];
        if (immutable.boolValue) {
            assignError(error, mkError(MTTagLibErrorNotWritable, path, @"文件被锁定（uchg）"));
            return NO;
        }
    }
    return YES;
}

}   // anonymous namespace

#pragma mark 写入代价预估（只读）

namespace {

// ---------------------------------------------------------------------------
// 只读的「标签区结构」解析。
//
// 为什么不直接问 TagLib：TagLib 没有公开「当前 PADDING / free 还剩多少」的查询接口
// （FLAC::File 的 blocks() 在 2.x 是 private，MP4::Atoms 也不对外）。而这套判断
// 只需要按容器规范扫一遍头部块表，几百字节的 IO，比开一次 FileRef 还便宜，
// 所以这里自己解析，**完全只读**，不引入任何写路径。
// ---------------------------------------------------------------------------

struct CostPlan {
    bool        fullRewrite  = false;
    bool        confident    = false;
    long long   fileBytes    = 0;
    long long   slackBytes   = 0;
    long long   needBytes    = 0;
    long long   rewriteBytes = 0;
    std::string container;
    std::string note;
};

inline unsigned int be24(const unsigned char *p)
{
    return (static_cast<unsigned int>(p[0]) << 16) | (static_cast<unsigned int>(p[1]) << 8) | p[2];
}

inline unsigned int be32(const unsigned char *p)
{
    return (static_cast<unsigned int>(p[0]) << 24) | (static_cast<unsigned int>(p[1]) << 16)
         | (static_cast<unsigned int>(p[2]) << 8)  |  static_cast<unsigned int>(p[3]);
}

inline unsigned long long be64(const unsigned char *p)
{
    unsigned long long v = 0;
    for (int i = 0; i < 8; ++i) { v = (v << 8) | p[i]; }
    return v;
}

/// ID3v2 的「同步安全整数」：每字节只有低 7 位有效。
inline unsigned int synchsafe(const unsigned char *p)
{
    return ((p[0] & 0x7fu) << 21) | ((p[1] & 0x7fu) << 14) | ((p[2] & 0x7fu) << 7) | (p[3] & 0x7fu);
}

inline bool readAt(FILE *f, long long off, void *buf, size_t n)
{
    if (fseeko(f, static_cast<off_t>(off), SEEK_SET) != 0) { return false; }
    return fread(buf, 1, n, f) == n;
}

/// `at` 处若是 ID3v2 头，返回整个标签的字节长度（含头与可选尾），否则返回 0。
long long id3v2TotalLength(FILE *f, long long at)
{
    unsigned char h[10];
    if (!readAt(f, at, h, 10)) { return 0; }
    if (h[0] != 'I' || h[1] != 'D' || h[2] != '3') { return 0; }
    if (h[3] == 0xff || h[4] == 0xff) { return 0; }
    const long long body   = synchsafe(h + 6);
    const long long footer = (h[5] & 0x10) ? 10 : 0;
    return 10 + body + footer;
}

// ------------------------------------------------------------------ FLAC

/// FLAC：元数据块表就是标签区。PADDING 块 + 本次会被替换掉的 PICTURE 块 = 可原地复用的空间。
bool planFLAC(FILE *f, long long fileBytes, long long payload, bool reclaim, CostPlan &out)
{
    // FLAC 允许前置一个 ID3v2（少见但合法），TagLib 也认。
    long long start = id3v2TotalLength(f, 0);
    unsigned char magic[4];
    if (!readAt(f, start, magic, 4)) { return false; }
    if (memcmp(magic, "fLaC", 4) != 0) { return false; }

    long long pos    = start + 4;
    long long region = 0;   // 全部元数据块（含块头）合计
    long long keep   = 0;   // 保存后仍要占位的块
    for (int guard = 0; guard < 4096; ++guard) {
        unsigned char h[4];
        if (!readAt(f, pos, h, 4)) { return false; }
        const bool         last = (h[0] & 0x80) != 0;
        const unsigned int type = h[0] & 0x7f;
        const long long    len  = be24(h + 1);
        region += 4 + len;
        if (type == 1) {                       // PADDING —— 纯空闲
        } else if (type == 6) {                // PICTURE
            if (!reclaim) { keep += 4 + len; } // 本次不动封面 → 旧封面继续占位
        } else {                               // STREAMINFO / VORBIS_COMMENT / SEEKTABLE / …
            keep += 4 + len;
        }
        pos += 4 + len;
        if (last) { break; }
        if (pos >= fileBytes) { return false; }
    }
    const long long streamStart = pos;

    // TagLib 保存后一定会补一个 PADDING 块（哪怕长度 0），给它留出 4 字节块头。
    long long slack = region - keep - 4;
    if (slack < 0) { slack = 0; }

    // PICTURE 块的容器开销：4 块头 + 32 固定字段（类型/长度/宽高/色深/色数各 4）
    // + mime 与描述串（留 64 字节余量）。
    const long long need = payload > 0 ? payload + 4 + 32 + 64 : 0;

    out.container    = "FLAC";
    out.confident    = true;
    out.fileBytes    = fileBytes;
    out.slackBytes   = slack;
    out.needBytes    = need;
    out.fullRewrite  = need > slack;
    out.rewriteBytes = out.fullRewrite ? (fileBytes - streamStart) : 0;
    char buf[256];
    snprintf(buf, sizeof buf,
             "元数据区 %lld 字节，其中固定占用 %lld、可复用 %lld；本次需要 %lld；音频数据 %lld 字节",
             region, keep, slack, need, fileBytes - streamStart);
    out.note = buf;
    return true;
}

// ------------------------------------------------------------------ MP3 / ID3v2

/// MP3：ID3v2 在文件头。新标签渲染后 ≤ 原 ID3v2 长度就原地覆盖（TagLib 会补 padding 填满），
/// 超出则 `insert()` 把后面整段 MPEG 帧流后移。
bool planMP3(FILE *f, long long fileBytes, long long payload, bool reclaim, CostPlan &out)
{
    const long long total = id3v2TotalLength(f, 0);
    long long used = 0, slack = 0;

    if (total > 0) {
        unsigned char h[10];
        if (!readAt(f, 0, h, 10)) { return false; }
        const int  major   = h[3];
        const bool footer  = (h[5] & 0x10) != 0;
        long long  pos     = 10;
        used = 10 + (footer ? 10 : 0);

        if (h[5] & 0x40) {                       // 扩展头
            unsigned char e[4];
            if (readAt(f, pos, e, 4)) {
                const long long ext = (major >= 4) ? synchsafe(e) : (be32(e) + 4);
                used += ext;
                pos  += ext;
            }
        }
        if (major >= 3) {                        // 2.3 / 2.4 的 10 字节帧头
            while (pos + 10 <= total) {
                unsigned char fh[10];
                if (!readAt(f, pos, fh, 10)) { break; }
                if (fh[0] == 0) { break; }       // 进入 padding
                const long long size = (major >= 4) ? synchsafe(fh + 4) : be32(fh + 4);
                if (size <= 0 || pos + 10 + size > total) { break; }
                const bool isPic = (memcmp(fh, "APIC", 4) == 0) || (memcmp(fh, "PIC", 3) == 0);
                if (!(reclaim && isPic)) { used += 10 + size; }
                pos += 10 + size;
            }
        } else {
            used = total;                        // 2.2 及更早：不细拆，按满算
        }
        slack = total - used;
        if (slack < 0) { slack = 0; }
    }

    // APIC 帧开销：10 帧头 + 编码/mime/类型/描述（留 64 字节余量）。
    const long long need = payload > 0 ? payload + 10 + 64 : 0;

    out.container    = "MP3 / ID3v2";
    out.confident    = true;
    out.fileBytes    = fileBytes;
    out.slackBytes   = slack;
    out.needBytes    = need;
    out.fullRewrite  = need > slack;
    out.rewriteBytes = out.fullRewrite ? (fileBytes - total) : 0;
    char buf[256];
    snprintf(buf, sizeof buf,
             "ID3v2 区 %lld 字节，其中帧占用 %lld、可复用 %lld；本次需要 %lld；音频数据 %lld 字节",
             total, used, slack, need, fileBytes - total);
    out.note = buf;
    return true;
}

// ------------------------------------------------------------------ MP4 / M4A

struct MP4Scan {
    long long moovEnd   = -1;
    long long ilstOff   = -1;
    long long ilstEnd   = -1;
    long long ilstUsed  = 0;    // ilst 里**不含**本次会被替换的 covr 的净占用
    long long freeAfter = 0;    // 紧跟在 ilst / moov 之后可吞掉的 free/skip 空间
    bool      moovAtTail = false;
};

/// 递归扫 atom 树，只取判定需要的几个位置。`depth` 防御畸形文件。
void scanMP4(FILE *f, long long begin, long long end, int depth, bool reclaim, MP4Scan &s)
{
    if (depth > 8) { return; }
    long long pos = begin;
    while (pos + 8 <= end) {
        unsigned char h[16];
        if (!readAt(f, pos, h, 8)) { return; }
        long long size = be32(h);
        long long hdr  = 8;
        if (size == 1) {
            if (!readAt(f, pos + 8, h + 8, 8)) { return; }
            size = static_cast<long long>(be64(h + 8));
            hdr  = 16;
        } else if (size == 0) {
            size = end - pos;
        }
        if (size < hdr || pos + size > end) { return; }
        const char *type = reinterpret_cast<const char *>(h + 4);

        if (memcmp(type, "moov", 4) == 0) {
            s.moovEnd = pos + size;
            scanMP4(f, pos + hdr, pos + size, depth + 1, reclaim, s);
        } else if (memcmp(type, "udta", 4) == 0 || memcmp(type, "meta", 4) == 0) {
            // meta 是 full atom：4 字节 version/flags 之后才是子 atom。
            const long long inner = (memcmp(type, "meta", 4) == 0) ? hdr + 4 : hdr;
            scanMP4(f, pos + inner, pos + size, depth + 1, reclaim, s);
        } else if (memcmp(type, "ilst", 4) == 0) {
            s.ilstOff = pos;
            s.ilstEnd = pos + size;
            // ilst 内部逐项统计：本次要覆盖封面时，旧 covr 的空间可回收。
            long long p = pos + hdr, used = hdr;
            while (p + 8 <= pos + size) {
                unsigned char e[8];
                if (!readAt(f, p, e, 8)) { break; }
                long long esz = be32(e);
                if (esz < 8 || p + esz > pos + size) { break; }
                const bool isCover = memcmp(e + 4, "covr", 4) == 0;
                if (!(reclaim && isCover)) { used += esz; }
                p += esz;
            }
            s.ilstUsed = used;
        } else if (memcmp(type, "free", 4) == 0 || memcmp(type, "skip", 4) == 0) {
            // 只有排在 ilst / moov 之后的 free 才是 TagLib 能就地吞掉的空间。
            if ((s.ilstEnd >= 0 && pos >= s.ilstEnd) || (s.moovEnd >= 0 && pos >= s.moovEnd)) {
                s.freeAfter += size;
            }
        } else if (memcmp(type, "mdat", 4) == 0) {
            if (s.moovEnd < 0) { s.moovAtTail = true; }   // mdat 在 moov 之前 → moov 在尾部
        }
        pos += size;
    }
}

bool planMP4(FILE *f, long long fileBytes, long long payload, bool reclaim, CostPlan &out)
{
    unsigned char h[12];
    if (!readAt(f, 0, h, 12)) { return false; }
    if (memcmp(h + 4, "ftyp", 4) != 0) { return false; }

    MP4Scan s;
    scanMP4(f, 0, fileBytes, 0, reclaim, s);
    if (s.moovEnd < 0) { return false; }

    const long long ilstLen = (s.ilstOff >= 0) ? (s.ilstEnd - s.ilstOff) : 0;
    long long slack = (ilstLen - s.ilstUsed) + s.freeAfter;
    if (slack < 0) { slack = 0; }

    // covr atom 开销：8 atom 头 + 16 data 头，留 64 字节余量。
    const long long need = payload > 0 ? payload + 8 + 16 + 64 : 0;

    const long long regionEnd = (s.ilstEnd > 0) ? std::max(s.ilstEnd, s.moovEnd) : s.moovEnd;
    out.container    = "MP4 / M4A";
    out.confident    = true;
    out.fileBytes    = fileBytes;
    out.slackBytes   = slack;
    out.needBytes    = need;
    out.fullRewrite  = need > slack;
    out.rewriteBytes = out.fullRewrite ? std::max(0LL, fileBytes - regionEnd) : 0;
    char buf[320];
    snprintf(buf, sizeof buf,
             "ilst %lld 字节（净占用 %lld）+ 其后 free %lld；可复用 %lld，本次需要 %lld；"
             "标签区之后还有 %lld 字节%s",
             ilstLen, s.ilstUsed, s.freeAfter, slack, need,
             std::max(0LL, fileBytes - regionEnd),
             s.moovAtTail ? "（moov 在文件尾部，扩容基本不搬数据）" : "");
    out.note = buf;
    return true;
}

}   // anonymous namespace

#pragma mark 文件头填充（只读解析 + 扩填充）

namespace {

// ---------------------------------------------------------------------------
// 「文件头还剩多少填充」的解析与扩容。
//
// 与上面的 CostPlan 是同一件事的两面：CostPlan 回答「这次保存会不会整文件重写」，
// 这里回答「现在预留了多少、能不能再多留点，让以后的保存都别重写」。
//
// 解析部分**完全只读**；扩容部分走「同目录临时文件 → rename() 原子替换」，
// 任何一步失败都会把临时文件删掉，原文件一个字节不动。
// ---------------------------------------------------------------------------

struct PadInfo {
    bool        supported      = false;
    long long   fileBytes      = 0;
    long long   currentPadding = 0;   // 可原地复用的填充字节
    long long   metadataBytes  = 0;   // 元数据区总字节（含填充）
    long long   audioOffset    = 0;   // 音频数据起点
    std::string container;
    std::string note;
};

struct FlacBlock {
    unsigned int type       = 0;
    long long    headerOff  = 0;      // 块头（4 字节）在文件中的偏移
    long long    length     = 0;      // 块数据长度（不含 4 字节块头）
    bool         last       = false;
};

const char *flacBlockName(unsigned int type)
{
    switch (type) {
        case 0:  return "STREAMINFO";
        case 1:  return "PADDING";
        case 2:  return "APPLICATION";
        case 3:  return "SEEKTABLE";
        case 4:  return "VORBIS_COMMENT";
        case 5:  return "CUESHEET";
        case 6:  return "PICTURE";
        case 127: return "INVALID";
        default: return "RESERVED";
    }
}

/// 扫 FLAC 元数据块链。`flacStart` = "fLaC" 魔数的偏移（前面可能有个 ID3v2）。
/// `streamStart` = 音频帧起点。失败返回 false。
bool scanFLAC(FILE *f, long long fileBytes,
              long long &flacStart, long long &streamStart,
              std::vector<FlacBlock> &blocks)
{
    flacStart = id3v2TotalLength(f, 0);
    unsigned char magic[4];
    if (!readAt(f, flacStart, magic, 4)) { return false; }
    if (memcmp(magic, "fLaC", 4) != 0) { return false; }

    long long pos = flacStart + 4;
    blocks.clear();
    for (int guard = 0; guard < 4096; ++guard) {
        unsigned char h[4];
        if (!readAt(f, pos, h, 4)) { return false; }
        FlacBlock b;
        b.last      = (h[0] & 0x80) != 0;
        b.type      = h[0] & 0x7f;
        b.length    = be24(h + 1);
        b.headerOff = pos;
        if (b.length < 0 || pos + 4 + b.length > fileBytes) { return false; }
        blocks.push_back(b);
        pos += 4 + b.length;
        if (b.last) { streamStart = pos; return !blocks.empty(); }
        if (pos >= fileBytes) { return false; }
    }
    return false;
}

/// ID3v2 区里「帧之后的零字节」= 可原地复用的填充。
/// 只解析 2.3 / 2.4（10 字节帧头）；2.2 及更早返回 false。
bool scanID3v2Padding(FILE *f, long long total, long long &padding, long long &usedBytes)
{
    unsigned char h[10];
    if (!readAt(f, 0, h, 10)) { return false; }
    const int  major  = h[3];
    const bool footer = (h[5] & 0x10) != 0;
    if (major < 3) { return false; }

    long long pos  = 10;
    long long used = 10 + (footer ? 10 : 0);
    if (h[5] & 0x40) {                                   // 扩展头
        unsigned char e[4];
        if (readAt(f, pos, e, 4)) {
            const long long ext = (major >= 4) ? synchsafe(e) : (be32(e) + 4);
            used += ext;
            pos  += ext;
        }
    }
    while (pos + 10 <= total) {
        unsigned char fh[10];
        if (!readAt(f, pos, fh, 10)) { break; }
        if (fh[0] == 0) { break; }                       // 进入 padding
        const long long size = (major >= 4) ? synchsafe(fh + 4) : be32(fh + 4);
        if (size <= 0 || pos + 10 + size > total) { break; }
        used += 10 + size;
        pos  += 10 + size;
    }
    usedBytes = used;
    padding   = total - used;
    if (padding < 0) { padding = 0; }
    return true;
}

/// MP4：ilst 内的空隙 + 其后的 free / skip atom。**只读**，与 planMP4 各走各的，
/// 免得为了取一个 mdat 偏移去动已经在用的估算路径。
struct MP4Pad {
    long long moovOff  = -1;
    long long moovEnd  = -1;
    long long ilstOff  = -1;
    long long ilstEnd  = -1;
    long long ilstUsed = 0;
    long long freeAfter = 0;
    long long mdatData = -1;   // mdat 的数据起点
};

void scanMP4Pad(FILE *f, long long begin, long long end, int depth, MP4Pad &s)
{
    if (depth > 8) { return; }
    long long pos = begin;
    while (pos + 8 <= end) {
        unsigned char h[16];
        if (!readAt(f, pos, h, 8)) { return; }
        long long size = be32(h);
        long long hdr  = 8;
        if (size == 1) {
            if (!readAt(f, pos + 8, h + 8, 8)) { return; }
            size = static_cast<long long>(be64(h + 8));
            hdr  = 16;
        } else if (size == 0) {
            size = end - pos;
        }
        if (size < hdr || pos + size > end) { return; }
        const char *type = reinterpret_cast<const char *>(h + 4);

        if (memcmp(type, "moov", 4) == 0) {
            s.moovOff = pos;
            s.moovEnd = pos + size;
            scanMP4Pad(f, pos + hdr, pos + size, depth + 1, s);
        } else if (memcmp(type, "udta", 4) == 0 || memcmp(type, "meta", 4) == 0) {
            const long long inner = (memcmp(type, "meta", 4) == 0) ? hdr + 4 : hdr;
            scanMP4Pad(f, pos + inner, pos + size, depth + 1, s);
        } else if (memcmp(type, "ilst", 4) == 0) {
            s.ilstOff = pos;
            s.ilstEnd = pos + size;
            long long p = pos + hdr, used = hdr;
            while (p + 8 <= pos + size) {
                unsigned char e[8];
                if (!readAt(f, p, e, 8)) { break; }
                long long esz = be32(e);
                if (esz < 8 || p + esz > pos + size) { break; }
                used += esz;
                p += esz;
            }
            s.ilstUsed = used;
        } else if (memcmp(type, "free", 4) == 0 || memcmp(type, "skip", 4) == 0) {
            if ((s.ilstEnd >= 0 && pos >= s.ilstEnd) || (s.moovEnd >= 0 && pos >= s.moovEnd)) {
                s.freeAfter += size;
            }
        } else if (memcmp(type, "mdat", 4) == 0) {
            if (s.mdatData < 0) { s.mdatData = pos + hdr; }
        }
        pos += size;
    }
}

/// 三种容器的只读 inspect。`blocksOut` 只有 FLAC 会填。
bool inspectPadding(NSString *path, PadInfo &info, NSMutableArray *blocksOut)
{
    NSString *ext = path.pathExtension.lowercaseString ?: @"";
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
    if (attrs) { info.fileBytes = (long long)[attrs[NSFileSize] unsignedLongLongValue]; }
    info.container = ext.UTF8String ?: "";

    FILE *f = fopen(path.fileSystemRepresentation, "rb");
    if (f == NULL) { info.note = "打不开文件"; return false; }

    bool ok = false;
    char buf[320];
    try {
        if ([ext isEqualToString:@"flac"]) {
            long long flacStart = 0, streamStart = 0;
            std::vector<FlacBlock> blocks;
            if (scanFLAC(f, info.fileBytes, flacStart, streamStart, blocks)) {
                long long padding = 0;
                for (const FlacBlock &b : blocks) {
                    if (b.type == 1) { padding += b.length; }
                    if (blocksOut != nil) {
                        [blocksOut addObject:@{
                            @"type"   : @(b.type),
                            @"name"   : [NSString stringWithUTF8String:flacBlockName(b.type)],
                            @"offset" : @(b.headerOff),
                            @"length" : @(b.length),
                            @"isLast" : @(b.last),
                        }];
                    }
                }
                info.supported      = true;
                info.container      = "FLAC";
                info.currentPadding = padding;
                info.metadataBytes  = streamStart - (flacStart + 4);
                info.audioOffset    = streamStart;
                snprintf(buf, sizeof buf,
                         "%zu 个元数据块，块区 %lld 字节，其中 PADDING %lld 字节；音频从 %lld 开始",
                         blocks.size(), info.metadataBytes, padding, streamStart);
                info.note = buf;
                ok = true;
            } else {
                info.note = "FLAC 元数据块链解析失败";
            }
        } else if ([ext isEqualToString:@"mp3"]) {
            const long long total = id3v2TotalLength(f, 0);
            if (total <= 0) {
                info.supported      = true;
                info.container      = "MP3 / ID3v2";
                info.currentPadding = 0;
                info.metadataBytes  = 0;
                info.audioOffset    = 0;
                info.note           = "文件里没有 ID3v2 标签（填充为 0）";
                ok = true;
            } else {
                long long padding = 0, used = 0;
                if (scanID3v2Padding(f, total, padding, used)) {
                    info.supported      = true;
                    info.container      = "MP3 / ID3v2";
                    info.currentPadding = padding;
                    info.metadataBytes  = total;
                    info.audioOffset    = total;
                    snprintf(buf, sizeof buf,
                             "ID3v2 区 %lld 字节，帧占用 %lld，填充 %lld；音频从 %lld 开始",
                             total, used, padding, total);
                    info.note = buf;
                    ok = true;
                } else {
                    info.container     = "MP3 / ID3v2";
                    info.metadataBytes = total;
                    info.audioOffset   = total;
                    info.note          = "ID3v2 2.2 及更早的帧头未解析，填充未知";
                }
            }
        } else if ([ext isEqualToString:@"mp4"] || [ext isEqualToString:@"m4a"]
                   || [ext isEqualToString:@"m4b"] || [ext isEqualToString:@"aac"]) {
            unsigned char h[12];
            if (readAt(f, 0, h, 12) && memcmp(h + 4, "ftyp", 4) == 0) {
                MP4Pad s;
                scanMP4Pad(f, 0, info.fileBytes, 0, s);
                if (s.moovEnd >= 0) {
                    const long long ilstLen = (s.ilstOff >= 0) ? (s.ilstEnd - s.ilstOff) : 0;
                    long long slack = (ilstLen - s.ilstUsed) + s.freeAfter;
                    if (slack < 0) { slack = 0; }
                    info.supported      = true;
                    info.container      = "MP4 / M4A";
                    info.currentPadding = slack;
                    info.metadataBytes  = (s.moovEnd - s.moovOff) + s.freeAfter;
                    info.audioOffset    = (s.mdatData >= 0) ? s.mdatData : s.moovEnd;
                    snprintf(buf, sizeof buf,
                             "moov %lld 字节，ilst %lld（净 %lld），其后 free %lld；可复用 %lld",
                             s.moovEnd - s.moovOff, ilstLen, s.ilstUsed, s.freeAfter, slack);
                    info.note = buf;
                    ok = true;
                } else {
                    info.note = "找不到 moov atom";
                }
            } else {
                info.note = "不是 ISO BMFF 容器（缺 ftyp）";
            }
        } else {
            info.note = "该格式未做填充结构解析";
        }
    } catch (...) {
        ok = false;
        info.note = "解析时原生层异常（已兜住）";
    }
    fclose(f);
    return ok;
}

// ------------------------------------------------------------------ 扩填充

inline void put24(unsigned char *p, long long v)
{
    p[0] = (unsigned char)((v >> 16) & 0xff);
    p[1] = (unsigned char)((v >> 8)  & 0xff);
    p[2] = (unsigned char)( v        & 0xff);
}

inline void putSynchsafe(unsigned char *p, long long v)
{
    p[0] = (unsigned char)((v >> 21) & 0x7f);
    p[1] = (unsigned char)((v >> 14) & 0x7f);
    p[2] = (unsigned char)((v >> 7)  & 0x7f);
    p[3] = (unsigned char)( v        & 0x7f);
}

/// 从 `src` 的 `off` 开始拷 `count` 字节到 `dst`。任何 IO 失败返回 false。
bool copyRange(FILE *src, FILE *dst, long long off, long long count)
{
    if (count <= 0) { return count == 0; }
    if (fseeko(src, (off_t)off, SEEK_SET) != 0) { return false; }
    const size_t chunk = 1 << 20;
    std::vector<unsigned char> buf(chunk);
    long long left = count;
    while (left > 0) {
        const size_t want = (size_t)std::min<long long>(left, (long long)chunk);
        const size_t got  = fread(buf.data(), 1, want, src);
        if (got == 0) { return false; }
        if (fwrite(buf.data(), 1, got, dst) != got) { return false; }
        left -= (long long)got;
    }
    return true;
}

bool writeZeros(FILE *dst, long long count)
{
    if (count <= 0) { return count == 0; }
    const size_t chunk = 1 << 16;
    std::vector<unsigned char> zero(chunk, 0);
    long long left = count;
    while (left > 0) {
        const size_t want = (size_t)std::min<long long>(left, (long long)chunk);
        if (fwrite(zero.data(), 1, want, dst) != want) { return false; }
        left -= (long long)want;
    }
    return true;
}

}   // anonymous namespace

#pragma mark - MTTagLibBridge

@implementation MTTagLibBridge

+ (void)initialize
{
    if (self == MTTagLibBridge.class) {
        installDebugListenerOnce();
    }
}

#pragma mark 环境

+ (NSString *)taglibVersion
{
    return [NSString stringWithFormat:@"%d.%d.%d",
            TAGLIB_MAJOR_VERSION, TAGLIB_MINOR_VERSION, TAGLIB_PATCH_VERSION];
}

+ (NSArray<NSString *> *)supportedFileExtensions
{
    static NSArray<NSString *> *cached = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray<NSString *> *a = [NSMutableArray array];
        try {
            StringList exts = FileRef::defaultFileExtensions();
            for (const auto &e : exts) {
                NSString *s = ns(e).lowercaseString;
                if (s.length && ![a containsObject:s]) { [a addObject:s]; }
            }
        } catch (...) {}
        cached = [a copy];
    });
    return cached;
}

+ (BOOL)isExtensionSupported:(NSString *)ext
{
    if (ext.length == 0) { return NO; }
    NSString *e = ext.lowercaseString;
    if ([e hasPrefix:@"."]) { e = [e substringFromIndex:1]; }
    return [self.supportedFileExtensions containsObject:e];
}

+ (MTLegacyEncoding)legacyEncoding
{
    std::lock_guard<std::mutex> guard(encodingMutex());
    return g_legacyEncoding;
}

+ (void)setLegacyEncoding:(MTLegacyEncoding)legacyEncoding
{
    applyLegacyEncoding(legacyEncoding);
}

#pragma mark 读

+ (MTAudioFileInfo *)readFileAtPath:(NSString *)path error:(NSError * _Nullable * _Nullable)error
{
    assignError(error, nil);
    if (!preflight(path, NO, error)) { return nil; }

    // 注意：所有 NSError / 返回值都必须先存进 @autoreleasepool **之外**的
    // __strong 局部变量。若直接把 mkError() 的结果写进 error 出参（ARC 下是
    // __autoreleasing），对象会被登记进内层池，池一 drain 就释放，调用方
    // （Swift 的 throws 桥接）随后 retain 到的就是野指针 → EXC_BAD_ACCESS。
    // 这个坑在畸形文件上必现，正是 B 报告风险点 6 描述的那类崩溃。
    __strong NSError *localError = nil;
    __strong MTAudioFileInfo *result = nil;

    @autoreleasepool {
        DiagScope diag;
        try {
            NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
            long long fileSize = (long long)[attrs[NSFileSize] unsignedLongLongValue];

            FileRef ref(path.fileSystemRepresentation, true, AudioProperties::Average);
            if (ref.isNull() || ref.file() == nullptr) {
                localError = mkError(MTTagLibErrorUnsupportedFormat, path,
                                     @"TagLib 无法识别该文件（格式不支持或文件头损坏）");
            }
            else if (!ref.file()->isValid()) {
                localError = mkError(MTTagLibErrorCorruptedFile, path,
                                     @"文件结构损坏，TagLib 判定为无效");
            }
            else {
                File *f = ref.file();
                MTAudioFileInfo *info = [[MTAudioFileInfo alloc] init];
                info.path = [path copy];
                info.isReadOnly = f->readOnly();
                info.tags = tagsFromFile(f);
                info.audioProperties = propsFromFile(f, ref.audioProperties(), fileSize);
                info.tagContainers = detectTagContainers(f);
                info.diagnostics = diag.toArray();
                result = info;
            }
        }
        catch (const std::exception &e) {
            result = nil;
            localError = mkError(MTTagLibErrorNativeException, path,
                                 [NSString stringWithFormat:@"原生层异常：%s", e.what()]);
        }
        catch (...) {
            result = nil;
            localError = mkError(MTTagLibErrorNativeException, path, @"原生层抛出未知异常");
        }
    }

    if (result == nil && localError == nil) {
        localError = mkError(MTTagLibErrorUnknown, path, @"读取失败但未产生具体原因");
    }
    if (result == nil) { assignError(error, localError); }
    return result;
}

+ (MTAudioProperties *)readAudioPropertiesAtPath:(NSString *)path error:(NSError * _Nullable * _Nullable)error
{
    assignError(error, nil);
    if (!preflight(path, NO, error)) { return nil; }

    __strong NSError *localError = nil;
    __strong MTAudioProperties *result = nil;

    @autoreleasepool {
        DiagScope diag;
        try {
            NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
            long long fileSize = (long long)[attrs[NSFileSize] unsignedLongLongValue];

            FileRef ref(path.fileSystemRepresentation, true, AudioProperties::Fast);
            if (ref.isNull() || ref.file() == nullptr || !ref.file()->isValid()) {
                localError = mkError(MTTagLibErrorUnsupportedFormat, path, @"TagLib 无法识别该文件");
            } else {
                result = propsFromFile(ref.file(), ref.audioProperties(), fileSize);
            }
        }
        catch (const std::exception &e) {
            result = nil;
            localError = mkError(MTTagLibErrorNativeException, path,
                                 [NSString stringWithFormat:@"原生层异常：%s", e.what()]);
        }
        catch (...) {
            result = nil;
            localError = mkError(MTTagLibErrorNativeException, path, @"原生层抛出未知异常");
        }
    }

    if (result == nil && localError == nil) {
        localError = mkError(MTTagLibErrorUnknown, path, @"读取技术参数失败但未产生具体原因");
    }
    if (result == nil) { assignError(error, localError); }
    return result;
}

+ (NSArray<MTArtwork *> *)readArtworksAtPath:(NSString *)path error:(NSError * _Nullable * _Nullable)error
{
    assignError(error, nil);
    if (!preflight(path, NO, error)) { return nil; }

    __strong NSError *localError = nil;
    __strong NSArray<MTArtwork *> *result = nil;

    @autoreleasepool {
        DiagScope diag;
        try {
            FileRef ref(path.fileSystemRepresentation, false);
            if (ref.isNull() || ref.file() == nullptr || !ref.file()->isValid()) {
                localError = mkError(MTTagLibErrorUnsupportedFormat, path, @"TagLib 无法识别该文件");
            } else {
                result = artworksFromFile(ref.file());
            }
        }
        catch (const std::exception &e) {
            result = nil;
            localError = mkError(MTTagLibErrorNativeException, path,
                                 [NSString stringWithFormat:@"原生层异常：%s", e.what()]);
        }
        catch (...) {
            result = nil;
            localError = mkError(MTTagLibErrorNativeException, path, @"原生层抛出未知异常");
        }
    }

    if (result == nil && localError == nil) {
        localError = mkError(MTTagLibErrorUnknown, path, @"读取封面失败但未产生具体原因");
    }
    if (result == nil) { assignError(error, localError); }
    return result;
}

#pragma mark 写

+ (MTWriteResult *)writeEdit:(MTTagEdit *)edit toFileAtPath:(NSString *)path
{
    MTWriteResult *result = [[MTWriteResult alloc] init];

    if (edit == nil) {
        result.error = mkError(MTTagLibErrorInvalidArgument, path, @"edit 为 nil");
        return result;
    }
    NSError *pre = nil;
    if (!preflight(path, YES, &pre)) {
        result.error = pre;
        return result;
    }
    if (edit.isEmpty) {           // 无事可做
        result.success = YES;
        return result;
    }

    @autoreleasepool {
        DiagScope diag;
        try {
            FileRef ref(path.fileSystemRepresentation, false);
            if (ref.isNull() || ref.file() == nullptr) {
                result.error = mkError(MTTagLibErrorUnsupportedFormat, path,
                                       @"TagLib 无法识别该文件，拒绝写入");
                return result;
            }
            File *f = ref.file();
            if (!f->isValid()) {
                result.error = mkError(MTTagLibErrorCorruptedFile, path,
                                       @"文件结构损坏，拒绝写入（避免二次破坏）");
                return result;
            }
            if (f->readOnly()) {
                result.error = mkError(MTTagLibErrorNotWritable, path,
                                       @"TagLib 以只读方式打开了该文件");
                return result;
            }

            // ---- 封面体积预检 ----
            // 必须排在**所有**改动之前：超限的图在渲染阶段会被静默丢弃，而原有封面
            // 早已被换掉，结果就是 AT-04「报成功、封面凭空消失」。这里一旦拒写就直接
            // 返回，`f` 上没有任何 setter 被调用过，更没有 save()，磁盘上的文件一字未动。
            if (edit.artworkMode == MTArtworkWriteModeReplace) {
                const ArtworkCapacity cap = artworkCapacityFor(f);
                if (cap.limit > 0) {
                    for (MTArtwork *art in edit.artworks) {
                        if (art.data.length == 0) { continue; }
                        NSString *mime = art.mimeType
                            ?: [MTArtwork sniffMIMETypeForData:art.data] ?: @"image/jpeg";
                        const unsigned long long overhead =
                            artworkOverheadBytes(f, mime, art.artworkDescription ?: @"");
                        const unsigned long long dataBytes = (unsigned long long)art.data.length;
                        if (overhead + dataBytes > cap.limit) {
                            const unsigned long long allowance =
                                (cap.limit > overhead) ? (cap.limit - overhead) : 0;
                            result.error = mkArtworkTooLargeError(path, cap.container,
                                                                  allowance, dataBytes);
                            result.diagnostics = diag.toArray();
                            return result;
                        }
                    }
                }
            }

            // ---- 字段 ----
            PropertyMap props = f->properties();

            for (NSString *field in edit.touchedFields) {
                id value = [edit valueForField:field];
                String key = tl(field);
                if (value == nil || value == [NSNull null]) {
                    props.erase(key);
                } else {
                    NSString *sv = (NSString *)value;
                    if (sv.length == 0) {
                        props.erase(key);
                    } else {
                        props.replace(key, StringList(tl(sv)));
                    }
                }
            }

            NSDictionary<NSString *, id> *rawFields = [edit mt_rawFields];
            for (NSString *key in rawFields) {
                id value = rawFields[key];
                String k = tl(key);
                if (value == [NSNull null]) {
                    props.erase(k);
                } else {
                    StringList list;
                    for (NSString *v in (NSArray<NSString *> *)value) { list.append(tl(v)); }
                    if (list.isEmpty()) { props.erase(k); }
                    else { props.replace(k, list); }
                }
            }

            PropertyMap rejected = f->setProperties(props);
            NSMutableArray<NSString *> *rejectedKeys = [NSMutableArray array];
            for (auto it = rejected.begin(); it != rejected.end(); ++it) {
                [rejectedKeys addObject:ns(it->first)];
            }

            // ---- 封面 ----
            if (edit.artworkMode == MTArtworkWriteModeRemoveAll) {
                if (!f->setComplexProperties("PICTURE", List<VariantMap>())) {
                    result.error = mkError(MTTagLibErrorCapabilityMissing, path,
                                           @"该格式不支持封面写入");
                    result.diagnostics = diag.toArray();
                    return result;
                }
            } else if (edit.artworkMode == MTArtworkWriteModeReplace) {
                List<VariantMap> pics;
                for (MTArtwork *art in edit.artworks) {
                    if (art.data.length == 0) { continue; }
                    VariantMap m;
                    m.insert("data", Variant(bytevector(art.data)));
                    NSString *mime = art.mimeType ?: [MTArtwork sniffMIMETypeForData:art.data] ?: @"image/jpeg";
                    m.insert("mimeType", Variant(tl(mime)));
                    m.insert("description", Variant(tl(art.artworkDescription ?: @"")));
                    m.insert("pictureType", Variant(tl(pictureTypeName(art.type))));
                    pics.append(m);
                }
                if (!f->setComplexProperties("PICTURE", pics)) {
                    result.error = mkError(MTTagLibErrorCapabilityMissing, path,
                                           @"该格式不支持封面写入");
                    result.diagnostics = diag.toArray();
                    return result;
                }
            }

            // ---- 保存 ----
            if (!f->save()) {
                NSArray<NSString *> *d = diag.toArray();
                NSString *why = d.count ? [d componentsJoinedByString:@"; "] : @"TagLib save() 返回 false";
                result.error = mkError(MTTagLibErrorWriteFailed, path, why);
                result.diagnostics = d;
                return result;
            }

            // ---- ID3v1 处理 ----
            // TagLib 对 MPEG 的默认行为：已存在 ID3v1 时会同步更新。
            // syncID3v1 == NO 表示保存后剥掉 ID3v1，只保留 ID3v2。
            if (!edit.syncID3v1) {
                if (auto *mpeg = dynamic_cast<MPEG::File *>(f)) {
                    if (mpeg->hasID3v1Tag()) { mpeg->strip(MPEG::File::ID3v1); }
                }
            }

            result.success = YES;
            result.rejectedKeys = [rejectedKeys copy];
            result.diagnostics = diag.toArray();
            return result;
        }
        catch (const std::exception &e) {
            result.success = NO;
            result.error = mkError(MTTagLibErrorNativeException, path,
                                   [NSString stringWithFormat:@"原生层异常：%s", e.what()]);
            result.diagnostics = diag.toArray();
            return result;
        }
        catch (...) {
            result.success = NO;
            result.error = mkError(MTTagLibErrorNativeException, path, @"原生层抛出未知异常");
            result.diagnostics = diag.toArray();
            return result;
        }
    }
}

+ (BOOL)stripAllTagsAtPath:(NSString *)path error:(NSError * _Nullable * _Nullable)error
{
    assignError(error, nil);
    if (!preflight(path, YES, error)) { return NO; }

    __strong NSError *localError = nil;
    BOOL ok = NO;

    @autoreleasepool {
        DiagScope diag;
        try {
            FileRef ref(path.fileSystemRepresentation, false);
            if (ref.isNull() || ref.file() == nullptr || !ref.file()->isValid()) {
                localError = mkError(MTTagLibErrorUnsupportedFormat, path, @"TagLib 无法识别该文件");
            }
            else {
                File *f = ref.file();
                if (auto *mpeg = dynamic_cast<MPEG::File *>(f)) {
                    ok = mpeg->strip(MPEG::File::AllTags);
                    if (!ok) {
                        localError = mkError(MTTagLibErrorWriteFailed, path, @"strip() 返回 false");
                    }
                } else {
                    PropertyMap empty;
                    f->setProperties(empty);
                    f->setComplexProperties("PICTURE", List<VariantMap>());
                    ok = f->save();
                    if (!ok) {
                        localError = mkError(MTTagLibErrorWriteFailed, path, @"TagLib save() 返回 false");
                    }
                }
            }
        }
        catch (...) {
            ok = NO;
            localError = mkError(MTTagLibErrorNativeException, path, @"原生层抛出未知异常");
        }
    }

    if (!ok) {
        if (localError == nil) {
            localError = mkError(MTTagLibErrorUnknown, path, @"清除标签失败但未产生具体原因");
        }
        assignError(error, localError);
    }
    return ok;
}

+ (NSDictionary<NSString *, id> *)estimateWriteCostAtPath:(NSString *)path
                                            payloadBytes:(long long)payloadBytes
                                         reclaimsArtwork:(BOOL)reclaimsArtwork
{
    NSString *ext = path.pathExtension.lowercaseString ?: @"";
    long long fileBytes = 0;
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
    if (attrs) { fileBytes = (long long)[attrs[NSFileSize] unsignedLongLongValue]; }

    CostPlan plan;
    plan.fileBytes = fileBytes;
    plan.container = ext.UTF8String ?: "";

    FILE *f = fopen(path.fileSystemRepresentation, "rb");
    bool parsed = false;
    if (f != NULL) {
        try {
            if ([ext isEqualToString:@"flac"]) {
                parsed = planFLAC(f, fileBytes, payloadBytes, reclaimsArtwork, plan);
            } else if ([ext isEqualToString:@"mp3"]) {
                parsed = planMP3(f, fileBytes, payloadBytes, reclaimsArtwork, plan);
            } else if ([ext isEqualToString:@"mp4"] || [ext isEqualToString:@"m4a"]
                       || [ext isEqualToString:@"m4b"] || [ext isEqualToString:@"aac"]) {
                parsed = planMP4(f, fileBytes, payloadBytes, reclaimsArtwork, plan);
            }
        } catch (...) {
            parsed = false;
        }
        fclose(f);
    }

    if (!parsed) {
        // 兜底：解析不了（或该格式的标签不在文件头）时不猜细节，只给保守判断。
        // ogg / opus 改注释包必然重排页，按整文件重写算；
        // ape / wv / tta / dsf / mpc 这类标签在**文件尾部**，扩容只是追加，不搬音频数据。
        static NSSet<NSString *> *tailTagged =
            [NSSet setWithArray:@[@"ape", @"wv", @"tta", @"dsf", @"dff", @"mpc", @"wav", @"aiff", @"aif"]];
        const bool isOgg  = [ext isEqualToString:@"ogg"] || [ext isEqualToString:@"oga"]
                         || [ext isEqualToString:@"opus"] || [ext isEqualToString:@"spx"];
        const bool isTail = [tailTagged containsObject:ext];
        plan.confident    = false;
        plan.slackBytes   = 0;
        plan.needBytes    = payloadBytes;
        plan.fullRewrite  = isOgg ? (payloadBytes > 0) : (isTail ? false : (payloadBytes > 0));
        plan.rewriteBytes = plan.fullRewrite ? fileBytes : 0;
        plan.note = isOgg   ? "Ogg 系：注释包变长会重排整条逻辑流，按整文件重写估"
                  : isTail  ? "标签位于文件尾部，扩容只是追加，不搬动音频数据"
                            : "该格式未做结构解析，按保守值估计";
    }

    return @{
        @"fullRewrite"  : @(plan.fullRewrite),
        @"confident"    : @(plan.confident),
        @"fileBytes"    : @(plan.fileBytes),
        @"slackBytes"   : @(plan.slackBytes),
        @"needBytes"    : @(plan.needBytes),
        @"rewriteBytes" : @(plan.rewriteBytes),
        @"container"    : [NSString stringWithUTF8String:plan.container.c_str()] ?: ext,
        @"note"         : [NSString stringWithUTF8String:plan.note.c_str()] ?: @"",
    };
}

#pragma mark 文件头填充（只读 inspect + 扩填充）

+ (NSDictionary<NSString *, id> *)inspectPaddingAtPath:(NSString *)path
{
    NSMutableArray *blocks = [NSMutableArray array];
    PadInfo info;
    inspectPadding(path, info, blocks);
    return @{
        @"supported"      : @(info.supported),
        @"container"      : [NSString stringWithUTF8String:info.container.c_str()] ?: @"",
        @"fileBytes"      : @(info.fileBytes),
        @"currentPadding" : @(info.currentPadding),
        @"metadataBytes"  : @(info.metadataBytes),
        @"audioOffset"    : @(info.audioOffset),
        @"blocks"         : [blocks copy],
        @"note"           : [NSString stringWithUTF8String:info.note.c_str()] ?: @"",
    };
}

+ (nullable NSDictionary<NSString *, id> *)reservePaddingAtPath:(NSString *)path
                                                    targetBytes:(long long)targetBytes
                                                          error:(NSError * _Nullable * _Nullable)error
{
    // ---- 入参与前置检查 -----------------------------------------------------
    if (targetBytes < 0 || targetBytes > 0xFFFFFELL) {
        // FLAC 块长度是 24 位；同一个上限也顺手挡住了荒唐的 ID3v2 预留值。
        assignError(error, mkError(MTTagLibErrorInvalidArgument, path,
                                   @"预留字节数必须在 0 ～ 16 MB 之间"));
        return nil;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) {
        assignError(error, mkError(MTTagLibErrorFileNotFound, path, @"文件不存在"));
        return nil;
    }
    if (![fm isWritableFileAtPath:path]) {
        assignError(error, mkError(MTTagLibErrorNotWritable, path, @"文件不可写"));
        return nil;
    }

    // 改写前先记下 TagLib 眼里的技术参数。收尾时拿**临时文件**跟它对一遍，
    // 对不上就直接丢弃临时文件 —— 原文件从头到尾没被碰过。
    int origLengthMs = -1, origSampleRate = -1, origChannels = -1;
    try {
        FileRef probeRef(path.fileSystemRepresentation, true, AudioProperties::Fast);
        if (!probeRef.isNull() && probeRef.audioProperties() != nullptr) {
            origLengthMs   = probeRef.audioProperties()->lengthInMilliseconds();
            origSampleRate = probeRef.audioProperties()->sampleRate();
            origChannels   = probeRef.audioProperties()->channels();
        }
    } catch (...) { origLengthMs = -1; }

    PadInfo info;
    inspectPadding(path, info, nil);
    if (!info.supported) {
        assignError(error, mkError(MTTagLibErrorCapabilityMissing, path,
                                   [NSString stringWithFormat:@"该格式不支持预留填充：%s", info.note.c_str()]));
        return nil;
    }

    NSString *ext = path.pathExtension.lowercaseString ?: @"";
    const bool isFLAC = [ext isEqualToString:@"flac"];
    const bool isMP3  = [ext isEqualToString:@"mp3"];
    if (!isFLAC && !isMP3) {
        // MP4：往 moov 之前插 free 会让 stco / co64 里的绝对块偏移全部作废，
        // 必须同步改写偏移表 —— 风险不划算，这里明确拒绝而不是硬来。TODO。
        assignError(error, mkError(MTTagLibErrorCapabilityMissing, path,
                                   @"当前只支持 FLAC 与 MP3(ID3v2) 扩填充；MP4 需同步改写 stco/co64，暂不支持"));
        return nil;
    }

    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"paddingBefore"]   = @(info.currentPadding);
    result[@"fileBytesBefore"] = @(info.fileBytes);

    if (info.currentPadding >= targetBytes) {
        result[@"changed"]        = @NO;
        result[@"paddingAfter"]   = @(info.currentPadding);
        result[@"fileBytesAfter"] = @(info.fileBytes);
        result[@"movedBytes"]     = @0;
        result[@"note"]           = [NSString stringWithFormat:
                                     @"当前填充 %lld 字节已达到目标 %lld，未改动文件",
                                     info.currentPadding, targetBytes];
        return result;
    }

    // ---- 打开原文件与同目录临时文件 -----------------------------------------
    FILE *src = fopen(path.fileSystemRepresentation, "rb");
    if (src == NULL) {
        assignError(error, mkError(MTTagLibErrorFileNotFound, path, @"打不开源文件"));
        return nil;
    }
    struct stat st;
    const bool haveStat = (fstat(fileno(src), &st) == 0);

    // 临时文件必须落在**同一个目录**（跨卷 rename 会失败），且要带上原扩展名 ——
    // 收尾复核时 TagLib 是按扩展名认容器的，没后缀就认不出来。
    NSString *dir = [path stringByDeletingLastPathComponent];
    NSString *suffix = ext.length ? [@"." stringByAppendingString:ext] : @"";
    NSString *tmpTemplate = [dir stringByAppendingPathComponent:
                             [@".mactagger-pad-XXXXXX" stringByAppendingString:suffix]];
    const char *tmpCString = tmpTemplate.fileSystemRepresentation;
    std::vector<char> tmpPath(tmpCString, tmpCString + strlen(tmpCString) + 1);
    const int tmpFD = mkstemps(tmpPath.data(), (int)strlen(suffix.fileSystemRepresentation));
    if (tmpFD < 0) {
        fclose(src);
        assignError(error, mkError(MTTagLibErrorWriteFailed, path, @"无法在同目录创建临时文件"));
        return nil;
    }
    FILE *dst = fdopen(tmpFD, "wb");
    if (dst == NULL) {
        close(tmpFD);
        unlink(tmpPath.data());
        fclose(src);
        assignError(error, mkError(MTTagLibErrorWriteFailed, path, @"临时文件打开失败"));
        return nil;
    }

    bool ok = false;
    long long movedBytes = 0;
    long long paddingAfter = info.currentPadding;
    NSString *failReason = @"写入失败";

    try {
        if (isFLAC) {
            long long flacStart = 0, streamStart = 0;
            std::vector<FlacBlock> blocks;
            if (!scanFLAC(src, info.fileBytes, flacStart, streamStart, blocks)) {
                failReason = @"FLAC 元数据块链解析失败";
            } else {
                // ① 可能存在的前置 ID3v2 + "fLaC" 魔数原样搬过去
                ok = copyRange(src, dst, 0, flacStart + 4);
                // ② 全部非 PADDING 块，保持原顺序，is_last 一律清零
                if (ok) {
                    for (const FlacBlock &b : blocks) {
                        if (b.type == 1) { continue; }
                        unsigned char h[4];
                        h[0] = (unsigned char)(b.type & 0x7f);      // is_last = 0
                        put24(h + 1, b.length);
                        if (fwrite(h, 1, 4, dst) != 4) { ok = false; break; }
                        if (!copyRange(src, dst, b.headerOff + 4, b.length)) { ok = false; break; }
                    }
                }
                // ③ 一个 PADDING 块收尾，长度 = 目标预留量
                if (ok) {
                    unsigned char h[4];
                    h[0] = 0x80 | 0x01;                             // is_last = 1，type = PADDING
                    put24(h + 1, targetBytes);
                    ok = (fwrite(h, 1, 4, dst) == 4) && writeZeros(dst, targetBytes);
                }
                // ④ 音频帧原样搬过去
                if (ok) {
                    movedBytes = info.fileBytes - streamStart;
                    ok = copyRange(src, dst, streamStart, movedBytes);
                }
                if (ok) { paddingAfter = targetBytes; }
                else if ([failReason isEqualToString:@"写入失败"]) { failReason = @"FLAC 重写时 IO 失败"; }
            }
        } else {   // MP3 / ID3v2
            const long long total = id3v2TotalLength(src, 0);
            unsigned char h[10];
            if (total <= 0 || !readAt(src, 0, h, 10)) {
                failReason = @"文件里没有 ID3v2 标签，先用 TagLib 保存一次再来预留";
            } else if (h[3] < 3) {
                failReason = @"ID3v2.2 及更早版本不做扩填充（TagLib 保存时会升到 2.4）";
            } else if (h[5] & 0x10) {
                failReason = @"该 ID3v2 带尾部 footer，规范禁止 padding";
            } else {
                const long long delta   = targetBytes - info.currentPadding;
                const long long newBody = (total - 10) + delta;
                if (newBody > 0x0FFFFFFFLL) {
                    failReason = @"扩容后 ID3v2 超出同步安全整数上限";
                } else {
                    unsigned char nh[10];
                    memcpy(nh, h, 10);
                    putSynchsafe(nh + 6, newBody);
                    ok = (fwrite(nh, 1, 10, dst) == 10);
                    if (ok) { ok = copyRange(src, dst, 10, total - 10); }   // 原标签体（含原有 padding）
                    if (ok) { ok = writeZeros(dst, delta); }                // 追加的零字节
                    if (ok) {
                        movedBytes = info.fileBytes - total;
                        ok = copyRange(src, dst, total, movedBytes);        // MPEG 帧流
                    }
                    if (ok) { paddingAfter = targetBytes; }
                    else if ([failReason isEqualToString:@"写入失败"]) { failReason = @"ID3v2 重写时 IO 失败"; }
                }
            }
        }
    } catch (...) {
        ok = false;
        failReason = @"扩填充时原生层异常（已兜住）";
    }

    // ---- 收尾：落盘 → 权限 → 原子替换 --------------------------------------
    if (ok) {
        ok = (fflush(dst) == 0) && (fsync(fileno(dst)) == 0);
        if (!ok) { failReason = @"临时文件落盘失败"; }
    }
    if (ok && haveStat) {
        // 权限继承原文件；owner 改不动就算了（普通用户改不了别人的文件属主）。
        fchmod(fileno(dst), st.st_mode & 07777);
        (void)fchown(fileno(dst), st.st_uid, st.st_gid);
    }
    long long newSize = 0;
    if (ok) {
        const off_t end = ftello(dst);
        newSize = (end >= 0) ? (long long)end : 0;
    }
    fclose(dst);
    fclose(src);

    if (!ok) {
        unlink(tmpPath.data());
        assignError(error, mkError(MTTagLibErrorWriteFailed, path, failReason));
        return nil;
    }

    // 复核：临时文件必须仍是个能被 TagLib 打开的合法音频，且时长 / 采样率 / 声道
    // 与原文件完全一致。不一致就丢弃 —— 宁可这次没预留成，也不能把用户的歌改坏。
    NSString *verifyNote = @"";
    if (origLengthMs >= 0) {
        int newLengthMs = -1, newSampleRate = -1, newChannels = -1;
        bool verifyOK = false;
        try {
            FileRef vref(tmpPath.data(), true, AudioProperties::Fast);
            if (!vref.isNull() && vref.audioProperties() != nullptr) {
                newLengthMs   = vref.audioProperties()->lengthInMilliseconds();
                newSampleRate = vref.audioProperties()->sampleRate();
                newChannels   = vref.audioProperties()->channels();
                verifyOK = (newLengthMs == origLengthMs)
                        && (newSampleRate == origSampleRate)
                        && (newChannels == origChannels);
            }
        } catch (...) { verifyOK = false; }
        if (!verifyOK) {
            unlink(tmpPath.data());
            assignError(error, mkError(MTTagLibErrorWriteFailed, path,
                [NSString stringWithFormat:
                 @"扩填充后复核不通过（时长 %d→%d ms，采样率 %d→%d，声道 %d→%d），已丢弃临时文件，原文件未改动",
                 origLengthMs, newLengthMs, origSampleRate, newSampleRate, origChannels, newChannels]));
            return nil;
        }
        verifyNote = [NSString stringWithFormat:@"；复核通过（%d ms / %d Hz / %d ch）",
                      newLengthMs, newSampleRate, newChannels];
    }

    if (rename(tmpPath.data(), path.fileSystemRepresentation) != 0) {
        unlink(tmpPath.data());
        assignError(error, mkError(MTTagLibErrorWriteFailed, path,
                                   [NSString stringWithFormat:@"原子替换失败：%s", strerror(errno)]));
        return nil;
    }

    result[@"changed"]        = @YES;
    result[@"paddingAfter"]   = @(paddingAfter);
    result[@"fileBytesAfter"] = @(newSize);
    result[@"movedBytes"]     = @(movedBytes);
    result[@"note"]           = [NSString stringWithFormat:
                                 @"填充 %lld → %lld 字节，搬动音频 %lld 字节%@",
                                 info.currentPadding, paddingAfter, movedBytes, verifyNote];
    return result;
}

#pragma mark 能力探测

+ (MTFormatCapability *)capabilityForExtension:(NSString *)ext
{
    MTFormatCapability *cap = [[MTFormatCapability alloc] init];
    NSString *e = (ext ?: @"").lowercaseString;
    if ([e hasPrefix:@"."]) { e = [e substringFromIndex:1]; }
    cap.fileExtension = e;
    cap.recognizedByTagLib = [self isExtensionSupported:e];

    static NSDictionary<NSString *, NSString *> *containers = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        containers = @{
            @"mp3": @"ID3v2 / ID3v1 / APEv2",
            @"flac": @"Xiph Comment (+ PICTURE block)",
            @"ogg": @"Xiph Comment", @"oga": @"Xiph Comment", @"opus": @"Xiph Comment",
            @"spx": @"Xiph Comment",
            @"m4a": @"MP4 atoms", @"mp4": @"MP4 atoms", @"m4b": @"MP4 atoms", @"m4r": @"MP4 atoms",
            @"wma": @"ASF", @"asf": @"ASF",
            @"ape": @"APEv2 / ID3v1",
            @"mpc": @"APEv2 / ID3v1",
            @"wv": @"APEv2 / ID3v1",
            @"tta": @"ID3v2 / ID3v1",
            @"wav": @"ID3v2 / RIFF INFO",
            @"aif": @"ID3v2", @"aiff": @"ID3v2", @"aifc": @"ID3v2",
            @"dsf": @"ID3v2",
            @"dff": @"ID3v2 / DIIN",
        };
    });
    cap.tagContainer = containers[e] ?: (cap.recognizedByTagLib ? @"（TagLib 内部决定）" : @"不支持");
    return cap;
}

+ (NSDictionary<NSString *, id> *)probeFileAtPath:(NSString *)path
{
    NSMutableDictionary<NSString *, id> *result = [NSMutableDictionary dictionary];
    result[@"path"] = path ?: @"";
    result[@"canRead"] = @NO;
    result[@"canWrite"] = @NO;
    result[@"canWriteArtwork"] = @NO;
    result[@"container"] = @"";
    result[@"codec"] = @"";
    result[@"durationMs"] = @0;
    result[@"note"] = @"";

    NSMutableArray<NSString *> *notes = [NSMutableArray array];

    // --- 读 ---
    NSError *readErr = nil;
    MTAudioFileInfo *info = [self readFileAtPath:path error:&readErr];
    if (!info) {
        [notes addObject:[NSString stringWithFormat:@"读失败：%@", readErr.localizedDescription]];
        result[@"note"] = [notes componentsJoinedByString:@"；"];
        return result;
    }
    result[@"canRead"] = @YES;
    result[@"container"] = info.audioProperties.containerName;
    result[@"codec"] = info.audioProperties.codecName;
    result[@"durationMs"] = @(info.audioProperties.durationMilliseconds);
    result[@"sampleRate"] = @(info.audioProperties.sampleRate);
    result[@"channels"] = @(info.audioProperties.channels);
    result[@"bitrate"] = @(info.audioProperties.bitrateKbps);
    if (info.diagnostics.count) {
        [notes addObject:[NSString stringWithFormat:@"读诊断：%@",
                          [info.diagnostics componentsJoinedByString:@" / "]]];
    }

    // --- 写（在临时副本上做，绝不动原文件） ---
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *tmpDir = NSTemporaryDirectory();
    NSString *tmp = [tmpDir stringByAppendingPathComponent:
                     [NSString stringWithFormat:@"mtprobe-%@.%@",
                      NSUUID.UUID.UUIDString, path.pathExtension]];
    NSError *copyErr = nil;
    if (![fm copyItemAtPath:path toPath:tmp error:&copyErr]) {
        [notes addObject:[NSString stringWithFormat:@"无法建立临时副本：%@", copyErr.localizedDescription]];
        result[@"note"] = [notes componentsJoinedByString:@"；"];
        return result;
    }

    NSString *probeTitle = @"探针标题-中文ABC";
    MTTagEdit *edit = [[MTTagEdit alloc] init];
    [edit setValue:probeTitle forField:MTTagFieldTitle];
    [edit setValue:@"探针艺术家" forField:MTTagFieldArtist];
    [edit setValue:@"7/12" forField:MTTagFieldTrack];

    MTWriteResult *writeResult = [self writeEdit:edit toFileAtPath:tmp];
    BOOL wrote = writeResult.success;
    if (wrote) {
        NSError *reErr = nil;
        MTAudioFileInfo *back = [self readFileAtPath:tmp error:&reErr];
        if (back && [back.tags.title isEqualToString:probeTitle]) {
            result[@"canWrite"] = @YES;
            if (back.tags.trackNumber.integerValue != 7 || back.tags.trackTotal.integerValue != 12) {
                [notes addObject:[NSString stringWithFormat:@"音轨号回读为 %@/%@（写入的是 7/12）",
                                  back.tags.trackNumber ?: @"-", back.tags.trackTotal ?: @"-"]];
            }
            result[@"containersAfterWrite"] = back.tagContainers;
        } else {
            [notes addObject:@"写入报成功但回读不到（标签容器未落盘）"];
        }
        if (writeResult.rejectedKeys.count) {
            [notes addObject:[NSString stringWithFormat:@"格式不支持的字段：%@",
                              [writeResult.rejectedKeys componentsJoinedByString:@","]]];
        }
    } else {
        [notes addObject:[NSString stringWithFormat:@"写失败：%@",
                          writeResult.error.localizedDescription ?: @"未知"]];
    }

    // --- 封面写 ---
    if (wrote) {
        // 1x1 PNG
        static const unsigned char kPNG[] = {
            0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A,0x00,0x00,0x00,0x0D,
            0x49,0x48,0x44,0x52,0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x01,
            0x08,0x02,0x00,0x00,0x00,0x90,0x77,0x53,0xDE,0x00,0x00,0x00,
            0x0C,0x49,0x44,0x41,0x54,0x08,0xD7,0x63,0xF8,0xCF,0xC0,0x00,
            0x00,0x03,0x01,0x01,0x00,0x18,0xDD,0x8D,0xB0,0x00,0x00,0x00,
            0x00,0x49,0x45,0x4E,0x44,0xAE,0x42,0x60,0x82
        };
        NSData *png = [NSData dataWithBytes:kPNG length:sizeof(kPNG)];
        MTTagEdit *artEdit = [[MTTagEdit alloc] init];
        artEdit.artworkMode = MTArtworkWriteModeReplace;
        artEdit.artworks = @[[[MTArtwork alloc] initWithData:png
                                                    mimeType:@"image/png"
                                                 description:@"probe"
                                                        type:MTPictureTypeFrontCover]];
        MTWriteResult *artResult = [self writeEdit:artEdit toFileAtPath:tmp];
        if (artResult.success) {
            NSError *rdErr = nil;
            NSArray<MTArtwork *> *arts = [self readArtworksAtPath:tmp error:&rdErr];
            if (arts.count > 0 && arts.firstObject.data.length == png.length) {
                result[@"canWriteArtwork"] = @YES;
            } else {
                [notes addObject:@"封面写入后回读为空"];
            }
        } else {
            [notes addObject:[NSString stringWithFormat:@"封面写失败：%@",
                              artResult.error.localizedDescription ?: @"未知"]];
        }
    }

    [fm removeItemAtPath:tmp error:nil];
    result[@"note"] = [notes componentsJoinedByString:@"；"];
    return result;
}

@end
