//
//  MTTagModels.mm
//  MacTagger — TagLib bridging layer (model implementations)
//

#import "MTTagModels.h"

NSErrorDomain const MTTagLibErrorDomain = @"com.lingluan.mactagger.taglib";

NSErrorUserInfoKey const MTArtworkLimitFormatKey = @"MTArtworkLimitFormat";
NSErrorUserInfoKey const MTArtworkLimitBytesKey  = @"MTArtworkLimitBytes";
NSErrorUserInfoKey const MTArtworkActualBytesKey = @"MTArtworkActualBytes";

NSString * const MTTagFieldTitle       = @"TITLE";
NSString * const MTTagFieldArtist      = @"ARTIST";
NSString * const MTTagFieldAlbumArtist = @"ALBUMARTIST";
NSString * const MTTagFieldAlbum       = @"ALBUM";
NSString * const MTTagFieldYear        = @"DATE";
NSString * const MTTagFieldTrack       = @"TRACKNUMBER";
NSString * const MTTagFieldDisc        = @"DISCNUMBER";
NSString * const MTTagFieldGenre       = @"GENRE";
NSString * const MTTagFieldComment     = @"COMMENT";
NSString * const MTTagFieldComposer    = @"COMPOSER";
NSString * const MTTagFieldLyricist    = @"LYRICIST";
NSString * const MTTagFieldLyrics      = @"LYRICS";

#pragma mark - MTArtwork

@implementation MTArtwork

- (instancetype)initWithData:(NSData *)data
                    mimeType:(NSString *)mimeType
                 description:(NSString *)description
                        type:(MTPictureType)type
{
    self = [super init];
    if (self) {
        _data = [data copy] ?: [NSData data];
        _mimeType = [mimeType copy] ?: [MTArtwork sniffMIMETypeForData:_data];
        _artworkDescription = [description copy];
        _type = type;
    }
    return self;
}

+ (NSString *)sniffMIMETypeForData:(NSData *)data
{
    if (data.length < 12) { return nil; }
    const unsigned char *b = (const unsigned char *)data.bytes;

    if (b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) { return @"image/jpeg"; }
    if (b[0] == 0x89 && b[1] == 'P' && b[2] == 'N' && b[3] == 'G') { return @"image/png"; }
    if (b[0] == 'G' && b[1] == 'I' && b[2] == 'F' && b[3] == '8') { return @"image/gif"; }
    if (b[0] == 'B' && b[1] == 'M') { return @"image/bmp"; }
    if (memcmp(b, "RIFF", 4) == 0 && memcmp(b + 8, "WEBP", 4) == 0) { return @"image/webp"; }
    // TIFF, little / big endian
    if ((b[0] == 'I' && b[1] == 'I' && b[2] == 0x2A && b[3] == 0x00) ||
        (b[0] == 'M' && b[1] == 'M' && b[2] == 0x00 && b[3] == 0x2A)) { return @"image/tiff"; }
    return nil;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<MTArtwork %@ %lu bytes type=%ld desc=%@>",
            self.mimeType ?: @"?", (unsigned long)self.data.length,
            (long)self.type, self.artworkDescription ?: @""];
}

@end

#pragma mark - MTAudioProperties

@implementation MTAudioProperties

- (instancetype)init
{
    self = [super init];
    if (self) {
        _codecName = @"";
        _containerName = @"";
    }
    return self;
}

- (NSString *)description
{
    return [NSString stringWithFormat:
            @"<MTAudioProperties %@/%@ %.3fs %ldkbps %ldHz %ldch %ldbit lossless=%@>",
            self.containerName, self.codecName,
            self.durationMilliseconds / 1000.0,
            (long)self.bitrateKbps, (long)self.sampleRate,
            (long)self.channels, (long)self.bitsPerSample,
            self.isLossless ? @"Y" : @"N"];
}

@end

#pragma mark - MTTags

@implementation MTTags

- (instancetype)init
{
    self = [super init];
    if (self) {
        _artworks = @[];
        _rawProperties = @{};
        _unsupportedProperties = @[];
    }
    return self;
}

@end

#pragma mark - MTAudioFileInfo

@implementation MTAudioFileInfo

- (instancetype)init
{
    self = [super init];
    if (self) {
        _path = @"";
        _tags = [[MTTags alloc] init];
        _audioProperties = [[MTAudioProperties alloc] init];
        _tagContainers = @[];
        _diagnostics = @[];
    }
    return self;
}

@end

#pragma mark - MTTagEdit

@implementation MTTagEdit
{
    NSMutableDictionary<NSString *, id> *_fields;      // NSString | NSNull
    NSMutableDictionary<NSString *, id> *_rawFields;   // NSArray<NSString*> | NSNull
    NSMutableArray<NSString *> *_order;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _fields = [NSMutableDictionary dictionary];
        _rawFields = [NSMutableDictionary dictionary];
        _order = [NSMutableArray array];
        _artworkMode = MTArtworkWriteModeKeep;
        _artworks = @[];
        _syncID3v1 = YES;
    }
    return self;
}

- (void)setValue:(NSString *)value forField:(NSString *)field
{
    if (field.length == 0) { return; }
    if (![_order containsObject:field]) { [_order addObject:field]; }
    _fields[field] = value ? (id)[value copy] : (id)[NSNull null];
}

- (BOOL)hasField:(NSString *)field
{
    return field.length > 0 && _fields[field] != nil;
}

- (id)valueForField:(NSString *)field
{
    return field.length > 0 ? _fields[field] : nil;
}

- (NSArray<NSString *> *)touchedFields
{
    return [_order copy];
}

- (void)setRawValues:(NSArray<NSString *> *)values forKey:(NSString *)key
{
    if (key.length == 0) { return; }
    NSString *upper = key.uppercaseString;
    _rawFields[upper] = values ? (id)[values copy] : (id)[NSNull null];
}

/// 供 .mm 内部使用（未在公开头文件中暴露，通过 valueForKey 取用）。
- (NSDictionary<NSString *, id> *)mt_rawFields
{
    return [_rawFields copy];
}

- (BOOL)isEmpty
{
    return _fields.count == 0
        && _rawFields.count == 0
        && self.artworkMode == MTArtworkWriteModeKeep;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<MTTagEdit fields=%@ raw=%@ artworkMode=%ld>",
            _fields, _rawFields, (long)self.artworkMode];
}

@end

#pragma mark - MTWriteResult

@implementation MTWriteResult

- (instancetype)init
{
    self = [super init];
    if (self) {
        _rejectedKeys = @[];
        _diagnostics = @[];
    }
    return self;
}

- (BOOL)isComplete
{
    return self.success && self.rejectedKeys.count == 0;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<MTWriteResult success=%@ rejected=%@ error=%@>",
            self.success ? @"YES" : @"NO", self.rejectedKeys,
            self.error.localizedDescription ?: @"-"];
}

@end

#pragma mark - MTFormatCapability

@implementation MTFormatCapability

- (instancetype)init
{
    self = [super init];
    if (self) {
        _fileExtension = @"";
        _tagContainer = @"";
    }
    return self;
}

@end
